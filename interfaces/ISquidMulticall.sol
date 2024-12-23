// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;


interface ISquidMulticall {
    enum CallType {
        Default,
        FullTokenBalance,
        FullNativeBalance,
        CollectTokenBalance
    }

    struct Call {
        CallType callType;
        address target;
        uint256 value;
        bytes callData;
        bytes payload;
    }

    function run(Call[] calldata calls) external payable;
}
