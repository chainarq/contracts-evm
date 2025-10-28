// SPDX-License-Identifier: Unlicensed
pragma solidity ^0.8.25;


// @notice This contract is used only on BSC, due to some bizzare issue with WBNB withdrawals,
//         which consistently fail when (apparently) being called from within an openzeppelin proxied contract.
//         Having an external contract perform the withdrawal (WBNB->BNB) and then sending it back
//         to the proxied contract works fine.
//         Note that WETH withdrawal from proxied contracts seems to ONLY fail in Binance Smart Chain

contract BNBWrap {
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    function bnbWithdraw(uint256 amount) external {
        address _sender = msg.sender;

        // transferFrom(address from, address to, uint256 amount) external returns (bool)
        (bool okA,) = WBNB.call(abi.encodeWithSelector(0x23b872dd, _sender, address(this), amount));
        require(okA, "wbnb transferFrom failed");

        // withdraw(uint amount)
        (bool okB,) = WBNB.call(abi.encodeWithSelector(0x2e1a7d4d, amount));
        require(okB, "withdraw failed");

        (bool okC,) = _sender.call{value: amount, gas: 40000}("");
        require(okC, "failed to send native");
    }

    fallback() external payable {}

    receive() external payable {}
}
