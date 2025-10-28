// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.25;


import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "../lib/MultiCallable.sol";


/**
 * @title Allows the owner to set fee account
 * @author Padoriku
 */
abstract contract FeeVaultRegistry is MultiCallable {
    address public feeVault;

    event FeeVaultUpdated(address from, address to);

    function initFeeVaultRegistry(address _vault) internal onlyInitializing {
        _setFeeVault(_vault);
    }

    function setFeeVault(address _vault) external onlyOwnerMulticall {
        _setFeeVault(_vault);
    }

    function _setFeeVault(address _vault) private {
        address oldFeeCollector = feeVault;
        feeVault = _vault;
        emit FeeVaultUpdated(oldFeeCollector, _vault);
    }
}
