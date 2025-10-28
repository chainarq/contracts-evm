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

interface RV2 { // RamsesV2 / PharaohV2
    struct Params {address tokenIn; address tokenOut; uint256 amountIn; uint24 fee; uint160 sqrtPriceLimitX96;}

    //SwapRouter.sol
//    struct ExactInputParams {bytes path; address recipient; uint256 deadline; uint256 amountIn; uint256 amountOutMinimum;}
    //SwapRouter.sol
//    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);

    function quoteExactInputSingle(Params memory params) external view returns (uint256 amountOut);

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

//traderjoe v2
interface LB {
    enum Version {V1, V2, V2_1, V2_2}
    /**
     * @dev The quote struct returned by the quoter
     * - route: address array of the token to go through
     * - pairs: address array of the pairs to go through
     * - binSteps: The bin step to use for each pair
     * - versions: The version to use for each pair
     * - amounts: The amounts of every step of the swap
     * - virtualAmountsWithoutSlippage: The virtual amounts of every step of the swap without slippage
     * - fees: The fees to pay for every step of the swap
     */
    struct Quote {address[] route; address[] pairs; uint256[] binSteps; Version[] versions; uint128[] amounts; uint128[] virtualAmountsWithoutSlippage; uint128[] fees;}

//    struct Path {uint256[] pairBinSteps; Version[] versions; IERC20U[] tokenPath;}
/**
     * @notice Finds the best path given a list of tokens and the input amount wanted from the swap
     * @param route List of the tokens to go through
     * @param amountIn Swap amount in
     * @return quote The Quote structure containing the necessary element to perform the swap
     */
    function findBestPathFromAmountIn(address[] calldata route, uint128 amountIn) external view returns (Quote memory quote);

//    function swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256 amountIn, uint256 amountOutMin, Path memory path, address to, uint256 deadline) external returns (uint256 amountOut);
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

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256 amountIn, uint256 amountOutMin, Route[] memory routes, address to, uint256 deadline) external;
}

