// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISwapFeeModule, SwapFeeModuleData} from "@valantis-core/swap-fee-modules/interfaces/ISwapFeeModule.sol";
import {ISovereignPool} from "@valantis-core/pools/interfaces/ISovereignPool.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title DynamicFeeModule
 * @notice Swap fee module that adapts fees based on pool imbalance
 * @dev Implements the whitepaper formula:
 *      swapFee = baseFee + imbalanceFee
 *      baseFee = 0.3% (fixed, protects against MEV)
 *      imbalanceFee = sqrt(|reserve0 - reserve1| / (reserve0 + reserve1)) * 0.1%
 * 
 * Benefits:
 * - Balanced reserves → Low fees (0.3%) → attract traders
 * - Imbalanced reserves → Higher fees → incentivize arbitrage rebalancing
 * - Reduces LVR through economic mechanism
 */
contract DynamicFeeModule is ISwapFeeModule {
    using Math for uint256;

    /// @notice Base fee in basis points (0.3% = 30 bps)
    uint256 public constant BASE_FEE_BPS = 30;

    /// @notice Imbalance multiplier in basis points (0.1% = 10 bps)
    uint256 public constant IMBALANCE_MULTIPLIER_BPS = 10;

    /// @notice Maximum fee cap (5% = 500 bps)
    uint256 public constant MAX_FEE_BPS = 500;

    /// @notice Precision for sqrt calculation
    uint256 public constant PRECISION = 1e18;

    /// @notice The Sovereign Pool this module serves
    ISovereignPool public immutable pool;

    /// @notice Pool manager who can adjust parameters
    address public poolManager;

    /// @notice Custom base fee (if set, overrides BASE_FEE_BPS)
    uint256 public customBaseFee;
    bool public useCustomBaseFee;

    error DynamicFeeModule__OnlyPoolManager();
    error DynamicFeeModule__OnlyPool();
    error DynamicFeeModule__FeeTooHigh();

    event BaseFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeCalculated(uint256 baseFee, uint256 imbalanceFee, uint256 totalFee);

    modifier onlyPoolManager() {
        if (msg.sender != poolManager) revert DynamicFeeModule__OnlyPoolManager();
        _;
    }

    modifier onlyPool() {
        if (msg.sender != address(pool)) revert DynamicFeeModule__OnlyPool();
        _;
    }

    constructor(address _pool, address _poolManager) {
        pool = ISovereignPool(_pool);
        poolManager = _poolManager;
    }

    /// @notice Returns the swap fee for a given swap
    function getSwapFeeInBips(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        address _user,
        bytes memory _swapFeeModuleContext
    ) external override returns (SwapFeeModuleData memory swapFeeModuleData) {
        // Get current reserves
        (uint256 reserve0, uint256 reserve1) = pool.getReserves();

        // Calculate fee
        uint256 totalFee = _calculateFee(reserve0, reserve1);

        // Cap at maximum
        if (totalFee > MAX_FEE_BPS) {
            totalFee = MAX_FEE_BPS;
        }

        swapFeeModuleData = SwapFeeModuleData({
            feeInBips: totalFee,
            internalContext: abi.encode(reserve0, reserve1, totalFee)
        });
    }

    /// @inheritdoc ISwapFeeModule
    function callbackOnSwapEnd(
        uint256 _effectiveFee,
        int24 _spotPriceTick,
        uint256 _amountInUsed,
        uint256 _amountOut,
        SwapFeeModuleData memory _swapFeeModuleData
    ) external override onlyPool {
        // Universal pool callback - not used for Sovereign Pool
    }

    /// @inheritdoc ISwapFeeModule
    function callbackOnSwapEnd(
        uint256 _effectiveFee,
        uint256 _amountInUsed,
        uint256 _amountOut,
        SwapFeeModuleData memory _swapFeeModuleData
    ) external override onlyPool {
        // Can emit events or update internal state here
        (uint256 reserve0, uint256 reserve1, uint256 totalFee) = 
            abi.decode(_swapFeeModuleData.internalContext, (uint256, uint256, uint256));
        
        emit FeeCalculated(
            _getBaseFee(),
            totalFee - _getBaseFee(),
            totalFee
        );
    }

    /**
     * @notice Calculate the dynamic fee based on reserve imbalance
     * @param reserve0 Amount of token0 in pool
     * @param reserve1 Amount of token1 in pool
     * @return fee Total fee in basis points
     */
    function _calculateFee(uint256 reserve0, uint256 reserve1) internal view returns (uint256 fee) {
        uint256 baseFee = _getBaseFee();

        // Handle edge cases
        if (reserve0 == 0 || reserve1 == 0) {
            return baseFee;
        }

        uint256 totalReserves = reserve0 + reserve1;
        if (totalReserves == 0) {
            return baseFee;
        }

        // Calculate imbalance ratio: |reserve0 - reserve1| / (reserve0 + reserve1)
        uint256 imbalance;
        if (reserve0 > reserve1) {
            imbalance = reserve0 - reserve1;
        } else {
            imbalance = reserve1 - reserve0;
        }

        // Scale to PRECISION for sqrt calculation
        uint256 imbalanceRatio = (imbalance * PRECISION) / totalReserves;

        // Calculate sqrt(imbalanceRatio) using Newton-Raphson
        uint256 sqrtImbalance = _sqrt(imbalanceRatio);

        // imbalanceFee = sqrt(ratio) * IMBALANCE_MULTIPLIER_BPS / sqrt(PRECISION)
        // sqrt(PRECISION) = sqrt(1e18) = 1e9
        uint256 imbalanceFee = (sqrtImbalance * IMBALANCE_MULTIPLIER_BPS) / 1e9;

        fee = baseFee + imbalanceFee;
    }

    /**
     * @notice Get current base fee
     */
    function _getBaseFee() internal view returns (uint256) {
        if (useCustomBaseFee) {
            return customBaseFee;
        }
        return BASE_FEE_BPS;
    }

    /**
     * @notice Integer square root using Newton-Raphson method
     * @param x Value to sqrt
     * @return y Square root of x
     */
    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Set custom base fee
     * @param _baseFee New base fee in basis points
     */
    function setBaseFee(uint256 _baseFee) external onlyPoolManager {
        if (_baseFee > MAX_FEE_BPS) revert DynamicFeeModule__FeeTooHigh();
        
        emit BaseFeeUpdated(_getBaseFee(), _baseFee);
        
        customBaseFee = _baseFee;
        useCustomBaseFee = true;
    }

    /**
     * @notice Reset to default base fee
     */
    function resetBaseFee() external onlyPoolManager {
        emit BaseFeeUpdated(_getBaseFee(), BASE_FEE_BPS);
        useCustomBaseFee = false;
    }

    /**
     * @notice Transfer pool manager role
     * @param _newManager New pool manager address
     */
    function setPoolManager(address _newManager) external onlyPoolManager {
        poolManager = _newManager;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Preview fee for given reserves
     * @param reserve0 Token0 reserves
     * @param reserve1 Token1 reserves
     * @return fee Fee in basis points
     */
    function previewFee(uint256 reserve0, uint256 reserve1) external view returns (uint256 fee) {
        return _calculateFee(reserve0, reserve1);
    }

    /**
     * @notice Get current fee based on actual pool reserves
     * @return fee Current fee in basis points
     */
    function getCurrentFee() external view returns (uint256 fee) {
        (uint256 reserve0, uint256 reserve1) = pool.getReserves();
        return _calculateFee(reserve0, reserve1);
    }

    /**
     * @notice Get current imbalance ratio
     * @return ratio Imbalance ratio (0 = balanced, 1e18 = fully imbalanced)
     */
    function getImbalanceRatio() external view returns (uint256 ratio) {
        (uint256 reserve0, uint256 reserve1) = pool.getReserves();
        
        if (reserve0 == 0 && reserve1 == 0) return 0;
        
        uint256 totalReserves = reserve0 + reserve1;
        uint256 imbalance = reserve0 > reserve1 ? reserve0 - reserve1 : reserve1 - reserve0;
        
        return (imbalance * PRECISION) / totalReserves;
    }
}
