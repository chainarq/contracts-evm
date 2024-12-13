// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

interface UV2 {
    //router
    function factory() external view returns (address);

    function quote(uint amountA, uint reserveA, uint reserveB) external pure returns (uint amountB);

    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);

    //factory
    function getPair(address tokenA, address tokenB) external view returns (address pair);

    //MDEX factory:
    function getPairFees(address) external view returns (uint256);

    //pair
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    //BiSwap has dynamic fee per pair
    function swapFee() external view returns (uint32);
}

interface UV3 {
    struct Params {address tokenIn; address tokenOut; uint256 amountIn; uint24 fee; uint160 sqrtPriceLimitX96;}

    function quoteExactInputSingle(Params memory params) external view returns (uint256 amountOut);

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);

}

interface SLD {
    //router
    function factory() external view returns (address);

    function getReserves(address tokenA, address tokenB, bool stable) external view returns (uint reserveA, uint reserveB);

    function getAmountOut(uint amountIn, address tokenIn, address tokenOut) external view returns (uint amount, bool stable);

    function pairFor(address tokenA, address tokenB, bool stable) external view returns (address pair);

    //factory
    function isPair(address pair) external view returns (bool);

}

interface SLDPair {
    //pair
    function getReserves() external view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast);
}

interface IERC20 {
    function decimals() external view returns (uint8);
}

interface VEL2 {
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    // router v2
    function factoryRegistry() external view returns (address);

    function defaultFactory() external view returns (address);

    function getAmountsOut(uint256 amountIn, Route[] memory routes) external view returns (uint256[] memory amounts);

    // factory registry v2
    function poolFactories() external view returns (address[] memory);

    function poolFactoriesLength() external view returns (uint);
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

    struct Quote {
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
    }

    // dexId => dex
    mapping(uint32 => Dex) public dexes;
    uint32[] public dexIds;

    function initialize() external initializer {
        __Context_init();
        __Ownable_init();
    }

    //UniswapV2
    function UV2_getAmountOutImpact(Quote memory _quo) public view returns (Quote memory quo) {
        quo = _quo;
        Dex memory dex = dexes[quo.dexId];
        uint amountIn = quo.amountIn;

        address[] memory path = new address[](2);
        address tokenA = path[0] = quo.tokenIn;
        address tokenB = path[1] = quo.tokenOut;

        address factory = UV2(dex.router).factory();

        if (amountIn == 0) return quo;

        (bool okP, bytes memory _dataP) = factory.staticcall(abi.encodeWithSelector(UV2.getPair.selector, tokenA, tokenB));
        if (!okP) return quo;
        (address pair) = abi.decode(_dataP, (address));

        (bool okA, bytes memory _data) = pair.staticcall(abi.encodeWithSelector(UV2.getReserves.selector));
        if (!okA) return quo;
        (uint112 reserve0, uint112 reserve1,) = abi.decode(_data, (uint112, uint112, uint32));

        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        uint112 reserveA = tokenA == token0 ? reserve0 : reserve1;
        uint112 reserveB = tokenB == token1 ? reserve1 : reserve0;

        (bool okB, bytes memory _dataB) = dex.router.staticcall(abi.encodeWithSelector(UV2.getAmountsOut.selector, amountIn, path));
        if (!okB) return quo;
        (uint[] memory amounts) = abi.decode(_dataB, (uint[]));

        quo.amountOut = amounts[amounts.length - 1];

        quo.quote = UV2(dex.router).quote(amountIn, uint(reserveA), uint(reserveB));

        quo.impact = uint32((quo.quote - quo.amountOut) * 1e4 / quo.quote);
    }

    // @notice: REQUIRES quoter deployed
    // (UniswapV3) quoteExactInputSingle(tuple(address tokenIn, address tokenOut, uint256 amountIn, uint24 fee, uint160 sqrtPriceLimitX96) params) public view returns (uint256 amountOut)
    function UV3_getAmountOutImpact(Quote memory _quo) public view returns (Quote memory quo){

        quo = _quo;
        Dex memory dex = dexes[quo.dexId];
        uint amountIn = quo.amountIn;

        address tokenA = quo.tokenIn;
        address tokenB = quo.tokenOut;

        address _quoter = dex.quoter;
        address _factory = dex.factory;

        uint24[] memory _poolFees = new uint24[](4);
        _poolFees[0] = 100;
        _poolFees[1] = 500;
        _poolFees[2] = 3000;
        _poolFees[3] = 10000;

        if (amountIn == 0) return quo;

        for (uint i; i < _poolFees.length; ++i) {
            (bool _ok, bytes memory _data) = _factory.staticcall(abi.encodeWithSelector(UV3.getPool.selector, tokenA, tokenB, _poolFees[i]));
            if (_ok) {
                (address _pool) = abi.decode(_data, (address));
                if (_pool != address(0)) {
                    UV3.Params memory _params = UV3.Params(tokenA, tokenB, amountIn, _poolFees[i], 0);
                    (_ok, _data) = _quoter.staticcall(abi.encodeWithSelector(dex.quoteSig, _params));
                    if (_ok) {
                        (uint _amt) = abi.decode(_data, (uint));
                        if (_amt > quo.amountOut) {
                            quo.amountOut = _amt;
                            quo.pool = _pool;
                            quo.fee = _poolFees[i];
                        }
                    }
                }
            }
        }

        return quo;

    }

