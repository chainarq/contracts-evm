// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.19;

import "../interfaces/IERC20.sol";
import "../interfaces/ICodec.sol";
import "../interfaces/IUniswapV3Pool.sol";
import "../interfaces/IUniswapV2Pair.sol";

contract OneInchCodec is ICodec {
    uint256 private constant _ONE_FOR_ZERO_MASK = 1 << 255;
    uint256 private constant _REVERSE_MASK = 0x8000000000000000000000000000000000000000000000000000000000000000;

    struct OrderRFQ {
        // lowest 64 bits is the order id, next 64 bits is the expiration timestamp
        // highest bit is unwrap WETH flag which is set on taker's side
        // [unwrap eth(1 bit) | unused (127 bits) | expiration timestamp(64 bits) | orderId (64 bits)]
        uint256 info;  // lowest 64 bits is the order id, next 64 bits is the expiration timestamp
        address makerAsset;
        address takerAsset;
        address maker;
        address allowedSender;  // equals to Zero address on public orders
        uint256 makingAmount;
        uint256 takingAmount;
    }

    struct SwapDesc {
        IERC20 srcToken;
        IERC20 dstToken;
        address payable srcReceiver;
        address payable dstReceiver;
        uint256 amount;
        uint256 minReturnAmount;
        uint256 flags;
    }

    function decodeCalldata(ICodec.Swap calldata _swap) external view returns (uint256 amountIn, address tokenIn, address tokenOut) {
        bytes4 selector = bytes4(_swap.data);
        if (selector == 0x84bd6d29) {
            // "0x84bd6d29": "clipperSwap(address clipperExchange, address srcToken, address dstToken, uint256 inputAmount, uint256 outputAmount, uint256 goodUntil, bytes32 r, bytes32 vs)",
            (, address srcToken, address dstToken, uint256 inputAmount,,,,) = abi.decode((_swap.data[4 :]), (address, address, address, uint256, uint256, uint256, bytes32, bytes32));
            return (inputAmount, srcToken, dstToken);
        } else if (selector == 0x3eca9c0a) {
            // "0x3eca9c0a": "fillOrderRFQ((uint256 info, address makerAsset, address takerAsset, address maker, address allowedSender, uint256 makingAmount, uint256 takingAmount) order, bytes calldata signature, uint256 flagsAndAmount)",
            (OrderRFQ memory order, ,) = abi.decode((_swap.data[4 :]), (OrderRFQ, bytes, uint256));
            return (order.takingAmount, order.takerAsset, order.makerAsset);
        } else if (selector == 0x12aa3caf) {
            // "0x12aa3caf": "swap(address executor, (address srcToken, address dstToken, address srcReceiver, address dstReceiver, uint256 amount, uint256 minReturnAmount, uint256 flags) desc, bytes permit, bytes data)",
            (, SwapDesc memory desc,,) = abi.decode((_swap.data[4 :]), (address, SwapDesc, bytes, bytes));
            return (desc.amount, address(desc.srcToken), address(desc.dstToken));
        } else if (selector == 0xe449022e) {
            // "0xe449022e": "uniswapV3Swap(uint256 amount,uint256 minReturn,uint256[] pools)",
            (uint256 amount, , uint256[] memory pools) = abi.decode((_swap.data[4 :]), (uint256, uint256, uint256[]));
            (address srcToken,) = decodeV3Pool(pools[0]);
            (, address dstToken) = decodeV3Pool(pools[pools.length - 1]);
            return (amount, srcToken, dstToken);
        } else if (selector == 0x0502b1c5) {
            // "0x0502b1c5": "unoswap(address srcToken, uint256 amount, uint256 minReturn, uint256[] pools)"
            (address srcToken, uint256 amount, , bytes32[] memory pools) = abi.decode((_swap.data[4 :]), (address, uint256, uint256, bytes32[]));
            (, address dstToken) = decodeV2Pool(uint256(pools[pools.length - 1]));
            return (amount, srcToken, dstToken);
        } else {
            // error, unknown selector
            revert("unknown selector");
        }
    }

    function encodeCalldataWithOverride(bytes calldata _data, uint256 _amountInOverride, address _receiverOverride) external pure returns (bytes memory swapCalldata) {
        bytes4 selector = bytes4(_data);
        if (selector == 0xb0431182) {
            // "0x84bd6d29": "clipperSwap(address clipperExchange, address srcToken, address dstToken, uint256 inputAmount, uint256 outputAmount, uint256 goodUntil, bytes32 r, bytes32 vs)",
            (address clipperExchange, address srcToken, address dstToken, , uint256 outputAmount, uint256 goodUntil, bytes32 r, bytes32 vs) = abi.decode((_data[4 :]), (address, address, address, uint256, uint256, uint256, bytes32, bytes32));
            return abi.encodeWithSelector(selector, clipperExchange, srcToken, dstToken, _amountInOverride, outputAmount, goodUntil, r, vs);
        } else if (selector == 0x3eca9c0a) {
            // "0x3eca9c0a": "fillOrderRFQ((uint256 info, address makerAsset, address takerAsset, address maker, address allowedSender, uint256 makingAmount, uint256 takingAmount) order, bytes calldata signature, uint256 flagsAndAmount)",
            (OrderRFQ memory order, bytes memory signature, uint256 flagsAndAmount) = abi.decode((_data[4 :]), (OrderRFQ, bytes, uint256));
            order.takingAmount = _amountInOverride;
            return abi.encodeWithSelector(selector, order, signature, flagsAndAmount);
        } else if (selector == 0x12aa3caf) {
            // "0x12aa3caf": "swap(address executor, (address srcToken, address dstToken, address srcReceiver, address dstReceiver, uint256 amount, uint256 minReturnAmount, uint256 flags) desc, bytes permit, bytes data)",
            (address executor, SwapDesc memory desc, bytes memory permit, bytes memory data) = abi.decode((_data[4 :]), (address, SwapDesc, bytes, bytes));
            desc.dstReceiver = payable(_receiverOverride);
            desc.amount = _amountInOverride;
            return abi.encodeWithSelector(selector, executor, desc, permit, data);
        } else if (selector == 0xe449022e) {
            // "0xe449022e": "uniswapV3Swap(uint256 amount,uint256 minReturn,uint256[] pools)",
            (, uint256 minReturn, uint256[] memory pools) = abi.decode((_data[4 :]), (uint256, uint256, uint256[]));
            return abi.encodeWithSelector(selector, _amountInOverride, minReturn, pools);
        } else if (selector == 0x0502b1c5) {
            // "0x0502b1c5": "unoswap(address srcToken, uint256 amount, uint256 minReturn, uint256[] pools)"
            (address srcToken, , uint256 minReturn, uint256[] memory pools) = abi.decode((_data[4 :]), (address, uint256, uint256, uint256[]));
            return abi.encodeWithSelector(selector, srcToken, _amountInOverride, minReturn, pools);
        } else {
            // error, unknown selector
            revert("unknown selector");
        }
    }

    function decodeV3Pool(uint256 pool) private view returns (address srcToken, address dstToken) {
        bool zeroForOne = pool & _ONE_FOR_ZERO_MASK == 0;
        address poolAddr = address(uint160(pool));
        if (zeroForOne) {
            return (IUniswapV3Pool(poolAddr).token0(), IUniswapV3Pool(poolAddr).token1());
        } else {
            return (IUniswapV3Pool(poolAddr).token1(), IUniswapV3Pool(poolAddr).token0());
        }
    }

    function decodeV2Pool(uint256 pool) private view returns (address srcToken, address dstToken) {
        bool zeroForOne = pool & _REVERSE_MASK == 0;
        address poolAddr = address(uint160(pool));
        if (zeroForOne) {
            return (IUniswapV2Pair(poolAddr).token0(), IUniswapV2Pair(poolAddr).token1());
        } else {
            return (IUniswapV2Pair(poolAddr).token1(), IUniswapV2Pair(poolAddr).token0());
        }
    }
}
