// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {L1OracleAdapter} from "../libraries/L1OracleAdapter.sol";
import {YieldTracker} from "../libraries/YieldTracker.sol";
import {ILendingModule} from "../interfaces/ILendingModule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title YieldOptimizer
 * @notice Compares ALM yield vs HyperCore lending yield to optimize capital allocation
 * @dev Decision logic:
 *   - If ALM yield (smoothed EWMA) > lending APY + threshold → keep in ALM
 *   - If lending APY > ALM yield + threshold → move to lending
 *   - Uses hysteresis to prevent constant rebalancing
 * 
 * Integration:
 *   - Reads lending APY from L1OracleAdapter (borrow/lend precompile)
 *   - Tracks ALM yield via YieldTracker
 *   - Executes rebalancing via LendingModule
 */
contract YieldOptimizer is Ownable2Step {
    using YieldTracker for YieldTracker.YieldState;

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Basis points precision
    uint256 constant BPS = 10_000;

    /// @notice Minimum time between rebalances (1 hour)
    uint256 constant MIN_REBALANCE_INTERVAL = 1 hours;

    /// @notice Minimum yield advantage to trigger rebalance (default 50 bps = 0.5%)
    uint256 constant DEFAULT_REBALANCE_THRESHOLD_BPS = 50;

    /// @notice Maximum portion of liquidity to move in single rebalance (50%)
    uint256 constant MAX_REBALANCE_PORTION_BPS = 5000;

    // ═══════════════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Token being optimized
    address public immutable token;

    /// @notice HyperCore token index for the token
    uint64 public immutable tokenIndex;

    /// @notice Lending module for supply/withdraw operations
    ILendingModule public lendingModule;

    /// @notice ALM contract that holds liquidity
    address public alm;

    /// @notice Yield tracking state for ALM
    YieldTracker.YieldState public almYieldState;

    /// @notice Rebalance threshold in basis points
    uint256 public rebalanceThresholdBps;

    /// @notice Last rebalance timestamp
    uint64 public lastRebalanceTime;

    /// @notice Current capital allocation (BPS in ALM, rest in lending)
    uint256 public almAllocationBps;

    /// @notice Whether optimizer is active
    bool public isActive;

    // ═══════════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════════

    event RebalanceExecuted(
        uint256 almYieldBps,
        uint256 lendingYieldBps,
        uint256 amountMoved,
        bool movedToLending
    );

    event YieldUpdated(
        uint256 almYieldBps,
        uint256 smoothedAlmYieldBps,
        uint256 lendingYieldBps
    );

    event AllocationUpdated(uint256 newAlmAllocationBps);
    event ThresholdUpdated(uint256 newThresholdBps);
    event ALMUpdated(address newALM);
    event LendingModuleUpdated(address newLendingModule);
    event OptimizerActivated(bool active);

    // ═══════════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════════

    error YieldOptimizer__NotActive();
    error YieldOptimizer__TooSoon();
    error YieldOptimizer__InvalidThreshold();
    error YieldOptimizer__InvalidAllocation();
    error YieldOptimizer__ZeroAddress();
    error YieldOptimizer__NoRebalanceNeeded();
    error YieldOptimizer__OnlyALM();

    // ═══════════════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════════════

    modifier onlyALM() {
        if (msg.sender != alm) revert YieldOptimizer__OnlyALM();
        _;
    }

    modifier whenActive() {
        if (!isActive) revert YieldOptimizer__NotActive();
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Initialize the yield optimizer
     * @param _token Token to optimize
     * @param _tokenIndex HyperCore token index
     * @param _lendingModule Lending module address
     * @param _alm ALM contract address
     * @param _owner Owner address
     */
    constructor(
        address _token,
        uint64 _tokenIndex,
        address _lendingModule,
        address _alm,
        address _owner
    ) {
        if (_token == address(0)) revert YieldOptimizer__ZeroAddress();
        if (_lendingModule == address(0)) revert YieldOptimizer__ZeroAddress();
        if (_alm == address(0)) revert YieldOptimizer__ZeroAddress();
        if (_owner == address(0)) revert YieldOptimizer__ZeroAddress();

        token = _token;
        tokenIndex = _tokenIndex;
        lendingModule = ILendingModule(_lendingModule);
        alm = _alm;
        rebalanceThresholdBps = DEFAULT_REBALANCE_THRESHOLD_BPS;
        almAllocationBps = BPS; // Start with 100% in ALM
        isActive = false; // Must be explicitly activated
        
        // Transfer ownership to _owner (OZ 4.x)
        _transferOwnership(_owner);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Initialize yield tracking with current ALM liquidity
     * @param initialLiquidity Current liquidity in ALM (WAD)
     */
    function initializeTracking(uint256 initialLiquidity) external onlyOwner {
        almYieldState.initialize(initialLiquidity);
        isActive = true;
        emit OptimizerActivated(true);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // ALM CALLBACKS (called by ALM on each swap)
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Record fee income from ALM swap
     * @dev Called by ALM after each swap
     * @param feeAmount Fee earned (WAD)
     * @param newLiquidity Updated liquidity after swap (WAD)
     */
    function recordSwapFees(
        uint256 feeAmount,
        uint256 newLiquidity
    ) external onlyALM whenActive {
        almYieldState.recordSwap(feeAmount, newLiquidity);
    }

    /**
     * @notice Update liquidity tracking (for deposits/withdrawals)
     * @param newLiquidity New liquidity amount (WAD)
     */
    function updateLiquidity(uint256 newLiquidity) external onlyALM whenActive {
        almYieldState.updateLiquidity(newLiquidity);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // REBALANCING
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Check if rebalancing is recommended
     * @return shouldRebalance True if rebalancing is recommended
     * @return moveToLending True if should move to lending, false if to ALM
     * @return suggestedAmount Amount to move (WAD)
     */
    function checkRebalance() external view whenActive returns (
        bool shouldRebalance,
        bool moveToLending,
        uint256 suggestedAmount
    ) {
        // Check cooldown
        if (block.timestamp < lastRebalanceTime + MIN_REBALANCE_INTERVAL) {
            return (false, false, 0);
        }

        // Get yields
        uint256 lendingYieldBps = L1OracleAdapter.getLendingAPY(tokenIndex);
        YieldTracker.YieldComparison memory comparison = almYieldState.compareYields(lendingYieldBps);

        // Determine if rebalance is needed
        if (comparison.yieldDifferenceBps > int256(rebalanceThresholdBps)) {
            // ALM yield is better by more than threshold
            // Move from lending to ALM
            uint256 lendingBalance = _getLendingBalance();
            if (lendingBalance > 0) {
                suggestedAmount = (lendingBalance * MAX_REBALANCE_PORTION_BPS) / BPS;
                return (true, false, suggestedAmount);
            }
        } else if (comparison.yieldDifferenceBps < -int256(rebalanceThresholdBps)) {
            // Lending yield is better by more than threshold
            // Move from ALM to lending
            uint256 almBalance = IERC20(token).balanceOf(alm);
            if (almBalance > 0) {
                suggestedAmount = (almBalance * MAX_REBALANCE_PORTION_BPS) / BPS;
                return (true, true, suggestedAmount);
            }
        }

        return (false, false, 0);
    }

    /**
     * @notice Execute rebalancing based on yield comparison
     * @dev Can only be called after MIN_REBALANCE_INTERVAL
     */
    function executeRebalance() external whenActive {
        if (block.timestamp < lastRebalanceTime + MIN_REBALANCE_INTERVAL) {
            revert YieldOptimizer__TooSoon();
        }

        // Get current yields
        uint256 lendingYieldBps = L1OracleAdapter.getLendingAPY(tokenIndex);
        uint256 almYieldBps = almYieldState.updateYieldEWMA();
        YieldTracker.YieldComparison memory comparison = almYieldState.compareYields(lendingYieldBps);

        emit YieldUpdated(almYieldBps, comparison.smoothedAlmYieldBps, lendingYieldBps);

        uint256 amountMoved;
        bool movedToLending;

        if (comparison.yieldDifferenceBps > int256(rebalanceThresholdBps)) {
            // ALM is better - move from lending to ALM
            amountMoved = _withdrawFromLending();
            movedToLending = false;
        } else if (comparison.yieldDifferenceBps < -int256(rebalanceThresholdBps)) {
            // Lending is better - move from ALM to lending
            amountMoved = _supplyToLending();
            movedToLending = true;
        } else {
            revert YieldOptimizer__NoRebalanceNeeded();
        }

        lastRebalanceTime = uint64(block.timestamp);
        _updateAllocation();

        // Reset tracking period after rebalance
        almYieldState.resetPeriod();

        emit RebalanceExecuted(
            comparison.almYieldBps,
            lendingYieldBps,
            amountMoved,
            movedToLending
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get current yield comparison
     * @return comparison Yield comparison struct
     */
    function getYieldComparison() external view returns (YieldTracker.YieldComparison memory comparison) {
        uint256 lendingYieldBps = L1OracleAdapter.getLendingAPY(tokenIndex);
        comparison = almYieldState.compareYields(lendingYieldBps);
    }

    /**
     * @notice Get current ALM yield (annualized, in BPS)
     * @return yieldBps Current ALM yield
     */
    function getCurrentALMYield() external view returns (uint256 yieldBps) {
        return almYieldState.calculateCurrentYield();
    }

    /**
     * @notice Get smoothed ALM yield (EWMA)
     * @return yieldBps Smoothed ALM yield
     */
    function getSmoothedALMYield() external view returns (uint256 yieldBps) {
        return almYieldState.getSmoothedYield();
    }

    /**
     * @notice Get current lending APY
     * @return yieldBps Lending APY in basis points
     */
    function getLendingYield() external view returns (uint256 yieldBps) {
        return L1OracleAdapter.getLendingAPY(tokenIndex);
    }

    /**
     * @notice Get total capital (ALM + lending)
     * @return totalCapital Total capital in WAD
     */
    function getTotalCapital() external view returns (uint256 totalCapital) {
        uint256 almBalance = IERC20(token).balanceOf(alm);
        uint256 lendingBalance = _getLendingBalance();
        totalCapital = almBalance + lendingBalance;
    }

    /**
     * @notice Get tracking statistics
     * @return totalFees Total fees earned in current period
     * @return avgLiquidity Average liquidity over period
     * @return trackingDuration Duration of current tracking period
     */
    function getTrackingStats() external view returns (
        uint256 totalFees,
        uint256 avgLiquidity,
        uint256 trackingDuration
    ) {
        totalFees = almYieldState.getTotalFees();
        avgLiquidity = almYieldState.getAverageLiquidity();
        trackingDuration = almYieldState.getTrackingDuration();
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Update rebalance threshold
     * @param newThresholdBps New threshold in basis points
     */
    function setRebalanceThreshold(uint256 newThresholdBps) external onlyOwner {
        if (newThresholdBps > BPS) revert YieldOptimizer__InvalidThreshold();
        rebalanceThresholdBps = newThresholdBps;
        emit ThresholdUpdated(newThresholdBps);
    }

    /**
     * @notice Update ALM address
     * @param newALM New ALM address
     */
    function setALM(address newALM) external onlyOwner {
        if (newALM == address(0)) revert YieldOptimizer__ZeroAddress();
        alm = newALM;
        emit ALMUpdated(newALM);
    }

    /**
     * @notice Update lending module
     * @param newLendingModule New lending module address
     */
    function setLendingModule(address newLendingModule) external onlyOwner {
        if (newLendingModule == address(0)) revert YieldOptimizer__ZeroAddress();
        lendingModule = ILendingModule(newLendingModule);
        emit LendingModuleUpdated(newLendingModule);
    }

    /**
     * @notice Pause/unpause optimizer
     * @param active New active state
     */
    function setActive(bool active) external onlyOwner {
        isActive = active;
        emit OptimizerActivated(active);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get current balance in lending (in EVM decimals)
     */
    function _getLendingBalance() internal view returns (uint256 balance) {
        return L1OracleAdapter.getUserSuppliedEVM(address(this), tokenIndex);
    }

    /**
     * @notice Move capital from ALM to lending
     */
    function _supplyToLending() internal returns (uint256 amountMoved) {
        uint256 almBalance = IERC20(token).balanceOf(alm);
        amountMoved = (almBalance * MAX_REBALANCE_PORTION_BPS) / BPS;
        
        if (amountMoved > 0) {
            // Transfer from ALM to this contract
            IERC20(token).transferFrom(alm, address(this), amountMoved);
            
            // Approve and supply to lending
            IERC20(token).approve(address(lendingModule), amountMoved);
            lendingModule.supply(token, amountMoved);
        }
    }

    /**
     * @notice Move capital from lending to ALM
     */
    function _withdrawFromLending() internal returns (uint256 amountMoved) {
        uint256 lendingBalance = _getLendingBalance();
        amountMoved = (lendingBalance * MAX_REBALANCE_PORTION_BPS) / BPS;
        
        if (amountMoved > 0) {
            // Withdraw from lending
            lendingModule.withdraw(token, amountMoved, alm);
        }
    }

    /**
     * @notice Update allocation tracking
     */
    function _updateAllocation() internal {
        uint256 almBalance = IERC20(token).balanceOf(alm);
        uint256 lendingBalance = _getLendingBalance();
        uint256 total = almBalance + lendingBalance;
        
        if (total > 0) {
            almAllocationBps = (almBalance * BPS) / total;
        } else {
            almAllocationBps = BPS;
        }
        
        emit AllocationUpdated(almAllocationBps);
    }
}
