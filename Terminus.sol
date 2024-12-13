// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import "./lib/Types.sol";
import "./lib/Pauser.sol";
import "./lib/NativeWrap.sol";
import "./lib/Bytes.sol";
import "./lib/Multicallable.sol";

import "./interfaces/IBridgeAdapter.sol";
import "./interfaces/ICodec.sol";
import "./interfaces/ITerminusEvents.sol";
import "./interfaces/IERC20U.sol";

import "./SigVerifier.sol";
import "./Custodian.sol";
import "./Registries.sol";
import "./TerminusRelay.sol";


contract Terminus
is Initializable, ITerminusEvents, SigVerifier, Multicallable, NativeWrap, ReentrancyGuardUpgradeable, Pauser {
    using SafeERC20Upgradeable for IERC20U;
    using ECDSA for bytes32;
    using Bytes for bytes;

    TerminusRelay public tRelay;

    Registries public reg;

    // chainId => address mapping
    mapping(uint64 => address) public remotes;

    event BridgeMessageSent(bytes32 id, address remote, uint64 dstChainId, bytes payload, MessageVia via);

    function initialize(
        address _nativeWrap,
        address _signer
    ) external initializer {
        __Context_init();
        __Ownable_init();
        initPauser();
        initSigVerifier(_signer);
        initNativeWrap(_nativeWrap);
    }

    modifier onlyRelay() {
        require(_msgSender() == address(tRelay), "only relay");
        _;
    }

    /* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *
    * Core
    * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

    /**
     * @notice executes a swap-bridge combo and relays the next swap-bridge combo to the next chain (if any)
     * @param _execs contains info that tells this contract how to collect a part of the bridge token
     * received as fee and how to swap can be omitted on the source chain if there is no swaps to execute
     * @param _src info that is processed on the source chain. only required on the source chain and should not be populated on subsequent hops
     * @param _dst the receiving info of the entire operation
     */

    function execute(Types.Execution[] memory _execs, Types.Source memory _src, Types.Destination memory _dst) external payable whenNotPaused nonReentrant {
        require(_execs.length > 0, "nop");
        require(_src.amountIn > 0, "0 amount");
        require(_dst.receiver != address(0), "0 receiver");

        Types.Execution memory _exec0 = _execs[0];

        bool isWU = _wrapUnwrap(_exec0, _src);

        if (isWU) return;

        (uint amountIn, address tokenIn) = _pullFundFromSender(_src);

        _execute(_execs, _src, _dst, amountIn, tokenIn);

    }

    function _execute(Types.Execution[] memory _execs, Types.Source memory _src, Types.Destination memory _dst, uint amountIn, address tokenIn) private {
        require(amountIn > 0, "amount must > 0");

        Types.Execution memory _exec0 = _execs[0];

        bytes32 id = _computeId(msg.sender, _dst.receiver, _src.nonce);

        if (_execs.length > 1) {
            _verify(_execs, _src);
        }

        // process swaps if any
        uint nextAmount = amountIn;
        address nextToken = tokenIn;
        bool success = true;
        bool sendTokenAfter = true;

        for (uint i = 0; i < _exec0.swaps.length; i++) {
            ICodec.Swap memory _swap = _exec0.swaps[i];
            if (_swap.dex != address(0)) {
                (success, nextAmount, nextToken, sendTokenAfter) = _executeSwap(_swap, nextAmount, nextToken, _dst.receiver);
                require(success, "swap fail");
            }
        }

        _processNextStep(id, _execs, _dst, tokenIn, nextToken, nextAmount, sendTokenAfter);
    }

    function executeReceivedMessage(Types.Message calldata _msg, address _executor) external payable
    onlyRelay whenNotPaused nonReentrant
    returns (bool) {
        uint remainingValue = msg.value;
        Types.Execution memory _exec0 = _msg.execs[0];
        (uint amountIn, address tokenIn) = _pullFundFromCustodian(_msg.id, _exec0);
        // if amountIn is 0 after deducting fee, this contract keeps all amountIn as fee and
        // ends the execution
        if (amountIn == 0) {
            emit StepExecuted(_msg.id, 0, tokenIn);
            return _refundValueAndDone(remainingValue, _executor);
        }
        // refund immediately if receives bridge out fallback token
        if (tokenIn == _exec0.bridgeOutFallbackToken) {
            _sendToken(tokenIn, amountIn, _msg.dst.receiver, false);
            emit StepExecuted(_msg.id, amountIn, tokenIn);
            return _refundValueAndDone(remainingValue, _executor);
        }
        // process swap if any
        uint nextAmount = amountIn;
        address nextToken = tokenIn;
        bool success = true;
        bool sendTokenAfter = true;

        for (uint i = 0; i < _exec0.swaps.length; i++) {
            ICodec.Swap memory _swap = _exec0.swaps[i];

            if (_swap.dex != address(0)) {
                (success, nextAmount, nextToken, sendTokenAfter) = _executeSwap(_swap, nextAmount, nextToken, _msg.dst.receiver);
                // refund immediately if swap fails
                if (!success) {
                    _sendToken(tokenIn, amountIn, _msg.dst.receiver, false);
                    emit StepExecuted(_msg.id, amountIn, tokenIn);
                    return _refundValueAndDone(remainingValue, _executor);
                }
            }
        }

        uint consumedValue = _processNextStep(_msg.id, _msg.execs, _msg.dst, tokenIn, nextToken, nextAmount, sendTokenAfter);

        remainingValue = (remainingValue > consumedValue) ? (remainingValue - consumedValue) : 0;

        return _refundValueAndDone(remainingValue, _executor);
    }

    // the receiver of a swap is entitled to all the funds in the custodian. as long as someone can prove
    // that they are the receiver of a swap, they can always call the custodian contract and claim the
    // funds inside.
    function claimCustodianFund(address _srcSender, address _dstReceiver, uint64 _nonce, address _token) external whenNotPaused nonReentrant {
        require(msg.sender == _dstReceiver, "only receiver can claim");
        // id ensures that only the designated receiver of a swap can claim funds from the designated custodian of a swap
        bytes32 _id = _computeId(_srcSender, _dstReceiver, _nonce);

        address payable _cust = payable(_getCustodianAddr(_id, address(this)));

        Custodian _custodian = (_cust.code.length == 0) ? new Custodian{salt: _id}(address(this)) : Custodian(_cust);

        uint erc20Amount = IERC20U(_token).balanceOf(address(_custodian));
        uint nativeAmount = address(_custodian).balance;
        require(erc20Amount > 0 || nativeAmount > 0, "custodian is empty");
        // this claims both _token and native
        _claimCustodianERC20(_custodian, _token, erc20Amount);
        if (erc20Amount > 0) {
            IERC20U(_token).safeTransfer(_dstReceiver, erc20Amount);
        }
        if (nativeAmount > 0) {
            (bool ok,) = _dstReceiver.call{value: nativeAmount, gas: 50000}("");
            require(ok, "failed to send native");
        }
        emit CustodianFundClaimed(_dstReceiver, erc20Amount, _token, nativeAmount);
    }

    /**
     * @notice allows the owner to extract stuck funds from this contract and sent to _receiver
     * @dev since bridged funds are sent to the custodian contract, and fees are sent to the fee vault,
     * normally there should be no residue funds in this contract. but in case someone mistakenly
     * send tokens directly to this contract, this function can be used to access these funds.
     * @param _token the token to extract, use address(0) for native token
     */
    function rescueFund(address _token) external onlyOwner {
        if (_token == address(0)) {
            (bool ok,) = owner().call{value: address(this).balance}("");
            require(ok, "send native failed");
        } else {
            IERC20U(_token).safeTransfer(owner(), IERC20U(_token).balanceOf(address(this)));
        }
    }

    /* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *
     * Misc
     * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

    // encoding src sender into the id prevents the scenario where different senders can send funds to the the same receiver
    // causing the swap behavior to be non-deterministic. e.g. if src sender is not in id generation, an attacker can send
    // send a modified swap data as soon as they see the victim executes on the src chain. since the processing of messages
    // is asynchronous, the hacker's message can be executed first, accessing the fund inside the victim's custodian and
    // swapping it in some unfavorable ways.
    //
    // note that if the original tx sender is a contract, the integrator MUST ensure that they maintain a unique nonce so
    // that the same sender/receiver/nonce combo cannot be used twice. otherwise, the above attack is possible via the
    // integrator's contract.
    function _computeId(address _srcSender, address _dstReceiver, uint64 _nonce) private pure returns (bytes32) {
        // the main purpose of this id is to uniquely identify a user-swap.
        return keccak256(abi.encodePacked(_srcSender, _dstReceiver, _nonce));
    }

    function _checkFee(bool _cond, uint _fee, uint _checkAmt) internal view {
        require(_cond && (_checkAmt >= ((_fee * (1e4 - reg.feeSlippage())) / 1e4)), "insufficient fee amount");
    }

    function _processFee(SwapType _st, uint stableAmt, address _stable, address tokenIn, address tokenOut, bool sendToVault) internal returns (uint) {
        if (_msgSender() == address(tRelay)) return 0;
        uint _regDec;
        uint _brgDec;
        uint _stableConv = 0;

        if (_stable == reg.stable()) {
            _stableConv = stableAmt;
        } else if (stableAmt > 0 && _stable != address(0)) {
            _brgDec = IERC20U(_stable).decimals();
            _regDec = reg.stableDecimals();

            _stableConv = (_brgDec >= _regDec) ? (stableAmt / (10 ** (_brgDec - _regDec))) : (stableAmt * (10 ** (_regDec - _brgDec)));
        }

        uint _fee = reg.getFee(_st, _stableConv, _msgSender(), tokenIn, tokenOut);

        if (sendToVault) {
            uint _transfAmt = address(this).balance;
            (bool ok,) = reg.feeVault().call{value: _transfAmt}("");
            _checkFee(ok, _fee, _transfAmt);
        }

        return _fee;
    }

    function _processNextStep(bytes32 _id, Types.Execution[] memory _execs, Types.Destination memory _dst, address tokenIn, address _nextToken, uint _nextAmount, bool _sendTokenAfter) private returns (uint consumedValue) {
        Types.Execution memory _exec0 = _execs[0];
        _execs = _removeFirst(_execs);
        // pay receiver if there is no more swaps or bridges
        if (_execs.length == 0 && _exec0.bridge.toChainId == 0) {
            _processFee(SwapType.Local, 0, address(0), tokenIn, _nextToken, true);
            if (_sendTokenAfter) _sendToken(_nextToken, _nextAmount, _dst.receiver, _dst.nativeOut);
            emit StepExecuted(_id, _nextAmount, _nextToken);
            return 0;
        }

        Types.Bridge memory _bridge = _exec0.bridge;

        // funds are bridged directly to the receiver if there are no subsequent executions on the destination chain.
        // otherwise, it's sent to a "custodian" contract addr to temporarily hold the fund before it is used for swapping.
        address bridgeOutReceiver = _dst.receiver;

        uint protoFee;

        address _feeVault = reg.feeVault();

        bytes memory bridgePayload = "";

        // if there are more execution steps left, pack them and send to the next chain
        if (_execs.length > 0) {
            address remote = remotes[_bridge.toChainId];
            require(remote != address(0), "remote not found");
            require(_bridge.dstGasCost > 0, "dst gas cant be 0");

            require(tRelay.remotes(_bridge.toChainId) != address(0), "rem relay is 0");

            bridgeOutReceiver = _getCustodianAddr(_id, remote);
            _dst.custodian = bridgeOutReceiver;

            protoFee = _processFee((_exec0.swaps.length > 0) ? SwapType.SwapSrcDst : SwapType.SwapDst, _nextAmount, _nextToken, tokenIn, _nextToken, false);

            bytes memory message = abi.encode(Types.Message({id: _id, execs: _execs, dst: _dst}));

            if (keccak256(bytes(_bridge.bridgeProvider)) == keccak256(bytes("stargate"))) {
                bridgePayload = message;
                bridgeOutReceiver = tRelay.remotes(_bridge.toChainId);
                emit BridgeMessageSent(_id, bridgeOutReceiver, _bridge.toChainId, message, MessageVia.LayerZero);
            } else {
                uint _msgFee = tRelay.messageFee(message, _bridge.toChainId, MessageVia.LayerZero);
                tRelay.sendMessage{value: _msgFee}(_bridge.toChainId, message, _msgFee, MessageVia.LayerZero);
                consumedValue += _msgFee;
            }
        } else if (_exec0.swaps.length > 0) {
            protoFee = _processFee(SwapType.SwapSrc, 0, address(0), tokenIn, _nextToken, false);
        } else {
            protoFee = _processFee(SwapType.Direct, 0, address(0), tokenIn, _nextToken, false);
        }

        _bridgeSend(_bridge, bridgeOutReceiver, _nextToken, _nextAmount, bridgePayload);

        consumedValue += _bridge.nativeFee;

        if (_bridge.dstGasCost > 0) {
            (bool okA,) = _feeVault.call{value: _bridge.dstGasCost}("");
            require(okA, "insufficient dst gas amount");
            consumedValue += _bridge.dstGasCost;
        }

        //if contract balance is more than the remaining fee send remaining balance to vault to avoid leaving dust behind
        uint _feeSendAmt = address(this).balance > protoFee ? address(this).balance : protoFee;

        (bool okB,) = _feeVault.call{value: _feeSendAmt}("");
        _checkFee(okB, protoFee, _feeSendAmt);

        emit StepExecuted(_id, _nextAmount, _nextToken);
    }

    function _bridgeSend(Types.Bridge memory _bridge, address _receiver, address _token, uint _amount, bytes memory _payload) private {
        IBridgeAdapter _bridgeAdp = reg.bridges(keccak256(bytes(_bridge.bridgeProvider)));

        IERC20U(_token).safeIncreaseAllowance(address(_bridgeAdp), _amount);

        _bridgeAdp.bridge{value: _bridge.nativeFee}(_bridge.toChainId, _receiver, _amount, _token, _bridge.bridgeParams, _payload);
    }

    function _refundValueAndDone(uint _remainingValue, address _executor) private returns (bool) {
        // chainarq executor would always send a set amount of native token when calling messagebus's executeMessage().
        // these tokens cover the fee introduced by chaining another message when there are more bridging.
        // refunding the unspent native tokens back to the executor
        if (_remainingValue > 0) {
            (bool ok,) = _executor.call{value: _remainingValue, gas: 50000}("");
        }
        return true;
    }

    function _pullFundFromSender(Types.Source memory _src) private returns (uint amount, address token) {
        if (_src.nativeIn) {
            require(_src.tokenIn == nativeWrap, "tokenIn not nativeWrap");
            require(msg.value >= _src.amountIn, "not enough native");
            depositNative(_src.amountIn);
            amount = _src.amountIn;
        } else {
            // @notice: in case the token has a transfer tax, the amount transfered would not be same as the amount in
            IERC20U _tokenIn = IERC20U(_src.tokenIn);
            uint balBefore = _tokenIn.balanceOf(address(this));
            _tokenIn.safeTransferFrom(msg.sender, address(this), _src.amountIn);
            uint balAfter = _tokenIn.balanceOf(address(this));
            amount = balAfter - balBefore;
        }

        return (amount, _src.tokenIn);
    }

    function _pullFundFromCustodian(bytes32 _id, Types.Execution memory _exec) private returns (uint amount, address token) {

        address payable _cust = payable(_getCustodianAddr(_id, address(this)));

        Custodian _custodian = (_cust.code.length == 0) ? new Custodian{salt: _id}(address(this)) : Custodian(_cust);

        uint fallbackAmount;
        if (_exec.bridgeOutFallbackToken != address(0)) {
            fallbackAmount = IERC20U(_exec.bridgeOutFallbackToken).balanceOf(address(_custodian));
            // e.g. hToken/anyToken
        }
        uint erc20Amount = IERC20U(_exec.bridgeOutToken).balanceOf(address(_custodian));
        uint nativeAmount = address(_custodian).balance;

        // if the custodian does not have bridgeOutMin, we consider the transfer not arrived yet. in
        // this case we tell the msgbus to revert the outter tx using the MSG::ABORT: prefix and
        // our executor will retry sending this tx later.
        //
        // this bridgeOutMin is also a counter-measure to a DoS attack vector. if we assume the bridge
        // funds have arrived once we see a balance in the custodian, an attacker can deposit a small
        // amount of fund into the custodian and confuse this contract that the bridged fund has arrived.
        // this triggers the refund logic branch and thus denying the dst swap for the victim.
        // bridgeOutMin is determined by the server before sending out the transfer.
        // bridgeOutMin = R * bridgeAmountIn where R is an arbitrary ratio that we feel effective in
        // raising the attacker's attack cost.

        if (fallbackAmount > _exec.bridgeOutFallbackMin) {
            _claimCustodianERC20(_custodian, _exec.bridgeOutFallbackToken, fallbackAmount);
            amount = fallbackAmount;
            token = _exec.bridgeOutFallbackToken;
        } else if (erc20Amount > _exec.bridgeOutMin) {
            _claimCustodianERC20(_custodian, _exec.bridgeOutToken, erc20Amount);
            amount = erc20Amount;
            token = _exec.bridgeOutToken;
        } else if (nativeAmount > _exec.bridgeOutMin) {
            // no need to check before/after balance here since selfdestruct is guaranteed to
            // send all native tokens from the custodian to this contract.
            _custodian.claim(address(0), 0);
            require(_exec.bridgeOutToken == nativeWrap, "bridgeOutToken not nativeWrap");
            amount = nativeAmount;
            depositNative(amount);
            token = _exec.bridgeOutToken;
        } else {
            revert("MSG::ABORT:empty");
        }
    }

    // since the call result of the transfer function in the custodian contract is not checked, we check
    // the before and after balance of this contract to ensure that the amount is indeed received.
    function _claimCustodianERC20(Custodian _custodian, address _token, uint _amount) private {
        uint balBefore = IERC20U(_token).balanceOf(address(this));
        _custodian.claim(_token, _amount);
        uint balAfter = IERC20U(_token).balanceOf(address(this));
        require(balAfter - balBefore >= _amount, "insufficient fund claimed");
    }

    function _getCustodianAddr(bytes32 _salt, address _deployer) private pure returns (address) {
        // how to predict a create2 address:
        // https://docs.soliditylang.org/en/v0.8.19/control-structures.html?highlight=create2#salted-contract-creations-create2
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                _deployer,
                _salt,
                keccak256(abi.encodePacked(type(Custodian).creationCode, abi.encode(_deployer)))
            )
        );
        return address(uint160(uint(hash)));
    }

    function getCustodianAddr(bytes32 _salt, address _deployer) external view onlyOwner returns (address){
        return _getCustodianAddr(_salt, _deployer);
    }


    function _executeSwap(ICodec.Swap memory _swap, uint _amountIn, address _tokenIn, address _dstReceiver) private returns (bool ok, uint amountOut, address tokenOut, bool sendTokenAfter) {
        if (_swap.dex == address(0)) {
            // nop swap
            return (true, _amountIn, _tokenIn, true);
        }
        bytes4 selector = bytes4(_swap.data);

        ICodec codec = reg.getCodec(_swap.dex, selector);
        address tokenIn;
        (, tokenIn, tokenOut) = codec.decodeCalldata(_swap);
        require(tokenIn == _tokenIn, "swap info mismatch");

        (,,bool exclusiveDex,,) = reg.tokens(tokenOut);

        address _receiver = exclusiveDex ? _dstReceiver : address(this);
        sendTokenAfter = !exclusiveDex;

        bytes memory data = codec.encodeCalldataWithOverride(_swap.data, _amountIn, _receiver);
        IERC20U(tokenIn).forceApprove(_swap.dex, _amountIn);
        uint balBefore = IERC20U(tokenOut).balanceOf(_receiver);
        (bool success,) = _swap.dex.call(data);
        if (!success) {
            return (false, 0, tokenOut, true);
        }
        uint balAfter = IERC20U(tokenOut).balanceOf(_receiver);
        return (true, balAfter - balBefore, tokenOut, sendTokenAfter);
    }

    function _sendToken(address _token, uint _amount, address _receiver, bool _nativeOut) private {
        if (_nativeOut) {
            require(_token == nativeWrap, "token is not nativeWrap");
            withdrawNative(_amount);
            (bool sent,) = _receiver.call{value: _amount, gas: 50000}("");
            require(sent, "send fail");
        } else {
            IERC20U(_token).safeTransfer(_receiver, _amount);
        }
    }

    function _removeFirst(Types.Execution[] memory _execs) private pure returns (Types.Execution[] memory rest) {
        require(_execs.length > 0, "empty execs");
        rest = new Types.Execution[](_execs.length - 1);
        for (uint i = 1; i < _execs.length; i++) {
            rest[i - 1] = _execs[i];
        }
    }

    function _verify(Types.Execution[] memory _execs, Types.Source memory _src) private view {
        require(_src.deadline > block.timestamp, "deadline exceeded");
        bytes memory data = abi.encodePacked(
            "terminus swap",
            uint64(block.chainid),
            _src.amountIn,
            _src.tokenIn,
            _src.deadline
        );

        for (uint i = 1; i < _execs.length; i++) {
            Types.Execution memory _ex = _execs[i];
            Types.Bridge memory prevBridge = _execs[i - 1].bridge;
            require(_ex.bridgeOutToken != address(0) && _ex.bridgeOutMin > 0, "invalid exec");
            require(_ex.bridgeOutFallbackToken == address(0) || (_ex.bridgeOutFallbackMin > 0), "invalid fallback");
            // bridged tokens and the chain id of the execution are encoded in the sig data so that
            // no malicious user can temper the fee they have to pay on any execution steps
            bytes memory execData = abi.encodePacked(
                prevBridge.toChainId,
                prevBridge.dstGasCost,
                _ex.bridgeOutToken,
                _ex.bridgeOutFallbackToken,
                // native fee also needs to be agreed upon by chainarq for any subsequent bridge
                // since the fee is provided by chainarq's executor
                _ex.bridge.nativeFee
            );
            data = data.concat(execData);
        }

        bytes32 signHash = keccak256(data).toEthSignedMessageHash();
        verifySig(signHash, _src.quoteSig);
    }

    function _wrapUnwrap(Types.Execution memory _exec, Types.Source memory _src) internal returns (bool){
        if (_exec.swaps.length == 0) return false;

        if (_exec.swaps[0].dex == nativeWrap && _src.tokenIn == NATIVE) {
            require(msg.value >= _src.amountIn, "not enough native");

            depositNative(_src.amountIn);

            IERC20U(nativeWrap).safeTransfer(msg.sender, _src.amountIn);

            return true;
        } else if (_exec.swaps[0].dex == NATIVE && _src.tokenIn == nativeWrap) {
            require(IERC20U(nativeWrap).balanceOf(msg.sender) >= _src.amountIn, "insufficient wrapped amount");

            IERC20U(nativeWrap).safeTransferFrom(msg.sender, address(this), _src.amountIn);

            withdrawNative(_src.amountIn);

            (bool ok,) = msg.sender.call{value: _src.amountIn, gas: 50000}("");
            require(ok, "failed to send native");

            return true;
        }

        return false;
    }

    function setRegistries(address _addr) external onlyOwnerMulticall {
        reg = Registries(_addr);
    }

    function setTerminusRelay(address _addr) external onlyOwnerMulticall {
        tRelay = TerminusRelay(payable(_addr));
    }

    function setRemotes(uint64[] memory _chainIds, address[] memory _remotes) external onlyOwnerMulticall {
        require(_chainIds.length == _remotes.length, "remotes length mismatch");
        for (uint256 i = 0; i < _chainIds.length; i++) {
            remotes[_chainIds[i]] = _remotes[i];
        }
    }
}
