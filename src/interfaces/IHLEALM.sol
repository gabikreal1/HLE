// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {TwoSpeedEWMA} from "../libraries/TwoSpeedEWMA.sol";

/**
 * @title IHLEALM
 * @notice Interface for the Hyper Liquidity Engine ALM
 * @dev Fill-or-Kill AMM with L1 oracle pricing and spread-based fees
 *      Spread = volSpread + impactSpread
 *      - volSpread = max(fastVar, slowVar) * K_VOL
 *      - impactSpread = amountIn * K_IMPACT / reserveIn
 *      BUY: askPrice = oracle * (1 + spread)
 *      SELL: bidPrice = oracle * (1 - spread)
 */
interface IHLEALM {
    // ═══════════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════════

    event SwapExecuted(
        address indexed sender,
        bool isBuy,
        uint256 amountIn,
        uint256 amountOut,
        uint256 oraclePrice,
        uint256 effectivePrice,
        uint256 spreadUsed
    );

    event VolatilityGated(
        uint256 fastEWMA,
        uint256 slowEWMA,
        uint256 deviationBps,
        uint256 thresholdBps
    );

    event SpreadConfigUpdated(uint256 kVol, uint256 kImpact);
    event VolatilityThresholdUpdated(uint256 volatilityThresholdBps);
    event FeesCollected(address indexed recipient, uint256 amount0, uint256 amount1);
    event SurplusCollected(address indexed recipient, uint256 amount0, uint256 amount1);
    event YieldOptimizerSet(address indexed optimizer);
    event Paused(bool isPaused);

    // ═══════════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get current oracle mid price (token0/token1)
     * @return price Price in WAD (18 decimals)
     */
    function getOracleMidPrice() external view returns (uint256 price);

    /**
     * @notice Get current volatility reading
     * @return reading Volatility reading struct (includes variance)
     */
    function getVolatility() external view returns (TwoSpeedEWMA.VolatilityReading memory reading);

    /**
     * @notice Check if current volatility allows trading
     * @return canTrade True if volatility is within threshold
     */
    function canTrade() external view returns (bool);

    /**
     * @notice Get total liquidity value (in token0 terms)
     * @return liquidity Total liquidity in WAD
     */
    function getTotalLiquidity() external view returns (uint256 liquidity);

    /**
     * @notice Get accumulated spread fees
     * @return fees0 Accumulated fees in token0
     * @return fees1 Accumulated fees in token1
     */
    function getAccumulatedFees() external view returns (uint256 fees0, uint256 fees1);

    /**
     * @notice Preview swap output for given input
     * @param tokenIn Address of input token
     * @param tokenOut Address of output token
     * @param amountIn Input amount
     * @return amountOut Expected output amount after spread
     * @return spreadFee Fee captured from spread
     * @return canExecute Whether swap can execute
     */
    function previewSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256 amountOut, uint256 spreadFee, bool canExecute);

    /**
     * @notice Get a quote for a swap
     * @param tokenIn Address of input token
     * @param tokenOut Address of output token
     * @param amountIn Input amount
     * @return amountOut Expected output amount after spread
     */
    function getQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256 amountOut);

    /**
     * @notice Get current spread for a given trade size
     * @param amountIn Trade size
     * @param tokenIn Token being sold
     * @return volSpread Volatility component of spread (WAD)
     * @return impactSpread Price impact component of spread (WAD)
     * @return totalSpread Total spread (WAD)
     */
    function getSpread(
        uint256 amountIn,
        address tokenIn
    ) external view returns (uint256 volSpread, uint256 impactSpread, uint256 totalSpread);

    /**
     * @notice Get current variance values
     * @return fastVar Fast EWMA variance (WAD)
     * @return slowVar Slow EWMA variance (WAD)
     * @return maxVar Maximum of fast/slow variance (WAD)
     */
    function getVariance() external view returns (uint256 fastVar, uint256 slowVar, uint256 maxVar);

    /**
     * @notice Get spread configuration
     * @return kVol Volatility multiplier (WAD)
     * @return kImpact Impact multiplier (WAD)
     */
    function getSpreadConfig() external view returns (uint256 kVol, uint256 kImpact);

    // ═══════════════════════════════════════════════════════════════════════════════
    // STATE GETTERS
    // ═══════════════════════════════════════════════════════════════════════════════

    function pool() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function token0Index() external view returns (uint64);
    function token1Index() external view returns (uint64);
    function volatilityThresholdBps() external view returns (uint256);
    function kVol() external view returns (uint256);
    function kImpact() external view returns (uint256);
    function feeRecipient() external view returns (address);
    function yieldOptimizer() external view returns (address);
    function paused() external view returns (bool);

    // ═══════════════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Initialize EWMA with current oracle price
     */
    function initialize() external;

    /**
     * @notice Initialize EWMA with custom alphas
     * @param fastAlpha Fast EWMA smoothing factor (WAD)
     * @param slowAlpha Slow EWMA smoothing factor (WAD)
     */
    function initializeWithAlphas(uint256 fastAlpha, uint256 slowAlpha) external;

    /**
     * @notice Set spread configuration (K_VOL and K_IMPACT)
     * @param _kVol New volatility multiplier (WAD)
     * @param _kImpact New impact multiplier (WAD)
     */
    function setSpreadConfig(uint256 _kVol, uint256 _kImpact) external;

    /**
     * @notice Set volatility threshold for gating
     * @param _volatilityThresholdBps New threshold in basis points
     */
    function setVolatilityThreshold(uint256 _volatilityThresholdBps) external;

    /**
     * @notice Set YieldOptimizer for fee tracking
     * @param _optimizer YieldOptimizer address
     */
    function setYieldOptimizer(address _optimizer) external;

    /**
     * @notice Set fee recipient
     * @param _recipient New fee recipient
     */
    function setFeeRecipient(address _recipient) external;

    /**
     * @notice Collect accumulated fees
     */
    function collectFees() external;

    /**
     * @notice Collect captured surplus
     */
    function collectSurplus() external;

    /**
     * @notice Pause/unpause the ALM
     * @param _paused New paused state
     */
    function setPaused(bool _paused) external;

    /**
     * @notice Update token indices
     * @param _token0Index New token0 index
     * @param _token1Index New token1 index
     */
    function setTokenIndices(uint64 _token0Index, uint64 _token1Index) external;
}
