// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "./lib/Types.sol";
import "./lib/MessageReceiver.sol";
import "./lib/Multicallable.sol";

import "./interfaces/IMessageBus.sol";
import "./interfaces/ILayerZeroReceiver.sol";
import "./interfaces/ILayerZeroEndpoint.sol";
import "./interfaces/IStargateRouter.sol";
import "./interfaces/IStargateReceiver.sol";
import "./interfaces/IERC20U.sol";

import "./Terminus.sol";

contract TerminusRelay is Initializable, Multicallable, MessageReceiver, ILayerZeroReceiver, IStargateReceiver, ReentrancyGuardUpgradeable {
    using SafeERC20Upgradeable for IERC20U;

    // @notice: the addresses allowed to execute messages
    mapping(address => bool) public executors;

    // @notice LayerZeroChainId to ChainId
    mapping(uint16 => uint64) public lzToChId;
    // @notice ChainId to LayerZeroChainId
    mapping(uint64 => uint16) public chToLZId;

    // @notice Default gas quantity for LayerZero
    uint public defaultGasQty;

    // remote Relays - chainId => address mapping
    mapping(uint64 => address) public remotes;

    // remote StargateAdapters - chainId => address mapping
    mapping(uint64 => address) public remoteAdapters;

    ILayerZeroEndpoint public lzEndpoint;

    Terminus public terminus;

    mapping(address => bool) public supportedRouters;

    // messageId => payload hash
    mapping(bytes32 => bytes32) public msgQueue;

    event MessageSent(bytes32 id, address remote, uint64 dstChainId, bytes payload, MessageVia via);
    event MessageExecuted(bytes32 id, uint timestamp);
    event MessageReceived(bytes32 id, address source, uint64 srcChainId, bytes payload, MessageVia via);
    event UnknownRemote(address source, uint64 srcChainId, bytes message, MessageVia via);
    event InvalidMessage(address source, uint64 srcChainId, bytes message, MessageVia via);
    event InvalidCustodian(address source, uint64 srcChainId, bytes message, MessageVia via);

    function initialize(address _messageBus) external initializer {
        __Context_init();
        __Ownable_init();
        initMessageReceiver(_messageBus);

        defaultGasQty = 5e5;
    }

    modifier onlyTerminus() {
        require(_msgSender() == address(terminus), "only terminus");
        _;
    }

    modifier onlyRemoteRelay(uint64 _chainId, address _remote) {
        require(remotes[_chainId] == _remote, "unknown remote");
        _;
    }

    modifier onlyExecutor(){
        require(executors[_msgSender()], "only executor");
        _;
    }

    modifier onlyLZEndpoint(){
        require(_msgSender() == address(lzEndpoint), "LzApp: invalid endpoint caller");
        _;
    }

    modifier onlySelf(){
        require(_msgSender() == address(this), "only self");
        _;
    }

    /**
    * @notice called by cBridge MessageBus. processes the execution info and carry on the executions
     * @param _message the message that contains the remaining swap-bridge combos to be executed
     * @return executionStatus always success if no reverts to let the MessageBus know that the message is processed
     */
    function executeMessage(address _sender, uint64 _srcChainId, bytes memory _message, address _executor) external payable override
    onlyMessageBus onlyRemoteRelay(_srcChainId, _sender) nonReentrant
    returns (ExecutionStatus) {
        Types.Message memory _msg = abi.decode((_message), (Types.Message));
        require(_msg.execs.length > 0, "nop");

        terminus.executeReceivedMessage{value: msg.value}(_msg, _executor);

        emit MessageExecuted(_msg.id, block.timestamp);
        return ExecutionStatus.Success;
    }

    function sgReceive(uint16 _srcLzChainId, bytes memory _srcAddress, uint _nonce, address _token, uint amountLD, bytes memory _payload) override external {
        require(supportedRouters[_msgSender()], "only sg");

        address _remote;
        assembly ("memory-safe") {
            _remote := mload(add(_srcAddress, 20))
        }

        if (remoteAdapters[lzToChId[_srcLzChainId]] != _remote) {
            emit UnknownRemote(_remote, lzToChId[_srcLzChainId], _payload, MessageVia.LayerZero);
            return;
        }

        Types.Message memory _msg;

        try this._decodePayload(_payload){
            _msg = this._decodePayload(_payload);
        } catch {
            emit InvalidMessage(_msgSender(), lzToChId[_srcLzChainId], _payload, MessageVia.LayerZero);
            return;
        }

        if (_msg.execs.length == 0) {
            emit InvalidMessage(_msgSender(), lzToChId[_srcLzChainId], _payload, MessageVia.LayerZero);
            return;
        }

        if (_msg.dst.custodian == address(0)) {
            emit InvalidCustodian(_msgSender(), lzToChId[_srcLzChainId], _payload, MessageVia.LayerZero);
            return;
        }

        emit MessageReceived(_msg.id, _remote, lzToChId[_srcLzChainId], _payload, MessageVia.LayerZero);

        msgQueue[_msg.id] = keccak256(_payload);

        IERC20U(_token).safeTransfer(_msg.dst.custodian, amountLD);
    }

    /* @dev: tolerant/nonblocking: will not revert when the conditions are not met, instead will not place the payload in to execution queue */
    function lzReceive(uint16 _srcLzChainId, bytes memory _srcAddress, uint64 _lzNonce, bytes memory _payload) public virtual override onlyLZEndpoint {
        address _remote;
        assembly ("memory-safe") {
            _remote := mload(add(_srcAddress, 20))
        }

        if (remotes[lzToChId[_srcLzChainId]] != _remote) {
            emit UnknownRemote(_remote, lzToChId[_srcLzChainId], _payload, MessageVia.LayerZero);
            return;
        }

        Types.Message memory _msg;

        try this._decodePayload(_payload){
            _msg = this._decodePayload(_payload);
        } catch {
            emit InvalidMessage(_remote, lzToChId[_srcLzChainId], _payload, MessageVia.LayerZero);
            return;
        }

        if (_msg.execs.length == 0) {
            emit InvalidMessage(_remote, lzToChId[_srcLzChainId], _payload, MessageVia.LayerZero);
            return;
        }

        msgQueue[_msg.id] = keccak256(_payload);

        emit MessageReceived(_msg.id, _remote, lzToChId[_srcLzChainId], _payload, MessageVia.LayerZero);
    }

    function _decodePayload(bytes memory _payload) external view onlySelf returns (Types.Message memory){
        return abi.decode((_payload), (Types.Message));
    }

    function messageFee(bytes calldata message, uint64 dstChainId, MessageVia _via) external view returns (uint nativeFee) {
        if (_via == MessageVia.Celer) {
            nativeFee = IMessageBus(messageBus).calcFee(message);
        } else if (_via == MessageVia.LayerZero) {
            (nativeFee,) = lzEndpoint.estimateFees(chToLZId[dstChainId], address(this), message, false, abi.encodePacked(uint16(1), defaultGasQty));
        }
    }

    function sendMessage(uint64 dstChainId, bytes calldata _payload, uint msgFee, MessageVia _via) external payable onlyTerminus {
        require(remotes[dstChainId] != address(0), "unknown remote");
        if (_via == MessageVia.Celer) {
            IMessageBus(messageBus).sendMessage{value: msgFee}(remotes[dstChainId], dstChainId, _payload);
        } else if (_via == MessageVia.LayerZero) {
            bytes memory remoteAndLocalAddresses = abi.encodePacked(remotes[dstChainId], address(this));
            lzEndpoint.send{value: msgFee}(chToLZId[dstChainId], remoteAndLocalAddresses, _payload, payable(address(terminus)), address(0), abi.encodePacked(uint16(1), defaultGasQty));
        } else {
            revert("unknown msg provider");
        }

        Types.Message memory _msg = abi.decode((_payload), (Types.Message));

        emit MessageSent(_msg.id, remotes[dstChainId], dstChainId, _payload, _via);
    }

    function processMessage(bytes32 id, bytes calldata _payload) external onlyExecutor {
        bytes32 _qHash = msgQueue[id];

        require(_qHash == keccak256(_payload), "MSG::NOTFOUND");

        terminus.executeReceivedMessage(abi.decode((_payload), (Types.Message)), _msgSender());

        delete msgQueue[id];

        emit MessageExecuted(id, block.timestamp);
    }

    function setRemoteRelays(uint64[] memory _chainIds, address[] memory _remotes) external onlyOwnerMulticall {
        require(_chainIds.length == _remotes.length, "remotes length mismatch");
        for (uint256 i = 0; i < _chainIds.length; i++) {
            remotes[_chainIds[i]] = _remotes[i];
        }
    }

    function setRemoteAdapters(uint64[] memory _chainIds, address[] memory _remotes) external onlyOwnerMulticall {
        require(_chainIds.length == _remotes.length, "remotes length mismatch");
        for (uint256 i = 0; i < _chainIds.length; i++) {
            remoteAdapters[_chainIds[i]] = _remotes[i];
        }
    }

    function setTerminus(address _addr) external onlyOwnerMulticall {
        terminus = Terminus(payable(_addr));
    }

    function setLZEndpoint(address _addr) external onlyOwnerMulticall {
        lzEndpoint = ILayerZeroEndpoint(_addr);
    }

    function setLZChainIds(uint16[] memory _lzIds, uint64[] memory _chainIds) external onlyOwnerMulticall {
        require(_lzIds.length == _chainIds.length, "lengths mismatch");
        for (uint i = 0; i < _lzIds.length; i++) {
            lzToChId[_lzIds[i]] = _chainIds[i];
            chToLZId[_chainIds[i]] = _lzIds[i];
        }
    }

    function setDefaultGasQty(uint _qty) external onlyOwnerMulticall {
        defaultGasQty = _qty;
    }

    function forceResumeReceive(uint64 _srcChainId) external onlyOwner {
        bytes memory _srcAddr = abi.encodePacked(address(this), remotes[_srcChainId]);

        lzEndpoint.forceResumeReceive(chToLZId[_srcChainId], _srcAddr);
    }

    function rescueFund(address _token) external onlyOwner {
        if (_token == address(0)) {
            (bool ok,) = owner().call{value: address(this).balance}("");
            require(ok, "send native failed");
        } else {
            IERC20U(_token).safeTransfer(owner(), IERC20U(_token).balanceOf(address(this)));
        }
    }

    function setExecutors(address[] memory _addrs, bool _allowed) external onlyOwnerMulticall {
        for (uint i = 0; i < _addrs.length; i++) {
            executors[_addrs[i]] = _allowed;
        }
    }

    function setSupportedRouters(address[] memory _routers, bool _enabled) public onlyOwnerMulticall {
        for (uint i = 0; i < _routers.length; i++) {
            supportedRouters[_routers[i]] = _enabled;
        }
    }


    receive() external payable {}

    fallback() external payable {}
}
