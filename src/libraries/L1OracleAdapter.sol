// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {PrecompileLib} from "@hyper-evm-lib/PrecompileLib.sol";
import {HLConstants} from "@hyper-evm-lib/common/HLConstants.sol";
import {HLConversions} from "@hyper-evm-lib/common/HLConversions.sol";

/**
 * @title L1OracleAdapter
 * @notice Thin wrapper around hyper-evm-lib's PrecompileLib for HLE-specific oracle operations
 * @dev Extends PrecompileLib with:
 *   - Price deviation checks for Fill-or-Kill validation
 *   - Borrow/Lend precompile reads (0x811, 0x812) not in hyper-evm-lib
 *   - Normalized price helpers (WAD format)
 * 
 * Uses PrecompileLib for:
 *   - spotPx(), oraclePx(), markPx()
 *   - spotBalance()
 *   - tokenInfo(), spotInfo()
 */
library L1OracleAdapter {
    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice WAD precision (18 decimals)
    uint256 constant WAD = 1e18;

    /// @notice Basis points precision
    uint256 constant BPS = 10_000;

    /// @notice Default decimal scale (8 → 18 decimals)
    uint256 constant DECIMAL_SCALE = 1e10;

    /// @notice Borrow/Lend User State precompile (NOT in hyper-evm-lib)
    address constant BORROW_LEND_USER_PRECOMPILE = 0x0000000000000000000000000000000000000811;

    /// @notice Borrow/Lend Reserve State precompile (NOT in hyper-evm-lib)
    address constant BORROW_LEND_RESERVE_PRECOMPILE = 0x0000000000000000000000000000000000000812;

    // ═══════════════════════════════════════════════════════════════════════════════
    // STRUCTS (for Borrow/Lend precompiles)
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice User's borrow/lend position
    struct BorrowLendUserState {
        uint64 borrowBasis;
        uint64 borrowValue;
        uint64 supplyBasis;
        uint64 supplyValue;
    }

    /// @notice Reserve pool state
    struct BorrowLendReserveState {
        uint64 borrowYearlyRateBps;
        uint64 supplyYearlyRateBps;
        uint64 balance;
        uint64 utilizationBps;
        uint64 oraclePx;
        uint64 ltvBps;
        uint64 totalSupplied;
        uint64 totalBorrowed;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════════

    error L1OracleAdapter__PrecompileCallFailed();
    error L1OracleAdapter__StalePrice();

    // ═══════════════════════════════════════════════════════════════════════════════
    // ORACLE PRICE FUNCTIONS (using PrecompileLib)
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get spot price for a token (normalized to WAD)
     * @param tokenAddress ERC20 token address
     * @return price Price in WAD (18 decimals)
     */
    function getSpotPriceWAD(address tokenAddress) internal view returns (uint256 price) {
        uint64 rawPrice = PrecompileLib.spotPx(tokenAddress);
        if (rawPrice == 0) revert L1OracleAdapter__StalePrice();
        price = uint256(rawPrice) * DECIMAL_SCALE;
    }

    /**
     * @notice Get spot price by token index (normalized to WAD)
     * @param spotIndex Spot market index
     * @return price Price in WAD (18 decimals)
     */
    function getSpotPriceByIndexWAD(uint64 spotIndex) internal view returns (uint256 price) {
        uint64 rawPrice = PrecompileLib.spotPx(spotIndex);
        if (rawPrice == 0) revert L1OracleAdapter__StalePrice();
        price = uint256(rawPrice) * DECIMAL_SCALE;
    }

    /**
     * @notice Get oracle (perp) price (normalized to WAD)
     * @param perpIndex Perp asset index
     * @return price Price in WAD (18 decimals)
     */
    function getOraclePriceWAD(uint32 perpIndex) internal view returns (uint256 price) {
        uint64 rawPrice = PrecompileLib.oraclePx(perpIndex);
        if (rawPrice == 0) revert L1OracleAdapter__StalePrice();
        price = uint256(rawPrice) * DECIMAL_SCALE;
    }

    /**
     * @notice Get mark price (normalized to WAD)
     * @param perpIndex Perp asset index
     * @return price Price in WAD (18 decimals)
     */
    function getMarkPriceWAD(uint32 perpIndex) internal view returns (uint256 price) {
        uint64 rawPrice = PrecompileLib.markPx(perpIndex);
        if (rawPrice == 0) revert L1OracleAdapter__StalePrice();
        price = uint256(rawPrice) * DECIMAL_SCALE;
    }

    /**
     * @notice Get normalized spot price (already in PrecompileLib but exposed here for convenience)
     * @param spotIndex Spot market index
     * @return price Price as fixed-point with 8 decimals
     */
    function getNormalizedSpotPx(uint64 spotIndex) internal view returns (uint256 price) {
        return PrecompileLib.normalizedSpotPx(spotIndex);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // BORROW/LEND FUNCTIONS (NOT in hyper-evm-lib)
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get user's borrow/lend state for a token
     * @param user User address
     * @param tokenIndex HyperCore token index
     * @return state User's supply and borrow positions
     */
    function getBorrowLendUserState(
        address user,
        uint64 tokenIndex
    ) internal view returns (BorrowLendUserState memory state) {
        (bool success, bytes memory data) = BORROW_LEND_USER_PRECOMPILE.staticcall(
            abi.encode(user, tokenIndex)
        );
        if (!success || data.length == 0) revert L1OracleAdapter__PrecompileCallFailed();
        state = abi.decode(data, (BorrowLendUserState));
    }

    /**
     * @notice Get reserve pool state for a token
     * @param tokenIndex HyperCore token index
     * @return state Reserve state including APYs
     */
    function getBorrowLendReserveState(
        uint64 tokenIndex
    ) internal view returns (BorrowLendReserveState memory state) {
        (bool success, bytes memory data) = BORROW_LEND_RESERVE_PRECOMPILE.staticcall(
            abi.encode(tokenIndex)
        );
        if (!success || data.length == 0) revert L1OracleAdapter__PrecompileCallFailed();
        state = abi.decode(data, (BorrowLendReserveState));
    }

    /**
     * @notice Get lending APY for a token
     * @param tokenIndex HyperCore token index
     * @return apyBps Supply APY in basis points
     */
    function getLendingAPY(uint64 tokenIndex) internal view returns (uint64 apyBps) {
        BorrowLendReserveState memory state = getBorrowLendReserveState(tokenIndex);
        return state.supplyYearlyRateBps;
    }

    /**
     * @notice Get borrow APY for a token
     * @param tokenIndex HyperCore token index
     * @return apyBps Borrow APY in basis points
     */
    function getBorrowAPY(uint64 tokenIndex) internal view returns (uint64 apyBps) {
        BorrowLendReserveState memory state = getBorrowLendReserveState(tokenIndex);
        return state.borrowYearlyRateBps;
    }

    /**
     * @notice Get user's supplied amount (in Core decimals)
     * @param user User address
     * @param tokenIndex HyperCore token index
     * @return supplied Amount supplied (8 decimals)
     */
    function getUserSupplied(address user, uint64 tokenIndex) internal view returns (uint64 supplied) {
        BorrowLendUserState memory state = getBorrowLendUserState(user, tokenIndex);
        return state.supplyValue;
    }

    /**
     * @notice Get user's supplied amount in EVM decimals
     * @param user User address
     * @param tokenIndex HyperCore token index
     * @return supplied Amount supplied (18 decimals)
     */
    function getUserSuppliedEVM(address user, uint64 tokenIndex) internal view returns (uint256 supplied) {
        uint64 coreAmount = getUserSupplied(user, tokenIndex);
        return HLConversions.weiToEvm(tokenIndex, coreAmount);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // PRICE VALIDATION FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Calculate price deviation in basis points
     * @param price1 First price (WAD)
     * @param price2 Second price (WAD)
     * @return deviationBps Absolute deviation in basis points
     */
    function calculateDeviationBps(
        uint256 price1,
        uint256 price2
    ) internal pure returns (uint256 deviationBps) {
        if (price2 == 0) return BPS; // Max deviation if reference is zero
        
        uint256 diff = price1 > price2 ? price1 - price2 : price2 - price1;
        deviationBps = (diff * BPS) / price2;
    }

    /**
     * @notice Check if price deviation is within acceptable bounds
     * @param targetPrice User's target price (WAD)
     * @param oraclePrice Current oracle price (WAD)
     * @param maxDeviationBps Maximum allowed deviation in basis points
     * @return valid True if deviation is acceptable
     */
    function isPriceValid(
        uint256 targetPrice,
        uint256 oraclePrice,
        uint256 maxDeviationBps
    ) internal pure returns (bool valid) {
        uint256 deviation = calculateDeviationBps(targetPrice, oraclePrice);
        valid = deviation <= maxDeviationBps;
    }

    /**
     * @notice Get mid price between two token prices
     * @param price0 Price of token0 (WAD)
     * @param price1 Price of token1 (WAD)
     * @return midPrice The mid price (price0 / price1) in WAD
     */
    function getMidPrice(
        uint256 price0,
        uint256 price1
    ) internal pure returns (uint256 midPrice) {
        if (price1 == 0) return 0;
        midPrice = (price0 * WAD) / price1;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // SPOT BALANCE HELPERS (using PrecompileLib)
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get spot balance in EVM decimals
     * @param user User address
     * @param tokenAddress Token address
     * @return balance Balance in EVM decimals (18)
     */
    function getSpotBalanceEVM(address user, address tokenAddress) internal view returns (uint256 balance) {
        PrecompileLib.SpotBalance memory spotBal = PrecompileLib.spotBalance(user, tokenAddress);
        uint64 tokenIndex = PrecompileLib.getTokenIndex(tokenAddress);
        return HLConversions.weiToEvm(tokenIndex, spotBal.total);
    }

    /**
     * @notice Get L1 block number
     * @return blockNumber Current L1 block
     */
    function l1BlockNumber() internal view returns (uint64 blockNumber) {
        return PrecompileLib.l1BlockNumber();
    }
}
