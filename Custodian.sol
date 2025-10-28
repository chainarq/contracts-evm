// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.25;

// @notice This contract is a replacement for Pocket contract, because selfdestruct is becoming deprecated and will eventually "break" it

contract Custodian {
    address public terminus;

    constructor(address _terminus){
        terminus = _terminus;
    }

    function claim(address _token) external {
        address _sender = msg.sender;
        require(_sender == terminus, "denied");

        if (_token == address(0)) {
            _sender.call{value: address(this).balance, gas: 50000}("");
        } else {
            (bool _ok, bytes memory _data) = _token.call(abi.encodeWithSelector(0x70a08231, address(this)));
            if (_ok) {
                uint _balance = abi.decode(_data, (uint));
                if (_balance > 0) _token.call(abi.encodeWithSelector(0xa9059cbb, _sender, _balance));
            }
        }

    }

    receive() external payable {}
}
