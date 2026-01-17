// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IOracleModule
 * @notice Interface for oracle module that reads HyperCore prices via precompiles
 */
interface IOracleModule {
    struct OracleSnapshot {
        uint256 priceX96;      // Price in Q64.96 format
        uint64 l1BlockNumber;  // L1 block when snapshot was taken
        uint256 timestamp;     // EVM timestamp of snapshot
    }

    /// @notice Get the current oracle price for a token pair
    /// @param token0 First token address
    /// @param token1 Second token address (quote)
    /// @return priceX96 Price in Q64.96 format (token0 per token1)
    function getCurrentPrice(address token0, address token1) external view returns (uint256 priceX96);

    /// @notice Take a snapshot of the current oracle price
    /// @param token0 First token address  
    /// @param token1 Second token address (quote)
    /// @return snapshot The oracle snapshot
    function snapshotPrice(address token0, address token1) external returns (OracleSnapshot memory snapshot);

    /// @notice Get the latest snapshot for a token pair
    /// @param token0 First token address
    /// @param token1 Second token address
    /// @return snapshot The most recent snapshot
    function getLatestSnapshot(address token0, address token1) external view returns (OracleSnapshot memory snapshot);

    /// @notice Check if a price is within acceptable deviation from oracle
    /// @param token0 First token address
    /// @param token1 Second token address
    /// @param priceX96 Price to check
    /// @param maxDeviationBps Maximum allowed deviation in basis points
    /// @return valid True if price is within bounds
    function isPriceValid(
        address token0,
        address token1,
        uint256 priceX96,
        uint256 maxDeviationBps
    ) external view returns (bool valid);
}
