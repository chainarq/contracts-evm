// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;


import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20PermitUpgradeable.sol";

interface IERC20U is IERC20Upgradeable, IERC20PermitUpgradeable {
    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function decimals() external view returns (uint8);
}
