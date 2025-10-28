// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.25;


import "../interfaces/ICodec.sol";
import "../interfaces/ISwapRouter.sol";

contract UniswapV3ExactInputCodec is ICodec {

    function decodeCalldata(ICodec.Swap calldata _swap) external pure returns (uint256 amountIn, address tokenIn, address tokenOut) {
        bytes4 selector = bytes4(_swap.data);
        if (selector == 0xc04b8d59) { // Router
            ISwapRouter.ExactInputParams memory _params = abi.decode((_swap.data[4 :]), (ISwapRouter.ExactInputParams));
            // path is in the format of abi.encodedPacked(address tokenIn, [uint24 fee, address token[, uint24 fee, address token]...])
            require((_params.path.length - 20) % 23 == 0, "malformed path");
            // first 20 bytes is tokenIn
            tokenIn = address(bytes20(copySubBytes(_params.path, 0, 20)));
            // last 20 bytes is tokenOut
            tokenOut = address(bytes20(copySubBytes(_params.path, _params.path.length - 20, _params.path.length)));
            amountIn = _params.amountIn;
        } else if (selector == 0xb858183f) { // Router2
            ISwapRouter.ExactInputParams2 memory _params = abi.decode((_swap.data[4 :]), (ISwapRouter.ExactInputParams2));
            // path is in the format of abi.encodedPacked(address tokenIn, [uint24 fee, address token[, uint24 fee, address token]...])
            require((_params.path.length - 20) % 23 == 0, "malformed path");
            // first 20 bytes is tokenIn
            tokenIn = address(bytes20(copySubBytes(_params.path, 0, 20)));
            // last 20 bytes is tokenOut
            tokenOut = address(bytes20(copySubBytes(_params.path, _params.path.length - 20, _params.path.length)));
            amountIn = _params.amountIn;
        } else {
            // error, unknown selector
            revert("UV3 unknown selector");
        }
    }

    function encodeCalldataWithOverride(bytes calldata _data, uint256 _amountInOverride, address _receiverOverride) external pure returns (bytes memory swapCalldata) {
        bytes4 selector = bytes4(_data);
        if (selector == 0xc04b8d59) {// Router
            ISwapRouter.ExactInputParams memory _params = abi.decode((_data[4 :]), (ISwapRouter.ExactInputParams));
            _params.amountIn = _amountInOverride;
            _params.recipient = _receiverOverride;
            return abi.encodeWithSelector(selector, _params);
        } else if (selector == 0xb858183f) { // Router2
            ISwapRouter.ExactInputParams2 memory _params = abi.decode((_data[4 :]), (ISwapRouter.ExactInputParams2));
            _params.amountIn = _amountInOverride;
            _params.recipient = _receiverOverride;
            return abi.encodeWithSelector(selector, _params);
        } else {
            // error, unknown selector
            revert("UV3 unknown selector");
        }

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
