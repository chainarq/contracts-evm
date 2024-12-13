// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.19;

import "../interfaces/ICodec.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/IZeroXCombo.sol";

contract ZeroXCodec is ICodec {

// 0xc43c9ef6: sellToPancakeSwap(address[],uint256,uint256,uint8)
// 0x415565b0: transformERC20(address,address,uint256,uint256,(uint32,bytes)[])
// 0xd9627aa4: sellToUniswap(address[],uint256,uint256,bool)
// 0x6af479b2: sellTokenForTokenToUniswapV3(bytes,uint256,uint256,address)
// 0x7a1eb1b9: multiplexBatchSellTokenForToken(address,address,(uint8,uint256,bytes)[],uint256,uint256)

    function decodeCalldata(ICodec.Swap calldata _swap) external view returns (uint256 amountIn, address tokenIn, address tokenOut) {
        bytes4 selector = bytes4(_swap.data);

        if (selector == IPancakeSwapFeature.sellToPancakeSwap.selector) {
            (address[] memory tokens, uint256 sellAmount,,) = abi.decode((_swap.data[4 :]), (address[], uint256, uint256, uint8));
            return (sellAmount, tokens[0], tokens[tokens.length - 1]);
        } else if (selector == IUniswapFeature.sellToUniswap.selector) {
            (address[] memory tokens, uint256 sellAmount,,) = abi.decode((_swap.data[4 :]), (address[], uint256, uint256, bool));
            return (sellAmount, tokens[0], tokens[tokens.length - 1]);
        } else if (selector == IUniswapV3Feature.sellTokenForTokenToUniswapV3.selector) {
            (bytes memory encodedPath, uint256 sellAmount,,) = abi.decode((_swap.data[4 :]), (bytes, uint256, uint256, address));
            require((encodedPath.length - 20) % 23 == 0, "01 malformed path");
            address _tokenIn = address(bytes20(copySubBytes(encodedPath, 0, 20)));
            address _tokenOut = address(bytes20(copySubBytes(encodedPath, encodedPath.length - 20, encodedPath.length)));
            return (sellAmount, _tokenIn, _tokenOut);
        } else if (selector == ITransformERC20Feature.transformERC20.selector) {
            (address inputToken, address outputToken, uint256 inputTokenAmount,,) = abi.decode((_swap.data[4 :]), (address, address, uint256, uint256, ITransformERC20Feature.Transformation[]));
            return (inputTokenAmount, inputToken, outputToken);
        } else if (selector == IMultiplexFeature.multiplexBatchSellTokenForToken.selector) {
            (address inputToken, address outputToken, , uint256 sellAmount,) = abi.decode((_swap.data[4 :]), (address, address, IMultiplexFeature.BatchSellSubcall[], uint256, uint256));
            return (sellAmount, inputToken, outputToken);
        }

        revert("O1a unknown selector");
    }

    function encodeCalldataWithOverride(bytes calldata _data, uint256 _amountInOverride, address _receiverOverride) external pure returns (bytes memory swapCalldata) {
        bytes4 selector = bytes4(_data);
        if (selector == IPancakeSwapFeature.sellToPancakeSwap.selector) { // @warning: can't override receiver here in this func!
            (address[] memory tokens, , uint256 minBuyAmount, uint8 fork) = abi.decode((_data[4 :]), (address[], uint256, uint256, uint8));
            return abi.encodeWithSelector(selector, tokens, _amountInOverride, minBuyAmount, fork);
        } else if (selector == IUniswapFeature.sellToUniswap.selector) { // @warning: can't override receiver here in this func!
            (address[] memory tokens, , uint256 minBuyAmount, bool isSushi) = abi.decode((_data[4 :]), (address[], uint256, uint256, bool));
            return abi.encodeWithSelector(selector, tokens, _amountInOverride, minBuyAmount, isSushi);
        } else if (selector == IUniswapV3Feature.sellTokenForTokenToUniswapV3.selector) {
            (bytes memory encodedPath, , uint256 minBuyAmount,) = abi.decode((_data[4 :]), (bytes, uint256, uint256, address));
            return abi.encodeWithSelector(selector, encodedPath, _amountInOverride, minBuyAmount, _receiverOverride);
        } else if (selector == ITransformERC20Feature.transformERC20.selector) { // @warning: can't override receiver here in this func!
            (address inputToken, address outputToken, , uint256 minOutputTokenAmount, ITransformERC20Feature.Transformation[] memory transformations) = abi.decode((_data[4 :]), (address, address, uint256, uint256, ITransformERC20Feature.Transformation[]));
            return abi.encodeWithSelector(selector, inputToken, outputToken, _amountInOverride, minOutputTokenAmount, transformations);
        } else if (selector == IMultiplexFeature.multiplexBatchSellTokenForToken.selector) { // @warning: can't override receiver here in this func!
            (address inputToken, address outputToken, IMultiplexFeature.BatchSellSubcall[] memory calls, , uint256 minBuyAmount) = abi.decode((_data[4 :]), (address, address, IMultiplexFeature.BatchSellSubcall[], uint256, uint256));
            return abi.encodeWithSelector(selector, inputToken, outputToken, calls, _amountInOverride, minBuyAmount);
        }

        revert("O1b unknown selector");
    }

    // basically a bytes' version of byteN[from:to] execpt it copies
    function copySubBytes(bytes memory data, uint256 from, uint256 to) private pure returns (bytes memory ret) {
        require(to <= data.length, "index overflow");
        uint256 len = to - from;
        ret = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            ret[i] = data[i + from];
        }
    }

}
