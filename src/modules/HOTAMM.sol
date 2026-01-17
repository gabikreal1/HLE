// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISovereignALM} from "@valantis-core/ALM/interfaces/ISovereignALM.sol";
import {ALMLiquidityQuoteInput, ALMLiquidityQuote} from "@valantis-core/ALM/structs/SovereignALMStructs.sol";
import {ISovereignPool} from "@valantis-core/pools/interfaces/ISovereignPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title HOTAMM (Hybrid Order Type ALM)
 * @notice Constant Function Market Maker ALM for Sovereign Pool
 * @dev Implements x * y = k pricing with concentrated liquidity style bounds
 * 
 * This ALM provides:
 * - Standard CFMM (constant product) pricing
 * - Liquidity provision with LP token accounting
 * - Integration with HyperCore oracle for price bounds
 */
contract HOTAMM is ISovereignALM {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Minimum liquidity locked forever to prevent division by zero
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    /// @notice Precision for calculations
    uint256 public constant PRECISION = 1e18;

    // ═══════════════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice The Sovereign Pool this ALM serves
    ISovereignPool public immutable pool;

    /// @notice Token0 of the pool
    address public immutable token0;

    /// @notice Token1 of the pool
    address public immutable token1;

    /// @notice Pool manager address
    address public poolManager;

    /// @notice Total LP tokens minted
    uint256 public totalSupply;

    /// @notice LP token balances
    mapping(address => uint256) public balanceOf;

    /// @notice Internal reserves (for k calculation)
    uint256 internal _reserve0;
    uint256 internal _reserve1;

    // ═══════════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════════

    error HOTAMM__OnlyPool();
    error HOTAMM__OnlyPoolManager();
    error HOTAMM__InsufficientLiquidity();
    error HOTAMM__InsufficientLiquidityMinted();
    error HOTAMM__InsufficientLiquidityBurned();
    error HOTAMM__InvalidRecipient();
    error HOTAMM__InsufficientOutputAmount();
    error HOTAMM__ZeroAmount();

    // ═══════════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════════

    event Mint(address indexed sender, uint256 amount0, uint256 amount1, uint256 liquidity);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, uint256 liquidity, address indexed to);
    event Sync(uint256 reserve0, uint256 reserve1);

    // ═══════════════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════════════

    modifier onlyPool() {
        if (msg.sender != address(pool)) revert HOTAMM__OnlyPool();
        _;
    }

    modifier onlyPoolManager() {
        if (msg.sender != poolManager) revert HOTAMM__OnlyPoolManager();
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════════

    constructor(address _pool, address _poolManager) {
        pool = ISovereignPool(_pool);
        poolManager = _poolManager;

        address[] memory tokens = ISovereignPool(_pool).getTokens();
        token0 = tokens[0];
        token1 = tokens[1];
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // ISovereignALM IMPLEMENTATION
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @inheritdoc ISovereignALM
     * @notice Calculate output amount for a swap using constant product formula
     * @dev Uses x * y = k invariant
     */
    function getLiquidityQuote(
        ALMLiquidityQuoteInput memory _almLiquidityQuoteInput,
        bytes calldata _externalContext,
        bytes calldata _verifierData
    ) external override onlyPool returns (ALMLiquidityQuote memory) {
        uint256 amountIn = _almLiquidityQuoteInput.amountInMinusFee;
        
        if (amountIn == 0) {
            return ALMLiquidityQuote({
                isCallbackOnSwap: false,
                amountOut: 0,
                amountInFilled: 0
            });
        }

        uint256 reserveIn;
        uint256 reserveOut;

        if (_almLiquidityQuoteInput.isZeroToOne) {
            reserveIn = _reserve0;
            reserveOut = _reserve1;
        } else {
            reserveIn = _reserve1;
            reserveOut = _reserve0;
        }

        if (reserveIn == 0 || reserveOut == 0) {
            revert HOTAMM__InsufficientLiquidity();
        }

        // Constant product: (x + dx) * (y - dy) = x * y
        // dy = y * dx / (x + dx)
        uint256 amountOut = (reserveOut * amountIn) / (reserveIn + amountIn);

        if (amountOut == 0) {
            revert HOTAMM__InsufficientOutputAmount();
        }

        return ALMLiquidityQuote({
            isCallbackOnSwap: true,
            amountOut: amountOut,
            amountInFilled: amountIn
        });
    }

    /**
     * @inheritdoc ISovereignALM
     * @notice Callback after liquidity deposit
     */
    function onDepositLiquidityCallback(
        uint256 _amount0,
        uint256 _amount1,
        bytes memory _data
    ) external override onlyPool {
        address sender = abi.decode(_data, (address));
        
        uint256 liquidity;
        
        if (totalSupply == 0) {
            // First deposit
            liquidity = Math.sqrt(_amount0 * _amount1) - MINIMUM_LIQUIDITY;
            // Permanently lock minimum liquidity
            balanceOf[address(0)] = MINIMUM_LIQUIDITY;
            totalSupply = MINIMUM_LIQUIDITY;
        } else {
            // Subsequent deposits - mint proportional to smaller ratio
            uint256 liquidity0 = (_amount0 * totalSupply) / _reserve0;
            uint256 liquidity1 = (_amount1 * totalSupply) / _reserve1;
            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        }

        if (liquidity == 0) revert HOTAMM__InsufficientLiquidityMinted();

        balanceOf[sender] += liquidity;
        totalSupply += liquidity;

        _reserve0 += _amount0;
        _reserve1 += _amount1;

        emit Mint(sender, _amount0, _amount1, liquidity);
        emit Sync(_reserve0, _reserve1);
    }

    /**
     * @inheritdoc ISovereignALM
     * @notice Callback after swap execution
     */
    function onSwapCallback(
        bool _isZeroToOne,
        uint256 _amountIn,
        uint256 _amountOut
    ) external override onlyPool {
        // Update reserves after swap
        if (_isZeroToOne) {
            _reserve0 += _amountIn;
            _reserve1 -= _amountOut;
        } else {
            _reserve1 += _amountIn;
            _reserve0 -= _amountOut;
        }

        emit Sync(_reserve0, _reserve1);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // LIQUIDITY MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Withdraw liquidity from the pool
     * @param liquidity Amount of LP tokens to burn
     * @param recipient Address to receive tokens
     * @return amount0 Amount of token0 withdrawn
     * @return amount1 Amount of token1 withdrawn
     */
    function withdrawLiquidity(
        uint256 liquidity,
        address recipient
    ) external returns (uint256 amount0, uint256 amount1) {
        if (liquidity == 0) revert HOTAMM__ZeroAmount();
        if (recipient == address(0)) revert HOTAMM__InvalidRecipient();
        if (balanceOf[msg.sender] < liquidity) revert HOTAMM__InsufficientLiquidityBurned();

        // Calculate proportional amounts
        amount0 = (liquidity * _reserve0) / totalSupply;
        amount1 = (liquidity * _reserve1) / totalSupply;

        if (amount0 == 0 && amount1 == 0) revert HOTAMM__InsufficientLiquidityBurned();

        // Update state
        balanceOf[msg.sender] -= liquidity;
        totalSupply -= liquidity;
        _reserve0 -= amount0;
        _reserve1 -= amount1;

        // Call pool to execute withdrawal
        pool.withdrawLiquidity(
            amount0,
            amount1,
            msg.sender,
            recipient,
            ""
        );

        emit Burn(msg.sender, amount0, amount1, liquidity, recipient);
        emit Sync(_reserve0, _reserve1);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get current reserves
     * @return reserve0 Token0 reserves
     * @return reserve1 Token1 reserves
     */
    function getReserves() external view returns (uint256 reserve0, uint256 reserve1) {
        return (_reserve0, _reserve1);
    }

    /**
     * @notice Get current k value (invariant)
     * @return k Product of reserves
     */
    function getK() external view returns (uint256 k) {
        return _reserve0 * _reserve1;
    }

    /**
     * @notice Preview output amount for swap
     * @param amountIn Input amount (after fees)
     * @param isZeroToOne Direction of swap
     * @return amountOut Expected output amount
     */
    function previewSwap(
        uint256 amountIn,
        bool isZeroToOne
    ) external view returns (uint256 amountOut) {
        uint256 reserveIn = isZeroToOne ? _reserve0 : _reserve1;
        uint256 reserveOut = isZeroToOne ? _reserve1 : _reserve0;

        if (reserveIn == 0 || reserveOut == 0) return 0;

        amountOut = (reserveOut * amountIn) / (reserveIn + amountIn);
    }

    /**
     * @notice Calculate current spot price
     * @return priceX96 Price of token0 in terms of token1 (Q96)
     */
    function getSpotPrice() external view returns (uint256 priceX96) {
        if (_reserve0 == 0) return 0;
        // price = reserve1 / reserve0 in Q96 format
        return (_reserve1 * (2**96)) / _reserve0;
    }

    /**
     * @notice Get LP balance for an account
     * @param account Address to check
     * @return balance LP token balance
     */
    function getLPBalance(address account) external view returns (uint256 balance) {
        return balanceOf[account];
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Sync reserves with actual pool balances (emergency)
     * @dev Only pool manager can call
     */
    function sync() external onlyPoolManager {
        (uint256 poolReserve0, uint256 poolReserve1) = pool.getReserves();
        _reserve0 = poolReserve0;
        _reserve1 = poolReserve1;
        emit Sync(_reserve0, _reserve1);
    }

    /**
     * @notice Transfer pool manager role
     * @param _newManager New pool manager
     */
    function setPoolManager(address _newManager) external onlyPoolManager {
        poolManager = _newManager;
    }
}
