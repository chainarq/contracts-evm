// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

contract Custodian {
    address public terminus;

    constructor(address _terminus){
        terminus = _terminus;
    }

    function claim(address _token, uint256 _amt) external {
        address _sender = msg.sender;
        require(_sender == terminus, "denied");
        _token.call(abi.encodeWithSelector(0xa9059cbb, _sender, _amt));
        _sender.call{value: address(this).balance}("");
    }

    receive() external payable {}
}
