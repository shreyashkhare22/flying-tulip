// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockAavePool {
    mapping(address => uint256) public userCollateral;
    mapping(address => uint256) public userDebt;
    mapping(address => uint8) public userEMode;

    // Mock price: 1 token = 1 USD (in 8 decimals)
    uint256 internal constant MOCK_PRICE = 1e8;

    function setUserEMode(uint8 categoryId) external {
        userEMode[msg.sender] = categoryId;
    }

    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 /*referralCode*/
    )
        external
        virtual
    {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        userCollateral[onBehalfOf] += amount;
    }

    function withdraw(address asset, uint256 amount, address to)
        external
        virtual
        returns (uint256)
    {
        require(userCollateral[msg.sender] >= amount, "Insufficient collateral");
        userCollateral[msg.sender] -= amount;
        IERC20(asset).transfer(to, amount);
        return amount;
    }

    function borrow(
        address asset,
        uint256 amount,
        uint256, /*interestRateMode*/
        uint16, /*referralCode*/
        address onBehalfOf
    )
        external
    {
        userDebt[onBehalfOf] += amount;
        IERC20(asset).transfer(msg.sender, amount);
    }

    function repay(
        address asset,
        uint256 amount,
        uint256, /*interestRateMode*/
        address onBehalfOf
    )
        external
        returns (uint256)
    {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        if (userDebt[onBehalfOf] >= amount) {
            userDebt[onBehalfOf] -= amount;
            return amount;
        } else {
            uint256 actualRepay = userDebt[onBehalfOf];
            userDebt[onBehalfOf] = 0;
            return actualRepay;
        }
    }

    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        totalCollateralBase = (userCollateral[user] * MOCK_PRICE) / 1e10; // Convert to 8 decimals
        totalDebtBase = (userDebt[user] * MOCK_PRICE) / 1e10;

        // Mock values for testing
        currentLiquidationThreshold = 8500; // 85%
        ltv = 8000; // 80%

        availableBorrowsBase = (totalCollateralBase * ltv) / 10000;
        if (availableBorrowsBase > totalDebtBase) {
            availableBorrowsBase -= totalDebtBase;
        } else {
            availableBorrowsBase = 0;
        }

        if (totalDebtBase == 0) {
            healthFactor = type(uint256).max;
        } else {
            healthFactor = (((totalCollateralBase * currentLiquidationThreshold) / 10000) * 1e18)
                / totalDebtBase;
        }
    }

    // Helper function to set user data for testing
    function setUserData(address user, uint256 collateral, uint256 debt) external {
        userCollateral[user] = collateral;
        userDebt[user] = debt;
    }
}
