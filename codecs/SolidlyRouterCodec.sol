// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.25;


import "../interfaces/ICodec.sol";

/***
 @notice: Known dexes using this router:
 Solidly (FTM), Velodrome (OPT), Thena (BSC), Dystopia (MATIC), Equalizer (FTM)
 and potentially others
*/

contract SolidlyRouterCodec is ICodec {
    struct Route {
        address from;
        address to;
        bool stable;
    }

    // 0x6cc1ae13 swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256 amountIn, uint256 amountOutMin, (address from, address to, bool stable)[] routes, address to, uint256 deadline) external
    function decodeCalldata(ICodec.Swap calldata _swap) external pure returns (uint256 amountIn, address tokenIn, address tokenOut)    {
        (uint _amtIn,,Route[] memory routes,,) = abi.decode((_swap.data[4 :]), (uint, uint, Route[], address, uint));

        return (_amtIn, routes[0].from, routes[0].to);
    }

    function encodeCalldataWithOverride(bytes calldata _data, uint256 _amountInOverride, address _receiverOverride) external pure returns (bytes memory swapCalldata) {
        bytes4 selector = bytes4(_data);

        (,uint _outMin,Route[] memory routes,,uint _ddl) = abi.decode((_data[4 :]), (uint, uint, Route[], address, uint));

        return abi.encodeWithSelector(selector, _amountInOverride, _outMin, routes, _receiverOverride, _ddl);
    }
}
