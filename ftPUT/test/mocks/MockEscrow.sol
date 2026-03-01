// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Escrow {
    IERC20 public constant FT = IERC20(address(0xF));

    address public immutable owner;
    address public immutable recipient;
    IERC20 public immutable denomination;
    uint256 public immutable amountDenom;

    uint256 public withdrawnAmountDenom;

    constructor(address _owner, address _recipient, address _denomination, uint256 _amountDenom) {
        owner = _owner;
        recipient = _recipient;
        denomination = IERC20(_denomination);
        amountDenom = _amountDenom;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call");
        _;
    }

    function exitFT(uint256 amount) external onlyOwner {
        FT.transfer(owner, amount);
    }

    function withdrawDenom(uint256 amount) external onlyOwner {
        withdrawnAmountDenom += amount;
        denomination.transfer(owner, amount);
    }

    function withdrawFT(uint256 amount) external {
        require(msg.sender == recipient, "Only recipient can call");
        require(
            denomination.balanceOf(address(this)) + withdrawnAmountDenom >= amountDenom,
            "Not enough denom"
        );
        FT.transfer(recipient, amount);
    }
}
