// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {YieldTracker} from "../libraries/YieldTracker.sol";

/**
 * @title IYieldOptimizer
 * @notice Interface for the Yield Optimizer module
 * @dev Compares ALM yield vs lending yield and manages capital allocation
 */
interface IYieldOptimizer {
    // ═══════════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════════

    event RebalanceExecuted(
        uint256 almYieldBps,
        uint256 lendingYieldBps,
        uint256 amountMoved,
        bool movedToLending
    );

    event YieldUpdated(
        uint256 almYieldBps,
        uint256 smoothedAlmYieldBps,
        uint256 lendingYieldBps
    );

    event AllocationUpdated(uint256 newAlmAllocationBps);
    event ThresholdUpdated(uint256 newThresholdBps);
    event ALMUpdated(address newALM);
    event LendingModuleUpdated(address newLendingModule);
    event OptimizerActivated(bool active);

    // ═══════════════════════════════════════════════════════════════════════════════
    // ALM CALLBACKS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Record fee income from ALM swap
     * @dev Called by ALM after each swap
     * @param feeAmount Fee earned (WAD)
     * @param newLiquidity Updated liquidity after swap (WAD)
     */
    function recordSwapFees(uint256 feeAmount, uint256 newLiquidity) external;

    /**
     * @notice Update liquidity tracking (for deposits/withdrawals)
     * @param newLiquidity New liquidity amount (WAD)
     */
    function updateLiquidity(uint256 newLiquidity) external;

    // ═══════════════════════════════════════════════════════════════════════════════
    // REBALANCING
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Check if rebalancing is recommended
     * @return shouldRebalance True if rebalancing is recommended
     * @return moveToLending True if should move to lending, false if to ALM
     * @return suggestedAmount Amount to move (WAD)
     */
    function checkRebalance() external view returns (
        bool shouldRebalance,
        bool moveToLending,
        uint256 suggestedAmount
    );

    /**
     * @notice Execute rebalancing based on yield comparison
     */
    function executeRebalance() external;

    // ═══════════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get current yield comparison
     * @return comparison Yield comparison struct
     */
    function getYieldComparison() external view returns (YieldTracker.YieldComparison memory comparison);

    /**
     * @notice Get current ALM yield (annualized, in BPS)
     * @return yieldBps Current ALM yield
     */
    function getCurrentALMYield() external view returns (uint256 yieldBps);

    /**
     * @notice Get smoothed ALM yield (EWMA)
     * @return yieldBps Smoothed ALM yield
     */
    function getSmoothedALMYield() external view returns (uint256 yieldBps);

    /**
     * @notice Get current lending APY
     * @return yieldBps Lending APY in basis points
     */
    function getLendingYield() external view returns (uint256 yieldBps);

    /**
     * @notice Get total capital (ALM + lending)
     * @return totalCapital Total capital in WAD
     */
    function getTotalCapital() external view returns (uint256 totalCapital);

    /**
     * @notice Get tracking statistics
     * @return totalFees Total fees earned in current period
     * @return avgLiquidity Average liquidity over period
     * @return trackingDuration Duration of current tracking period
     */
    function getTrackingStats() external view returns (
        uint256 totalFees,
        uint256 avgLiquidity,
        uint256 trackingDuration
    );

    // ═══════════════════════════════════════════════════════════════════════════════
    // STATE GETTERS
    // ═══════════════════════════════════════════════════════════════════════════════

    function token() external view returns (address);
    function tokenIndex() external view returns (uint64);
    function lendingModule() external view returns (address);
    function alm() external view returns (address);
    function rebalanceThresholdBps() external view returns (uint256);
    function almAllocationBps() external view returns (uint256);
    function isActive() external view returns (bool);

    // ═══════════════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Initialize yield tracking with current ALM liquidity
     * @param initialLiquidity Current liquidity in ALM (WAD)
     */
    function initializeTracking(uint256 initialLiquidity) external;

    /**
     * @notice Update rebalance threshold
     * @param newThresholdBps New threshold in basis points
     */
    function setRebalanceThreshold(uint256 newThresholdBps) external;

    /**
     * @notice Update ALM address
     * @param newALM New ALM address
     */
    function setALM(address newALM) external;

    /**
     * @notice Update lending module
     * @param newLendingModule New lending module address
     */
    function setLendingModule(address newLendingModule) external;

    /**
     * @notice Pause/unpause optimizer
     * @param active New active state
     */
    function setActive(bool active) external;
}
