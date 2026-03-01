// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    function transfer(address to, uint256 amount) external returns (bool);

    function balanceOf(address account) external view returns (uint256);
}

contract MockYieldWrapper {
    address public token;
    uint256 public totalDeposited;

    constructor(address _token) {
        token = _token;
    }

    function deposit(uint256 amount) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        totalDeposited += amount;
    }

    function withdraw(uint256 amount, address to) external {
        require(totalDeposited >= amount, "Insufficient balance");
        totalDeposited -= amount;
        IERC20(token).transfer(to, amount);
    }

    function canWithdraw(uint256 amount) external view returns (bool) {
        return totalDeposited >= amount && IERC20(token).balanceOf(address(this)) >= amount;
    }

    function maxAbleToWithdraw(uint256 amount) external view returns (uint256) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 available = totalDeposited;

        if (balance < available) available = balance;
        if (amount < available) return amount;
        return available;
    }
}
