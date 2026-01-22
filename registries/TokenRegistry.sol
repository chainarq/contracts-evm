// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.25;


import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "../lib/MultiCallable.sol";

abstract contract TokenRegistry is MultiCallable {

    struct TokenParams {
        address pairedWith;
        address dex;
        bool exclusiveDex; // use only defined dex
        int32 feeDiscount; // 1e4: 100% = 1000000
        bool feeExempt; // no fees
    }

    mapping(address => TokenParams) public tokens;

    function setToken(address _token, TokenParams memory _params) external onlyOwnerMulticall {
        require(tokens[_token].feeDiscount < 1e6, "discount GT 1e6");
        tokens[_token] = _params;
    }
}
