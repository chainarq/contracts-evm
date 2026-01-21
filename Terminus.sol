// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

import "./lib/Types.sol";
import "./lib/Pauser.sol";
import "./lib/NativeWrap.sol";
import "./lib/Bytes.sol";
import "./lib/MultiCallable.sol";

import "./interfaces/IBridgeAdapter.sol";
import "./interfaces/ICodec.sol";
import "./interfaces/ITerminusEvents.sol";
import "./interfaces/IERC20U.sol";
import "./interfaces/ITerminusRelay.sol";

import "./SigVerifier.sol";
import "./Custodian.sol";
import "./Registries.sol";
import "./TerminusDelegate.sol";

contract Terminus is Initializable, ITerminusEvents, MultiCallable, SigVerifier, NativeWrap, ReentrancyGuardUpgradeable, Pauser {
    using SafeERC20Upgradeable for IERC20U;
    using ECDSA for bytes32;
    using Bytes for bytes;
    using Strings for address;
    using Strings for uint256;

    ITerminusRelay public tRelay;

    Registries public reg;

    // chainId => address mapping
    mapping(uint64 => address) public remotes;

    TerminusDelegate public terminusDelegate;

    address public terminusGasless;

    function initialize(address _nativeWrap, address _signer) external initializer {
        __Context_init();
        initSigVerifier(_signer);
        initNativeWrap(_nativeWrap);
        __ReentrancyGuard_init();
        initPauser();
    }

    modifier onlyRelay() {
        require(_msgSender() == address(tRelay), "only relay");
        _;
    }

    modifier onlyTerminusGasless() {
        require(_msgSender() == address(terminusGasless), "only t.gasless");
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
        _executeChecks(_execs.length, _src.amountIn, _dst.receiver, _src.deadline);

        Types.Execution memory _exec0 = _execs[0];

        bool isWU = _wrapUnwrap(_exec0, _src);

        if (isWU) return;

        (uint amountIn, address tokenIn) = _pullFundFromSender(_src);

        _execute(_execs, _src, _dst, amountIn, tokenIn, _msgSender());
    }

    // @notice: when executeGasless the msg.sender is the contract not the user
    // @notice: token amount is sent in to terminus by terminusGasless
    function executeGasless(Types.Execution[] memory _execs, Types.Source memory _src, Types.Destination memory _dst, uint _amountIn, address _tokenIn, address _sender) external payable whenNotPaused nonReentrant onlyTerminusGasless {
        _executeChecks(_execs.length, _src.amountIn, _dst.receiver, _src.deadline);

        _amountIn = _amountIn - _src.gaslessFees;

        IERC20U(_tokenIn).safeTransfer(reg.feeVault(), _src.gaslessFees);

        _execute(_execs, _src, _dst, _amountIn, _tokenIn, _sender);
    }

    function _execute(Types.Execution[] memory _execs, Types.Source memory _src, Types.Destination memory _dst, uint amountIn, address tokenIn, address _sender) private {
        require(amountIn > 0, "amount must > 0");

        Types.Execution memory _exec0 = _execs[0];

        bytes32 id = _computeId(_sender, _dst.receiver, _src.nonce);

        if (_execs.length > 1) {
            terminusDelegate.verify(_execs, _src);
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

        _processNextStep(id, _execs, _dst, tokenIn, nextToken, nextAmount, sendTokenAfter, _src.splitAddr, _sender);
    }

    function _executeChecks(uint _execsLen, uint _srcAmountIn, address _dstReceiver, uint _deadline) internal view {
        require(_execsLen > 0, "nop");
        require(_srcAmountIn > 0, "0 amount");
        require(_dstReceiver != address(0), "0 receiver");
        require(_deadline > block.timestamp, "deadline exceeded");
    }

    function executeReceivedMessage(Types.Message calldata _msg, address _executor, bool retrySwap) external payable onlyRelay whenNotPaused nonReentrant returns (bool) {
        uint remainingValue = msg.value;
        Types.Execution memory _exec0 = _msg.execs[0];

//        _debugCustodian(_msg.id, _exec0);
//        return true;

        (uint amountIn, address tokenIn) = _pullFundFromCustodian(_msg.id, _exec0);

//        revert(string(abi.encodePacked("t:", tokenIn.toHexString(), " a:", amountIn.toString())));
//        return true;

//        _msg.dst.receiver.call{value: ((_remainingValue > _bal) ? _bal : _remainingValue), gas: 50000}("");
//        revert(string(abi.encodePacked("t:", nextToken.toHexString(), " a:", nextAmount.toString())));

        // if amountIn is 0 after deducting fee, this contract keeps all amountIn as fee and
        // ends the execution
        if (amountIn == 0) {
            emit StepExecuted(_msg.id, 0, tokenIn);
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
                if (!success && !retrySwap) {
                    _sendToken(tokenIn, amountIn, _msg.dst.receiver, false);
                    emit SwapFailedRefunded(_msg.id, amountIn, tokenIn);
                    return _refundValueAndDone(remainingValue, _executor);
                } else if (!success && retrySwap) {
                    revert("SWAP_FAIL_RETRY");
                }
            }
        }

        uint consumedValue = _processNextStep(_msg.id, _msg.execs, _msg.dst, tokenIn, nextToken, nextAmount, sendTokenAfter, address(0), _msgSender());

        remainingValue = (remainingValue > consumedValue) ? (remainingValue - consumedValue) : 0;

        return _refundValueAndDone(remainingValue, _executor);
    }

    // the receiver of a swap is entitled to all the funds in the custodian. as long as someone can prove
    // that they are the receiver of a swap, they can always call the custodian contract and claim the
    // funds inside.
    function claimCustodianFund(address _srcSender, address _dstReceiver, uint64 _nonce, address _token) external whenNotPaused nonReentrant {
        require(_msgSender() == _dstReceiver, "only receiver can claim");
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
            (bool ok,) = _dstReceiver.call{value: nativeAmount}("");
            require(ok, "failed to send native");
        }
        emit CustodianFundClaimed(address(_custodian), _srcSender, _dstReceiver, erc20Amount, _token, nativeAmount);
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
            (bool ok,) = owner().call{value: _thisBalance()}("");
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
    // integrator's contract. TODO: maybe add the nonce maintenance in this contract.
    function _computeId(address _srcSender, address _dstReceiver, uint64 _nonce) private pure returns (bytes32) {
        // the main purpose of this id is to uniquely identify a user-swap.
        return keccak256(abi.encodePacked(_srcSender, _dstReceiver, _nonce));
    }

    function _processNextStep(bytes32 _id, Types.Execution[] memory _execs, Types.Destination memory _dst, address tokenIn, address _nextToken, uint _nextAmount, bool _sendTokenAfter, address _splitAddr, address _sender) private returns (uint consumedValue) {
        Types.Execution memory _exec0 = _execs[0];
        _execs = _removeFirst(_execs);

        // pay receiver if there is no more swaps or bridges
        if (_execs.length == 0 && _exec0.bridge.toChainId == 0) {
            consumedValue += _procDistFees(SwapType.Local, 0, address(0), tokenIn, _nextToken, _splitAddr, 0, _sender);

            if (_sendTokenAfter) _sendToken(_nextToken, _nextAmount, _dst.receiver, _dst.nativeOut);
            emit StepExecuted(_id, _nextAmount, _nextToken);
            return 0;
        }

        Types.Bridge memory _bridge = _exec0.bridge;

        // funds are bridged directly to the receiver if there are no subsequent executions on the destination chain.
        // otherwise, it's sent to a "custodian" contract addr to temporarily hold the fund before it is used for swapping.
        address _bridgeOutReceiver = _dst.receiver;

        bytes memory _bridgePayload = "";

        // if there are more execution steps left, pack them and send to the next chain
        if (_execs.length > 0) {
            address remote = remotes[_bridge.toChainId];
            require(remote != address(0), "remote not found");
            require(_bridge.dstGasCost > 0, "dst gas cant be 0");

            require(tRelay.remotes(_bridge.toChainId) != address(0), "rem relay is 0");

            _bridgeOutReceiver = _getCustodianAddr(_id, remote);
            _dst.custodian = _bridgeOutReceiver;

            consumedValue += _procDistFees(SwapType.Cross, _nextAmount, _nextToken, tokenIn, _nextToken, _splitAddr, _bridge.dstGasCost, _sender);

            uint _consVal;
            address _brgOutRec;

            (_bridgePayload, _brgOutRec, _consVal) = _processMsgBridge(_id, _bridge, _execs, _dst);

            _bridgeOutReceiver = _brgOutRec != address(0) ? _brgOutRec : _bridgeOutReceiver;

            consumedValue += _consVal;
        } else {
            consumedValue += _procDistFees(SwapType.Cross, 0, address(0), tokenIn, _nextToken, _splitAddr, 0, _sender);
        }

//        if (_execs.length == 0) {
//            IERC20U(_nextToken).safeTransfer(_dst.receiver, _nextAmount); //TODO: DEBUG - REMOVE
//            return 0; //TODO: DEBUG - REMOVE
//        }

        _bridgeSend(_bridge, _bridgeOutReceiver, _nextToken, _nextAmount, _bridgePayload);

        consumedValue += _bridge.nativeFee;

        emit StepExecuted(_id, _nextAmount, _nextToken);
    }

    function _procDistFees(SwapType _st, uint _stableAmt, address _stable, address _tokenIn, address _tokenOut, address _splitAddr, uint _dstGasCost, address _sender) internal returns (uint totalVal){
        return terminusDelegate.procDistFees{value: _thisBalance()}(_st, _stableAmt, _stable, _tokenIn, _tokenOut, _splitAddr, _dstGasCost, _sender);
    }

    function _processMsgBridge(bytes32 _id, Types.Bridge memory _bridge, Types.Execution[] memory _execs, Types.Destination memory _dst) internal returns (bytes memory _bridgePayload, address _bridgeOutReceiver, uint consumedValue) {
        return terminusDelegate.processMsgBridge{value: _thisBalance()}(_id, _bridge, _execs, _dst);
    }

    function _bridgeSend(Types.Bridge memory _bridge, address _receiver, address _token, uint _amount, bytes memory _payload) private {
        require(_thisBalance() >= _bridge.nativeFee, "bridge fee insufficient");
        IBridgeAdapter _bridgeAdp = reg.bridges(keccak256(bytes(_bridge.bridgeProvider)));
        IERC20U(_token).safeIncreaseAllowance(address(_bridgeAdp), _amount);
        _bridgeAdp.bridge{value: _bridge.nativeFee}(_bridge.toChainId, _receiver, _amount, _token, _bridge.bridgeParams, _payload);
    }

    function _refundValueAndDone(uint _remainingValue, address _executor) private returns (bool) {
        // chainarq executor would always send a set amount of native token when calling messagebus's executeMessage().
        // these tokens cover the fee introduced by chaining another message when there are more bridging.
        // refunding the unspent native tokens back to the executor
        uint _bal = address(this).balance;

        if (_remainingValue > 0 && _bal > 0) {
            _executor.call{value: ((_remainingValue > _bal) ? _bal : _remainingValue)}("");
            // require(ok, "failed to refund remaining native token");
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
            _tokenIn.safeTransferFrom(_msgSender(), address(this), _src.amountIn);
            uint balAfter = _tokenIn.balanceOf(address(this));
            amount = balAfter - balBefore;
        }

        return (amount, _src.tokenIn);
    }

    event CustodianDebug(bytes32 id, address custodianAddress, address token, uint256 balance);

    function _debugCustodian(bytes32 _id, Types.Execution memory _exec) private {
        address payable _cust = payable(_getCustodianAddr(_id, address(this)));

        emit CustodianDebug(_id, address(_cust), _exec.bridgeOutToken, IERC20U(_exec.bridgeOutToken).balanceOf(address(_cust)));
    }

    function _pullFundFromCustodian(bytes32 _id, Types.Execution memory _exec) private returns (uint amount, address token) {
        address payable _cust = payable(_getCustodianAddr(_id, address(this)));

        Custodian _custodian = (_cust.code.length == 0) ? new Custodian{salt: _id}(address(this)) : Custodian(_cust);

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

        if (erc20Amount >= _exec.bridgeOutMin) {
            _claimCustodianERC20(_custodian, _exec.bridgeOutToken, erc20Amount);
            amount = erc20Amount;
            token = _exec.bridgeOutToken;
        } else if (nativeAmount >= _exec.bridgeOutMin) {
            require(_exec.bridgeOutToken == nativeWrap, "bridgeOutToken not nativeWrap");
            _custodian.claim(address(0));
            depositNative(nativeAmount);
            amount = nativeAmount;
            token = _exec.bridgeOutToken;
        } else {
            revert(string(abi.encodePacked("MSG::ABORT:empty t:", _exec.bridgeOutToken.toHexString(), " a:", erc20Amount.toString(), " bOm:", _exec.bridgeOutMin.toString())));
        }
    }

    // since the call result of the transfer function in the custodian contract is not checked, we check
    // the before and after balance of this contract to ensure that the amount is indeed received.
    function _claimCustodianERC20(Custodian _custodian, address _token, uint _amount) private {
        uint balBefore = IERC20U(_token).balanceOf(address(this));
        _custodian.claim(_token);
        uint balAfter = IERC20U(_token).balanceOf(address(this));
        require(balAfter - balBefore >= _amount, "insufficient fund claimed");
    }

    function _getCustodianAddr(bytes32 _salt, address _deployer) private pure returns (address) {
        // how to predict a create2 address:
        // https://docs.soliditylang.org/en/v0.8.19/control-structures.html?highlight=create2#salted-contract-creations-create2
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), _deployer, _salt, keccak256(abi.encodePacked(type(Custodian).creationCode, abi.encode(_deployer)))));
        return address(uint160(uint(hash)));
    }

    function getCustodianAddr(bytes32 _salt, address _deployer) external view onlyOwner returns (address) {
        return _getCustodianAddr(_salt, _deployer);
    }

    function _executeSwap(ICodec.Swap memory _swap, uint _amountIn, address _tokenIn, address _dstReceiver) private returns (bool ok, uint amountOut, address tokenOut, bool sendTokenAfter) {
        IERC20U(_tokenIn).safeTransfer(address(terminusDelegate), _amountIn);

        return terminusDelegate.executeSwap(_swap, _amountIn, _tokenIn, _dstReceiver);
    }

    function _sendToken(address _token, uint _amount, address _receiver, bool _nativeOut) private {
        if (_nativeOut) {
            require(_token == nativeWrap, "token not nativeWrap");
            withdrawNative(_amount);
            (bool sent,) = _receiver.call{value: _amount}("");
            require(sent, "send fail");
        } else {
//            _safeTransfer(_token, _receiver, _amount, string(abi.encodePacked("T: _sendToken fail t:", _token.toHexString(), " a:", _amount.toString(), " r:", _receiver.toHexString(), " bal:", IERC20U(_token).balanceOf(address(this)).toString())));
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

    function _wrapUnwrap(Types.Execution memory _exec, Types.Source memory _src) internal returns (bool) {
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

            (bool ok,) = msg.sender.call{value: _src.amountIn}("");
            require(ok, "failed to send native");

            return true;
        }

        return false;
    }

    function _thisBalance() internal view returns (uint){
        return address(this).balance;
    }

    function setRegistries(address _addr) external onlyOwnerMulticall {
        reg = Registries(_addr);
        terminusDelegate.setRegistries(_addr);
    }

    function setTerminusRelay(address _addr) external onlyOwnerMulticall {
        tRelay = ITerminusRelay(payable(_addr));
        terminusDelegate.setTerminusRelay(_addr);
    }

    function setTerminusGasless(address _addr) external onlyOwnerMulticall {
        terminusGasless = _addr;
    }

    function setTerminusDelegate(address _addr) external onlyOwnerMulticall {
        terminusDelegate = TerminusDelegate(payable(_addr));
    }

    function setRemotes(uint64[] memory _chainIds, address[] memory _remotes) external onlyOwnerMulticall {
        require(_chainIds.length == _remotes.length, "remotes length mismatch");
        for (uint256 i = 0; i < _chainIds.length; i++) {
            remotes[_chainIds[i]] = _remotes[i];
        }
    }
}
