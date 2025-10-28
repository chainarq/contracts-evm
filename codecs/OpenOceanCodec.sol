// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.25;


import "../interfaces/IERC20.sol";
import "../interfaces/ICodec.sol";
import "../interfaces/IUniswapV3Pool.sol";
import "../interfaces/IUniswapV2Pair.sol";

contract OpenOceanCodec is ICodec {
    uint256 private constant _ONE_FOR_ZERO_MASK = 1 << 255;
    uint256 private constant _REVERSE_MASK = 0x8000000000000000000000000000000000000000000000000000000000000000;

    struct SwapDesc {
        IERC20 srcToken;
        IERC20 dstToken;
        address srcReceiver;
        address dstReceiver;
        uint256 amount;
        uint256 minReturnAmount;
        uint256 guaranteedAmount;
        uint256 flags;
        address referrer;
        bytes permit;
    }

    struct CallDesc {
        uint256 target;
        uint256 gasLimit;
        uint256 value;
        bytes data;
    }

    // 0x90411a32: function swap(IOpenOceanCaller caller, SwapDescription calldata desc, IOpenOceanCaller.CallDescription[] calldata calls) external payable whenNotPaused returns (uint256 returnAmount)
    // 0x6b58f2f0: function callUniswapTo(IERC20 srcToken, uint256 amount, uint256 minReturn, bytes32[] calldata, /* pools */ address payable recipient) public payable returns (uint256 returnAmount)
    // 0xbc80f1a8: function uniswapV3SwapTo(address payable recipient, uint256 amount, uint256 minReturn, uint256[] calldata pools) public payable returns (uint256 returnAmount)
    function decodeCalldata(ICodec.Swap calldata _swap) external view returns (uint256 amountIn, address tokenIn, address tokenOut) {
        bytes4 selector = bytes4(_swap.data);

        if (selector == 0x90411a32) {
            (,SwapDesc memory desc,) = abi.decode((_swap.data[4 :]), (address, SwapDesc, CallDesc[]));
            return (desc.amount, address(desc.srcToken), address(desc.dstToken));
        } else if (selector == 0x6b58f2f0) {
            (address srcToken, uint256 amount, , bytes32[] memory pools,) = abi.decode((_swap.data[4 :]), (address, uint256, uint256, bytes32[], address));
            (, address dstToken) = decodeV2Pool(uint256(pools[pools.length - 1]));
            return (amount, srcToken, dstToken);
        } else if (selector == 0xbc80f1a8) {
            (, uint256 amount, , uint256[] memory pools) = abi.decode((_swap.data[4 :]), (address, uint256, uint256, uint256[]));
            (address srcToken,) = decodeV3Pool(pools[0]);
            (, address dstToken) = decodeV3Pool(pools[pools.length - 1]);
            return (amount, srcToken, dstToken);
        } else {
            // error, unknown selector
            revert("OO unknown selector");
        }
    }

    function encodeCalldataWithOverride(bytes calldata _data, uint256 _amountInOverride, address _receiverOverride) external pure returns (bytes memory swapCalldata) {
        bytes4 selector = bytes4(_data);
        if (selector == 0x90411a32) {
            (address caller, SwapDesc memory desc, CallDesc[] memory calls) = abi.decode((_data[4 :]), (address, SwapDesc, CallDesc[]));
            desc.dstReceiver = payable(_receiverOverride);
            desc.amount = _amountInOverride;
            return abi.encodeWithSelector(selector, caller, desc, calls);
        } else if (selector == 0x6b58f2f0) {
            (address srcToken, , uint256 minReturn, bytes32[] memory pools, address recipient) = abi.decode((_data[4 :]), (address, uint256, uint256, bytes32[], address));
            return abi.encodeWithSelector(selector, srcToken, _amountInOverride, minReturn, pools, recipient);
        } else if (selector == 0xbc80f1a8) {
            (,  , uint256 minReturn, uint256[] memory pools) = abi.decode((_data[4 :]), (address, uint256, uint256, uint256[]));
            return abi.encodeWithSelector(selector, _receiverOverride, _amountInOverride, minReturn, pools);
        } else {
            // error, unknown selector
            revert("OO unknown selector");
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
