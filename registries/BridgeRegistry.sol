// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.25;


import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "../lib/MultiCallable.sol";

import "../interfaces/IBridgeAdapter.sol";


/**
 * @title Manages a list of supported bridges
 * @author lionelhoho
 * @author Padoriku
 */
abstract contract BridgeRegistry is MultiCallable {
    event SupportedBridgesUpdated(string[] providers, address[] adapters);

    mapping(bytes32 => IBridgeAdapter) public bridges;

    function initBridgeRegistry(string[] memory _providers, address[] memory _adapters) internal onlyInitializing {
        _setSupportedbridges(_providers, _adapters);
    }

    // to disable a bridge, set the bridge addr of the corresponding provider to address(0)
    function setSupportedBridges(string[] memory _providers, address[] memory _adapters) external onlyOwnerMulticall {
        _setSupportedbridges(_providers, _adapters);
    }

    function _setSupportedbridges(string[] memory _providers, address[] memory _adapters) private {
        require(_providers.length == _adapters.length, "params size mismatch");
        for (uint256 i = 0; i < _providers.length; i++) {
            bridges[keccak256(bytes(_providers[i]))] = IBridgeAdapter(_adapters[i]);
        }
        emit SupportedBridgesUpdated(_providers, _adapters);
    }

    uint256[50] private __gap;
}
