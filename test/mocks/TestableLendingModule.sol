// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LendingModule, ICoreWriter} from "../../src/modules/LendingModule.sol";

/**
 * @title TestableLendingModule
 * @notice Test version of LendingModule that doesn't use hyper-evm-lib precompiles
 * @dev Overrides bridging and conversion functions to make tests work without forking
 */
contract TestableLendingModule is LendingModule {
    
    /// @notice Whether bridging should be simulated (for testing)
    bool public simulateBridging = true;
    
    /// @notice Simulated bridge balance tracking
    mapping(address => uint256) public bridgedToCore;
    mapping(address => uint256) public bridgedFromCore;
    
    constructor(
        address _pool,
        address _strategist,
        uint256 _minSupplyAmount,
        uint256 _cooldownBlocks
    ) LendingModule(_pool, _strategist, _minSupplyAmount, _cooldownBlocks) {}
    
    /**
     * @notice Override supply to skip CoreWriterLib bridging
     */
    function supplyToLending(
        address token,
        uint256 amount
    ) external override onlyStrategist whenNotPaused cooldownPassed {
        uint64 tokenIndex = tokenIndices[token];
        if (tokenIndex == 0 && token != address(0)) {
            revert LendingModule__TokenNotSupported();
        }

        if (amount < minSupplyAmount && amount != 0) {
            revert LendingModule__AmountTooSmall();
        }

        // Simple conversion: 18 decimals to 8 decimals
        uint64 weiAmount = uint64(amount / 1e10);

        lastOperationBlock = block.number;
        totalSupplied[token] += amount;

        // Skip bridging for tests, just track
        if (simulateBridging) {
            bridgedToCore[token] += amount;
        }

        bytes memory encodedAction = _encodeLendingAction(OP_SUPPLY, tokenIndex, weiAmount);
        ICoreWriter(CORE_WRITER).sendRawAction(encodedAction);

        emit SupplyToLending(token, tokenIndex, amount, weiAmount, msg.sender);
    }
    
    /**
     * @notice Override withdraw to skip CoreWriterLib bridging
     */
    function withdrawFromLending(
        address token,
        uint256 amount
    ) external override onlyStrategist whenNotPaused cooldownPassed {
        uint64 tokenIndex = tokenIndices[token];
        if (tokenIndex == 0 && token != address(0)) {
            revert LendingModule__TokenNotSupported();
        }

        if (amount > 0 && amount > totalSupplied[token]) {
            revert LendingModule__InsufficientSupplied();
        }

        // Simple conversion: 18 decimals to 8 decimals
        uint64 weiAmount = uint64(amount / 1e10);

        lastOperationBlock = block.number;
        if (amount == 0) {
            totalSupplied[token] = 0;
        } else {
            totalSupplied[token] -= amount;
        }

        bytes memory encodedAction = _encodeLendingAction(OP_WITHDRAW, tokenIndex, weiAmount);
        ICoreWriter(CORE_WRITER).sendRawAction(encodedAction);

        // Skip bridging for tests, just track
        if (simulateBridging) {
            bridgedFromCore[token] += amount;
        }

        emit WithdrawFromLending(token, tokenIndex, amount, weiAmount, msg.sender);
    }
    
    /**
     * @notice Override preview functions for tests
     */
    function previewSupplyAction(
        address token,
        uint256 amount
    ) external view override returns (bytes memory) {
        uint64 tokenIndex = tokenIndices[token];
        uint64 weiAmount = uint64(amount / 1e10);
        return _encodeLendingAction(OP_SUPPLY, tokenIndex, weiAmount);
    }

    function previewWithdrawAction(
        address token,
        uint256 amount
    ) external view override returns (bytes memory) {
        uint64 tokenIndex = tokenIndices[token];
        uint64 weiAmount = uint64(amount / 1e10);
        return _encodeLendingAction(OP_WITHDRAW, tokenIndex, weiAmount);
    }
    
    /**
     * @notice Override simplified interface functions
     */
    function supply(address token, uint256 amount) external override onlyStrategist whenNotPaused cooldownPassed {
        uint64 tokenIndex = tokenIndices[token];
        if (tokenIndex == 0 && token != address(0)) {
            revert LendingModule__TokenNotSupported();
        }

        if (amount < minSupplyAmount && amount != 0) {
            revert LendingModule__AmountTooSmall();
        }

        uint64 weiAmount = uint64(amount / 1e10);

        lastOperationBlock = block.number;
        totalSupplied[token] += amount;

        if (simulateBridging) {
            bridgedToCore[token] += amount;
        }

        bytes memory encodedAction = _encodeLendingAction(OP_SUPPLY, tokenIndex, weiAmount);
        ICoreWriter(CORE_WRITER).sendRawAction(encodedAction);

        emit SupplyToLending(token, tokenIndex, amount, weiAmount, msg.sender);
    }

    function withdraw(address token, uint256 amount, address recipient) external override onlyStrategist whenNotPaused cooldownPassed {
        if (recipient == address(0)) revert LendingModule__ZeroAddress();
        
        uint64 tokenIndex = tokenIndices[token];
        if (tokenIndex == 0 && token != address(0)) {
            revert LendingModule__TokenNotSupported();
        }

        if (amount > 0 && amount > totalSupplied[token]) {
            revert LendingModule__InsufficientSupplied();
        }

        uint64 weiAmount = uint64(amount / 1e10);

        lastOperationBlock = block.number;
        if (amount == 0) {
            totalSupplied[token] = 0;
        } else {
            totalSupplied[token] -= amount;
        }

        bytes memory encodedAction = _encodeLendingAction(OP_WITHDRAW, tokenIndex, weiAmount);
        ICoreWriter(CORE_WRITER).sendRawAction(encodedAction);

        if (simulateBridging) {
            bridgedFromCore[token] += amount;
        }

        emit WithdrawFromLending(token, tokenIndex, amount, weiAmount, msg.sender);
    }
    
    // Test helper to toggle bridging simulation
    function setSimulateBridging(bool _simulate) external {
        simulateBridging = _simulate;
    }
}
