// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

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


contract TerminusDelegate is Initializable, ITerminusEvents, MultiCallable, SigVerifier, NativeWrap, ReentrancyGuardUpgradeable, Pauser {
    using SafeERC20Upgradeable for IERC20U;
    using ECDSA for bytes32;
    using Bytes for bytes;

    ITerminusRelay public tRelay;

    Registries public reg;

    address public terminus;

    event BridgeMessageSent(bytes32 id, address remote, uint64 dstChainId, bytes payload, MessageVia via);

    modifier onlyTerminus() {
        require(_msgSender() == address(terminus), "only terminus");
        _;
    }

    modifier isOwnTermMult() {
        require(owner() == _msgSender() || multicall == _msgSender() || address(terminus) == _msgSender(), "only owner / terminus / mcall");
        _;
    }

    function initialize(address _nativeWrap, address _signer) external initializer {
        __Context_init();
        initSigVerifier(_signer);
        initNativeWrap(_nativeWrap);
        __ReentrancyGuard_init();
        initPauser();
    }

    function executeSwap(ICodec.Swap memory _swap, uint _amountIn, address _tokenIn, address _dstReceiver) external onlyTerminus returns (bool ok, uint amountOut, address tokenOut, bool sendTokenAfter) {
        if (_swap.dex == address(0)) {
            // nop swap
            return (true, _amountIn, _tokenIn, true);
        }
        bytes4 selector = bytes4(_swap.data);

        ICodec codec = reg.getCodec(_swap.dex, selector);
        address tokenIn;
        (, tokenIn, tokenOut) = codec.decodeCalldata(_swap);
        require(tokenIn == _tokenIn, "swap info mismatch");

        (, , bool exclusiveDex, ,) = reg.tokens(tokenOut);

        address _receiver = exclusiveDex ? _dstReceiver : address(this);
        sendTokenAfter = !exclusiveDex;

        bytes memory data = codec.encodeCalldataWithOverride(_swap.data, _amountIn, _receiver);
        IERC20U(tokenIn).forceApprove(_swap.dex, _amountIn);
        uint balBefore = IERC20U(tokenOut).balanceOf(_receiver);
        (bool success,) = _swap.dex.call(data);
        if (!success) {
            IERC20U(_tokenIn).safeTransfer(address(terminus), _amountIn);
            return (false, 0, tokenOut, true);
        }
        uint balAfter = IERC20U(tokenOut).balanceOf(_receiver);

        IERC20U(tokenOut).safeTransfer(address(terminus), (balAfter - balBefore));
        
        IERC20U(tokenIn).forceApprove(_swap.dex, 0);

        return (true, (balAfter - balBefore), tokenOut, sendTokenAfter);
    }

    function processMsgBridge(bytes32 _id, Types.Bridge memory _bridge, Types.Execution[] memory _execs, Types.Destination memory _dst) external payable onlyTerminus nonReentrant returns (bytes memory _bridgePayload, address _bridgeOutReceiver, uint consumedValue) {
        bytes memory message = abi.encode(Types.Message({id: _id, execs: _execs, dst: _dst}));

        _bridgePayload = "";

        bytes32 _brigProvKec = keccak256(bytes(_bridge.bridgeProvider));
        bytes32 _sgKec = keccak256(bytes("stargate"));
// bytes32 _sgV2Kec = keccak256(bytes("stargatev2"));
        bytes32 _arqKec = keccak256(bytes("arq"));
        bytes32 _icttKec = keccak256(bytes("ictt"));

        if (_brigProvKec == _sgKec) {
            _bridgePayload = message;
            _bridgeOutReceiver = tRelay.remotes(_bridge.toChainId);
            emit BridgeMessageSent(_id, _bridgeOutReceiver, _bridge.toChainId, message, MessageVia.LayerZero);
        } else {
            MessageVia _via = MessageVia.LayerZero;
            if (_brigProvKec == _arqKec) {
                _via = MessageVia.Hyperlane;
            } else if (_brigProvKec == _icttKec) {
                _via = MessageVia.Teleporter;
            }

            uint _msgFee = tRelay.messageFee(message, _bridge.toChainId, _via);
            tRelay.sendMessage{value: _msgFee}(_bridge.toChainId, message, _msgFee, _bridge.bridgeGasLimit, _via);
            consumedValue += _msgFee;
        }

        terminus.call{value: _thisBalance()}("");
    }

    function procDistFees(SwapType _st, uint _stableAmt, address _stable, address _tokenIn, address _tokenOut, address _splitAddr, uint _dstGasCost, address _sender) external payable onlyTerminus nonReentrant returns (uint totalVal){
        (uint _fee, uint _splitFee) = reg.processFee(_sender, _st, _stableAmt, _stable, _tokenIn, _tokenOut, _splitAddr);
        if ((_fee + _splitFee) > 0) {
            reg.distributeFees{value: (_fee + _splitFee)}(_fee, _splitFee, _splitAddr);
            totalVal += (_fee + _splitFee);
        }
        if (_dstGasCost > 0  && _sender != address(tRelay)) {
            (bool _ok,) = reg.feeVault().call{value: _dstGasCost}("");
            require(_ok, "feeVault send failed");
            totalVal += _dstGasCost;
        }

        terminus.call{value: _thisBalance()}("");
    }

    function verify(Types.Execution[] memory _execs, Types.Source memory _src) external view onlyTerminus {
        require(_src.deadline > block.timestamp, "deadline exceeded");
        bytes memory data = abi.encodePacked("terminus swap", uint64(block.chainid), _src.amountIn, _src.tokenIn, _src.deadline);

        for (uint i = 1; i < _execs.length; i++) {
            Types.Execution memory _ex = _execs[i];
            Types.Bridge memory prevBridge = _execs[i - 1].bridge;
            require(_ex.bridgeOutToken != address(0) && _ex.bridgeOutMin > 0, "invalid exec");
            // bridged tokens and the chain id of the execution are encoded in the sig data so that
            // no malicious user can temper the fee they have to pay on any execution steps
            bytes memory execData = abi.encodePacked(
                prevBridge.toChainId,
                prevBridge.dstGasCost,
                _ex.bridgeOutToken,
                // native fee also needs to be agreed upon by chainarq for any subsequent bridge
                // since the fee is provided by chainarq's executor
                _ex.bridge.nativeFee
            );
            data = data.concat(execData);
        }

        bytes32 signHash = keccak256(data).toEthSignedMessageHash();
        verifySig(signHash, _src.quoteSig);
    }

    function _thisBalance() internal view returns (uint){
        return address(this).balance;
    }

    function setTerminus(address _addr) external onlyOwnerMulticall {
        terminus = _addr;
    }

    function setRegistries(address _addr) external isOwnTermMult {
        reg = Registries(_addr);
    }

    function setTerminusRelay(address _addr) external isOwnTermMult {
        tRelay = ITerminusRelay(payable(_addr));
    }
}
