// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "../interfaces/IDexInterfaces.sol";

interface IERC20 {
    function decimals() external view returns (uint8);
}

contract DexHelper is OwnableUpgradeable {

    struct Dex {
        uint32 dexId;
        address router;
        address factory; // if applicable
        address quoter; // if applicable
        bytes4 quoteSig; // should be sig, some equivalent of getAmountsOut
        bytes4 swapSiq; // should be sig, some equivalent of swapExactTokensForTokens
    }

    // NEW
    struct QuoteReq {
        uint amountIn;
        address tokenIn;
        address tokenMid;
        address tokenOut;
    }

    // NEW
    struct SwQuote {
        uint32 dexId;
        uint amountIn;
        address tokenIn;
        address tokenOut;
        uint amountOut;
        uint amountOutMin;
        uint32 impact;
        uint24 fee;
        bool stable;
        address pool; // This is normally the uniswap v3 pool, incase of Velodrome V2, its the pair factory address
        LB.Quote lbQuote; // trader joe v2 quote if applicable
    }

    //OLD
    /*struct Quote {
        uint amountIn;
        address tokenIn;
        address tokenOut;
        uint amountOut;
        uint quote;
        uint32 impact;
        uint24 fee;
        address pool; // This is normally the uniswap v3 pool, incase of Velodrome V2, its the pair factory address
        bool stable;
        uint32 dexId;
        uint8 tokenInDecimals;
        uint8 tokenOutDecimals;
    }*/

    // dexId => dex
    mapping(uint32 => Dex) public dexes;
    uint32[] public dexIds;

    function initialize() external initializer {
        __Context_init();
        __Ownable_init();
    }

    //UniswapV2
    function UV2_getAmountOutImpact(QuoteReq memory _quo, uint32 _dexId) public view returns (SwQuote memory swQuo) {
        Dex memory _dex = dexes[_dexId];

        swQuo = SwQuote(_dexId, _quo.amountIn, _quo.tokenIn, _quo.tokenOut, 0, 0, 0, 0, false, address(0), _emptyLBQuote());

        uint amountIn = _quo.amountIn;

        address[] memory path = new address[](2);
        address tokenA = path[0] = _quo.tokenIn;
        address tokenB = path[1] = _quo.tokenOut;

        address factory = UV2(_dex.router).factory();

        if (amountIn == 0) return swQuo;

        (bool okP, bytes memory _dataP) = factory.staticcall(abi.encodeWithSelector(UV2.getPair.selector, tokenA, tokenB));
        if (!okP) return swQuo;
        (address pair) = abi.decode(_dataP, (address));
        if (pair == address(0)) return swQuo;

        (bool okA, bytes memory _data) = pair.staticcall(abi.encodeWithSelector(UV2.getReserves.selector));
        if (!okA) return swQuo;
        (uint112 reserve0, uint112 reserve1,) = abi.decode(_data, (uint112, uint112, uint32));


        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        uint112 reserveA = tokenA == token0 ? reserve0 : reserve1;
        uint112 reserveB = tokenB == token1 ? reserve1 : reserve0;

        (bool okB, bytes memory _dataB) = _dex.router.staticcall(abi.encodeWithSelector(UV2.getAmountsOut.selector, amountIn, path));
        if (!okB) return swQuo;
        (uint[] memory amounts) = abi.decode(_dataB, (uint[]));

        uint _quote = UV2(_dex.router).quote(amountIn, uint(reserveA), uint(reserveB));

        swQuo.amountOut = amounts[amounts.length - 1];

        swQuo.impact = uint32((_quote - swQuo.amountOut) * 1e4 / _quote);
    }

    // @notice: REQUIRES quoter deployed
    function RV2_getAmountOutImpact(QuoteReq memory _quo, uint32 _dexId) public view returns (SwQuote memory swQuo) {
        Dex memory _dex = dexes[_dexId];

        swQuo = SwQuote(_dexId, _quo.amountIn, _quo.tokenIn, _quo.tokenOut, 0, 0, 0, 0, false, address(0), _emptyLBQuote());

        uint amountIn = _quo.amountIn;

        address tokenA = _quo.tokenIn;
        address tokenB = _quo.tokenOut;

        uint24[] memory _poolFees = new uint24[](4);
        _poolFees[0] = 100;
        _poolFees[1] = 500;
        _poolFees[2] = 3000;
        _poolFees[3] = 10000;

        if (amountIn == 0) return swQuo;

        for (uint i; i < _poolFees.length; ++i) {
            (bool _ok, bytes memory _data) = _dex.factory.staticcall(abi.encodeWithSelector(RV2.getPool.selector, tokenA, tokenB, _poolFees[i]));
            if (_ok) {
                (address _pool) = abi.decode(_data, (address));
                if (_pool != address(0)) {
                    RV2.Params memory _params = RV2.Params(tokenA, tokenB, amountIn, _poolFees[i], 0);
                    //quote sig: 0xc6a5026a
                    (_ok, _data) = _dex.quoter.staticcall(abi.encodeWithSelector(RV2.quoteExactInputSingle.selector, _params));
                    if (_ok) {
                        (uint _amt) = abi.decode(_data, (uint));
                        if (_amt > swQuo.amountOut) {
                            swQuo.amountOut = _amt;
                            swQuo.pool = _pool;
                            swQuo.fee = _poolFees[i];
                        }
                    }
                }
            }
        }

        return swQuo;
    }

    // @notice: REQUIRES quoter deployed
    // (UniswapV3) quoteExactInputSingle(tuple(address tokenIn, address tokenOut, uint256 amountIn, uint24 fee, uint160 sqrtPriceLimitX96) params) public view returns (uint256 amountOut)
    function UV3_getAmountOutImpact(QuoteReq memory _quo, uint32 _dexId) public view returns (SwQuote memory swQuo) {
        Dex memory _dex = dexes[_dexId];

        swQuo = SwQuote(_dexId, _quo.amountIn, _quo.tokenIn, _quo.tokenOut, 0, 0, 0, 0, false, address(0), _emptyLBQuote());

        uint amountIn = _quo.amountIn;

        address tokenA = _quo.tokenIn;
        address tokenB = _quo.tokenOut;

        uint24[] memory _poolFees = new uint24[](4);
        _poolFees[0] = 100;
        _poolFees[1] = 500;
        _poolFees[2] = 3000;
        _poolFees[3] = 10000;

        if (amountIn == 0) return swQuo;

        for (uint i; i < _poolFees.length; ++i) {
            (bool _ok, bytes memory _data) = _dex.factory.staticcall(abi.encodeWithSelector(UV3.getPool.selector, tokenA, tokenB, _poolFees[i]));
            if (_ok) {
                (address _pool) = abi.decode(_data, (address));
                if (_pool != address(0)) {
                    UV3.Params memory _params = UV3.Params(tokenA, tokenB, amountIn, _poolFees[i], 0);
                    //quote sig: 0xc6a5026a
                    (_ok, _data) = _dex.quoter.staticcall(abi.encodeWithSelector(UV3.quoteExactInputSingle.selector, _params));
                    if (_ok) {
                        (uint _amt) = abi.decode(_data, (uint));
                        if (_amt > swQuo.amountOut) {
                            swQuo.amountOut = _amt;
                            swQuo.pool = _pool;
                            swQuo.fee = _poolFees[i];
                        }
                    }
                }
            }
        }

        return swQuo;
    }

    // TraderJoe / LFJ
    function LB_getAmountOutImpact(QuoteReq memory _quo, uint32 _dexId) public view returns (SwQuote memory swQuo) {
        Dex memory _dex = dexes[_dexId];

        swQuo = SwQuote(_dexId, _quo.amountIn, _quo.tokenIn, _quo.tokenOut, 0, 0, 0, 0, false, address(0), _emptyLBQuote());

        address[] memory _route;

        if (_quo.tokenMid != address(0)) {
            _route = new address[](3);
            _route[0] = _quo.tokenIn;
            _route[1] = _quo.tokenMid;
            _route[2] = _quo.tokenOut;
        } else {
            _route = new address[](2);
            _route[0] = _quo.tokenIn;
            _route[1] = _quo.tokenOut;
        }

        uint128 _amountIn = uint128(_quo.amountIn);

        (bool _ok, bytes memory _data) = _dex.quoter.staticcall(abi.encodeWithSelector(LB.findBestPathFromAmountIn.selector, _route, _amountIn));
        if (_ok) {
            (LB.Quote memory lbQuote) = abi.decode(_data, (LB.Quote));

            swQuo.amountOut = lbQuote.amounts[_route.length - 1];
            swQuo.lbQuote = lbQuote;
        }
    }

    //Solidly/Velodrome/Thena/Dystopia etc...
    function SLD_getAmountOutImpact(QuoteReq memory _quo, uint32 _dexId) public view returns (SwQuote memory swQuo){
        Dex memory _dex = dexes[_dexId];

        swQuo = SwQuote(_dexId, _quo.amountIn, _quo.tokenIn, _quo.tokenOut, 0, 0, 0, 0, false, address(0), _emptyLBQuote());

        uint amountIn = _quo.amountIn;

        address tokenA = _quo.tokenIn;
        address tokenB = _quo.tokenOut;


        if (amountIn == 0) return swQuo;
        (bool okA, bytes memory _data) = _dex.router.staticcall(abi.encodeWithSelector(SLD.getAmountOut.selector, amountIn, tokenA, tokenB));
        if (!okA) return swQuo;
        (uint _amt, bool _stbl) = abi.decode(_data, (uint, bool));

        (uint reserveA, uint reserveB) = SLD(_dex.router).getReserves(tokenA, tokenB, _stbl);

        uint _quote = (amountIn * reserveB) / reserveA;
        swQuo.amountOut = _amt;
        swQuo.impact = uint32((_quote - swQuo.amountOut) * 1e4 / _quote);
        swQuo.stable = _stbl;
    }

    //VelodromeV2
    function VEL2_getAmountOutImpact(QuoteReq memory _quo, uint32 _dexId) public view returns (SwQuote memory swQuo){
        // @notice: the `quo.stable` or not, will be determined in the loop
        // @notice: the `quo.pool` address is the factory address in this case, to be used in VEL2.Route
        Dex memory _dex = dexes[_dexId];
        swQuo = SwQuote(_dexId, _quo.amountIn, _quo.tokenIn, _quo.tokenOut, 0, 0, 0, 0, false, address(0), _emptyLBQuote());

        uint amountIn = _quo.amountIn;

        address tokenA = _quo.tokenIn;
        address tokenB = _quo.tokenOut;
        if (amountIn == 0) return swQuo;

        address _router = _dex.router;
        // address _defFact = VEL2(_router).defaultFactory();
        address _factoryReg = VEL2(_router).factoryRegistry();
        uint _factLen = VEL2(_factoryReg).poolFactoriesLength();
        address[] memory _poolFactories = VEL2(_factoryReg).poolFactories();


        for (uint i; i < _factLen; ++i) {
            address _fact = _poolFactories[i];
            VEL2.Route memory _rtA = VEL2.Route(tokenA, tokenB, true, _fact);
            VEL2.Route memory _rtB = VEL2.Route(tokenA, tokenB, false, _fact);
            VEL2.Route[] memory _routesA = new VEL2.Route[](1);
            VEL2.Route[] memory _routesB = new VEL2.Route[](1);
            _routesA[0] = _rtA;
            _routesB[0] = _rtB;

            (bool _okA, bytes memory _dataA) = _router.staticcall(abi.encodeWithSelector(VEL2.getAmountsOut.selector, amountIn, _routesA));
            if (_okA) {
                (uint[] memory _amts) = abi.decode(_dataA, (uint[]));
                if (swQuo.amountOut < _amts[1]) {
                    swQuo.amountOut = _amts[1];
                    swQuo.pool = _fact;
                    swQuo.stable = true;
                }
            }
            (bool _okB, bytes memory _dataB) = _router.staticcall(abi.encodeWithSelector(VEL2.getAmountsOut.selector, amountIn, _routesB));
            if (_okB) {
                (uint[] memory _amts) = abi.decode(_dataB, (uint[]));
                if (swQuo.amountOut < _amts[1]) {
                    swQuo.amountOut = _amts[1];
                    swQuo.pool = _fact;
                    swQuo.stable = false;
                }
            }
        }
    }

    function getAmountOut(QuoteReq memory _quo, uint32[] calldata _dexIds) external view returns (SwQuote memory quoA, SwQuote memory quoB){

        // has mid token
        if (_quo.tokenMid != address(0)) {
            // first pair is usdc & wnative
            quoA = bestQuote(QuoteReq(_quo.amountIn, _quo.tokenIn, address(0), _quo.tokenMid), _dexIds);

            quoB = bestQuote(QuoteReq(quoA.amountOut, quoA.tokenOut, address(0), _quo.tokenOut), _dexIds);

        } else {
            quoA = bestQuote(_quo, _dexIds);
        }
    }

    function bestQuote(QuoteReq memory _quo, uint32[] memory _dexIds) public view returns (SwQuote memory swQuo){
        //if _dexIds is empty, quote ALL registered dexes
        if (_dexIds.length == 0) {
            _dexIds = dexIds;
        }
        for (uint i = 0; i < _dexIds.length; i++) {
            SwQuote memory _tmp = _getAmountOutBy(_quo, _dexIds[i]);
            if (i == 0 || _tmp.amountOut > swQuo.amountOut) {
                swQuo = _tmp;
            }
        }
    }

    function _getAmountOutBy(QuoteReq memory _quo, uint32 _dexId) internal view returns (SwQuote memory swQuo) {
        Dex memory _dex = dexes[_dexId];

        if (_dex.quoteSig == UV2.getAmountsOut.selector) {
            swQuo = UV2_getAmountOutImpact(_quo, _dexId);
        } else if (_dex.quoteSig == UV3.quoteExactInputSingle.selector) {
            swQuo = UV3_getAmountOutImpact(_quo, _dexId);
        } else if (_dex.quoteSig == RV2.quoteExactInputSingle.selector) {
            swQuo = RV2_getAmountOutImpact(_quo, _dexId);
        } else if (_dex.quoteSig == LB.findBestPathFromAmountIn.selector) {
            swQuo = LB_getAmountOutImpact(_quo, _dexId);
        } else if (_dex.quoteSig == SLD.getAmountOut.selector) {
            swQuo = SLD_getAmountOutImpact(_quo, _dexId);
        } else if (_dex.quoteSig == VEL2.getAmountsOut.selector) {
            swQuo = VEL2_getAmountOutImpact(_quo, _dexId);
        }
    }

    function getLiquidity(address tokenA, address tokenB, uint32 dexId) external view returns (address[] memory tokens, uint[] memory reserves, uint8[] memory decimals, uint32 fee, bool stable){
        tokens = new address[](2);
        reserves = new uint[](2);
        decimals = new uint8[](2);
        stable = false;
        fee = 0;

        Dex memory dex = dexes[dexId];

        // (UniswapV2)
        if (dex.quoteSig == UV2.getAmountsOut.selector) {

            address factory = UV2(dex.router).factory();

            (bool okP, bytes memory _dataP) = factory.staticcall(abi.encodeWithSelector(UV2.getPair.selector, tokenA, tokenB));
            if (!okP) return (tokens, reserves, decimals, fee, stable);
            (address pair) = abi.decode(_dataP, (address));

            (bool okA, bytes memory _data) = pair.staticcall(abi.encodeWithSelector(UV2.getReserves.selector));
            if (!okA) return (tokens, reserves, decimals, fee, stable);
            (uint112 reserve0, uint112 reserve1,) = abi.decode(_data, (uint112, uint112, uint32));
            (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
            tokens[0] = token0;
            tokens[1] = token1;
            reserves[0] = reserve0;
            reserves[1] = reserve1;
            decimals[0] = IERC20(token0).decimals();
            decimals[1] = IERC20(token1).decimals();

            (bool okF, bytes memory _dataF) = pair.staticcall(abi.encodeWithSelector(UV2.swapFee.selector));
            if (okF) {
                (fee) = abi.decode(_dataP, (uint32));
                return (tokens, reserves, decimals, fee, stable);
            }

            (bool okE, bytes memory _dataE) = factory.staticcall(abi.encodeWithSelector(UV2.getPairFees.selector, pair));
            if (okE) {
                (uint _fee) = abi.decode(_dataE, (uint));
                return (tokens, reserves, decimals, uint32((1e4 - _fee)), stable);
            }

        }

        // (Solidly / Thena / Dystopia)
        if (dex.quoteSig == SLD.getAmountOut.selector) {
            //get pair liquidity
            //function pairFor(address tokenA, address tokenB, bool stable) external view returns (address pair);
            SLD router = SLD(dex.router);
            SLD factory = SLD(router.factory());

            (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);

            address _pair = router.pairFor(tokenA, tokenB, true);
            address pair;
            (pair, stable) = factory.isPair(_pair) ? (_pair, true) : (router.pairFor(tokenA, tokenB, false), false);
            if (!factory.isPair(pair)) return (tokens, reserves, decimals, fee, stable);

            (bool okA, bytes memory _data) = pair.staticcall(abi.encodeWithSelector(SLDPair.getReserves.selector));
            if (!okA) return (tokens, reserves, decimals, fee, stable);
            (uint112 reserve0, uint112 reserve1,) = abi.decode(_data, (uint112, uint112, uint32));
            tokens[0] = token0;
            tokens[1] = token1;
            reserves[0] = reserve0;
            reserves[1] = reserve1;
            decimals[0] = IERC20(token0).decimals();
            decimals[1] = IERC20(token1).decimals();
        }
    }

    function setDexes(Dex[] calldata _dexes, uint32[] calldata _indices) external onlyOwner {
        require(_dexes.length > 0, "nop");
        require(_dexes.length == _indices.length, "dexes not equal to indices");

        dexIds = _indices;
        for (uint i = 0; i < _indices.length; i++) {
            dexes[_indices[i]] = _dexes[i];
        }
    }

    function nativeBalanceOf(address _addr) external view returns (uint) {
        return _addr.balance;
    }

    function _emptyLBQuote() internal pure returns (LB.Quote memory qt){
        return qt;
    }

}
