// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title TwoSpeedEWMA
 * @notice Two-speed Exponentially Weighted Moving Average for volatility tracking
 * @dev Implements fast and slow EWMAs to detect price deviations:
 *   - Fast EWMA: Responsive to recent changes (~5min equivalent)
 *   - Slow EWMA: Stable long-term average (~30min equivalent)
 *   - Volatility signal: |fast - slow| / slow
 * 
 * Used for:
 *   1. Detecting abnormal price deviations
 *   2. Gating trades during high volatility
 *   3. Adjusting fees dynamically
 */
library TwoSpeedEWMA {
    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice WAD precision (18 decimals)
    uint256 constant WAD = 1e18;

    /// @notice Basis points precision
    uint256 constant BPS = 10_000;

    /// @notice Default fast alpha (λ=0.1 → higher weight to recent values)
    /// @dev In WAD: 0.1 * 1e18 = 1e17
    uint256 constant DEFAULT_FAST_ALPHA = 1e17;

    /// @notice Default slow alpha (λ=0.01 → slower adaptation)
    /// @dev In WAD: 0.01 * 1e18 = 1e16
    uint256 constant DEFAULT_SLOW_ALPHA = 1e16;

    /// @notice Maximum alpha value (must be < 1.0)
    uint256 constant MAX_ALPHA = WAD - 1;

    /// @notice Minimum meaningful alpha to prevent stale values
    uint256 constant MIN_ALPHA = 1e14; // 0.0001

    // ═══════════════════════════════════════════════════════════════════════════════
    // STRUCTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice EWMA state for a single price tracker
    struct EWMAState {
        uint256 fastEWMA;       // Fast-moving average (WAD)
        uint256 slowEWMA;       // Slow-moving average (WAD)
        uint256 fastVar;        // Fast variance (squared deviation from mean) (WAD^2)
        uint256 slowVar;        // Slow variance (squared deviation from mean) (WAD^2)
        uint256 fastAlpha;      // Fast smoothing factor (WAD, 0 < α < 1)
        uint256 slowAlpha;      // Slow smoothing factor (WAD, 0 < α < 1)
        uint64 lastUpdateTime;  // Last update timestamp
        bool initialized;       // Whether the EWMA has been seeded
    }

    /// @notice Volatility reading from EWMA comparison
    struct VolatilityReading {
        uint256 fastEWMA;           // Current fast EWMA
        uint256 slowEWMA;           // Current slow EWMA
        uint256 fastVar;            // Fast variance (WAD^2)
        uint256 slowVar;            // Slow variance (WAD^2)
        uint256 deviationBps;       // |fast - slow| / slow in basis points
        bool isVolatile;            // Whether deviation exceeds threshold
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════════

    error TwoSpeedEWMA__NotInitialized();
    error TwoSpeedEWMA__InvalidAlpha();
    error TwoSpeedEWMA__ZeroPrice();

    // ═══════════════════════════════════════════════════════════════════════════════
    // INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Initialize EWMA state with default alphas
     * @param state EWMA state storage reference
     * @param initialPrice Initial price to seed the EWMA (WAD)
     */
    function initialize(EWMAState storage state, uint256 initialPrice) internal {
        initializeWithAlphas(state, initialPrice, DEFAULT_FAST_ALPHA, DEFAULT_SLOW_ALPHA);
    }

    /**
     * @notice Initialize EWMA state with custom alphas
     * @param state EWMA state storage reference
     * @param initialPrice Initial price to seed the EWMA (WAD)
     * @param fastAlpha Fast smoothing factor (WAD)
     * @param slowAlpha Slow smoothing factor (WAD)
     */
    function initializeWithAlphas(
        EWMAState storage state,
        uint256 initialPrice,
        uint256 fastAlpha,
        uint256 slowAlpha
    ) internal {
        if (fastAlpha > MAX_ALPHA || fastAlpha < MIN_ALPHA) revert TwoSpeedEWMA__InvalidAlpha();
        if (slowAlpha > MAX_ALPHA || slowAlpha < MIN_ALPHA) revert TwoSpeedEWMA__InvalidAlpha();
        if (initialPrice == 0) revert TwoSpeedEWMA__ZeroPrice();

        state.fastEWMA = initialPrice;
        state.slowEWMA = initialPrice;
        state.fastVar = 0;  // No variance at initialization
        state.slowVar = 0;
        state.fastAlpha = fastAlpha;
        state.slowAlpha = slowAlpha;
        state.lastUpdateTime = uint64(block.timestamp);
        state.initialized = true;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // UPDATE FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Update both EWMAs with a new price observation
     * @dev EWMA formula: new_ewma = α * price + (1 - α) * old_ewma
     *      Variance formula: var = α * (price - ewma)² + (1 - α) * old_var
     * @param state EWMA state storage reference
     * @param newPrice New price observation (WAD)
     * @return reading Updated volatility reading
     */
    function update(
        EWMAState storage state,
        uint256 newPrice
    ) internal returns (VolatilityReading memory reading) {
        if (!state.initialized) revert TwoSpeedEWMA__NotInitialized();
        if (newPrice == 0) revert TwoSpeedEWMA__ZeroPrice();

        // Calculate deviations from current EWMA (before update)
        uint256 fastDev = newPrice > state.fastEWMA 
            ? newPrice - state.fastEWMA 
            : state.fastEWMA - newPrice;
        uint256 slowDev = newPrice > state.slowEWMA 
            ? newPrice - state.slowEWMA 
            : state.slowEWMA - newPrice;

        // Update fast EWMA: fastEWMA = α_fast * price + (1 - α_fast) * fastEWMA
        state.fastEWMA = _calculateEWMA(state.fastEWMA, newPrice, state.fastAlpha);
        
        // Update slow EWMA: slowEWMA = α_slow * price + (1 - α_slow) * slowEWMA
        state.slowEWMA = _calculateEWMA(state.slowEWMA, newPrice, state.slowAlpha);
        
        // Update variances: var = α * deviation² + (1 - α) * old_var
        // deviation² scaled: (dev * dev) / WAD to keep in WAD scale
        state.fastVar = _calculateVariance(state.fastVar, fastDev, state.fastAlpha);
        state.slowVar = _calculateVariance(state.slowVar, slowDev, state.slowAlpha);
        
        state.lastUpdateTime = uint64(block.timestamp);

        reading = _getVolatilityReading(state.fastEWMA, state.slowEWMA, state.fastVar, state.slowVar, 0);
    }

    /**
     * @notice Update with time-weighted adjustment for gaps
     * @dev Adjusts alpha based on time elapsed since last update
     * @param state EWMA state storage reference
     * @param newPrice New price observation (WAD)
     * @param expectedInterval Expected update interval in seconds
     * @return reading Updated volatility reading
     */
    function updateTimeWeighted(
        EWMAState storage state,
        uint256 newPrice,
        uint256 expectedInterval
    ) internal returns (VolatilityReading memory reading) {
        if (!state.initialized) revert TwoSpeedEWMA__NotInitialized();
        if (newPrice == 0) revert TwoSpeedEWMA__ZeroPrice();

        uint256 elapsed = block.timestamp - state.lastUpdateTime;
        
        // Calculate time-adjusted alphas
        uint256 timeFactor = elapsed > expectedInterval 
            ? WAD 
            : (elapsed * WAD) / expectedInterval;
        
        uint256 adjustedFastAlpha = (state.fastAlpha * timeFactor) / WAD;
        uint256 adjustedSlowAlpha = (state.slowAlpha * timeFactor) / WAD;
        
        // Clamp to minimum alpha
        if (adjustedFastAlpha < MIN_ALPHA) adjustedFastAlpha = MIN_ALPHA;
        if (adjustedSlowAlpha < MIN_ALPHA) adjustedSlowAlpha = MIN_ALPHA;

        // Calculate deviations from current EWMA (before update)
        uint256 fastDev = newPrice > state.fastEWMA 
            ? newPrice - state.fastEWMA 
            : state.fastEWMA - newPrice;
        uint256 slowDev = newPrice > state.slowEWMA 
            ? newPrice - state.slowEWMA 
            : state.slowEWMA - newPrice;

        state.fastEWMA = _calculateEWMA(state.fastEWMA, newPrice, adjustedFastAlpha);
        state.slowEWMA = _calculateEWMA(state.slowEWMA, newPrice, adjustedSlowAlpha);
        
        // Update variances
        state.fastVar = _calculateVariance(state.fastVar, fastDev, adjustedFastAlpha);
        state.slowVar = _calculateVariance(state.slowVar, slowDev, adjustedSlowAlpha);
        
        state.lastUpdateTime = uint64(block.timestamp);

        reading = _getVolatilityReading(state.fastEWMA, state.slowEWMA, state.fastVar, state.slowVar, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get current volatility reading without updating state
     * @param state EWMA state storage reference
     * @param volatilityThresholdBps Threshold for isVolatile flag
     * @return reading Current volatility reading
     */
    function getVolatility(
        EWMAState storage state,
        uint256 volatilityThresholdBps
    ) internal view returns (VolatilityReading memory reading) {
        if (!state.initialized) revert TwoSpeedEWMA__NotInitialized();
        reading = _getVolatilityReading(state.fastEWMA, state.slowEWMA, state.fastVar, state.slowVar, volatilityThresholdBps);
    }

    /**
     * @notice Get max variance between fast and slow (used for spread calculation)
     * @param state EWMA state storage reference
     * @return maxVar The larger of fastVar or slowVar
     */
    function getMaxVariance(EWMAState storage state) internal view returns (uint256 maxVar) {
        if (!state.initialized) revert TwoSpeedEWMA__NotInitialized();
        maxVar = state.fastVar > state.slowVar ? state.fastVar : state.slowVar;
    }

    /**
     * @notice Calculate what the deviation would be with a new price
     * @param state EWMA state storage reference
     * @param newPrice Hypothetical new price (WAD)
     * @return fastEWMA What fast EWMA would become
     * @return slowEWMA What slow EWMA would become  
     * @return deviationBps Hypothetical deviation in basis points
     */
    function previewUpdate(
        EWMAState storage state,
        uint256 newPrice
    ) internal view returns (uint256 fastEWMA, uint256 slowEWMA, uint256 deviationBps) {
        if (!state.initialized) revert TwoSpeedEWMA__NotInitialized();
        
        fastEWMA = _calculateEWMA(state.fastEWMA, newPrice, state.fastAlpha);
        slowEWMA = _calculateEWMA(state.slowEWMA, newPrice, state.slowAlpha);
        deviationBps = _calculateDeviationBps(fastEWMA, slowEWMA);
    }

    /**
     * @notice Get raw variance values
     * @param state EWMA state storage reference
     * @return fastVar Fast variance (WAD scale)
     * @return slowVar Slow variance (WAD scale)
     */
    function getVariances(
        EWMAState storage state
    ) internal view returns (uint256 fastVar, uint256 slowVar) {
        if (!state.initialized) revert TwoSpeedEWMA__NotInitialized();
        return (state.fastVar, state.slowVar);
    }

    /**
     * @notice Check if current state is volatile
     * @param state EWMA state storage reference
     * @param thresholdBps Volatility threshold in basis points
     * @return isVolatile True if deviation exceeds threshold
     */
    function isVolatile(
        EWMAState storage state,
        uint256 thresholdBps
    ) internal view returns (bool) {
        if (!state.initialized) return true; // Conservative: treat uninitialized as volatile
        
        uint256 deviation = _calculateDeviationBps(state.fastEWMA, state.slowEWMA);
        return deviation > thresholdBps;
    }

    /**
     * @notice Get time since last update
     * @param state EWMA state storage reference
     * @return elapsed Seconds since last update
     */
    function timeSinceUpdate(EWMAState storage state) internal view returns (uint256 elapsed) {
        if (!state.initialized) return type(uint256).max;
        elapsed = block.timestamp - state.lastUpdateTime;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Calculate EWMA: α * new + (1 - α) * old
     */
    function _calculateEWMA(
        uint256 oldEWMA,
        uint256 newValue,
        uint256 alpha
    ) internal pure returns (uint256) {
        // new_ewma = α * newValue + (1 - α) * oldEWMA
        // = (α * newValue + oldEWMA - α * oldEWMA) / 1
        // = oldEWMA + α * (newValue - oldEWMA)
        if (newValue >= oldEWMA) {
            return oldEWMA + (alpha * (newValue - oldEWMA)) / WAD;
        } else {
            return oldEWMA - (alpha * (oldEWMA - newValue)) / WAD;
        }
    }

    /**
     * @notice Calculate variance: α * deviation² + (1 - α) * old_var
     * @dev Deviation squared is scaled by WAD to maintain WAD scale for variance
     */
    function _calculateVariance(
        uint256 oldVar,
        uint256 deviation,
        uint256 alpha
    ) internal pure returns (uint256) {
        // Squared deviation scaled: (dev * dev) / WAD 
        // This keeps variance in WAD scale (not WAD^2)
        uint256 deviationSquared = (deviation * deviation) / WAD;
        
        // new_var = α * deviation² + (1 - α) * old_var
        uint256 weightedNew = (alpha * deviationSquared) / WAD;
        uint256 weightedOld = ((WAD - alpha) * oldVar) / WAD;
        
        return weightedNew + weightedOld;
    }

    /**
     * @notice Calculate deviation between fast and slow EWMA in basis points
     */
    function _calculateDeviationBps(
        uint256 fastEWMA,
        uint256 slowEWMA
    ) internal pure returns (uint256) {
        if (slowEWMA == 0) return BPS; // Max deviation if slow is zero
        
        uint256 diff = fastEWMA > slowEWMA 
            ? fastEWMA - slowEWMA 
            : slowEWMA - fastEWMA;
            
        return (diff * BPS) / slowEWMA;
    }

    /**
     * @notice Build volatility reading struct
     */
    function _getVolatilityReading(
        uint256 fastEWMA,
        uint256 slowEWMA,
        uint256 fastVar,
        uint256 slowVar,
        uint256 thresholdBps
    ) internal pure returns (VolatilityReading memory reading) {
        uint256 deviationBps = _calculateDeviationBps(fastEWMA, slowEWMA);
        
        reading = VolatilityReading({
            fastEWMA: fastEWMA,
            slowEWMA: slowEWMA,
            fastVar: fastVar,
            slowVar: slowVar,
            deviationBps: deviationBps,
            isVolatile: thresholdBps > 0 && deviationBps > thresholdBps
        });
    }
}
