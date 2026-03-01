// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/// @title ICircuitBreaker
/// @notice Interface for the optional circuit breaker module
/// @dev Designed for fail-open behavior - all calls should be wrapped in try/catch
interface ICircuitBreaker {
    // ============ Events ============

    /// @notice Emitted when an inflow (deposit) is recorded
    /// @param asset The collateral token address
    /// @param amount The amount deposited
    /// @param newTvl The TVL after this deposit
    event Inflow(address indexed asset, uint256 amount, uint256 newTvl);

    /// @notice Emitted when an outflow (withdrawal) is recorded
    /// @param asset The collateral token address
    /// @param amount The amount withdrawn
    /// @param newTvl The TVL after this withdrawal
    event Outflow(address indexed asset, uint256 amount, uint256 newTvl);

    /// @notice Emitted when a rate limit is triggered
    /// @param asset The collateral token address
    /// @param requested The amount requested to withdraw
    /// @param available The maximum amount available to withdraw
    event RateLimitTriggered(address indexed asset, uint256 requested, uint256 available);

    /// @notice Emitted when the circuit breaker configuration is updated
    /// @param maxDrawRateWad Maximum withdrawal rate as WAD (1e18 = 100%)
    /// @param mainWindow Time for main buffer to fully replenish (in seconds)
    /// @param elasticWindow Time for elastic buffer to decay (in seconds)
    event ConfigUpdated(uint256 maxDrawRateWad, uint256 mainWindow, uint256 elasticWindow);

    /// @notice Emitted when the circuit breaker is paused
    /// @param by The address that paused the circuit breaker
    event CircuitBreakerPaused(address indexed by);

    /// @notice Emitted when the circuit breaker is unpaused
    /// @param by The address that unpaused the circuit breaker
    event CircuitBreakerUnpaused(address indexed by);

    /// @notice Emitted when an emergency override is performed
    /// @param asset The collateral token address
    /// @param amount The amount added to withdrawal capacity
    event EmergencyOverride(address indexed asset, uint256 amount);

    // ============ Core Functions ============

    /// @notice Record an asset inflow (deposit)
    /// @dev Called after assets have been transferred in
    /// @param asset The collateral token address
    /// @param amount The amount deposited
    /// @param preTvl The TVL before this deposit
    function recordInflow(address asset, uint256 amount, uint256 preTvl) external;

    /// @notice Check if outflow is allowed and record it
    /// @dev Called before assets are transferred out
    /// @param asset The collateral token address
    /// @param amount The amount to withdraw
    /// @param preTvl The TVL before this withdrawal
    /// @return allowed Whether the withdrawal is within rate limits
    /// @return available The maximum amount that could be withdrawn
    function checkAndRecordOutflow(
        address asset,
        uint256 amount,
        uint256 preTvl
    )
        external
        returns (bool allowed, uint256 available);

    // ============ View Functions ============

    /// @notice Get the current withdrawal capacity for an asset
    /// @param asset The collateral token address
    /// @param currentTvl The current TVL
    /// @return capacity The maximum amount that can be withdrawn
    function withdrawalCapacity(
        address asset,
        uint256 currentTvl
    )
        external
        view
        returns (uint256 capacity);

    /// @notice Check if the circuit breaker is currently active (not paused)
    /// @return active True if the circuit breaker is active, false if paused
    function isActive() external view returns (bool active);

    // ============ Monitoring View Functions ============

    /// @notice Get all protected contracts
    /// @return contracts Array of protected contract addresses
    function getProtectedContracts() external view returns (address[] memory contracts);

    /// @notice Get count of protected contracts
    /// @return count Number of protected contracts
    function protectedContractCount() external view returns (uint256 count);

    /// @notice Get all tracked assets
    /// @return assets Array of tracked asset addresses
    function getTrackedAssets() external view returns (address[] memory assets);

    /// @notice Get count of tracked assets
    /// @return count Number of tracked assets
    function trackedAssetCount() external view returns (uint256 count);

    /// @notice Get health metrics for an asset
    /// @param asset The asset to query
    /// @param currentTvl The current TVL
    /// @return mainUtilizationBps Main buffer usage in basis points (0 = full, 10000 = depleted)
    /// @return elasticBuffer Current elastic buffer amount
    /// @return totalCapacity Total withdrawal capacity
    /// @return maxCapacity Maximum possible capacity
    /// @return secondsUntilFullReplenishment Seconds until main buffer fully replenishes
    function getAssetHealth(
        address asset,
        uint256 currentTvl
    )
        external
        view
        returns (
            uint256 mainUtilizationBps,
            uint256 elasticBuffer,
            uint256 totalCapacity,
            uint256 maxCapacity,
            uint256 secondsUntilFullReplenishment
        );

    /// @notice Get comprehensive system status
    /// @return active Whether circuit breaker is active
    /// @return adminAddr Current admin address
    /// @return maxDrawRateBps Max draw rate in basis points
    /// @return mainWindowSecs Main window in seconds
    /// @return elasticWindowSecs Elastic window in seconds
    /// @return numProtectedContracts Number of protected contracts
    /// @return numTrackedAssets Number of tracked assets
    function getSystemStatus()
        external
        view
        returns (
            bool active,
            address adminAddr,
            uint256 maxDrawRateBps,
            uint256 mainWindowSecs,
            uint256 elasticWindowSecs,
            uint256 numProtectedContracts,
            uint256 numTrackedAssets
        );

    // ============ Admin Functions ============

    /// @notice Pause the circuit breaker (allows all transactions)
    /// @dev Only callable by admin
    function pause() external;

    /// @notice Unpause the circuit breaker
    /// @dev Only callable by admin
    function unpause() external;

    /// @notice Update rate limiting configuration
    /// @dev Only callable by admin
    /// @param maxDrawRateWad Maximum withdrawal rate as WAD (1e18 = 100%)
    /// @param mainWindow Time for main buffer to fully replenish (in seconds)
    /// @param elasticWindow Time for elastic buffer to decay (in seconds)
    function updateConfig(
        uint256 maxDrawRateWad,
        uint256 mainWindow,
        uint256 elasticWindow
    )
        external;

    /// @notice Emergency override to allow a specific withdrawal
    /// @dev Only callable by admin, for false positive resolution
    /// @param asset The collateral token address
    /// @param amount The amount to allow for withdrawal
    function emergencyOverride(address asset, uint256 amount) external;
}
