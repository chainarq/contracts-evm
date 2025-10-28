// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.25;

import "../lib/Types.sol";

interface ITerminus {
    function executeReceivedMessage(Types.Message calldata _msg, address _executor, bool retrySwap) external payable returns (bool);

    function execute(Types.Execution[] memory _execs, Types.Source memory _src, Types.Destination memory _dst) external payable;

    function executeGasless(Types.Execution[] memory _execs, Types.Source memory _src, Types.Destination memory _dst, uint _amountIn, address _tokenIn, address _sender) external payable;
}
