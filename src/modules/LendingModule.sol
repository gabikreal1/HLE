// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ILendingModule} from "../interfaces/ILendingModule.sol";
import {ISovereignPool} from "@valantis-core/pools/interfaces/ISovereignPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {CoreWriterLib} from "@hyper-evm-lib/CoreWriterLib.sol";
import {HLConversions} from "@hyper-evm-lib/common/HLConversions.sol";
import {PrecompileLib} from "@hyper-evm-lib/PrecompileLib.sol";

/**
 * @title ICoreWriter
 * @notice Interface for HyperCore's CoreWriter contract
 */
interface ICoreWriter {
    function sendRawAction(bytes calldata data) external;
}

/**
 * @title LendingModule
 * @notice Module for HLE to supply/withdraw tokens to HyperCore lending via CoreWriter
 * @dev Follows Valantis modular architecture - reads poolManager from the Sovereign Pool
 * 
 * Uses CoreWriter at 0x3333333333333333333333333333333333333333
 * 
 * Action ID: 15 (Lending - NOT in hyper-evm-lib, custom implementation)
 * Fields: (encodedOperation, token, wei) - (uint8, uint64, uint64)
 * 
 * encodedOperation:
 *   - 0 for Supply
 *   - 1 for Withdraw
 * 
 * If wei is 0, maximally applies the operation (e.g., withdraw full balance)
 * 
 * IMPORTANT: Flow for Supply requires bridging first!
 *   1. Bridge tokens to Core via CoreWriterLib.bridgeToCore()
 *   2. Then supply to lending via lending action (action ID 15)
 * 
 * Flow for Withdraw:
 *   1. Withdraw from lending via lending action (action ID 15)
 *   2. Bridge tokens back to EVM via CoreWriterLib.bridgeToEvm()
 */
