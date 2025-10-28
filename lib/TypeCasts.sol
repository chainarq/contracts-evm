// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.25;

library TypeCasts {
    // alignment preserving cast
    function addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

    function uint64ToBytes32(uint64 _val) internal pure returns (bytes32) {
        return bytes32(uint256(_val));
    }

    // alignment preserving cast
    function bytes32ToAddress(bytes32 _buf) internal pure returns (address) {
        return address(uint160(uint256(_buf)));
    }
}
