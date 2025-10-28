// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.25;


interface IBridgeAdapter {
    function bridge(
        uint64 _dstChainId,
    // the address that the fund is transfered to on the destination chain
        address _receiver,
        uint256 _amount,
        address _token,
    // Bridge transfers quoted and abi encoded by chainarq backend server.
    // Bridge adapter implementations need to decode this themselves.
        bytes memory _bridgeParams,
        bytes memory _bridgePayload
    ) external payable returns (bytes memory bridgeResp);
}