contract LendingModule is ILendingModule {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice CoreWriter contract address on HyperEVM
    address public constant CORE_WRITER = 0x3333333333333333333333333333333333333333;

    /// @notice Action ID for Lending operations
    uint8 public constant LENDING_ACTION_ID = 15;

    /// @notice Operation codes
    uint8 public constant OP_SUPPLY = 0;
    uint8 public constant OP_WITHDRAW = 1;

    /// @notice Basis points denominator
    uint256 public constant BPS = 10000;

    // ═══════════════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Reference to the Sovereign Pool (to read poolManager)
    ISovereignPool public immutable pool;

    /// @notice Strategist who can trigger lending operations
    address public strategist;

    /// @notice Mapping of ERC20 token address to HyperCore token index
    mapping(address => uint64) public tokenIndices;

    /// @notice Tracking supplied amounts per token
    mapping(address => uint256) public totalSupplied;

    /// @notice Minimum supply amount to avoid dust
    uint256 public minSupplyAmount;

    /// @notice Cooldown between operations (in blocks)
    uint256 public cooldownBlocks;

    /// @notice Last operation block
    uint256 public lastOperationBlock;

    /// @notice Whether the module is paused
    bool public paused;

    // ═══════════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════════

    error LendingModule__OnlyPoolManager();
    error LendingModule__OnlyStrategist();
    error LendingModule__Paused();
    error LendingModule__CooldownNotPassed();
    error LendingModule__AmountTooSmall();
    error LendingModule__TokenNotSupported();
    error LendingModule__InsufficientSupplied();
    error LendingModule__ZeroAddress();
    error LendingModule__InvalidAmount();

    // ═══════════════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════════════

    modifier onlyPoolManager() {
        if (msg.sender != pool.poolManager()) revert LendingModule__OnlyPoolManager();
        _;
    }

    modifier onlyStrategist() {
        if (msg.sender != strategist && msg.sender != pool.poolManager()) {
            revert LendingModule__OnlyStrategist();
        }
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert LendingModule__Paused();
        _;
    }

    modifier cooldownPassed() {
        if (block.number < lastOperationBlock + cooldownBlocks) {
            revert LendingModule__CooldownNotPassed();
        }
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Initialize the lending module
     * @param _pool Sovereign Pool address (poolManager is read from here)
     * @param _strategist Address authorized to execute lending operations
     * @param _minSupplyAmount Minimum amount required for supply operations
     * @param _cooldownBlocks Minimum blocks between operations
     */
    constructor(
        address _pool,
        address _strategist,
        uint256 _minSupplyAmount,
        uint256 _cooldownBlocks
    ) {
        if (_pool == address(0)) revert LendingModule__ZeroAddress();
        if (_strategist == address(0)) revert LendingModule__ZeroAddress();

        pool = ISovereignPool(_pool);
        strategist = _strategist;
        minSupplyAmount = _minSupplyAmount;
        cooldownBlocks = _cooldownBlocks;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // LENDING OPERATIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Supply tokens to HyperCore lending protocol
     * @param token ERC20 token address to supply
     * @param amount Amount to supply (in EVM wei, 18 decimals)
     * @dev Encodes and sends action to CoreWriter with operation=0 (Supply)
     * @dev FLOW: 1) Bridge to Core → 2) Supply to lending
     */
    function supplyToLending(
        address token,
        uint256 amount
    ) external virtual onlyStrategist whenNotPaused cooldownPassed {
        // Validate token is supported
        uint64 tokenIndex = tokenIndices[token];
        if (tokenIndex == 0 && token != address(0)) {
            // Token index 0 might be valid (USDC), so check if explicitly set
            revert LendingModule__TokenNotSupported();
        }

        // Validate amount
        if (amount < minSupplyAmount && amount != 0) {
            revert LendingModule__AmountTooSmall();
        }

        // Convert EVM amount to HyperCore wei (8 decimals)
        uint64 weiAmount = uint64(HLConversions.evmToWei(tokenIndex, amount));

        // Update state
        lastOperationBlock = block.number;
        totalSupplied[token] += amount;

        // Step 1: Bridge tokens from EVM to Core
        // CoreWriterLib.bridgeToCore handles the transfer internally
        CoreWriterLib.bridgeToCore(token, amount);

        // Step 2: Supply to lending after bridge completes
        // Note: Due to async nature, these may need to be separate transactions
        // in production. For now, we send both actions.
        bytes memory encodedAction = _encodeLendingAction(OP_SUPPLY, tokenIndex, weiAmount);
        ICoreWriter(CORE_WRITER).sendRawAction(encodedAction);

        emit SupplyToLending(token, tokenIndex, amount, weiAmount, msg.sender);
    }

    /**
     * @notice Withdraw tokens from HyperCore lending protocol
     * @param token ERC20 token address to withdraw
     * @param amount Amount to withdraw (in EVM wei, 18 decimals). Use 0 for max withdrawal.
     * @dev Encodes and sends action to CoreWriter with operation=1 (Withdraw)
     * @dev FLOW: 1) Withdraw from lending → 2) Bridge back to EVM
     */
    function withdrawFromLending(
        address token,
        uint256 amount
    ) external virtual onlyStrategist whenNotPaused cooldownPassed {
        // Validate token is supported
        uint64 tokenIndex = tokenIndices[token];
        if (tokenIndex == 0 && token != address(0)) {
            revert LendingModule__TokenNotSupported();
        }

        // If amount is 0, this means max withdrawal (full balance)
        // Otherwise validate we have enough supplied
        if (amount > 0 && amount > totalSupplied[token]) {
            revert LendingModule__InsufficientSupplied();
        }

        // Convert EVM amount to HyperCore wei (8 decimals)
        // Note: If amount is 0, weiAmount will be 0, meaning max withdrawal
        uint64 weiAmount = uint64(HLConversions.evmToWei(tokenIndex, amount));

        // Update state
        lastOperationBlock = block.number;
        if (amount == 0) {
            // Max withdrawal - clear all tracked supply
            totalSupplied[token] = 0;
        } else {
            totalSupplied[token] -= amount;
        }

        // Step 1: Withdraw from lending
        bytes memory encodedAction = _encodeLendingAction(OP_WITHDRAW, tokenIndex, weiAmount);
        ICoreWriter(CORE_WRITER).sendRawAction(encodedAction);

        // Step 2: Bridge from Core back to EVM
        // Note: This needs to happen after withdraw completes (async)
        // In production, these may need to be separate transactions
        CoreWriterLib.bridgeToEvm(token, amount);

        emit WithdrawFromLending(token, tokenIndex, amount, weiAmount, msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // SIMPLIFIED INTERFACE (for YieldOptimizer integration)
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Alias for supplyToLending - simpler interface
     * @param token ERC20 token address to supply
     * @param amount Amount to supply (in EVM wei, 18 decimals)
     */
    function supply(address token, uint256 amount) external virtual onlyStrategist whenNotPaused cooldownPassed {
        _supplyInternal(token, amount);
    }

    /**
     * @notice Withdraw tokens from lending and send to a specific recipient
     * @param token ERC20 token address to withdraw
     * @param amount Amount to withdraw
     * @param recipient Address to receive the tokens
     */
    function withdraw(address token, uint256 amount, address recipient) external virtual onlyStrategist whenNotPaused cooldownPassed {
        if (recipient == address(0)) revert LendingModule__ZeroAddress();
        
        // Validate token is supported
        uint64 tokenIndex = tokenIndices[token];
        if (tokenIndex == 0 && token != address(0)) {
            revert LendingModule__TokenNotSupported();
        }

        if (amount > 0 && amount > totalSupplied[token]) {
            revert LendingModule__InsufficientSupplied();
        }

        uint64 weiAmount = uint64(HLConversions.evmToWei(tokenIndex, amount));

        lastOperationBlock = block.number;
        if (amount == 0) {
            totalSupplied[token] = 0;
        } else {
            totalSupplied[token] -= amount;
        }

        // Step 1: Withdraw from lending
        bytes memory encodedAction = _encodeLendingAction(OP_WITHDRAW, tokenIndex, weiAmount);
        ICoreWriter(CORE_WRITER).sendRawAction(encodedAction);

        // Step 2: Bridge from Core back to EVM to recipient
        CoreWriterLib.bridgeToEvm(recipient, amount);

        emit WithdrawFromLending(token, tokenIndex, amount, weiAmount, msg.sender);
    }

    /**
     * @notice Internal supply function
     */
    function _supplyInternal(address token, uint256 amount) internal {
        uint64 tokenIndex = tokenIndices[token];
        if (tokenIndex == 0 && token != address(0)) {
            revert LendingModule__TokenNotSupported();
        }

        if (amount < minSupplyAmount && amount != 0) {
            revert LendingModule__AmountTooSmall();
        }

        uint64 weiAmount = uint64(HLConversions.evmToWei(tokenIndex, amount));

        lastOperationBlock = block.number;
        totalSupplied[token] += amount;

        CoreWriterLib.bridgeToCore(token, amount);

        bytes memory encodedAction = _encodeLendingAction(OP_SUPPLY, tokenIndex, weiAmount);
        ICoreWriter(CORE_WRITER).sendRawAction(encodedAction);

        emit SupplyToLending(token, tokenIndex, amount, weiAmount, msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Encode a lending action for CoreWriter
     * @param operation 0 for Supply, 1 for Withdraw
     * @param tokenIndex HyperCore token index
     * @param weiAmount Amount in HyperCore wei (8 decimals), 0 for max
     * @return Encoded action bytes to send to CoreWriter
     * 
     * @dev Action format:
     *      Bytes 0-3: Action header (0x01, 0x00, 0x00, actionId)
     *      Bytes 4+:  ABI encoded (uint8 operation, uint64 tokenIndex, uint64 weiAmount)
     */
    function _encodeLendingAction(
        uint8 operation,
        uint64 tokenIndex,
        uint64 weiAmount
    ) internal pure returns (bytes memory) {
        // Encode the operation parameters
        bytes memory encodedParams = abi.encode(operation, tokenIndex, weiAmount);
        
        // Create the full action with header
        bytes memory data = new bytes(4 + encodedParams.length);
        
        // Header bytes: version (0x01), reserved (0x00, 0x00), action ID (15 = 0x0F)
        data[0] = 0x01;
        data[1] = 0x00;
        data[2] = 0x00;
        data[3] = bytes1(LENDING_ACTION_ID); // 15 = 0x0F
        
        // Copy encoded parameters
        for (uint256 i = 0; i < encodedParams.length; i++) {
            data[4 + i] = encodedParams[i];
        }
        
        return data;
    }

    /**
     * @notice Convert EVM wei (18 decimals) to HyperCore wei (8 decimals)
     * @param tokenIndex HyperCore token index  
     * @param evmAmount Amount in EVM wei (18 decimals)
     * @return Amount in HyperCore wei (8 decimals)
     * @dev Uses HLConversions from hyper-evm-lib for proper conversion
     */
    function _convertToHyperCoreWei(uint64 tokenIndex, uint256 evmAmount) internal view returns (uint64) {
        return uint64(HLConversions.evmToWei(tokenIndex, evmAmount));
    }

    /**
     * @notice Convert HyperCore wei (8 decimals) to EVM wei (18 decimals)
     * @param tokenIndex HyperCore token index
     * @param coreAmount Amount in HyperCore wei (8 decimals)
     * @return Amount in EVM wei (18 decimals)
     */
    function _convertToEVMWei(uint64 tokenIndex, uint64 coreAmount) internal view returns (uint256) {
        return HLConversions.weiToEvm(tokenIndex, coreAmount);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Check if an operation can be performed (cooldown passed)
     * @return True if cooldown has passed
     */
    function canOperate() external view returns (bool) {
        return block.number >= lastOperationBlock + cooldownBlocks;
    }

    /**
     * @notice Get the total amount supplied for a token
     * @param token Token address
     * @return Amount supplied (in EVM wei)
     */
    function getSuppliedAmount(address token) external view returns (uint256) {
        return totalSupplied[token];
    }

    /**
     * @notice Get token index for a token
     * @param token Token address
     * @return Token index on HyperCore
     */
    function getTokenIndex(address token) external view returns (uint64) {
        return tokenIndices[token];
    }

    /**
     * @notice Preview the encoded action that would be sent for a supply operation
     * @param token Token to supply
     * @param amount Amount to supply
     * @return Encoded action bytes
     */
    function previewSupplyAction(
        address token,
        uint256 amount
    ) external view virtual returns (bytes memory) {
        uint64 tokenIndex = tokenIndices[token];
        uint64 weiAmount = _convertToHyperCoreWei(tokenIndex, amount);
        return _encodeLendingAction(OP_SUPPLY, tokenIndex, weiAmount);
    }

    /**
     * @notice Preview the encoded action that would be sent for a withdraw operation
     * @param token Token to withdraw
     * @param amount Amount to withdraw (0 for max)
     * @return Encoded action bytes
     */
    function previewWithdrawAction(
        address token,
        uint256 amount
    ) external view virtual returns (bytes memory) {
        uint64 tokenIndex = tokenIndices[token];
        uint64 weiAmount = _convertToHyperCoreWei(tokenIndex, amount);
        return _encodeLendingAction(OP_WITHDRAW, tokenIndex, weiAmount);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Set the HyperCore token index for an ERC20 token
     * @param token ERC20 token address
     * @param tokenIndex HyperCore token index
     * @dev Common indices:
     *      - USDC: 0
     *      - HYPE: 1105
     */
    function setTokenIndex(address token, uint64 tokenIndex) external onlyPoolManager {
        tokenIndices[token] = tokenIndex;
        emit TokenIndexSet(token, tokenIndex);
    }

    /**
     * @notice Batch set token indices
     * @param tokens Array of token addresses
     * @param indices Array of token indices
     */
    function setTokenIndices(
        address[] calldata tokens,
        uint64[] calldata indices
    ) external onlyPoolManager {
        require(tokens.length == indices.length, "Length mismatch");
        for (uint256 i = 0; i < tokens.length; i++) {
            tokenIndices[tokens[i]] = indices[i];
            emit TokenIndexSet(tokens[i], indices[i]);
        }
    }

    /**
     * @notice Update the strategist address
     * @param _newStrategist New strategist address
     */
    function setStrategist(address _newStrategist) external onlyPoolManager {
        if (_newStrategist == address(0)) revert LendingModule__ZeroAddress();
        address oldStrategist = strategist;
        strategist = _newStrategist;
        emit StrategistUpdated(oldStrategist, _newStrategist);
    }

    /**
     * @notice Update module configuration
     * @param _minSupplyAmount New minimum supply amount
     * @param _cooldownBlocks New cooldown blocks
     */
    function setConfig(
        uint256 _minSupplyAmount,
        uint256 _cooldownBlocks
    ) external onlyPoolManager {
        minSupplyAmount = _minSupplyAmount;
        cooldownBlocks = _cooldownBlocks;
        emit ConfigUpdated(_minSupplyAmount, _cooldownBlocks);
    }

    /**
     * @notice Pause the module
     */
    function pause() external onlyPoolManager {
        paused = true;
        emit Paused(msg.sender);
    }

    /**
     * @notice Unpause the module
     */
    function unpause() external onlyPoolManager {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /**
     * @notice Emergency rescue tokens stuck in the contract
     * @param token Token to rescue
     * @param to Recipient address
     * @param amount Amount to rescue
     */
    function rescueTokens(
        address token,
        address to,
        uint256 amount
    ) external onlyPoolManager {
        if (to == address(0)) revert LendingModule__ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
    }
}
