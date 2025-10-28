// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.25;


import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

abstract contract MultiCallable is OwnableUpgradeable {

    address public multicall;

    modifier onlyOwnerMulticall() {
        require(msg.sender == multicall || msg.sender == owner(), "not owner or mcall");
        _;
    }

    function setMulticall(address _addr) external onlyOwner {
        multicall = _addr;
    }
}
