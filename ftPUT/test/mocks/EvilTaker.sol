// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract EvilTaker {
    IERC20 public aToken;

    constructor(address _aToken) {
        aToken = IERC20(_aToken);
    }

    function take() external {
        // Take 1 aUSDC from whoever gave us approval
        aToken.transferFrom(msg.sender, address(this), 1);
    }
}
