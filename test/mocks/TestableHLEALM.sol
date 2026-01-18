// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HLEALM} from "../../src/modules/HLEALM.sol";
import {ISovereignPool} from "@valantis-core/pools/interfaces/ISovereignPool.sol";
import {TwoSpeedEWMA} from "../../src/libraries/TwoSpeedEWMA.sol";

/**
 * @title TestableHLEALM
 * @notice Testable version of HLEALM that allows mocking oracle prices
 * @dev Overrides _getOracleMidPrice to use configurable mock prices instead of precompiles
 */
contract TestableHLEALM is HLEALM {
    // Mock price (ratio of token0/token1 in WAD)
    uint256 private _mockMidPrice = 2000e18; // Default: 1 token0 = 2000 token1

    constructor(
        address _pool,
        uint64 _token0Index,
        uint64 _token1Index,
        address _feeRecipient,
        address _owner
    ) HLEALM(_pool, _token0Index, _token1Index, _feeRecipient, _owner) {}

    /**
     * @notice Set mock mid price for testing
     * @param midPrice Token0/token1 price ratio in WAD
     */
    function setMockMidPrice(uint256 midPrice) external {
        _mockMidPrice = midPrice;
    }

    /**
     * @notice Get mock mid price
     */
    function getMockMidPrice() external view returns (uint256) {
        return _mockMidPrice;
    }

    /**
     * @notice Override to use mock price
     * @dev Returns price ratio: price0/price1 in WAD
     */
    function _getOracleMidPrice() internal view override returns (uint256 price) {
        return _mockMidPrice;
    }

    /**
     * @notice Force initialize EWMA with a specific price
     * @param initialPrice The starting price in WAD
     */
    function forceInitialize(uint256 initialPrice) external {
        TwoSpeedEWMA.EWMAState storage state = priceEWMA;
        state.initialized = true;
        state.lastTimestamp = uint64(block.timestamp);
        state.fastEWMA = initialPrice;
        state.slowEWMA = initialPrice;
        state.fastVar = 0;
        state.slowVar = 0;
    }

    /**
     * @notice Update EWMA with current mock price (for testing variance)
     */
    function updateEWMA() external {
        uint256 currentPrice = _getOracleMidPrice();
        TwoSpeedEWMA.update(
            priceEWMA,
            currentPrice,
            uint64(block.timestamp)
        );
    }

    /**
     * @notice Force set variance for testing spread calculations
     * @param fastVariance Fast variance value
     * @param slowVariance Slow variance value
     */
    function forceSetVariance(uint256 fastVariance, uint256 slowVariance) external {
        priceEWMA.fastVar = fastVariance;
        priceEWMA.slowVar = slowVariance;
    }

    /**
     * @notice Get spread calculation details for testing
     * @param amountIn Input amount
     * @param reserveIn Reserve of input token
     * @return volSpread Volatility spread component
     * @return impactSpread Impact spread component  
     * @return totalSpread Combined spread (capped)
     */
    function calculateSpreadDetails(
        uint256 amountIn,
        uint256 reserveIn
    ) external view returns (uint256 volSpread, uint256 impactSpread, uint256 totalSpread) {
        // Get variance
        uint256 maxVariance = TwoSpeedEWMA.getMaxVariance(priceEWMA);
        
        // Calculate vol spread: max(fastVar, slowVar) * kVol / WAD
        volSpread = (maxVariance * kVol) / 1e18;
        
        // Calculate impact spread: amountIn * kImpact / reserveIn
        if (reserveIn > 0) {
            impactSpread = (amountIn * kImpact) / reserveIn;
        }
        
        // Total spread capped at MAX_SPREAD
        totalSpread = volSpread + impactSpread;
        if (totalSpread > MAX_SPREAD) {
            totalSpread = MAX_SPREAD;
        }
    }
}
