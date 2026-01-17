// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IQuoteValidator} from "../interfaces/IQuoteValidator.sol";
import {IOracleModule} from "../interfaces/IOracleModule.sol";
import {ISovereignPool} from "@valantis-core/pools/interfaces/ISovereignPool.sol";
import {SovereignPoolSwapParams, SovereignPoolSwapContextData} from "@valantis-core/pools/structs/SovereignPoolStructs.sol";
import {PrecompileLib} from "@hyper-evm-lib/PrecompileLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title QuoteValidator
 * @notice Oracle-backed quote validation for HOT AMM
 * @dev Key innovation: Quotes are validated against HyperCore oracle prices on-chain
 *      No signatures needed - oracle prices are public consensus data
 * 
 * Validation flow:
 * 1. Check caller is intendedUser
 * 2. Check quote hasn't expired (EVM block)
 * 3. Check oracle hasn't drifted beyond maxDeviation
 * 4. If valid → execute swap
 * 5. If invalid → revert with reason
 */
contract QuoteValidator is IQuoteValidator {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Q96 constant for fixed-point math
    uint256 public constant Q96 = 2**96;

    /// @notice Default maximum deviation (1% = 100 bps)
    uint256 public constant DEFAULT_MAX_DEVIATION_BPS = 100;

    /// @notice Maximum allowed deviation cap (5%)
    uint256 public constant MAX_DEVIATION_CAP_BPS = 500;

    // ═══════════════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice The Sovereign Pool for swap execution
    ISovereignPool public immutable pool;

    /// @notice Oracle module for price reads
    IOracleModule public immutable oracleModule;

    /// @notice Strategist who can adjust parameters
    address public strategist;

    /// @notice Used quote IDs (prevent replay)
    mapping(bytes32 => bool) public usedQuotes;

    /// @notice Global maximum deviation setting
    uint256 public globalMaxDeviationBps;

    // ═══════════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════════

    error QuoteValidator__NotIntendedUser();
    error QuoteValidator__QuoteExpired();
    error QuoteValidator__QuoteAlreadyUsed();
    error QuoteValidator__OracleDrifted();
    error QuoteValidator__InvalidQuote();
    error QuoteValidator__DeviationTooHigh();
    error QuoteValidator__OnlyStrategist();
    error QuoteValidator__InsufficientOutput();

    // ═══════════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════════

    event StrategistUpdated(address indexed oldStrategist, address indexed newStrategist);
    event MaxDeviationUpdated(uint256 oldDeviation, uint256 newDeviation);

    // ═══════════════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════════════

    modifier onlyStrategist() {
        if (msg.sender != strategist) revert QuoteValidator__OnlyStrategist();
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════════

    constructor(
        address _pool,
        address _oracleModule,
        address _strategist
    ) {
        pool = ISovereignPool(_pool);
        oracleModule = IOracleModule(_oracleModule);
        strategist = _strategist;
        globalMaxDeviationBps = DEFAULT_MAX_DEVIATION_BPS;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // QUOTE EXECUTION
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @inheritdoc IQuoteValidator
     * @notice Execute a validated quote
     */
    function executeQuote(Quote calldata quote) external returns (uint256 amountOut) {
        // 1. Validate quote
        (bool valid, string memory reason) = _validateQuote(quote);
        if (!valid) {
            emit QuoteRejected(quote.quoteId, reason);
            revert QuoteValidator__InvalidQuote();
        }

        // 2. Mark quote as used
        usedQuotes[quote.quoteId] = true;

        // 3. Transfer tokens from user
        IERC20(quote.tokenIn).safeTransferFrom(msg.sender, address(this), quote.amountIn);

        // 4. Approve pool
        IERC20(quote.tokenIn).approve(address(pool), quote.amountIn);

        // 5. Determine swap direction
        address[] memory tokens = pool.getTokens();
        bool isZeroToOne = quote.tokenIn == tokens[0];

        // 6. Execute swap on pool
        SovereignPoolSwapParams memory swapParams = SovereignPoolSwapParams({
            isSwapCallback: false,
            isZeroToOne: isZeroToOne,
            amountIn: quote.amountIn,
            amountOutMin: quote.amountOutMin,
            deadline: block.timestamp,
            recipient: msg.sender,
            swapTokenOut: quote.tokenOut,
            swapContext: SovereignPoolSwapContextData({
                externalContext: abi.encode(quote),
                verifierContext: "",
                swapCallbackContext: "",
                swapFeeModuleContext: ""
            })
        });

        (amountOut, ) = pool.swap(swapParams);

        // 7. Verify output
        if (amountOut < quote.amountOutMin) {
            revert QuoteValidator__InsufficientOutput();
        }

        emit QuoteExecuted(
            quote.quoteId,
            msg.sender,
            quote.tokenIn,
            quote.tokenOut,
            quote.amountIn,
            amountOut
        );
    }

    /**
     * @inheritdoc IQuoteValidator
     * @notice Validate a quote without executing
     */
    function validateQuote(Quote calldata quote) external view returns (bool valid, string memory reason) {
        return _validateQuote(quote);
    }

    /**
     * @inheritdoc IQuoteValidator
     * @notice Check if oracle price has drifted from quote snapshot
     */
    function hasOracleDrifted(Quote calldata quote) external view returns (bool drifted) {
        uint256 currentPrice = oracleModule.getCurrentPrice(quote.tokenIn, quote.tokenOut);
        uint256 snapshotPrice = quote.oracleSnapshotPriceX96;

        uint256 maxDeviation = quote.maxDeviationBps > 0 ? quote.maxDeviationBps : globalMaxDeviationBps;

        // Calculate deviation
        uint256 deviation = _calculateDeviation(currentPrice, snapshotPrice);

        return deviation > maxDeviation;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INTERNAL VALIDATION
    // ═══════════════════════════════════════════════════════════════════════════════

    function _validateQuote(Quote calldata quote) internal view returns (bool valid, string memory reason) {
        // 1. Check caller is intended user
        if (msg.sender != quote.intendedUser) {
            return (false, "Not intended user");
        }

        // 2. Check quote hasn't been used
        if (usedQuotes[quote.quoteId]) {
            return (false, "Quote already used");
        }

        // 3. Check expiration
        if (block.number > quote.expirationBlock) {
            return (false, "Quote expired");
        }

        // 4. Check oracle drift
        uint256 currentPrice = oracleModule.getCurrentPrice(quote.tokenIn, quote.tokenOut);
        uint256 snapshotPrice = quote.oracleSnapshotPriceX96;
        uint256 maxDeviation = quote.maxDeviationBps > 0 ? quote.maxDeviationBps : globalMaxDeviationBps;

        uint256 deviation = _calculateDeviation(currentPrice, snapshotPrice);

        if (deviation > maxDeviation) {
            return (false, "Oracle drifted");
        }

        // 5. Validate execution price is within bounds
        uint256 executionDeviation = _calculateDeviation(quote.executionPriceX96, currentPrice);
        if (executionDeviation > maxDeviation) {
            return (false, "Execution price out of bounds");
        }

        return (true, "");
    }

    function _calculateDeviation(uint256 price1, uint256 price2) internal pure returns (uint256) {
        if (price2 == 0) return type(uint256).max;
        
        if (price1 > price2) {
            return ((price1 - price2) * 10000) / price2;
        } else {
            return ((price2 - price1) * 10000) / price2;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // QUOTE GENERATION HELPERS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Generate a quote ID from quote parameters
     * @param tokenIn Input token
     * @param tokenOut Output token
     * @param amountIn Input amount
     * @param user Intended user
     * @param nonce User-provided nonce
     * @return quoteId Unique quote identifier
     */
    function generateQuoteId(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address user,
        uint256 nonce
    ) external pure returns (bytes32 quoteId) {
        return keccak256(abi.encodePacked(tokenIn, tokenOut, amountIn, user, nonce));
    }

    /**
     * @notice Get current oracle snapshot for quote creation
     * @param tokenIn Input token
     * @param tokenOut Output token
     * @return priceX96 Current oracle price
     * @return l1Block Current L1 block
     */
    function getOracleSnapshot(
        address tokenIn,
        address tokenOut
    ) external view returns (uint256 priceX96, uint64 l1Block) {
        priceX96 = oracleModule.getCurrentPrice(tokenIn, tokenOut);
        l1Block = PrecompileLib.l1BlockNumber();
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Update global maximum deviation
     * @param _maxDeviationBps New max deviation in basis points
     */
    function setMaxDeviation(uint256 _maxDeviationBps) external onlyStrategist {
        if (_maxDeviationBps > MAX_DEVIATION_CAP_BPS) revert QuoteValidator__DeviationTooHigh();
        
        emit MaxDeviationUpdated(globalMaxDeviationBps, _maxDeviationBps);
        globalMaxDeviationBps = _maxDeviationBps;
    }

    /**
     * @notice Transfer strategist role
     * @param _newStrategist New strategist address
     */
    function setStrategist(address _newStrategist) external onlyStrategist {
        emit StrategistUpdated(strategist, _newStrategist);
        strategist = _newStrategist;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Check if a quote ID has been used
     * @param quoteId Quote ID to check
     * @return used True if already used
     */
    function isQuoteUsed(bytes32 quoteId) external view returns (bool used) {
        return usedQuotes[quoteId];
    }
}