    //Solidly/Velodrome/Thena/Dystopia etc...
    function SLD_getAmountOutImpact(Quote memory _quo) public view returns (Quote memory quo){
        quo = _quo;
        Dex memory dex = dexes[quo.dexId];
        uint amountIn = quo.amountIn;

        address tokenA = quo.tokenIn;
        address tokenB = quo.tokenOut;


        if (amountIn == 0) return quo;
        (bool okA, bytes memory _data) = dex.router.staticcall(abi.encodeWithSelector(SLD.getAmountOut.selector, amountIn, tokenA, tokenB));
        if (!okA) return quo;
        (uint _amt, bool _stbl) = abi.decode(_data, (uint, bool));

        (uint reserveA, uint reserveB) = SLD(dex.router).getReserves(tokenA, tokenB, _stbl);

        quo.quote = (amountIn * reserveB) / reserveA;
        quo.amountOut = _amt;
        quo.impact = uint32((quo.quote - quo.amountOut) * 1e4 / quo.quote);
        quo.stable = _stbl;
    }

    //VelodromeV2
    function VEL2_getAmountOutImpact(Quote memory _quo) public view returns (Quote memory quo){
        // @notice: the `quo.stable` or not, will be determined in the loop
        // @notice: the `quo.pool` address is the factory address in this case, to be used in VEL2.Route
        quo = _quo;
        Dex memory dex = dexes[quo.dexId];
        uint amountIn = quo.amountIn;

        address tokenA = quo.tokenIn;
        address tokenB = quo.tokenOut;
        if (amountIn == 0) return quo;

        address _router = dex.router;
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
                if (quo.amountOut < _amts[1]) {
                    quo.amountOut = _amts[1];
                    quo.pool = _fact;
                    quo.stable = true;
                }
            }
            (bool _okB, bytes memory _dataB) = _router.staticcall(abi.encodeWithSelector(VEL2.getAmountsOut.selector, amountIn, _routesB));
            if (_okB) {
                (uint[] memory _amts) = abi.decode(_dataB, (uint[]));
                if (quo.amountOut < _amts[1]) {
                    quo.amountOut = _amts[1];
                    quo.pool = _fact;
                    quo.stable = false;
                }
            }
        }
    }

    function getAmountOutImpact(uint amountIn, address tokenA, address tokenB, uint32 dexId) external view returns (Quote memory quo){
        return _getAmountOutImpact(amountIn, tokenA, tokenB, dexId);
    }

    function _getAmountOutImpact(uint amountIn, address tokenA, address tokenB, uint32 dexId) internal view returns (Quote memory quo){
        address[] memory _path = new address[](2);
        _path[0] = tokenA;
        _path[1] = tokenB;

        Dex memory _dex = dexes[dexId];

        quo = Quote(amountIn, tokenA, tokenB, 0, 0, 0, 0, address(0), false, _dex.dexId, IERC20(tokenA).decimals(), IERC20(tokenB).decimals());

        // (UniswapV2)
        if (_dex.quoteSig == UV2.getAmountsOut.selector) {
            quo = UV2_getAmountOutImpact(quo);
        }

        // (Solidly / Thena / Dystopia)
        if (_dex.quoteSig == SLD.getAmountOut.selector) {
            quo = SLD_getAmountOutImpact(quo);
        }

        // (UniswapV3)
        if (_dex.quoteSig == UV3.quoteExactInputSingle.selector) {
            quo = UV3_getAmountOutImpact(quo);
        }

        // (VelodromeV2)
        if (_dex.quoteSig == VEL2.getAmountsOut.selector) {
            quo = VEL2_getAmountOutImpact(quo);
        }
    }

    function _emptyQuote() internal pure returns (Quote memory){
        return Quote(0, address(0), address(0), 0, 0, 0, 0, address(0), false, 0, 0, 0);
    }

    function bestQuote(uint amountIn, address tokenIn, address tokenOut) external view returns (Quote memory quo){

        quo = _emptyQuote();
        Quote memory _q = _emptyQuote();

        for (uint j = 0; j < dexIds.length; j++) {
            (bool ok, bytes memory _data) = address(this).staticcall(abi.encodeWithSelector(this.getAmountOutImpact.selector, amountIn, tokenIn, tokenOut, dexIds[j]));

            if (ok) {
                (_q) = abi.decode(_data, (Quote));
                if (_q.amountOut >= quo.amountOut) {
                    quo = _q;
                }
            }
        }
    }

    function dexQuote(uint amountIn, address tokenIn, address tokenOut, uint32 dexId) external view returns (Quote memory quo){
        quo = _emptyQuote();
        (bool ok, bytes memory _data) = address(this).staticcall(abi.encodeWithSelector(this.getAmountOutImpact.selector, amountIn, tokenIn, tokenOut, dexId));
        if (ok) {
            (quo) = abi.decode(_data, (Quote));
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
}
