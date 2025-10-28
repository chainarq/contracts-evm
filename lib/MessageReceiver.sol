// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.25;


import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "../interfaces/IMessageReceiver.sol";

abstract contract MessageReceiver is IMessageReceiver, OwnableUpgradeable {
    event MessageBusUpdated(address messageBus);

    address public messageBus;

    function initMessageReceiver(address _msgbus) internal onlyInitializing {
        messageBus = _msgbus;
        emit MessageBusUpdated(messageBus);
    }

    function setMessageBus(address _msgbus) public onlyOwner {
        messageBus = _msgbus;
        emit MessageBusUpdated(messageBus);
    }

    modifier onlyMessageBus() {
        require(msg.sender == messageBus, "caller is not message bus");
        _;
    }

    /**
     * @notice Called by MessageBus (MessageBusReceiver)
     * @param _sender The address of the source app contract
     * @param _srcChainId The source chain ID where the transfer is originated from
     * @param _message Arbitrary message bytes originated from and encoded by the source app contract
     * @param _executor Address who called the MessageBus execution function
     */
    function executeMessage(
        address _sender,
        uint64 _srcChainId,
        bytes calldata _message,
        address _executor
    ) external payable virtual returns (ExecutionStatus) {}

    /**
     * @notice Called by MessageBus (MessageBusReceiver) to process refund of the original transfer from this contract
     * @param _token The token address of the original transfer
     * @param _amount The amount of the original transfer
     * @param _message The same message associated with the original transfer
     */
    function executeMessageWithTransferRefund(
        address _token,
        uint256 _amount,
        bytes calldata _message
    ) external payable virtual returns (bool) {}
}
