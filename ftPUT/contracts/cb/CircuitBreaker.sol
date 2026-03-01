// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {ICircuitBreaker} from "../interfaces/ICircuitBreaker.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title CircuitBreaker
/// @notice Rate limiter implementing dual buffer system (ERC-7265 inspired)
/// @dev Uses main buffer (time-replenishing) + elastic buffer (deposit-tracking) to prevent flashloan DoS
contract CircuitBreaker is ICircuitBreaker, Ownable2Step {
    using SafeCast for uint256;

    // ============ Structs ============

    /// @notice Configuration for rate limiting (packed into 1 slot)
    struct LimiterConfig {
        uint64 maxDrawRateWad; // Maximum withdrawal rate as WAD (1e18 = 100%), max ~18.4e18
        uint48 mainWindow; // Time for main buffer to fully replenish (seconds), max ~8.9M years
        uint48 elasticWindow; // Time for elastic buffer to decay to zero (seconds)
    }

    /// @notice State tracking for an asset's rate limiter (packed into 1 slot)
    struct LimiterState {
        uint96 mainBuffer; // Current main buffer capacity, max ~7.9e28
        uint96 elasticBuffer; // Current elastic buffer capacity
        uint48 lastUpdate; // Timestamp of last state update
    }

    // ============ State Variables ============

    /// @notice Global rate limiting configuration
    LimiterConfig public config;

    /// @notice Per-asset rate limiter state
    mapping(address asset => LimiterState state) public assetState;

    /// @notice Whether the circuit breaker is paused (allows all transactions)
    bool public paused;

    /// @notice Whitelist of addresses allowed to call recordInflow/checkAndRecordOutflow
    mapping(address => bool) public protectedContracts;

    /// @notice Array of protected contracts for enumeration
    address[] internal _protectedContractList;

    /// @notice Index tracking for O(1) removal from protected contract list
    mapping(address => uint256) internal _protectedContractIndex;

    /// @notice Array of assets with tracked state for enumeration
    address[] internal _trackedAssets;

    /// @notice Whether an asset is already in the tracked list
    mapping(address => bool) public isTrackedAsset;

    // ============ Errors ============

    error CircuitBreakerInvalidConfig();
    error CircuitBreakerZeroAddress();
    error CircuitBreakerNotProtectedContract();

    // ============ Events ============

    event ProtectedContractAdded(address indexed protectedContract);
    event ProtectedContractRemoved(address indexed protectedContract);

    // ============ Modifiers ============

    modifier onlyProtectedContract() {
        if (!protectedContracts[msg.sender]) revert CircuitBreakerNotProtectedContract();
        _;
    }

    // ============ Constructor ============

    /// @notice Initialize circuit breaker with configuration
    /// @param maxDrawRateWad Maximum withdrawal rate as WAD (1e18 = 100%)
    /// @param mainWindow Time for main buffer to fully replenish (seconds)
    /// @param elasticWindow Time for elastic buffer to decay (seconds)
    constructor(
        uint256 maxDrawRateWad,
        uint256 mainWindow,
        uint256 elasticWindow
    )
        Ownable(msg.sender)
    {
        _updateConfig(maxDrawRateWad, mainWindow, elasticWindow);
        paused = false;
    }

    // ============ Core Functions ============

    /// @inheritdoc ICircuitBreaker
    function recordInflow(
        address asset,
        uint256 amount,
        uint256 preTvl
    )
        external
        onlyProtectedContract
    {
        // If paused, don't track inflows (state frozen)
        if (paused) {
            return;
        }

        LimiterState storage state = assetState[asset];

        // Update buffers with time decay/replenishment before processing inflow
        _updateBuffers(asset, state, preTvl);

        // Increase elastic buffer by deposit amount
        state.elasticBuffer = (uint256(state.elasticBuffer) + amount).toUint96();

        emit Inflow(asset, amount, preTvl + amount);
    }

    /// @inheritdoc ICircuitBreaker
    function checkAndRecordOutflow(
        address asset,
        uint256 amount,
        uint256 preTvl
    )
        external
        onlyProtectedContract
        returns (bool allowed, uint256 available)
    {
        // If paused, allow all withdrawals
        if (paused) {
            return (true, type(uint256).max);
        }

        LimiterState storage state = assetState[asset];

        // Update buffers with time decay/replenishment
        _updateBuffers(asset, state, preTvl);

        // Calculate total available capacity
        available = state.mainBuffer + state.elasticBuffer;

        // Check if withdrawal fits within capacity
        if (amount <= available) {
            // Deduct from elastic buffer first, then main buffer
            if (amount <= state.elasticBuffer) {
                state.elasticBuffer -= uint96(amount);
            } else {
                uint256 remainingAfterElastic = amount - state.elasticBuffer;
                state.elasticBuffer = 0;
                state.mainBuffer -= uint96(remainingAfterElastic);
            }

            emit Outflow(asset, amount, preTvl - amount);
            return (true, available);
        } else {
            // Rate limit exceeded - wrapper will revert
            return (false, available);
        }
    }

    // ============ View Functions ============

    /// @inheritdoc ICircuitBreaker
    function withdrawalCapacity(
        address asset,
        uint256 currentTvl
    )
        external
        view
        returns (uint256 capacity)
    {
        if (paused) {
            return type(uint256).max;
        }

        LimiterState memory state = assetState[asset];

        // Simulate buffer updates without modifying state
        (uint256 mainBuffer, uint256 elasticBuffer) = _calculateBuffers(state, currentTvl);

        return mainBuffer + elasticBuffer;
    }

    /// @inheritdoc ICircuitBreaker
    function isActive() external view returns (bool active) {
        return !paused;
    }

    /// @notice Get the current configuration
    /// @return maxDrawRateWad Maximum withdrawal rate as WAD
    /// @return mainWindow Time for main buffer to fully replenish
    /// @return elasticWindow Time for elastic buffer to decay
    function getConfig()
        external
        view
        returns (uint256 maxDrawRateWad, uint256 mainWindow, uint256 elasticWindow)
    {
        return (config.maxDrawRateWad, config.mainWindow, config.elasticWindow);
    }

    /// @notice Get the current state for an asset (with time-adjusted values)
    /// @param asset The asset to query
    /// @param currentTvl The current TVL for accurate buffer calculation
    /// @return mainBuffer Current main buffer capacity
    /// @return elasticBuffer Current elastic buffer capacity
    /// @return lastUpdate Timestamp of last state update
    function getAssetState(
        address asset,
        uint256 currentTvl
    )
        external
        view
        returns (uint256 mainBuffer, uint256 elasticBuffer, uint256 lastUpdate)
    {
        LimiterState memory state = assetState[asset];
        (mainBuffer, elasticBuffer) = _calculateBuffers(state, currentTvl);
        return (mainBuffer, elasticBuffer, state.lastUpdate);
    }

    /// @notice Get raw asset state without time adjustments (for debugging)
    /// @param asset The asset to query
    function getRawAssetState(address asset)
        external
        view
        returns (uint256 mainBuffer, uint256 elasticBuffer, uint256 lastUpdate)
    {
        LimiterState memory state = assetState[asset];
        return (state.mainBuffer, state.elasticBuffer, state.lastUpdate);
    }

    // ============ Enumeration View Functions ============

    /// @notice Get all protected contracts
    /// @return contracts Array of protected contract addresses
    function getProtectedContracts() external view returns (address[] memory contracts) {
        return _protectedContractList;
    }

    /// @notice Get count of protected contracts
    /// @return count Number of protected contracts
    function protectedContractCount() external view returns (uint256 count) {
        return _protectedContractList.length;
    }

    /// @notice Get all tracked assets (assets that have had inflows/outflows recorded)
    /// @return assets Array of tracked asset addresses
    function getTrackedAssets() external view returns (address[] memory assets) {
        return _trackedAssets;
    }

    /// @notice Get count of tracked assets
    /// @return count Number of tracked assets
    function trackedAssetCount() external view returns (uint256 count) {
        return _trackedAssets.length;
    }

    // ============ Monitoring View Functions ============

    /// @notice Get health metrics for an asset (for status page display)
    /// @param asset The asset to query
    /// @param currentTvl The current TVL for accurate calculations
    /// @return mainUtilizationBps Main buffer usage in basis points (0 = full capacity, 10000 = depleted)
    /// @return elasticBuffer Current elastic buffer amount
    /// @return totalCapacity Total withdrawal capacity available now
    /// @return maxCapacity Maximum possible capacity (cap when fully replenished)
    /// @return secondsUntilFullReplenishment Estimated seconds until main buffer fully replenishes (0 if full)
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
        )
    {
        if (paused) {
            return (0, type(uint256).max, type(uint256).max, type(uint256).max, 0);
        }

        LimiterState memory state = assetState[asset];
        uint256 cap = (currentTvl * config.maxDrawRateWad) / 1e18;

        (uint256 mainBuffer, uint256 elastic) = _calculateBuffers(state, currentTvl);

        // Main utilization in basis points: 0 = full capacity, 10000 = fully depleted
        if (cap > 0) {
            mainUtilizationBps = ((cap - mainBuffer) * 10000) / cap;
        }

        // Time until full replenishment
        if (mainBuffer < cap && cap > 0) {
            uint256 deficit = cap - mainBuffer;
            // replenishment rate = cap / mainWindow, so time = deficit * mainWindow / cap
            secondsUntilFullReplenishment = (deficit * config.mainWindow) / cap;
        }

        return
            (mainUtilizationBps, elastic, mainBuffer + elastic, cap, secondsUntilFullReplenishment);
    }

    /// @notice Get comprehensive system status for monitoring dashboards
    /// @return active Whether circuit breaker is active (not paused)
    /// @return adminAddr Current admin address
    /// @return maxDrawRateBps Max draw rate in basis points (e.g., 500 = 5%)
    /// @return mainWindowSecs Main window in seconds
    /// @return elasticWindowSecs Elastic window in seconds
    /// @return numProtectedContracts Number of registered protected contracts
    /// @return numTrackedAssets Number of assets with recorded state
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
        )
    {
        return (
            !paused,
            owner(),
            config.maxDrawRateWad / 1e14, // Convert WAD to basis points
            config.mainWindow,
            config.elasticWindow,
            _protectedContractList.length,
            _trackedAssets.length
        );
    }

    // ============ Admin Functions ============

    /// @inheritdoc ICircuitBreaker
    function pause() external onlyOwner {
        paused = true;
        emit CircuitBreakerPaused(owner());
    }

    /// @inheritdoc ICircuitBreaker
    function unpause() external onlyOwner {
        paused = false;
        emit CircuitBreakerUnpaused(owner());
    }

    /// @inheritdoc ICircuitBreaker
    function updateConfig(
        uint256 maxDrawRateWad,
        uint256 mainWindow,
        uint256 elasticWindow
    )
        external
        onlyOwner
    {
        _updateConfig(maxDrawRateWad, mainWindow, elasticWindow);
    }

    /// @inheritdoc ICircuitBreaker
    function emergencyOverride(address asset, uint256 amount) external onlyOwner {
        LimiterState storage state = assetState[asset];

        // Add the amount to main buffer to allow this specific withdrawal
        state.mainBuffer = (uint256(state.mainBuffer) + amount).toUint96();
        emit EmergencyOverride(asset, amount);
    }

    /// @notice Register a contract as allowed to call recordInflow/checkAndRecordOutflow
    /// @param protectedContract The contract address to register
    function addProtectedContract(address protectedContract) external onlyOwner {
        if (protectedContract == address(0)) revert CircuitBreakerZeroAddress();
        if (protectedContracts[protectedContract]) return; // Already registered

        protectedContracts[protectedContract] = true;

        // Track index for O(1) removal (index + 1 to distinguish from default 0)
        _protectedContractIndex[protectedContract] = _protectedContractList.length + 1;
        _protectedContractList.push(protectedContract);

        emit ProtectedContractAdded(protectedContract);
    }

    /// @notice Unregister a contract from calling recordInflow/checkAndRecordOutflow
    /// @param protectedContract The contract address to unregister
    function removeProtectedContract(address protectedContract) external onlyOwner {
        if (!protectedContracts[protectedContract]) return; // Not registered

        protectedContracts[protectedContract] = false;

        // O(1) removal using swap-and-pop
        uint256 indexPlusOne = _protectedContractIndex[protectedContract];
        if (indexPlusOne > 0) {
            uint256 index = indexPlusOne - 1;
            uint256 lastIndex = _protectedContractList.length - 1;

            if (index != lastIndex) {
                address lastContract = _protectedContractList[lastIndex];
                _protectedContractList[index] = lastContract;
                _protectedContractIndex[lastContract] = indexPlusOne;
            }

            _protectedContractList.pop();
            delete _protectedContractIndex[protectedContract];
        }

        emit ProtectedContractRemoved(protectedContract);
    }

    // ============ Internal Functions ============

    /// @notice Validate and set rate limiter configuration
    /// @param maxDrawRateWad Maximum withdrawal rate as WAD (1e18 = 100%)
    /// @param mainWindow Time for main buffer to fully replenish (seconds)
    /// @param elasticWindow Time for elastic buffer to decay (seconds)
    function _updateConfig(
        uint256 maxDrawRateWad,
        uint256 mainWindow,
        uint256 elasticWindow
    )
        private
    {
        if (maxDrawRateWad > 1e18) revert CircuitBreakerInvalidConfig();
        if (maxDrawRateWad == 0) revert CircuitBreakerInvalidConfig();
        if (mainWindow == 0) revert CircuitBreakerInvalidConfig();
        if (elasticWindow == 0) revert CircuitBreakerInvalidConfig();

        config = LimiterConfig({
            maxDrawRateWad: maxDrawRateWad.toUint64(),
            mainWindow: mainWindow.toUint48(),
            elasticWindow: elasticWindow.toUint48()
        });

        emit ConfigUpdated(maxDrawRateWad, mainWindow, elasticWindow);
    }

    /// @notice Update buffers based on time elapsed
    /// @param asset The asset address (for tracking)
    /// @param state The limiter state to update
    /// @param currentTvl The current TVL for calculating main buffer cap
    function _updateBuffers(
        address asset,
        LimiterState storage state,
        uint256 currentTvl
    )
        internal
    {
        uint256 timeElapsed = block.timestamp - state.lastUpdate;
        uint256 cap = (currentTvl * config.maxDrawRateWad) / 1e18;

        // First interaction or no time has passed
        if (state.lastUpdate == 0) {
            // Track this asset for enumeration
            if (!isTrackedAsset[asset]) {
                isTrackedAsset[asset] = true;
                _trackedAssets.push(asset);
            }

            // Initialize: main buffer starts at cap, elastic at 0
            state.mainBuffer = cap.toUint96();
            state.elasticBuffer = 0;
            state.lastUpdate = uint48(block.timestamp);
            return;
        }

        if (timeElapsed == 0) {
            return;
        }

        // Calculate main buffer replenishment
        // Cap timeElapsed to mainWindow to prevent overflow
        uint256 effectiveTimeMain =
            timeElapsed > config.mainWindow ? config.mainWindow : timeElapsed;
        uint256 replenishment = (cap * effectiveTimeMain) / config.mainWindow;
        state.mainBuffer = _min(cap, uint256(state.mainBuffer) + replenishment).toUint96();

        // Calculate elastic buffer decay
        // Cap timeElapsed to elasticWindow to prevent overflow
        uint256 effectiveTimeElastic =
            timeElapsed > config.elasticWindow ? config.elasticWindow : timeElapsed;
        uint256 decay = (uint256(state.elasticBuffer) * effectiveTimeElastic) / config.elasticWindow;
        state.elasticBuffer = state.elasticBuffer > decay ? state.elasticBuffer - uint96(decay) : 0;

        state.lastUpdate = uint48(block.timestamp);
    }

    /// @notice Calculate buffers without updating state (for view functions)
    /// @param state The limiter state to calculate from
    /// @param currentTvl The current TVL for calculating main buffer cap
    /// @return mainBuffer The calculated main buffer
    /// @return elasticBuffer The calculated elastic buffer
    function _calculateBuffers(
        LimiterState memory state,
        uint256 currentTvl
    )
        internal
        view
        returns (uint256 mainBuffer, uint256 elasticBuffer)
    {
        uint256 cap = (currentTvl * config.maxDrawRateWad) / 1e18;

        // First interaction
        if (state.lastUpdate == 0) {
            return (cap, 0);
        }

        uint256 timeElapsed = block.timestamp - state.lastUpdate;

        // Calculate main buffer replenishment
        // Cap timeElapsed to mainWindow to prevent overflow
        uint256 effectiveTimeMain =
            timeElapsed > config.mainWindow ? config.mainWindow : timeElapsed;
        uint256 replenishment = (cap * effectiveTimeMain) / config.mainWindow;
        mainBuffer = _min(cap, state.mainBuffer + replenishment);

        // Calculate elastic buffer decay
        // Cap timeElapsed to elasticWindow to prevent overflow
        uint256 effectiveTimeElastic =
            timeElapsed > config.elasticWindow ? config.elasticWindow : timeElapsed;
        uint256 decay = (state.elasticBuffer * effectiveTimeElastic) / config.elasticWindow;
        elasticBuffer = state.elasticBuffer > decay ? state.elasticBuffer - decay : 0;

        return (mainBuffer, elasticBuffer);
    }

    /// @notice Return the minimum of two values
    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
