// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IStrategy is IERC20Metadata {
    event YieldClaimed(address yieldClaimer, address treasury, address token, uint256 amount);
    event Deposit(address owner, uint256 amount);
    event Withdraw(address owner, uint256 amount);
    event WithdrawUnderlying(address owner, uint256 amount);
    event UpdateftYieldWrapper(address newftYieldWrapper);

    error StrategyNotYieldWrapper();
    error StrategyZeroAddress();
    error StrategyAmountZero();
    error StrategyInsufficientLiquidity();
    error StrategyCantInteractWithCoreAssets();
    error StrategyCapitalMustNotChange();

    function token() external view returns (address);

    function valueOfCapital() external view returns (uint256);

    function setftYieldWrapper(address _ftYieldWrapper) external;

    function capital() external view returns (uint256);

    function yield() external view returns (uint256);

    function claimYield(address treasury) external returns (uint256);

    function execute(
        address to,
        uint256 value,
        bytes calldata data
    )
        external
        returns (bool success, bytes memory result);

    function availableToWithdraw() external view returns (uint256);

    function maxAbleToWithdraw(uint256 amount) external view returns (uint256);

    function withdraw(uint256 amount) external returns (uint256);

    function deposit(uint256 amount) external;

    /// @dev Address of the strategy's position token (e.g., aToken, stETH, etc)
    function positionToken() external view returns (address);

    /// @dev Burns wrapper's strategy shares and transfers `amount` of the position token to `to`.
    /// Must return the actual amount sent (should be == amount for 1:1 strategies).
    function withdrawUnderlying(uint256 amount) external returns (uint256 received);
}

interface IStrategyWithQueue is IStrategy {
    event WithdrawQueued(address owner, uint256 amount, uint256 id);
    event WithdrawClaimed(address owner, uint256 amount, uint256 id);

    function withdrawQueued(uint256 amount) external returns (uint256 id);
    function claimQueued(uint256 id) external returns (uint256 received);
}
