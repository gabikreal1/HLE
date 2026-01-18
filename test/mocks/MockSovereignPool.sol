// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISovereignPool} from "@valantis-core/pools/interfaces/ISovereignPool.sol";
import {SovereignPoolSwapParams} from "@valantis-core/pools/structs/SovereignPoolStructs.sol";

/**
 * @title MockSovereignPool
 * @notice Mock Sovereign Pool for testing
 */
contract MockSovereignPool {
    address[] public tokens;
    uint256 public reserve0;
    uint256 public reserve1;
    address public swapFeeModule;
    address public alm;
    address public poolManager;
    address public sovereignVault;
    address public sovereignOracleModule;
    address public verifierModule;
    uint256 public defaultSwapFeeBips;
    uint256 public poolManagerFeeBips;
    bool public isLocked;
    bool public isRebaseTokenPool;
    address public gauge;
    address public protocolFactory;

    constructor(address _token0, address _token1) {
        tokens = new address[](2);
        tokens[0] = _token0;
        tokens[1] = _token1;
    }

    function getTokens() external view returns (address[] memory) {
        return tokens;
    }

    function getReserves() external view returns (uint256, uint256) {
        return (reserve0, reserve1);
    }

    function setReserves(uint256 _reserve0, uint256 _reserve1) external {
        reserve0 = _reserve0;
        reserve1 = _reserve1;
    }

    function setSwapFeeModule(address _swapFeeModule) external {
        swapFeeModule = _swapFeeModule;
    }

    function setALM(address _alm) external {
        alm = _alm;
    }

    function setPoolManager(address _poolManager) external {
        poolManager = _poolManager;
    }

    function swap(SovereignPoolSwapParams calldata _swapParams) external returns (uint256, uint256) {
        // Simplified mock - just return expected amounts
        return (_swapParams.amountIn, _swapParams.amountOutMin);
    }

    function depositLiquidity(
        uint256 _amount0,
        uint256 _amount1,
        address _sender,
        bytes calldata _verificationContext,
        bytes calldata _depositData
    ) external returns (uint256 amount0Deposited, uint256 amount1Deposited) {
        reserve0 += _amount0;
        reserve1 += _amount1;
        return (_amount0, _amount1);
    }

    function withdrawLiquidity(
        uint256 _amount0,
        uint256 _amount1,
        address _sender,
        address _recipient,
        bytes calldata _verificationContext
    ) external {
        reserve0 -= _amount0;
        reserve1 -= _amount1;
    }

    function getPoolManagerFees() external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function swapFeeModuleUpdateTimestamp() external pure returns (uint256) {
        return 0;
    }

    function setSovereignOracle(address _sovereignOracle) external {
        sovereignOracleModule = _sovereignOracle;
    }

    function setGauge(address _gauge) external {
        gauge = _gauge;
    }

    function setPoolManagerFeeBips(uint256 _poolManagerFeeBips) external {
        poolManagerFeeBips = _poolManagerFeeBips;
    }

    function token0() external view returns (address) {
        return tokens[0];
    }

    function token1() external view returns (address) {
        return tokens[1];
    }
}
