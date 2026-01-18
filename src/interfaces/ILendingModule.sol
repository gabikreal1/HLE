// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title ILendingModule
 * @notice Interface for the HLE lending module
 * @dev Enables supply/withdraw operations to HyperCore lending via CoreWriter
 * 
 * Action ID: 15 (not in hyper-evm-lib, custom implementation)
 * Fields: (encodedOperation, token, wei) - (uint8, uint64, uint64)
 * 
 * Operations:
 *   - 0: Supply tokens to lending
 *   - 1: Withdraw tokens from lending
 * 
 * Note: If wei is 0, the operation is applied maximally (e.g., withdraw full balance)
 * 
 * IMPORTANT: Supply requires bridging to Core first!
 * IMPORTANT: Withdraw requires bridging back to EVM after!
 */
interface ILendingModule {
    // ═══════════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════════

    event SupplyToLending(
        address indexed token,
        uint64 indexed tokenIndex,
        uint256 amount,
        uint64 weiAmount,
        address indexed sender
    );

    event WithdrawFromLending(
        address indexed token,
        uint64 indexed tokenIndex,
        uint256 amount,
        uint64 weiAmount,
        address indexed sender
    );

    event TokenIndexSet(address indexed token, uint64 indexed tokenIndex);
    event StrategistUpdated(address indexed oldStrategist, address indexed newStrategist);
    event ConfigUpdated(uint256 minSupplyAmount, uint256 cooldownBlocks);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    // ═══════════════════════════════════════════════════════════════════════════════
    // LENDING OPERATIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Supply tokens to HyperCore lending protocol
     * @param token ERC20 token address to supply
     * @param amount Amount to supply (in EVM wei, 18 decimals)
     * @dev Internally calls bridgeToCore() then sends lending action
     */
    function supplyToLending(address token, uint256 amount) external;

    /**
     * @notice Alias for supplyToLending for simpler interface
     */
    function supply(address token, uint256 amount) external;

    /**
     * @notice Withdraw tokens from HyperCore lending protocol
     * @param token ERC20 token address to withdraw
     * @param amount Amount to withdraw (in EVM wei, 18 decimals). Use 0 for max withdrawal.
     * @dev Internally sends lending action then calls bridgeToEvm()
     */
    function withdrawFromLending(address token, uint256 amount) external;

    /**
     * @notice Withdraw tokens from lending and send to recipient
     * @param token ERC20 token address to withdraw
     * @param amount Amount to withdraw
     * @param recipient Address to receive tokens
     */
    function withdraw(address token, uint256 amount, address recipient) external;

    // ═══════════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Check if an operation can be performed (cooldown passed)
     * @return True if cooldown has passed
     */
    function canOperate() external view returns (bool);

    /**
     * @notice Get the total amount supplied for a token
     * @param token Token address
     * @return Amount supplied (in EVM wei)
     */
    function getSuppliedAmount(address token) external view returns (uint256);

    /**
     * @notice Get token index for a token
     * @param token Token address
     * @return Token index on HyperCore
     */
    function getTokenIndex(address token) external view returns (uint64);

    /**
     * @notice Preview the encoded action that would be sent for a supply operation
     * @param token Token to supply
     * @param amount Amount to supply
     * @return Encoded action bytes
     */
    function previewSupplyAction(address token, uint256 amount) external view returns (bytes memory);

    /**
     * @notice Preview the encoded action that would be sent for a withdraw operation
     * @param token Token to withdraw
     * @param amount Amount to withdraw (0 for max)
     * @return Encoded action bytes
     */
    function previewWithdrawAction(address token, uint256 amount) external view returns (bytes memory);

    // ═══════════════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Set the HyperCore token index for an ERC20 token
     * @param token ERC20 token address
     * @param tokenIndex HyperCore token index
     */
    function setTokenIndex(address token, uint64 tokenIndex) external;

    /**
     * @notice Batch set token indices
     * @param tokens Array of token addresses
     * @param indices Array of token indices
     */
    function setTokenIndices(address[] calldata tokens, uint64[] calldata indices) external;

    /**
     * @notice Update the strategist address
     * @param _newStrategist New strategist address
     */
    function setStrategist(address _newStrategist) external;

    /**
     * @notice Update module configuration
     * @param _minSupplyAmount New minimum supply amount
     * @param _cooldownBlocks New cooldown blocks
     */
    function setConfig(uint256 _minSupplyAmount, uint256 _cooldownBlocks) external;

    /**
     * @notice Pause the module
     */
    function pause() external;

    /**
     * @notice Unpause the module
     */
    function unpause() external;

    /**
     * @notice Emergency rescue tokens stuck in the contract
     * @param token Token to rescue
     * @param to Recipient address
     * @param amount Amount to rescue
     */
    function rescueTokens(address token, address to, uint256 amount) external;
}
