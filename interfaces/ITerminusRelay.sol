// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.25;

import "../lib/Types.sol";

interface ITerminusRelay {

    function executors(address) external returns (bool);

    function remotes(uint64) external returns (address);

    function messageFee(bytes calldata message, uint64 dstChainId, MessageVia _via) external view returns (uint nativeFee);

    function sendMessage(uint64 dstChainId, bytes calldata _payload, uint msgFee, uint brgGasLimit, MessageVia _via) external payable;

    function tlpMsgQueue(bytes32 id, bytes32 msgHash) external;
}
