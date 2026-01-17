// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ILendingOrchestrator} from "../interfaces/ILendingOrchestrator.sol";
import {ISovereignPool} from "@valantis-core/pools/interfaces/ISovereignPool.sol";
import {CoreWriterLib} from "@hyper-evm-lib/CoreWriterLib.sol";
import {PrecompileLib} from "@hyper-evm-lib/PrecompileLib.sol";
import {HLConstants} from "@hyper-evm-lib/common/HLConstants.sol";
import {HLConversions} from "@hyper-evm-lib/common/HLConversions.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title LendingOrchestrator
 * @notice Manages capital allocation between AMM and HyperCore staking/lending
 * @dev Uses CoreWriter to execute cross-layer actions:
 *      - Bridge tokens to HyperCore
 *      - Delegate to validators for staking yield
 *      - Withdraw from staking back to AMM
 * 
 * Flow:
 * 1. Detect excess reserves in AMM
 * 2. Calculate target based on policy (e.g., 60% AMM, 40% staking)
 * 3. Bridge excess to HyperCore via system address
 * 4. Delegate to validator via CoreWriter
 * 5. Actions execute async (2-3 seconds)
 */
contract LendingOrchestrator is ILendingOrchestrator {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Basis points denominator
    uint256 public constant BPS = 10000;

    /// @notice Default target AMM share (60%)
    uint256 public constant DEFAULT_TARGET_AMM_SHARE = 6000;

    /// @notice Default max rebalance per call (10k tokens)
    uint256 public constant DEFAULT_MAX_REBALANCE = 10_000 ether;

    /// @notice Default cooldown between rebalances (30 L1 blocks ≈ 2.5 seconds)
    uint256 public constant DEFAULT_COOLDOWN = 30;

    /// @notice Minimum rebalance amount to avoid dust
    uint256 public constant MIN_REBALANCE_AMOUNT = 0.01 ether;

    // ═══════════════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice The Sovereign Pool we're managing capital for
    ISovereignPool public immutable pool;

    /// @notice HYPE token on HyperEVM
    address public immutable hypeToken;

    /// @notice Strategist who can trigger rebalancing
    address public strategist;

    /// @notice Rebalancing configuration
    RebalanceConfig public config;

    /// @notice Last rebalance L1 block
    uint64 public lastRebalanceL1Block;

    /// @notice Total amount currently staked on HyperCore
    uint256 public totalStaked;

    // ═══════════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════════

    error LendingOrchestrator__OnlyStrategist();
    error LendingOrchestrator__CooldownNotPassed();
    error LendingOrchestrator__AmountTooSmall();
    error LendingOrchestrator__AmountExceedsMax();
    error LendingOrchestrator__InsufficientStaked();
    error LendingOrchestrator__InvalidConfig();

    // ═══════════════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════════════

    modifier onlyStrategist() {
        if (msg.sender != strategist) revert LendingOrchestrator__OnlyStrategist();
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════════

    constructor(
        address _pool,
        address _hypeToken,
        address _strategist,
        address _validator
    ) {
        pool = ISovereignPool(_pool);
        hypeToken = _hypeToken;
        strategist = _strategist;

        // Set default config
        config = RebalanceConfig({
            targetAmmShareBps: DEFAULT_TARGET_AMM_SHARE,
            maxRebalanceAmount: DEFAULT_MAX_REBALANCE,
            cooldownBlocks: DEFAULT_COOLDOWN,
            validator: _validator
        });
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // REBALANCING
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @inheritdoc ILendingOrchestrator
     * @notice Move excess AMM reserves to HyperCore staking
     * @param amount Amount of HYPE to move to staking
     */
    function rebalanceToStaking(uint256 amount) external onlyStrategist {
        // Check cooldown
        if (!canRebalance()) revert LendingOrchestrator__CooldownNotPassed();
        
        // Validate amount
        if (amount < MIN_REBALANCE_AMOUNT) revert LendingOrchestrator__AmountTooSmall();
        if (amount > config.maxRebalanceAmount) revert LendingOrchestrator__AmountExceedsMax();

        // Get HYPE from pool reserves
        // Note: In production, this would coordinate with the ALM
        (uint256 reserve0, uint256 reserve1) = pool.getReserves();
        address[] memory tokens = pool.getTokens();
        
        uint256 hypeReserve;
        if (tokens[0] == hypeToken) {
            hypeReserve = reserve0;
        } else {
            hypeReserve = reserve1;
        }

        // Ensure we have enough
        require(amount <= hypeReserve, "Insufficient reserves");

        // Update state
        lastRebalanceL1Block = PrecompileLib.l1BlockNumber();
        totalStaked += amount;

        // 1. Bridge HYPE to HyperCore
        CoreWriterLib.bridgeToCore(hypeToken, amount);

        // 2. Deposit to staking
        uint64 coreAmount = HLConversions.evmToWei(HLConstants.hypeTokenIndex(), amount);
        CoreWriterLib.depositStake(coreAmount);

        // 3. Delegate to validator
        CoreWriterLib.delegateToken(config.validator, coreAmount, false);

        emit RebalanceToStaking(amount, config.validator);
    }

    /**
     * @inheritdoc ILendingOrchestrator
     * @notice Withdraw from staking back to AMM
     * @param amount Amount of HYPE to withdraw from staking
     */
    function rebalanceFromStaking(uint256 amount) external onlyStrategist {
        // Check cooldown
        if (!canRebalance()) revert LendingOrchestrator__CooldownNotPassed();

        // Validate amount
        if (amount < MIN_REBALANCE_AMOUNT) revert LendingOrchestrator__AmountTooSmall();
        if (amount > config.maxRebalanceAmount) revert LendingOrchestrator__AmountExceedsMax();
        if (amount > totalStaked) revert LendingOrchestrator__InsufficientStaked();

        // Update state
        lastRebalanceL1Block = PrecompileLib.l1BlockNumber();
        totalStaked -= amount;

        // 1. Undelegate from validator
        uint64 coreAmount = HLConversions.evmToWei(HLConstants.hypeTokenIndex(), amount);
        CoreWriterLib.delegateToken(config.validator, coreAmount, true);

        // 2. Withdraw from staking
        CoreWriterLib.withdrawStake(coreAmount);

        // 3. Bridge back to EVM
        CoreWriterLib.bridgeToEvm(hypeToken, amount);

        emit RebalanceFromStaking(amount);
    }

    /**
     * @inheritdoc ILendingOrchestrator
     * @notice Calculate recommended rebalance amounts
     */
    function calculateRebalanceAmount() external view returns (uint256 toStaking, uint256 fromStaking) {
        // Get current AMM reserves
        (uint256 reserve0, uint256 reserve1) = pool.getReserves();
        address[] memory tokens = pool.getTokens();
        
        uint256 hypeReserve;
        if (tokens[0] == hypeToken) {
            hypeReserve = reserve0;
        } else {
            hypeReserve = reserve1;
        }

        // Calculate total capital (AMM + staked)
        uint256 totalCapital = hypeReserve + totalStaked;
        
        if (totalCapital == 0) return (0, 0);

        // Calculate target AMM amount
        uint256 targetAmmAmount = (totalCapital * config.targetAmmShareBps) / BPS;

        if (hypeReserve > targetAmmAmount) {
            // Excess in AMM → move to staking
            uint256 excess = hypeReserve - targetAmmAmount;
            toStaking = excess > config.maxRebalanceAmount ? config.maxRebalanceAmount : excess;
        } else if (hypeReserve < targetAmmAmount) {
            // Deficit in AMM → withdraw from staking
            uint256 deficit = targetAmmAmount - hypeReserve;
            uint256 available = totalStaked > deficit ? deficit : totalStaked;
            fromStaking = available > config.maxRebalanceAmount ? config.maxRebalanceAmount : available;
        }
    }

    /**
     * @inheritdoc ILendingOrchestrator
     * @notice Check if rebalancing is allowed (cooldown passed)
     */
    function canRebalance() public view returns (bool) {
        uint64 currentL1Block = PrecompileLib.l1BlockNumber();
        return (currentL1Block - lastRebalanceL1Block) >= config.cooldownBlocks;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @inheritdoc ILendingOrchestrator
     * @notice Update rebalancing configuration
     */
    function setConfig(RebalanceConfig calldata _config) external onlyStrategist {
        if (_config.targetAmmShareBps > BPS) revert LendingOrchestrator__InvalidConfig();
        if (_config.validator == address(0)) revert LendingOrchestrator__InvalidConfig();
        
        config = _config;
        emit ConfigUpdated(_config);
    }

    /**
     * @inheritdoc ILendingOrchestrator
     * @notice Get current configuration
     */
    function getConfig() external view returns (RebalanceConfig memory) {
        return config;
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
     * @notice Get current capital allocation
     * @return ammAmount Amount in AMM
     * @return stakedAmount Amount staked
     * @return ammShareBps Current AMM share in basis points
     */
    function getCapitalAllocation() external view returns (
        uint256 ammAmount,
        uint256 stakedAmount,
        uint256 ammShareBps
    ) {
        (uint256 reserve0, uint256 reserve1) = pool.getReserves();
        address[] memory tokens = pool.getTokens();
        
        if (tokens[0] == hypeToken) {
            ammAmount = reserve0;
        } else {
            ammAmount = reserve1;
        }

        stakedAmount = totalStaked;

        uint256 total = ammAmount + stakedAmount;
        if (total > 0) {
            ammShareBps = (ammAmount * BPS) / total;
        }
    }

    /**
     * @notice Get blocks until next rebalance allowed
     * @return blocks Remaining cooldown blocks (0 if rebalance allowed)
     */
    function blocksUntilRebalance() external view returns (uint64 blocks) {
        uint64 currentL1Block = PrecompileLib.l1BlockNumber();
        uint64 elapsed = currentL1Block - lastRebalanceL1Block;
        
        if (elapsed >= config.cooldownBlocks) {
            return 0;
        }
        
        return uint64(config.cooldownBlocks) - elapsed;
    }

    /**
     * @notice Read staking delegations from HyperCore
     * @return delegations Array of current delegations
     */
    function getDelegations() external view returns (PrecompileLib.Delegation[] memory) {
        return PrecompileLib.delegations(address(this));
    }

    /**
     * @notice Read delegator summary from HyperCore
     * @return summary Delegation summary
     */
    function getDelegatorSummary() external view returns (PrecompileLib.DelegatorSummary memory) {
        return PrecompileLib.delegatorSummary(address(this));
    }
}
