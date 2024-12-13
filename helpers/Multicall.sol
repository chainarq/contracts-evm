// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";

contract Multicall is Ownable {

    struct Call {
        address target;
        bytes callData;
    }

    function aggregate(Call[] calldata calls) public onlyOwner payable {
        uint256 length = calls.length;
        Call calldata call;
        for (uint256 i = 0; i < length;) {
            bool success;
            call = calls[i];
            (success,) = call.target.call(call.callData);
            require(success, "Multicall call failed");
            unchecked {++i;}
        }
    }
}
