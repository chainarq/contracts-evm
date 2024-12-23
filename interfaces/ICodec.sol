// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.19;

interface ICodec {
    struct Swap {
        address dex; // the DEX to use for the swap, zero address implies no swap needed
        bytes data; // the data to call the dex with
        bytes swapData; // packed tokenIn and tokenOut
    }

    function decodeCalldata(Swap calldata swap)
        external
        view
        returns (
            uint256 amountIn,
            address tokenIn,
            address tokenOut
        );

    function encodeCalldataWithOverride(
        bytes calldata data,
        uint256 amountInOverride,
        address receiverOverride
    ) external pure returns (bytes memory swapCalldata);
}
