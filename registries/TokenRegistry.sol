// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "../lib/Multicallable.sol";

abstract contract TokenRegistry is Multicallable {

    // @notice this is also defined in Types.sol, make sure they are identical
    struct TokenParams {
        address pairedWith;
        address dex;
        bool exclusiveDex; // use only defined dex
        int32 feeDiscount; // 1e4: 100% = 1000000
        bool feeExempt; // no fees
    }

    mapping(address => TokenParams) public tokens;

    function setToken(address _token, TokenParams memory _params) external onlyOwnerMulticall {
        tokens[_token] = _params;
    }
}
