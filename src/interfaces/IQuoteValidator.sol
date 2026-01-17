// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOracleModule} from "./IOracleModule.sol";

/**
 * @title IQuoteValidator
 * @notice Interface for oracle-backed quote validation
 */
interface IQuoteValidator {
    struct Quote {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountOutMin;
        uint256 executionPriceX96;    // Agreed execution price
        uint256 oracleSnapshotPriceX96; // Oracle price at quote creation
        uint64 oracleL1Block;          // L1 block of oracle snapshot
        uint256 expirationBlock;       // EVM block when quote expires
        address intendedUser;          // Only this address can execute
        uint256 maxDeviationBps;       // Max allowed deviation from oracle
        bytes32 quoteId;               // Unique identifier
    }

    event QuoteExecuted(
        bytes32 indexed quoteId,
        address indexed user,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    event QuoteRejected(
        bytes32 indexed quoteId,
        string reason
    );

    /// @notice Validate and execute a quote
    /// @param quote The quote to execute
    /// @return amountOut The amount of tokenOut received
    function executeQuote(Quote calldata quote) external returns (uint256 amountOut);

    /// @notice Validate a quote without executing
    /// @param quote The quote to validate
    /// @return valid True if quote passes all checks
    /// @return reason Reason if invalid
    function validateQuote(Quote calldata quote) external view returns (bool valid, string memory reason);

    /// @notice Check if oracle price has drifted too far from quote snapshot
    /// @param quote The quote to check
    /// @return drifted True if price has drifted beyond maxDeviationBps
    function hasOracleDrifted(Quote calldata quote) external view returns (bool drifted);
}
