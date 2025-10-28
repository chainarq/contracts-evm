// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.25;


interface ICircleMessageReceiver {

    function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool success);
}
