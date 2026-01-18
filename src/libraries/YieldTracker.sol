// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {TwoSpeedEWMA} from "./TwoSpeedEWMA.sol";

/**
 * @title YieldTracker
 * @notice Tracks and compares yield from different capital deployment strategies
 * @dev Calculates:
 *   - ALM yield: Fee revenue / deployed liquidity (annualized)
 *   - Uses EWMA to smooth yield over time
 *   - Provides yield comparison for YieldOptimizer decisions
 * 
 * Yield Calculation:
 *   ALM APY = (fees_earned / liquidity_deployed) * (365 days / time_period) * 10000 (bps)
 */
library YieldTracker {
    using TwoSpeedEWMA for TwoSpeedEWMA.EWMAState;

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice WAD precision
    uint256 constant WAD = 1e18;

    /// @notice Basis points precision
    uint256 constant BPS = 10_000;

    /// @notice Seconds per year (365 days)
    uint256 constant SECONDS_PER_YEAR = 365 days;

    /// @notice Minimum period for yield calculation (1 hour)
    uint256 constant MIN_YIELD_PERIOD = 1 hours;

    /// @notice Maximum yield in BPS (1000% = 100000 bps) to prevent overflow
    uint256 constant MAX_YIELD_BPS = 1_000_000;

    /// @notice Alpha for yield EWMA (0.05 = moderate smoothing)
    uint256 constant YIELD_EWMA_ALPHA = 5e16;

    // ═══════════════════════════════════════════════════════════════════════════════
    // STRUCTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Yield tracking state for a single strategy
    struct YieldState {
        uint256 cumulativeFees;      // Total fees earned (WAD)
        uint256 cumulativeLiquidity;  // Time-weighted liquidity (WAD * seconds)
        uint256 lastLiquidity;        // Last recorded liquidity amount (WAD)
        uint64 lastUpdateTime;        // Last update timestamp
        uint64 trackingStartTime;     // When tracking began
        TwoSpeedEWMA.EWMAState yieldEWMA;  // EWMA of yield for smoothing
        bool initialized;
    }

    /// @notice Yield comparison result
    struct YieldComparison {
        uint256 almYieldBps;         // ALM yield in basis points (annualized)
        uint256 lendingYieldBps;     // Lending yield in basis points
        uint256 smoothedAlmYieldBps; // EWMA-smoothed ALM yield
        int256 yieldDifferenceBps;   // ALM - Lending (positive = ALM better)
        bool almBetter;              // True if ALM yield > lending yield
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════════

    error YieldTracker__NotInitialized();
    error YieldTracker__ZeroLiquidity();
    error YieldTracker__PeriodTooShort();

    // ═══════════════════════════════════════════════════════════════════════════════
    // INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Initialize yield tracking state
     * @param state Yield state storage reference
     * @param initialLiquidity Initial liquidity amount (WAD)
     */
    function initialize(
        YieldState storage state,
        uint256 initialLiquidity
    ) internal {
        state.lastLiquidity = initialLiquidity;
        state.lastUpdateTime = uint64(block.timestamp);
        state.trackingStartTime = uint64(block.timestamp);
        state.initialized = true;
        
        // Initialize EWMA with a neutral starting yield (e.g., 5% = 500 bps)
        // Will be updated after first real yield observation
        state.yieldEWMA.initializeWithAlphas(500 * WAD / BPS, YIELD_EWMA_ALPHA, YIELD_EWMA_ALPHA / 5);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // UPDATE FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Record fees earned
     * @param state Yield state storage reference
     * @param feeAmount Fee amount earned (WAD)
     */
    function recordFees(
        YieldState storage state,
        uint256 feeAmount
    ) internal {
        if (!state.initialized) revert YieldTracker__NotInitialized();
        
        // Update time-weighted liquidity before recording fee
        _updateLiquidityAccumulator(state);
        
        state.cumulativeFees += feeAmount;
    }

    /**
     * @notice Update current liquidity level
     * @param state Yield state storage reference
     * @param newLiquidity New liquidity amount (WAD)
     */
    function updateLiquidity(
        YieldState storage state,
        uint256 newLiquidity
    ) internal {
        if (!state.initialized) revert YieldTracker__NotInitialized();
        
        // Accumulate time-weighted liquidity with old value
        _updateLiquidityAccumulator(state);
        
        // Set new liquidity
        state.lastLiquidity = newLiquidity;
    }

    /**
     * @notice Record a swap with fees and update liquidity
     * @param state Yield state storage reference
     * @param feeAmount Fee earned from swap (WAD)
     * @param newLiquidity Updated liquidity after swap (WAD)
     */
    function recordSwap(
        YieldState storage state,
        uint256 feeAmount,
        uint256 newLiquidity
    ) internal {
        if (!state.initialized) revert YieldTracker__NotInitialized();
        
        _updateLiquidityAccumulator(state);
        
        state.cumulativeFees += feeAmount;
        state.lastLiquidity = newLiquidity;
    }

    /**
     * @notice Update EWMA with current yield observation
     * @param state Yield state storage reference
     * @return currentYieldBps Current period yield in basis points
     */
    function updateYieldEWMA(
        YieldState storage state
    ) internal returns (uint256 currentYieldBps) {
        if (!state.initialized) revert YieldTracker__NotInitialized();
        
        currentYieldBps = calculateCurrentYield(state);
        
        // Update EWMA with yield observation (convert to WAD for EWMA)
        uint256 yieldWAD = currentYieldBps * WAD / BPS;
        state.yieldEWMA.update(yieldWAD);
    }

    /**
     * @notice Reset tracking period (call after yield optimization decision)
     * @param state Yield state storage reference
     */
    function resetPeriod(YieldState storage state) internal {
        if (!state.initialized) revert YieldTracker__NotInitialized();
        
        state.cumulativeFees = 0;
        state.cumulativeLiquidity = 0;
        state.trackingStartTime = uint64(block.timestamp);
        state.lastUpdateTime = uint64(block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Calculate current period yield (annualized, in basis points)
     * @param state Yield state storage reference
     * @return yieldBps Annualized yield in basis points
     */
    function calculateCurrentYield(
        YieldState storage state
    ) internal view returns (uint256 yieldBps) {
        if (!state.initialized) revert YieldTracker__NotInitialized();
        
        uint256 elapsed = block.timestamp - state.trackingStartTime;
        if (elapsed < MIN_YIELD_PERIOD) return 0;
        
        // Get total time-weighted liquidity including current period
        uint256 currentPeriodLiquidity = state.lastLiquidity * (block.timestamp - state.lastUpdateTime);
        uint256 totalLiquidity = state.cumulativeLiquidity + currentPeriodLiquidity;
        
        if (totalLiquidity == 0) return 0;
        
        // Average liquidity = total time-weighted liquidity / time
        uint256 avgLiquidity = totalLiquidity / elapsed;
        if (avgLiquidity == 0) return 0;
        
        // Yield = (fees / avgLiquidity) * (seconds_per_year / elapsed) * BPS
        // = (fees * BPS * SECONDS_PER_YEAR) / (avgLiquidity * elapsed)
        yieldBps = (state.cumulativeFees * BPS * SECONDS_PER_YEAR) / (avgLiquidity * elapsed);
        
        // Cap at maximum yield
        if (yieldBps > MAX_YIELD_BPS) yieldBps = MAX_YIELD_BPS;
    }

    /**
     * @notice Get smoothed yield from EWMA (in basis points)
     * @param state Yield state storage reference
     * @return smoothedYieldBps EWMA-smoothed yield in basis points
     */
    function getSmoothedYield(
        YieldState storage state
    ) internal view returns (uint256 smoothedYieldBps) {
        if (!state.initialized) return 0;
        if (!state.yieldEWMA.initialized) return 0;
        
        // Convert from WAD back to BPS
        smoothedYieldBps = (state.yieldEWMA.slowEWMA * BPS) / WAD;
    }

    /**
     * @notice Compare ALM yield against lending yield
     * @param state Yield state storage reference
     * @param lendingYieldBps Current lending APY in basis points
     * @return comparison Yield comparison result
     */
    function compareYields(
        YieldState storage state,
        uint256 lendingYieldBps
    ) internal view returns (YieldComparison memory comparison) {
        if (!state.initialized) revert YieldTracker__NotInitialized();
        
        uint256 almYield = calculateCurrentYield(state);
        uint256 smoothedYield = getSmoothedYield(state);
        
        comparison = YieldComparison({
            almYieldBps: almYield,
            lendingYieldBps: lendingYieldBps,
            smoothedAlmYieldBps: smoothedYield,
            yieldDifferenceBps: int256(smoothedYield) - int256(lendingYieldBps),
            almBetter: smoothedYield > lendingYieldBps
        });
    }

    /**
     * @notice Get average liquidity over tracking period
     * @param state Yield state storage reference
     * @return avgLiquidity Average liquidity in WAD
     */
    function getAverageLiquidity(
        YieldState storage state
    ) internal view returns (uint256 avgLiquidity) {
        if (!state.initialized) return 0;
        
        uint256 elapsed = block.timestamp - state.trackingStartTime;
        if (elapsed == 0) return state.lastLiquidity;
        
        uint256 currentPeriodLiquidity = state.lastLiquidity * (block.timestamp - state.lastUpdateTime);
        uint256 totalLiquidity = state.cumulativeLiquidity + currentPeriodLiquidity;
        
        avgLiquidity = totalLiquidity / elapsed;
    }

    /**
     * @notice Get total fees earned in current period
     * @param state Yield state storage reference
     * @return fees Total fees in WAD
     */
    function getTotalFees(YieldState storage state) internal view returns (uint256 fees) {
        return state.cumulativeFees;
    }

    /**
     * @notice Get tracking period duration
     * @param state Yield state storage reference
     * @return duration Duration in seconds
     */
    function getTrackingDuration(YieldState storage state) internal view returns (uint256 duration) {
        if (!state.initialized) return 0;
        return block.timestamp - state.trackingStartTime;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Update cumulative time-weighted liquidity
     */
    function _updateLiquidityAccumulator(YieldState storage state) internal {
        uint256 elapsed = block.timestamp - state.lastUpdateTime;
        if (elapsed > 0) {
            state.cumulativeLiquidity += state.lastLiquidity * elapsed;
            state.lastUpdateTime = uint64(block.timestamp);
        }
    }
}
