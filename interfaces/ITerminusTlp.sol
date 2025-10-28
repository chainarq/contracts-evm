// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

interface ITerminusTlp {

    function sendTeleporterMessage(uint64 dstChainId, address feeTokenAddress, uint256 feeAmount, uint256 requiredGasLimit, bytes calldata message) external;

}
