// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "./lib/Types.sol";

import "./interfaces/IERC20U.sol";
import "./interfaces/ITerminus.sol";
import "./interfaces/ITerminusRelay.sol";

import {MultiCallable} from "./lib/MultiCallable.sol";


import "../avalabs/teleporter/ITeleporterMessenger.sol";
import {ITeleporterReceiver} from "../avalabs/teleporter/ITeleporterReceiver.sol";
import {ITerminusEvents} from "./interfaces/ITerminusEvents.sol";

contract TerminusTlp is Initializable, MultiCallable, ReentrancyGuardUpgradeable, ITeleporterReceiver {
    using SafeERC20Upgradeable for IERC20U;

    // @notice: the addresses allowed to execute messages
    mapping(address => bool) public executors;

    // remote Tlps - chainId => address mapping
    mapping(uint64 => address) public remotes;

    // @notice Teleporter blockchainId to ChainId
    mapping(bytes32 => uint64) public blkToChId;
    // @notice Teleporter ChainId to blockchainId
    mapping(uint64 => bytes32) public chToblkId;

    ITerminusRelay public tRelay;
    address public terminusDelegate;
    ITerminus public terminus;

    ITeleporterMessenger public teleporterMessenger;

    event MessageSent(bytes32 id, address remote, uint64 dstChainId, bytes payload, MessageVia via);
    event MessageExecuted(bytes32 id, uint timestamp);
    event MessageReceived(bytes32 id, address source, uint64 srcChainId, bytes payload, MessageVia via);
    event UnknownRemote(address source, uint64 srcChainId, bytes message, MessageVia via);
    event InvalidMessage(address source, uint64 srcChainId, bytes message, MessageVia via);
    event InvalidCustodian(address source, uint64 srcChainId, bytes message, MessageVia via);

    /**
   * @dev Teleporter:  Emitted when a message is submited to be sent.
     */
    event TeleporterSendMessage(bytes32 destinationBlockchainID, address destinationAddress, address feeTokenAddress, uint256 feeAmount, uint256 requiredGasLimit, bytes32 messageId, bytes message);
    event TeleporterReceivedMessage(bytes32 sourceBlockchainID, address originSenderAddress, bytes payload);

    modifier onlySelf(){
        require(_msgSender() == address(this), "only self");
        _;
    }

    modifier onlyTerminus() {
        require(address(terminus) == _msgSender() || address(terminusDelegate) == _msgSender(), "only terminus");
        _;
    }

    modifier onlyRelay() {
        require(address(tRelay) == _msgSender(), "only relay");
        _;
    }

    modifier onlyRemoteTlp(uint64 _chainId, address _remote) {
        require(remotes[_chainId] == _remote, "unknown remote");
        _;
    }

    modifier onlyExecutor(){
        require(executors[_msgSender()], "only executor");
        _;
    }

    modifier onlyTeleporter(){
        require(address(teleporterMessenger) == _msgSender());
        _;
    }

    function initialize() external initializer {
        __Ownable_init();
        __ReentrancyGuard_init();
    }

    function sendTeleporterMessage(uint64 _dstChainId, address _feeTokenAddress, uint256 _feeAmount, uint256 _requiredGasLimit, bytes calldata _message) external onlyRelay {
        // For non-zero fee amounts, first transfer the fee to this contract, and then
        // allow the Teleporter contract to spend it.

        bytes32 _dstBlockchainID = chToblkId[_dstChainId];
        address _dstAddress = remotes[_dstChainId];

        uint256 adjustedFeeAmount;
        if (_feeAmount > 0) {
            adjustedFeeAmount = _safeTransferFrom(IERC20U(_feeTokenAddress), _msgSender(), _feeAmount);

            IERC20U(_feeTokenAddress).safeApprove(address(teleporterMessenger), adjustedFeeAmount);
        }

        bytes32 _messageId = teleporterMessenger.sendCrossChainMessage(
            TeleporterMessageInput({
                destinationBlockchainID: _dstBlockchainID,
                destinationAddress: _dstAddress,
                feeInfo: TeleporterFeeInfo({feeTokenAddress: _feeTokenAddress, amount: adjustedFeeAmount}),
                requiredGasLimit: _requiredGasLimit,
                allowedRelayerAddresses: new address[](0),
                message: _message
            })
        );

        emit TeleporterSendMessage(_dstBlockchainID, _dstAddress, _feeTokenAddress, adjustedFeeAmount, _requiredGasLimit, _messageId, _message);
    }


    function receiveTeleporterMessage(bytes32 sourceBlockchainID, address originSenderAddress, bytes calldata _payload) external onlyTeleporter {

        address _remote = originSenderAddress;

        uint64 _srcChainId = blkToChId[sourceBlockchainID];

        /*if (remotes[_srcChainId] != _remote) {
            emit UnknownRemote(_remote, _srcChainId, _payload, MessageVia.Teleporter);
            return;
        }*/

        Types.Message memory _msg;

        try this._decodePayload(_payload){
            _msg = this._decodePayload(_payload);
        } catch {
            emit InvalidMessage(_remote, _srcChainId, _payload, MessageVia.Teleporter);
            return;
        }

        if (_msg.execs.length == 0) {
            emit InvalidMessage(_remote, _srcChainId, _payload, MessageVia.Teleporter);
            return;
        }

        tRelay.tlpMsgQueue(_msg.id, keccak256(_payload));

        emit TeleporterReceivedMessage(sourceBlockchainID, originSenderAddress, _payload);
    }

    function setTerminus(address _addr) external onlyOwnerMulticall {
        terminus = ITerminus(_addr);
    }

    function setTerminusDelegate(address _addr) external onlyOwnerMulticall {
        terminusDelegate = _addr;
    }

    function setTerminusRelay(address _addr) external onlyOwnerMulticall {
        tRelay = ITerminusRelay(payable(_addr));
    }

    function setTeleporterMessenger(address _addr) external onlyOwnerMulticall {
        teleporterMessenger = ITeleporterMessenger(_addr);
    }

    function setBlkChainIds(bytes32[] memory _blkIds, uint64[] memory _chainIds) external onlyOwnerMulticall {
        require(_blkIds.length == _chainIds.length, "lengths mismatch");
        for (uint i = 0; i < _blkIds.length; i++) {
            blkToChId[_blkIds[i]] = _chainIds[i];
            chToblkId[_chainIds[i]] = _blkIds[i];
        }
    }

    function setExecutors(address[] memory _addrs, bool _allowed) external onlyOwnerMulticall {
        for (uint i = 0; i < _addrs.length; i++) {
            executors[_addrs[i]] = _allowed;
        }
    }

    function setRemoteTerminusTlps(uint64[] memory _chainIds, address[] memory _remotes) external onlyOwnerMulticall {
        require(_chainIds.length == _remotes.length, "remotes length mismatch");
        for (uint256 i = 0; i < _chainIds.length; i++) {
            remotes[_chainIds[i]] = _remotes[i];
        }
    }


    function _decodePayload(bytes memory _payload) external view onlySelf returns (Types.Message memory){
        return abi.decode((_payload), (Types.Message));
    }

    function _safeTransferFrom(IERC20U erc20, address from, uint256 amount) internal returns (uint256) {
        uint256 balanceBefore = erc20.balanceOf(address(this));
        erc20.safeTransferFrom(from, address(this), amount);
        uint256 balanceAfter = erc20.balanceOf(address(this));

        require(balanceAfter > balanceBefore, "_safeTransferFrom: balance not increased");

        return balanceAfter - balanceBefore;
    }

    receive() external payable {}

    fallback() external payable {}
}
