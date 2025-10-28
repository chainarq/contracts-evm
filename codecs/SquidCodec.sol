// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.25;


import "../interfaces/ICodec.sol";
import "../interfaces/IERC20.sol";

interface ISquidMulticall {
    enum CallType {
        Default,
        FullTokenBalance,
        FullNativeBalance,
        CollectTokenBalance
    }

    struct Call {
        CallType callType;
        address target;
        uint256 value;
        bytes callData;
        bytes payload;
    }
}


contract SquidCodec is ICodec {

// 0x58181a80: fundAndRunMulticall(address token, uint256 amount, (uint8 callType, address target, uint256 value, bytes callData, bytes payload)[] calls)

    function decodeCalldata(ICodec.Swap calldata _swap) external pure returns (uint256 amountIn, address tokenIn, address tokenOut) {
        bytes4 selector = bytes4(_swap.data);

        if (selector == 0x58181a80) {
            address _tokenOut = address(bytes20(copySubBytes(_swap.swapData, 20, 40)));

            (address _tokenIn, uint _amountIn, /*ISquidMulticall.Call[] memory calls*/) = abi.decode((_swap.data[4 :]), (address, uint256, ISquidMulticall.Call[]));

            return (_amountIn, _tokenIn, _tokenOut);
        }

        revert("SQ unknown selector");
    }

    function encodeCalldataWithOverride(bytes calldata _data, uint256 _amountInOverride, address /*_receiverOverride*/) external pure returns (bytes memory swapCalldata) {
        bytes4 selector = bytes4(_data);
        if (selector == 0x58181a80) { // @warning:
            (address _tokenIn,/* uint _amountIn*/, ISquidMulticall.Call[] memory calls) = abi.decode((_data[4 :]), (address, uint256, ISquidMulticall.Call[]));
            return abi.encodeWithSelector(selector, _tokenIn, _amountInOverride, calls);
        }

        revert("SQ unknown selector");
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
