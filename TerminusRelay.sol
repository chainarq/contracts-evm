// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import "./lib/Types.sol";
import "./lib/TypeCasts.sol";
import "./lib/MessageReceiver.sol";
import {MailboxClient} from "./lib/MailboxClient.sol";
import "./lib/EnumerableMapExtended.sol";

import "./interfaces/IMessageBus.sol";
import "./interfaces/ILayerZeroReceiver.sol";
import "./interfaces/ILayerZeroEndpoint.sol";
import "./interfaces/IStargateRouter.sol";
import "./interfaces/IStargateReceiver.sol";
import "./interfaces/IERC20U.sol";
import "./interfaces/ITerminus.sol";
import "./interfaces/IMailbox.sol";
import "./interfaces/IMessageRecipient.sol";
import "./interfaces/ICircleMessageReceiver.sol";
import "./interfaces/ITerminusTlp.sol";

contract TerminusRelay is Initializable, MailboxClient, MessageReceiver, ILayerZeroReceiver, IStargateReceiver, IMessageRecipient {
    using EnumerableMapExtended for EnumerableMapExtended.UintToBytes32Map;
    using SafeERC20Upgradeable for IERC20U;
    using TypeCasts for address;
    using TypeCasts for bytes32;
    using TypeCasts for uint64;
    using Strings for uint32;

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

    ITerminus public terminus;
    ITerminusTlp public terminusTlp;

    mapping(address => bool) public supportedRouters;

    // messageId => payload hash
    mapping(bytes32 => bytes32) public msgQueue;

    EnumerableMapExtended.UintToBytes32Map internal _hlRemotes;

    // @notice DomainId to ChainId
    mapping(uint32 => uint64) public domToChId;
    // @notice ChainId to DomainId
    mapping(uint64 => uint32) public chToDomId;

    ICircleMessageReceiver public cctpMessageTransmitter;

    address public terminusDelegate;

    event MessageSent(bytes32 id, address remote, uint64 dstChainId, bytes payload, MessageVia via);
    event MessageExecuted(bytes32 id, uint timestamp);
    event MessageReceived(bytes32 id, address source, uint64 srcChainId, bytes payload, MessageVia via);
    event UnknownRemote(address source, uint64 srcChainId, bytes message, MessageVia via);
    event InvalidMessage(address source, uint64 srcChainId, bytes message, MessageVia via);
    event MsgIdExistsInQueue(address source, uint64 srcChainId, bytes message, MessageVia via);
    event InvalidCustodian(address source, uint64 srcChainId, bytes message, MessageVia via);
    event SgAmountReceivedInvalid(address source, uint64 srcChainId, bytes message, MessageVia via, uint _balance, uint _expected);

    /**
   * @dev Teleporter:  Emitted when a message is submited to be sent.
     */
    event TeleporterSendMessage(bytes32 destinationBlockchainID, address destinationAddress, address feeTokenAddress, uint256 feeAmount, uint256 requiredGasLimit, bytes32 messageId, bytes message);
    event TeleporterReceivedMessage(bytes32 sourceBlockchainID, address originSenderAddress, bytes payload);

//    event TeleporterDbgSent(uint64 dstChainId, bytes32 destinationBlockchainID, address destinationAddress);


    function initialize(address _messageBus) external initializer {
        __Context_init();
        _MailboxClient_initialize(address(0), address(0), _msgSender());
        initMessageReceiver(_messageBus);

        defaultGasQty = 5e5;
    }

    modifier onlyTerminus() {
        require(address(terminus) == _msgSender() || address(terminusDelegate) == _msgSender(), "only terminus");
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

    modifier onlyTerminusTlp(){
        require(_msgSender() == address(terminusTlp), "only tlp");
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

        terminus.executeReceivedMessage{value: msg.value}(_msg, _executor, false);

        emit MessageExecuted(_msg.id, block.timestamp);
        return ExecutionStatus.Success;
    }

    function sgReceive(uint16 _srcLzChainId, bytes memory _srcAddress, uint /*_nonce*/, address _token, uint amountLD, bytes memory _payload) override external {
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

        require(IERC20U(_token).balanceOf(address(this)) >= amountLD, "SG amount received invalid");

        try this._decodePayload(_payload) returns (Types.Message memory _decMsg) {
            _msg = _decMsg;
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

        if (msgQueue[_msg.id] != "") {
            emit MsgIdExistsInQueue(_msgSender(), lzToChId[_srcLzChainId], _payload, MessageVia.LayerZero);
            return;
        }

        emit MessageReceived(_msg.id, _remote, lzToChId[_srcLzChainId], _payload, MessageVia.LayerZero);

        msgQueue[_msg.id] = keccak256(_payload);

        IERC20U(_token).safeTransfer(_msg.dst.custodian, amountLD);
    }

    /* @dev: tolerant/nonblocking: will not revert when the conditions are not met, instead will not place the payload in to execution queue */
    function lzReceive(uint16 _srcLzChainId, bytes memory _srcAddress, uint64 /*_lzNonce*/, bytes memory _payload) public virtual override onlyLZEndpoint {
        address _remote;
        assembly ("memory-safe") {
            _remote := mload(add(_srcAddress, 20))
        }

        if (remotes[lzToChId[_srcLzChainId]] != _remote) {
            emit UnknownRemote(_remote, lzToChId[_srcLzChainId], _payload, MessageVia.LayerZero);
            return;
        }

        Types.Message memory _msg;

        try this._decodePayload(_payload) returns (Types.Message memory _decMsg) {
            _msg = _decMsg;
        } catch {
            emit InvalidMessage(_remote, lzToChId[_srcLzChainId], _payload, MessageVia.LayerZero);
            return;
        }

        if (_msg.execs.length == 0) {
            emit InvalidMessage(_remote, lzToChId[_srcLzChainId], _payload, MessageVia.LayerZero);
            return;
        }

        if (msgQueue[_msg.id] != "") {
            emit MsgIdExistsInQueue(_remote, lzToChId[_srcLzChainId], _payload, MessageVia.LayerZero);
            return;
        }

        msgQueue[_msg.id] = keccak256(_payload);

        emit MessageReceived(_msg.id, _remote, lzToChId[_srcLzChainId], _payload, MessageVia.LayerZero);
    }

    function _decodePayload(bytes memory _payload) external view onlySelf returns (Types.Message memory){
        return abi.decode((_payload), (Types.Message));
    }

    function messageFee(bytes calldata _message, uint64 _dstChainId, MessageVia _via) external view returns (uint nativeFee) {
        if (_via == MessageVia.Celer) {
            nativeFee = IMessageBus(messageBus).calcFee(_message);
        } else if (_via == MessageVia.LayerZero) {
            (nativeFee,) = lzEndpoint.estimateFees(chToLZId[_dstChainId], address(this), _message, false, abi.encodePacked(uint16(1), defaultGasQty));
        } else if (_via == MessageVia.Hyperlane) {
            nativeFee = _quoteDispatch(chToDomId[_dstChainId], remotes[_dstChainId].addressToBytes32(), _message);
        } else if (_via == MessageVia.Teleporter) {
            // TODO : (Not implemented yet)
            nativeFee = 0;
        }
    }

    function sendMessage(uint64 _dstChainId, bytes calldata _payload, uint _msgFee, uint _brgGasLimit, MessageVia _via) external payable onlyTerminus {
        require(remotes[_dstChainId] != address(0), "unknown remote");
        if (_via == MessageVia.Celer) {
            IMessageBus(messageBus).sendMessage{value: _msgFee}(remotes[_dstChainId], _dstChainId, _payload);
        } else if (_via == MessageVia.LayerZero) {
            bytes memory remoteAndLocalAddresses = abi.encodePacked(remotes[_dstChainId], address(this));
            lzEndpoint.send{value: _msgFee}(chToLZId[_dstChainId], remoteAndLocalAddresses, _payload, payable(address(terminus)), address(0), abi.encodePacked(uint16(1), defaultGasQty));
        } else if (_via == MessageVia.Hyperlane) {
            _dispatch(chToDomId[_dstChainId], remotes[_dstChainId].addressToBytes32(), _msgFee, _payload);
        } else if (_via == MessageVia.Teleporter) {
            terminusTlp.sendTeleporterMessage(_dstChainId, address(0), 0, _brgGasLimit, _payload);
        } else {
            revert("unknown msg provider");
        }

        Types.Message memory _msg = abi.decode((_payload), (Types.Message));

        emit MessageSent(_msg.id, remotes[_dstChainId], _dstChainId, _payload, _via);
    }

    /* Non blocking returns false if id already exists*/
    function tlpMsgQueue(bytes32 id, bytes32 msgHash) external onlyTerminusTlp returns (bool) {
        if (msgQueue[id] != "") return false;

        msgQueue[id] = msgHash;
        return true;
    }

    function processMessage(bytes32 id, bytes calldata _payload, bool retrySwap) external payable onlyExecutor {
        bytes32 _qHash = msgQueue[id];

        require(_qHash == keccak256(_payload), "MSG::NOTFOUND");

        terminus.executeReceivedMessage{value: msg.value}(abi.decode((_payload), (Types.Message)), _msgSender(), retrySwap);

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
        terminus = ITerminus(payable(_addr));
    }

    function setTerminusTlp(address _addr) external onlyOwnerMulticall {
        terminusTlp = ITerminusTlp(payable(_addr));
    }

    function setTerminusDelegate(address _addr) external onlyOwnerMulticall {
        terminusDelegate = _addr;
    }

    function setLZEndpoint(address _addr) external onlyOwnerMulticall {
        lzEndpoint = ILayerZeroEndpoint(_addr);
    }

    // Teleporter IDs, LZ IDs and Domain IDs mappings to ChainIDs
    function setLZDomainChainIds(uint16[] memory _lzIds, uint32[] memory _domIds, uint64[] memory _chainIds) external onlyOwnerMulticall {
        require(_lzIds.length == _chainIds.length, "lengths mismatch");
        require(_lzIds.length == _domIds.length, "lengths mismatch");
        for (uint i = 0; i < _lzIds.length; i++) {
            lzToChId[_lzIds[i]] = _chainIds[i];
            chToLZId[_chainIds[i]] = _lzIds[i];
            domToChId[_domIds[i]] = _chainIds[i];
            chToDomId[_chainIds[i]] = _domIds[i];
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

    /************** CIRCLE CCTP SECTION ***************/

    function circleReceiveMessage(bytes calldata message, bytes calldata attestation) external onlyExecutor {
        cctpMessageTransmitter.receiveMessage(message, attestation);
    }

    function setCircleMessageTransmitter(address _addr) external onlyOwnerMulticall {
        cctpMessageTransmitter = ICircleMessageReceiver(_addr);
    }

    /************** HYPERLANE SECTION ***************/

    function domains() external view returns (uint32[] memory) {
        return _hlRemotes.uint32Keys();
    }

    function hlRemotes(uint32 _domain) public view virtual returns (bytes32) {
        (, bytes32 _hlRemote) = _hlRemotes.tryGet(_domain);
        return _hlRemote;
    }

    function unenrollRemoteHLRemote(uint32 _domain) external virtual onlyOwnerMulticall {
        _unenrollRemoteHLRemote(_domain);
    }

    function enrollRemoteHLRemote(uint32 _domain, bytes32 _hlRemote) external virtual onlyOwnerMulticall {
        _enrollRemoteHLRemote(_domain, _hlRemote);
    }

    function enrollRemoteHLRemotes(uint32[] calldata _domains, address[] calldata _addresses) external virtual onlyOwnerMulticall {
        require(_domains.length == _addresses.length, "!length");
        uint256 length = _domains.length;
        for (uint256 i = 0; i < length; i += 1) {
            _enrollRemoteHLRemote(_domains[i], _addresses[i].addressToBytes32());
        }
    }

    function unenrollRemoteHLRemotes(uint32[] calldata _domains) external virtual onlyOwnerMulticall {uint256 length = _domains.length;
        for (uint256 i = 0; i < length; i += 1) {
            _unenrollRemoteHLRemote(_domains[i]);
        }
    }

    function _enrollRemoteHLRemote(uint32 _domain, bytes32 _address) internal virtual {
        _hlRemotes.set(_domain, _address);
    }

    function _unenrollRemoteHLRemote(uint32 _domain) internal virtual {
        require(_hlRemotes.remove(_domain), _domainNotFoundError(_domain));
    }

    function _isRemoteHLRemote(uint32 _domain, bytes32 _address) internal view returns (bool) {
        return hlRemotes(_domain) == _address;
    }

    function _mustHaveRemoteHLRemote(uint32 _domain) internal view returns (bytes32) {
        (bool contained, bytes32 _hlRemote) = _hlRemotes.tryGet(_domain);
        require(contained, _domainNotFoundError(_domain));
        return _hlRemote;
    }

    function _domainNotFoundError(uint32 _domain) internal pure returns (string memory) {
        return string.concat("No router enrolled for hlremote: ", _domain.toString());
    }

    function _dispatch(uint32 _destinationDomain, bytes memory _messageBody) internal virtual returns (bytes32) {
        return _dispatch(_destinationDomain, msg.value, _messageBody);
    }

    function _dispatch(uint32 _destinationDomain, uint256 _value, bytes memory _messageBody) internal virtual returns (bytes32) {
        bytes32 _hlRemote = _mustHaveRemoteHLRemote(_destinationDomain);
        return super._dispatch(_destinationDomain, _hlRemote, _value, _messageBody);
    }

    function _quoteDispatch(uint32 _destinationDomain, bytes memory _messageBody) internal view virtual returns (uint256) {
        bytes32 _hlRemote = _mustHaveRemoteHLRemote(_destinationDomain);
        return super._quoteDispatch(_destinationDomain, _hlRemote, _messageBody);
    }

    function handle(uint32 _origin, bytes32 _sender, bytes calldata _message) external payable onlyMailbox {
        _handle(_origin, _sender, _message);
    }

    function _handle(uint32 _srcDomainId, bytes32 _sender, bytes memory _payload) internal {
        address _remote = _sender.bytes32ToAddress();

        if (remotes[domToChId[_srcDomainId]] != _remote) {
            emit UnknownRemote(_remote, domToChId[_srcDomainId], _payload, MessageVia.Hyperlane);
            return;
        }

        Types.Message memory _msg;

        try this._decodePayload(_payload) returns (Types.Message memory _decMsg) {
            _msg = _decMsg;
        } catch {
            emit InvalidMessage(_remote, domToChId[_srcDomainId], _payload, MessageVia.Hyperlane);
            return;
        }

        if (_msg.execs.length == 0) {
            emit InvalidMessage(_remote, domToChId[_srcDomainId], _payload, MessageVia.Hyperlane);
            return;
        }

        if (msgQueue[_msg.id] != "") {
            emit MsgIdExistsInQueue(_remote, domToChId[_srcDomainId], _payload, MessageVia.Hyperlane);
            return;
        }

        msgQueue[_msg.id] = keccak256(_payload);

        emit MessageReceived(_msg.id, _remote, domToChId[_srcDomainId], _payload, MessageVia.Hyperlane);
    }

    /* function sendMessageTest(uint64 _dstChainId, bytes calldata _payload, uint msgFee, MessageVia _via) external payable onlyOwnerMulticall {
        require(remotes[_dstChainId] != address(0), "unknown remote");
        if (_via == MessageVia.Celer) {
            IMessageBus(messageBus).sendMessage{value: msgFee}(remotes[_dstChainId], _dstChainId, _payload);
        } else if (_via == MessageVia.LayerZero) {
            bytes memory remoteAndLocalAddresses = abi.encodePacked(remotes[_dstChainId], address(this));
            lzEndpoint.send{value: msgFee}(chToLZId[_dstChainId], remoteAndLocalAddresses, _payload, payable(address(terminus)), address(0), abi.encodePacked(uint16(1), defaultGasQty));
        } else if (_via == MessageVia.Hyperlane) {
            _dispatch(chToDomId[_dstChainId], remotes[_dstChainId].addressToBytes32(), msgFee, _payload);
        } else {
            revert("unknown msg provider");
        }

        Types.Message memory _msg = abi.decode((_payload), (Types.Message));

        emit MessageSent(_msg.id, remotes[_dstChainId], _dstChainId, _payload, _via);
    } */


    receive() external payable {}

    fallback() external payable {}

    uint256[50] private __gap;

}
