// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "../interfaces/IERC20U.sol";
import "../BNBWrap.sol";

abstract contract NativeWrap is OwnableUpgradeable {
    using SafeERC20Upgradeable for IERC20U;

    address public nativeWrap;

    BNBWrap public bnbWrap;

    address public constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    event NativeWrapUpdated(address nativeWrap);

    function initNativeWrap(address _nativeWrap) internal onlyInitializing {
        _setNativeWrap(_nativeWrap);
    }

    function setNativeWrap(address _nativeWrap) external onlyOwner {
        _setNativeWrap(_nativeWrap);
    }

    function _setNativeWrap(address _nativeWrap) private {
        nativeWrap = _nativeWrap;
        emit NativeWrapUpdated(_nativeWrap);
    }

    function depositNative(uint amount) internal {
        (bool ok,) = nativeWrap.call{value: amount}(abi.encodeWithSelector(0xd0e30db0));
        require(ok, "deposit failed");
    }

    function withdrawNative(uint amount) internal {
        if (block.chainid == 56) {
            IERC20U(nativeWrap).safeApprove(address(bnbWrap), amount);
            bnbWrap.bnbWithdraw(amount);
            IERC20U(nativeWrap).safeApprove(address(bnbWrap), 0);
        } else {
            (bool ok,) = nativeWrap.call(abi.encodeWithSelector(0x2e1a7d4d, amount));
            require(ok, "withdraw failed");
        }
    }

    // ONLY FOR BSC CHAIN
    function setBNBWrap(address payable _addr) external onlyOwner {
        bnbWrap = BNBWrap(_addr);
    }

    receive() external payable {}

    fallback() external payable {}
}
