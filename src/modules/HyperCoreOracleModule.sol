// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOracleModule} from "../interfaces/IOracleModule.sol";
import {PrecompileLib} from "@hyper-evm-lib/PrecompileLib.sol";
import {HLConstants} from "@hyper-evm-lib/common/HLConstants.sol";

/**
 * @title HyperCoreOracleModule
 * @notice Oracle module that reads prices from HyperCore via precompiles
 * @dev Uses spot price precompile (0x808) for real-time price data
 * 
 * Key features:
 * - Trustless: Reads from HyperBFT-backed consensus
 * - Real-time: Updated every ~100ms on HyperCore
 * - Low gas: ~2k gas per read
 * - Cacheable: Snapshots enable quote validation
 */
contract HyperCoreOracleModule is IOracleModule {
    using PrecompileLib for address;

    /// @notice Q96 constant for fixed-point math (2^96)
    uint256 public constant Q96 = 2**96;

    /// @notice Precision for price normalization
    uint256 public constant PRICE_PRECISION = 1e8;

    /// @notice Mapping of token pair hash to latest snapshot
    mapping(bytes32 => OracleSnapshot) private _snapshots;

    /// @notice Pool that can update snapshots
    address public immutable pool;

    error OracleModule__OnlyPool();
    error OracleModule__TokenNotLinked();
    error OracleModule__StaleSnapshot();

    modifier onlyPool() {
        if (msg.sender != pool) revert OracleModule__OnlyPool();
        _;
    }

    constructor(address _pool) {
        pool = _pool;
    }

    /// @inheritdoc IOracleModule
    function getCurrentPrice(address token0, address token1) external view returns (uint256 priceX96) {
        // Get spot price from HyperCore precompile
        // spotPx returns price with 8 decimals after normalizing for szDecimals
        uint64 rawPrice = PrecompileLib.spotPx(token0);
        
        // Convert to Q96 format
        // rawPrice is base/quote with PRICE_PRECISION (1e8)
        // priceX96 = rawPrice * Q96 / PRICE_PRECISION
        priceX96 = (uint256(rawPrice) * Q96) / PRICE_PRECISION;
    }

    /// @inheritdoc IOracleModule
    function snapshotPrice(address token0, address token1) external returns (OracleSnapshot memory snapshot) {
        uint64 rawPrice = PrecompileLib.spotPx(token0);
        uint64 l1Block = PrecompileLib.l1BlockNumber();

        snapshot = OracleSnapshot({
            priceX96: (uint256(rawPrice) * Q96) / PRICE_PRECISION,
            l1BlockNumber: l1Block,
            timestamp: block.timestamp
        });

        bytes32 pairHash = _getPairHash(token0, token1);
        _snapshots[pairHash] = snapshot;

        return snapshot;
    }

    /// @inheritdoc IOracleModule
    function getLatestSnapshot(address token0, address token1) external view returns (OracleSnapshot memory snapshot) {
        bytes32 pairHash = _getPairHash(token0, token1);
        return _snapshots[pairHash];
    }

    /// @inheritdoc IOracleModule
    function isPriceValid(
        address token0,
        address token1,
        uint256 priceX96,
        uint256 maxDeviationBps
    ) external view returns (bool valid) {
        uint64 rawPrice = PrecompileLib.spotPx(token0);
        uint256 oraclePriceX96 = (uint256(rawPrice) * Q96) / PRICE_PRECISION;

        // Calculate deviation
        uint256 deviation;
        if (priceX96 > oraclePriceX96) {
            deviation = ((priceX96 - oraclePriceX96) * 10000) / oraclePriceX96;
        } else {
            deviation = ((oraclePriceX96 - priceX96) * 10000) / oraclePriceX96;
        }

        return deviation <= maxDeviationBps;
    }

    /// @notice Get raw spot price from precompile (for debugging/testing)
    /// @param token Token address to get price for
    /// @return rawPrice Price with 8 decimals
    function getRawSpotPrice(address token) external view returns (uint64 rawPrice) {
        return PrecompileLib.spotPx(token);
    }

    /// @notice Get L1 block number from precompile
    /// @return blockNumber Current L1/Core block number
    function getL1BlockNumber() external view returns (uint64 blockNumber) {
        return PrecompileLib.l1BlockNumber();
    }

    /// @notice Check if snapshot is fresh (within N L1 blocks)
    /// @param token0 First token
    /// @param token1 Second token
    /// @param maxAgeBlocks Maximum age in L1 blocks
    /// @return fresh True if snapshot is within maxAgeBlocks
    function isSnapshotFresh(
        address token0,
        address token1,
        uint64 maxAgeBlocks
    ) external view returns (bool fresh) {
        bytes32 pairHash = _getPairHash(token0, token1);
        OracleSnapshot memory snapshot = _snapshots[pairHash];
        
        if (snapshot.timestamp == 0) return false;
        
        uint64 currentL1Block = PrecompileLib.l1BlockNumber();
        return (currentL1Block - snapshot.l1BlockNumber) <= maxAgeBlocks;
    }

    /// @dev Generate unique hash for token pair (order-independent)
    function _getPairHash(address token0, address token1) internal pure returns (bytes32) {
        if (token0 < token1) {
            return keccak256(abi.encodePacked(token0, token1));
        }
        return keccak256(abi.encodePacked(token1, token0));
    }
}
