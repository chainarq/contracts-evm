// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "../interfaces/IERC20U.sol";

import "../interfaces/IBridgeAdapter.sol";
import "../interfaces/IHyphenLiquidityPool.sol";

import "../lib/NativeWrap.sol";

contract HyphenAdapter is Initializable, IBridgeAdapter, NativeWrap {
    using SafeERC20Upgradeable for IERC20U;

    address public pool;

    event PoolUpdated(address pool);

    function initialize(address _nativeWrap) external initializer {
        __Context_init();
        __Ownable_init();
        initNativeWrap(_nativeWrap);
    }

    function bridge(uint64 _dstChainId, address _receiver, uint256 _amount, address _token, bytes memory /* _bridgeParams */, bytes memory /*_bridgePayload*/) external payable returns (bytes memory bridgeResp) {
        require(pool != address(0), "pool not set");
        IERC20U(_token).safeTransferFrom(msg.sender, address(this), _amount);
        if (_token == nativeWrap) {
            // depositErc20 doesn't work for WETH, so we have to convert it back to native first
            withdrawNative(_amount);

            IHyphenLiquidityPool(pool).depositNative{value: _amount}(_receiver, _dstChainId, "chainarq");
        } else {
            IERC20U(_token).safeIncreaseAllowance(pool, _amount);
            IHyphenLiquidityPool(pool).depositErc20(_dstChainId, _token, _receiver, _amount, "chainarq");
        }
        // hyphen uses src tx hash to track history so bridgeResp is not needed. returning empty
        return bridgeResp;
    }

    function setPool(address _pool) external onlyOwner {
        pool = _pool;
        emit PoolUpdated(_pool);
    }

    function rescueFund(address _token) external onlyOwner {
        if (_token == address(0)) {
            (bool ok,) = owner().call{value: address(this).balance}("");
            require(ok, "send native failed");
        } else {
            IERC20U(_token).safeTransfer(owner(), IERC20U(_token).balanceOf(address(this)));
        }
    }

}
