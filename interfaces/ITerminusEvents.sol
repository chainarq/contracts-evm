// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.19;

import "../lib/Types.sol";

interface ITerminusEvents {
    /**
     * @notice Emitted when operations on dst chain is done.
     * @param id see _computeId()
     * @param amountOut the amount of tokenOut from this step
     * @param tokenOut the token that is outputted from this step
     */
    event StepExecuted(bytes32 id, uint256 amountOut, address tokenOut);

    event CustodianFundClaimed(address receiver, uint256 erc20Amount, address token, uint256 nativeAmount);
}
