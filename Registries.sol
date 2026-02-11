// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "./interfaces/IERC20U.sol";
import "./interfaces/ITerminusRelay.sol";
import "./lib/MultiCallable.sol";
import "./lib/Types.sol";

import "./registries/BridgeRegistry.sol";
import "./registries/DexRegistry.sol";

import "./registries/FeeVaultRegistry.sol";
import "./registries/TokenRegistry.sol";


interface UV2 {
    function getAmountsIn(uint amountOut, address[] calldata path) external view returns (uint[] memory amounts);

    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
}

interface UV3 {
    struct InParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    struct OutParams {
        address tokenIn;
        address tokenOut;
        uint256 amountOut;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(InParams memory params) external view returns (uint256 amountOut);

    function quoteExactOutputSingle(OutParams memory params) external view returns (uint256 amountIn);
}

contract Registries is DexRegistry, BridgeRegistry, FeeVaultRegistry, TokenRegistry {
    struct VarFee {
        uint min; // min fee
        uint max; // max fee
        uint thres; // min fee will be in effect up until threshold then % rate on amount will be in effect
        uint rate; // 1e4: 100% = 1000000
    }

    struct FeeSplit {
        uint16 feePer; // % of fees split with 2 decimal precision ie 5000/10000
        VarFee localFee; // if rate > 0 will override the default
        VarFee crossFee; // if rate > 0 will override the default
    }

    address public terminus;
    address public nativeWrap;
    address public stable;
    uint public stableDecimals;
    address public dexRouter;

    mapping(address => bool) public feeExempt;

    VarFee public localFee; // local swap
    VarFee public crossFee; // cross swap

    uint32 public feeSlippage; // slippage converting stable to native

    address public uv3Quoter; // UniswapV3 Quoter
    uint24 public uv3PoolFee; //UniswapV3 pool fee

    uint16 public defaultFeeSplit; // default % of fees split with 2 decimal precision ie 5000/10000

    mapping(address => FeeSplit) public feeSplitReg;
    address[] public feeSplitRegList;

    mapping(address => uint) public splitAccumFees;

    mapping(address => bool) public splitBlackList;

    ITerminusRelay public tRelay;

    address public terminusDelegate;
    address public terminusGasless;

    modifier onlyTerminus() {
        require(address(terminus) == _msgSender() || address(terminusDelegate) == _msgSender(), "only terminus");
        _;
    }

    function initialize(address _feeVault, address[] memory _dexList, string[] memory _funcs, address[] memory _codecs, string[] memory _bridgeProviders, address[] memory _bridgeAdapters) external initializer {
        __Context_init();
        __Ownable_init();

        initDexRegistry(_dexList, _funcs, _codecs);
        initBridgeRegistry(_bridgeProviders, _bridgeAdapters);
        initFeeVaultRegistry(_feeVault);
    }

    function feeSplitRegListLength() external view returns (uint){
        return feeSplitRegList.length;
    }

    function getFee(SwapType _st, uint _stableAmt, address _account, address _tokenIn, address _tokenOut, address _splitAddr) public view returns (uint fee, uint splitFee) {
        if (feeExempt[_account]) return (0, 0);

        if (dexRouter == address(0) && uv3Quoter == address(0)) return (0, 0);
        if (stable == address(0)) return (0, 0);

        VarFee memory _localFee = localFee;
        VarFee memory _crossFee = crossFee;

        FeeSplit memory _fs = feeSplitReg[_splitAddr];

        // overrides on default fees
        if (_splitAddr != address(0) && _fs.feePer > 0 && !splitBlackList[_splitAddr]) {
            if (_fs.localFee.rate > 0) {
                _localFee = _fs.localFee;
            }
            if (_fs.crossFee.rate > 0) {
                _crossFee = _fs.crossFee;
            }
        }

        if (_st == SwapType.Local) {
            /* same chain swap */
            fee = _feeWithTokenOverride(_feeMinMax(_stableAmt, _localFee), _tokenIn, _tokenOut);
        } else if (_st == SwapType.Cross) {
            /* bridging */
            fee = _feeWithTokenOverride(_feeMinMax(_stableAmt, _crossFee), _tokenIn, _tokenOut);
        }

        if (splitBlackList[_splitAddr]) {
            splitFee = 0;
        } else {
            if (_fs.feePer > 0) {
                splitFee = (fee * _fs.feePer) / 1e4;
                fee = fee - splitFee;
            } else if (_splitAddr != address(0)) {
                splitFee = (fee * defaultFeeSplit) / 1e4;
                fee = fee - splitFee;
            }
        }
    }

    function _feeWithTokenOverride(uint _baseFee, address _tokenIn, address _tokenOut) internal view returns (uint) {
        if (tokens[_tokenIn].feeExempt || tokens[_tokenOut].feeExempt) return 0;

        uint feeOverride = tokens[_tokenIn].feeDiscount > 0 ? (_baseFee * uint32(1e6 - tokens[_tokenIn].feeDiscount)) / 1e6 : _baseFee;
        feeOverride = tokens[_tokenOut].feeDiscount > 0 ? (feeOverride * uint32(1e6 - tokens[_tokenOut].feeDiscount)) / 1e6 : feeOverride;

        address[] memory path = new address[](2);
        path[0] = nativeWrap;
        path[1] = stable;

        if (dexRouter == address(0)) {
            UV3.OutParams memory _params = UV3.OutParams(nativeWrap, stable, feeOverride, uv3PoolFee, 0);
            (bool ok, bytes memory _data) = uv3Quoter.staticcall(abi.encodeWithSelector(UV3.quoteExactOutputSingle.selector, _params));
            if (!ok) return 0;
            uint _amtIn = abi.decode(_data, (uint));
            return _amtIn;
        } else {
            (bool ok, bytes memory _data) = dexRouter.staticcall(abi.encodeWithSelector(UV2.getAmountsIn.selector, feeOverride, path));
            if (!ok) return 0;
            uint[] memory amounts = abi.decode(_data, (uint[]));
            return amounts[0];
        }
    }

    function _feeMinMax(uint _amount, VarFee memory _vf) internal pure returns (uint) {
        uint _feeStable = (_amount * _vf.rate) / (100 * 1e4);
        return _amount >= _vf.thres
            ? (_feeStable < _vf.min ? _vf.min : (_feeStable > _vf.max ? _vf.max : _feeStable))
            : _vf.min;
    }

    function _checkFee(bool _cond, uint _fee, uint _checkAmt) internal view {
        require(_cond && (_checkAmt >= ((_fee * (1e4 - feeSlippage)) / 1e4)), "insufficient fee amount");
    }

    function processFee(address _sender, SwapType _st, uint stableAmt, address _stable, address tokenIn, address tokenOut, address _splitAddr) external view onlyTerminus returns (uint _fee, uint _splitFee) {
        return _processFee(_sender, _st, stableAmt, _stable, tokenIn, tokenOut, _splitAddr);
    }

    function _processFee(address _sender, SwapType _st, uint stableAmt, address _stable, address tokenIn, address tokenOut, address _splitAddr) internal view returns (uint _fee, uint _splitFee) {
        if (_sender == address(tRelay) || _sender == address(terminusGasless)) return (0, 0);
        uint _regDec;
        uint _brgDec;
        uint _stableConv = 0;

        if (_stable == stable) {
            _stableConv = stableAmt;
        } else if (stableAmt > 0 && _stable != address(0)) {
            _brgDec = IERC20U(_stable).decimals();
            _regDec = stableDecimals;

            _stableConv = (_brgDec >= _regDec) ? (stableAmt / (10 ** (_brgDec - _regDec))) : (stableAmt * (10 ** (_regDec - _brgDec)));
        }

        return getFee(_st, _stableConv, _sender, tokenIn, tokenOut, _splitAddr);
    }

    function distributeFees(uint _fee, uint _splitFee, address _splitAddr) external payable onlyTerminus {
        _distributeFees(_fee, _splitFee, _splitAddr);
    }

    function _distributeFees(uint _fee, uint _splitFee, address _splitAddr) internal {
        uint _feeSendAmt = address(this).balance;

        bool _okA = true;

        if (_splitFee > 0 && _splitAddr != address(0)) {
            (_okA,) = payable(_splitAddr).call{value: _splitFee}("");

            splitAccumFees[_splitAddr] += _splitFee;
        }

        (bool _okB,) = feeVault.call{value: (_feeSendAmt - _splitFee)}("");

        _checkFee((_okA && _okB), (_fee + _splitFee), _feeSendAmt);
    }

    function setAddresses(address _terminus, address _terminusDelegate, address _terminusGasless, address _terminusRelay, address _nativeWrap, address _stable, uint _stableDecimals, address _dexRouter, address _uv3Quoter, uint24 _uv3PoolFee) public onlyOwnerMulticall {
        terminus = _terminus;
        terminusDelegate = _terminusDelegate;
        terminusGasless = _terminusGasless;
        tRelay = ITerminusRelay(payable(_terminusRelay));
        nativeWrap = _nativeWrap;
        stable = _stable;
        stableDecimals = _stableDecimals;
        dexRouter = _dexRouter;
        uv3Quoter = _uv3Quoter;
        uv3PoolFee = _uv3PoolFee;

        feeExempt[owner()] = true;
    }

    function setDefaultFees(uint16 _defSplit, VarFee calldata _local, VarFee calldata _cross, uint32 _slippage) public onlyOwnerMulticall {
        require(_slippage < 1e4, "_slippage GT 1e4");
        defaultFeeSplit = _defSplit;
        localFee = _local;
        crossFee = _cross;
        feeSlippage = _slippage;
    }

    function setExempt(address[] memory _accounts, bool _enable) public onlyOwnerMulticall {
        for (uint i = 0; i < _accounts.length; i++) {
            feeExempt[_accounts[i]] = _enable;
        }
    }

    function setFeeSplit(address _splitAddr, uint16 _feePer, VarFee calldata _local, VarFee calldata _cross) external onlyOwnerMulticall {
        feeSplitReg[_splitAddr] = FeeSplit(_feePer, _local, _cross);

        bool _found = false;
        for (uint i = 0; i < feeSplitRegList.length; i++) {
            if (feeSplitRegList[i] == _splitAddr) {
                _found = true;
                break;
            }
        }

        if (!_found) {
            feeSplitRegList.push(_splitAddr);
        }
    }

    function removeFeeSplit(address _splitAddr) external onlyOwnerMulticall {
        // remove fee split but do not remove accumulated fees
        feeSplitReg[_splitAddr] = FeeSplit(0, VarFee(0, 0, 0, 0), VarFee(0, 0, 0, 0));
    }

    function setSplitBlackList(address[] memory _accounts, bool _enable) public onlyOwnerMulticall {
        for (uint i = 0; i < _accounts.length; i++) {
            splitBlackList[_accounts[i]] = _enable;
        }
    }

    uint256[50] private __gap;

}
