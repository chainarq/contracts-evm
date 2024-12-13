// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import "./registries/BridgeRegistry.sol";
import "./registries/DexRegistry.sol";
import "./registries/FeeVaultRegistry.sol";
import "./registries/TokenRegistry.sol";

import "./lib/Types.sol";
import "./lib/Multicallable.sol";

interface UV2 {
    function getAmountsIn(uint amountOut, address[] calldata path) external view returns (uint[] memory amounts);

    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
}

interface UV3 {
    struct InParams {address tokenIn; address tokenOut; uint256 amountIn; uint24 fee; uint160 sqrtPriceLimitX96;}

    struct OutParams {address tokenIn; address tokenOut; uint256 amountOut; uint24 fee; uint160 sqrtPriceLimitX96;}

    function quoteExactInputSingle(InParams memory params) external view returns (uint256 amountOut);

    function quoteExactOutputSingle(OutParams memory params) external view returns (uint256 amountIn);

}

contract Registries is DexRegistry, BridgeRegistry, FeeVaultRegistry, TokenRegistry {

    struct VarFee {
        uint min;
        uint max;
        uint rate; // 1e4: 100% = 1000000
    }

    address public terminus;
    address public nativeWrap;
    address public stable;
    uint public stableDecimals;
    address public dexRouter;

    mapping(address => bool) public feeExempt;

    uint public localFee; // local swap: fixed fee
    uint public directFee; // direct bridge: fixed fee
    uint public srcFee; // swap src and bridge (no dst swap): fixed fee
    VarFee public dstFee; // swap dst with or without src swap: variable fee

    uint32 public feeSlippage; // slippage converting stable to native

    address public uv3Quoter; // UniswapV3 Quoter
    uint24 public uv3PoolFee; //UniswapV3 pool fee

    function initialize(
        address _feeVault,
        address[] memory _dexList,
        string[] memory _funcs,
        address[] memory _codecs,
        string[] memory _bridgeProviders,
        address[] memory _bridgeAdapters
    ) external initializer {
        __Context_init();
        __Ownable_init();

        initDexRegistry(_dexList, _funcs, _codecs);
        initBridgeRegistry(_bridgeProviders, _bridgeAdapters);
        initFeeVaultRegistry(_feeVault);
    }

    function getFee(SwapType _st, uint stableAmt, address account, address tokenIn, address tokenOut) public view returns (uint fee) {
        if (feeExempt[account]) return 0;

        if (_st == SwapType.Local) { /* same chain swap */
            return feeWithTokenOverride(localFee, tokenIn, tokenOut);
        } else if (_st == SwapType.Direct) { /* direct bridge  */
            return feeWithTokenOverride(directFee, tokenIn, tokenOut);
        } else if (_st == SwapType.SwapSrc) { /* swap src, no dst */
            return feeWithTokenOverride(srcFee, tokenIn, tokenOut);
        } else if (_st == SwapType.SwapDst || _st == SwapType.SwapSrcDst) { /* swap/no src, swap dst */
            return feeWithTokenOverride(feeMinMax(stableAmt, dstFee), tokenIn, tokenOut);
        }

        return 0;
    }

    function feeWithTokenOverride(uint baseFee, address tokenIn, address tokenOut) internal view returns (uint){
        if (tokens[tokenIn].feeExempt || tokens[tokenOut].feeExempt) return 0;

        uint feeOverride = tokens[tokenIn].feeDiscount > 0 ? (baseFee * uint32(1e6 - tokens[tokenIn].feeDiscount)) / 1e6 : baseFee;
        feeOverride = tokens[tokenOut].feeDiscount > 0 ? (feeOverride * uint32(1e6 - tokens[tokenOut].feeDiscount)) / 1e6 : feeOverride;

        address[] memory path = new address[](2);
        path[0] = nativeWrap;
        path[1] = stable;

        if (dexRouter == address(0)) {
            UV3.OutParams memory _params = UV3.OutParams(nativeWrap, stable, feeOverride, uv3PoolFee, 0);
            (bool ok, bytes memory _data) = uv3Quoter.staticcall(abi.encodeWithSelector(UV3.quoteExactOutputSingle.selector, _params));
            if (!ok) return 0;
            (uint _amtIn) = abi.decode(_data, (uint));
            return _amtIn;
        } else {
            (bool ok, bytes memory _data) = dexRouter.staticcall(abi.encodeWithSelector(UV2.getAmountsIn.selector, feeOverride, path));
            if (!ok) return 0;
            (uint[] memory amounts) = abi.decode(_data, (uint[]));
            return amounts[0];
        }
    }

    function feeMinMax(uint _amount, VarFee memory _vf) internal pure returns (uint){
        uint _feeStable = (_amount * _vf.rate) / (100 * 1e4);
        return (_feeStable < _vf.min ? _vf.min : (_feeStable > _vf.max ? _vf.max : _feeStable));
    }

    function setAddresses(address _terminus, address _nativeWrap, address _stable, uint _stableDecimals, address _dexRouter, address _uv3Quoter, uint24 _uv3PoolFee) public onlyOwnerMulticall {
        terminus = _terminus;
        nativeWrap = _nativeWrap;
        stable = _stable;
        stableDecimals = _stableDecimals;
        dexRouter = _dexRouter;
        uv3Quoter = _uv3Quoter;
        uv3PoolFee = _uv3PoolFee;

        feeExempt[owner()] = true;
    }

    function setFees(uint _local, uint _direct, uint _src, VarFee calldata _dst, uint32 _slippage) public onlyOwnerMulticall {
        localFee = _local;
        directFee = _direct;
        srcFee = _src;
        dstFee = _dst;
        feeSlippage = _slippage;
    }

    function setExempt(address[] memory _accounts, bool _enable) public onlyOwnerMulticall {
        for (uint i = 0; i < _accounts.length; i++) {
            feeExempt[_accounts[i]] = _enable;
        }
    }
}
