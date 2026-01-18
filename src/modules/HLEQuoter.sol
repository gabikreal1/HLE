// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ISovereignPool} from "@valantis-core/pools/interfaces/ISovereignPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {L1OracleAdapter} from "../libraries/L1OracleAdapter.sol";

/**
 * @title IHLEALMState
 * @notice Interface to read HLEALM state for quoting
 */
interface IHLEALMState {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function token0Index() external view returns (uint64);
    function token1Index() external view returns (uint64);
    function kVol() external view returns (uint256);
    function kImpact() external view returns (uint256);
    function getVariance() external view returns (uint256 fastVar, uint256 slowVar, uint256 maxVar);
}

/**
 * @title HLEQuoter
 * @notice On-chain quoter module with spread-based pricing
 * @dev Uses same spread formula as HLEALM:
 *      - volSpread = max(fastVar, slowVar) * K_VOL / WAD
 *      - impactSpread = amountIn * K_IMPACT / reserveIn
 *      - BUY: askPrice = oracle * (1 + spread)
 *      - SELL: bidPrice = oracle * (1 - spread)
 * 
 * Usage:
 *   1. Call quoter.quote(tokenIn, tokenOut, amountIn) 
 *   2. Get back amountOut
 *   3. Submit swap to SovereignPool with amountOutMin = amountOut
 *   4. Pool's native Fill-or-Kill protection handles the rest
 */
contract HLEQuoter {

    uint256 constant WAD = 1e18;
    uint256 constant BPS = 10_000;
    uint256 constant MAX_SPREAD = 5e17; // 50%

    /// @notice Sovereign Pool
    ISovereignPool public immutable pool;

    /// @notice HLEALM (reads token info and spread config)
    IHLEALMState public immutable alm;

    constructor(address _pool, address _alm) {
        pool = ISovereignPool(_pool);
        alm = IHLEALMState(_alm);
    }

    /**
     * @notice Get expected output amount for a swap with spread-based pricing
     * @param tokenIn Token being sold
     * @param tokenOut Token being bought
     * @param amountIn Amount of tokenIn
     * @return amountOut Expected output (use as amountOutMin in swap)
     */
    function quote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256 amountOut) {
        // Validate tokens
        address token0 = alm.token0();
        address token1 = alm.token1();
        
        bool isBuy = (tokenIn == token0 && tokenOut == token1);
        bool isSell = (tokenIn == token1 && tokenOut == token0);
        require(isBuy || isSell, "Invalid pair");

        // Get oracle price (token0/token1)
        uint256 oraclePrice = _getOraclePrice();

        // Get pool swap fee
        uint256 swapFeeBps = pool.defaultSwapFeeBips();
        
        // Calculate amountIn after pool fee (how Valantis does it)
        uint256 amountInAfterFee = (amountIn * BPS) / (BPS + swapFeeBps);

        // Calculate spread
        uint256 totalSpread = _calculateSpread(amountInAfterFee, tokenIn);

        // Calculate output with spread
        if (isBuy) {
            // BUY: askPrice = oraclePrice * (1 + spread)
            uint256 effectivePrice = (oraclePrice * (WAD + totalSpread)) / WAD;
            amountOut = (amountInAfterFee * oraclePrice) / effectivePrice;
        } else {
            // SELL: bidPrice = oraclePrice * (1 - spread)
            uint256 effectivePrice = (oraclePrice * (WAD - totalSpread)) / WAD;
            amountOut = (amountInAfterFee * WAD) / effectivePrice;
        }
    }

    /**
     * @notice Get detailed quote with spread breakdown
     * @param tokenIn Token being sold
     * @param tokenOut Token being bought
     * @param amountIn Amount of tokenIn
     * @return amountOut Expected output
     * @return volSpread Volatility spread component (WAD)
     * @return impactSpread Impact spread component (WAD)
     * @return effectivePrice Price after spread applied (WAD)
     */
    function quoteDetailed(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (
        uint256 amountOut,
        uint256 volSpread,
        uint256 impactSpread,
        uint256 effectivePrice
    ) {
        // Validate tokens
        address token0 = alm.token0();
        address token1 = alm.token1();
        
        bool isBuy = (tokenIn == token0 && tokenOut == token1);
        bool isSell = (tokenIn == token1 && tokenOut == token0);
        require(isBuy || isSell, "Invalid pair");

        // Get oracle price
        uint256 oraclePrice = _getOraclePrice();

        // Get pool swap fee
        uint256 swapFeeBps = pool.defaultSwapFeeBips();
        uint256 amountInAfterFee = (amountIn * BPS) / (BPS + swapFeeBps);

        // Get spread components
        (volSpread, impactSpread) = _getSpreadComponents(amountInAfterFee, tokenIn);
        uint256 totalSpread = volSpread + impactSpread;
        if (totalSpread > MAX_SPREAD) {
            totalSpread = MAX_SPREAD;
        }

        // Calculate effective price and output
        if (isBuy) {
            effectivePrice = (oraclePrice * (WAD + totalSpread)) / WAD;
            amountOut = (amountInAfterFee * oraclePrice) / effectivePrice;
        } else {
            effectivePrice = (oraclePrice * (WAD - totalSpread)) / WAD;
            amountOut = (amountInAfterFee * WAD) / effectivePrice;
        }
    }

    /**
     * @notice Get oracle mid price (token0 per token1)
     * @return price Price in WAD
     */
    function getPrice() external view returns (uint256 price) {
        return _getOraclePrice();
    }

    /**
     * @notice Get current spread for a trade size
     * @param amountIn Trade size
     * @param tokenIn Token being sold
     * @return totalSpread Total spread (WAD)
     */
    function getSpread(uint256 amountIn, address tokenIn) external view returns (uint256 totalSpread) {
        return _calculateSpread(amountIn, tokenIn);
    }

    /**
     * @notice Internal: Get oracle mid price
     */
    function _getOraclePrice() internal view returns (uint256 price) {
        uint64 idx0 = alm.token0Index();
        uint64 idx1 = alm.token1Index();
        
        uint256 price0 = L1OracleAdapter.getSpotPriceByIndexWAD(idx0);
        uint256 price1 = L1OracleAdapter.getSpotPriceByIndexWAD(idx1);
        
        // Mid price = price0 / price1 (token0 per token1)
        price = (price0 * WAD) / price1;
    }

    /**
     * @notice Internal: Calculate total spread
     */
    function _calculateSpread(uint256 amountIn, address tokenIn) internal view returns (uint256 totalSpread) {
        (uint256 volSpread, uint256 impactSpread) = _getSpreadComponents(amountIn, tokenIn);
        totalSpread = volSpread + impactSpread;
        if (totalSpread > MAX_SPREAD) {
            totalSpread = MAX_SPREAD;
        }
    }

    /**
     * @notice Internal: Get spread components
     */
    function _getSpreadComponents(
        uint256 amountIn,
        address tokenIn
    ) internal view returns (uint256 volSpread, uint256 impactSpread) {
        // Get variance from ALM
        (, , uint256 maxVar) = alm.getVariance();
        
        // Get spread config
        uint256 kVol = alm.kVol();
        uint256 kImpact = alm.kImpact();
        
        // Calculate volatility spread
        volSpread = (maxVar * kVol) / WAD;
        
        // Calculate impact spread
        uint256 reserveIn = IERC20(tokenIn).balanceOf(address(pool));
        impactSpread = reserveIn > 0 ? (amountIn * kImpact) / reserveIn : 0;
    }
}
