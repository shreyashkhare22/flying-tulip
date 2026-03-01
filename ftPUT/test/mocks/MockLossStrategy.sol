// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {MockStrategy} from "./MockStrategy.sol";

contract MockLossStrategy is MockStrategy {
    uint256 public lossPercentage = 50;

    constructor(address token_) MockStrategy(token_) {}

    function setLossPercentage(uint256 _lossPercentage) external {
        require(_lossPercentage <= 100, "Loss cannot exceed 100%");
        lossPercentage = _lossPercentage;
    }

    function simulateLoss() external {
        uint256 currentBalance = underlying.balanceOf(address(this));
        uint256 lossAmount = (currentBalance * lossPercentage) / 100;

        if (lossAmount > 0) {
            underlying.transfer(address(0xdead), lossAmount);
        }

        if (capitalBase > lossAmount) {
            capitalBase -= lossAmount;
        } else {
            capitalBase = 0;
        }
    }
}
