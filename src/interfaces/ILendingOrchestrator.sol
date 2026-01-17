// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ILendingOrchestrator
 * @notice Interface for lending/staking orchestration via CoreWriter
 */
interface ILendingOrchestrator {
    struct RebalanceConfig {
        uint256 targetAmmShareBps;   // Target % of capital in AMM (e.g., 6000 = 60%)
        uint256 maxRebalanceAmount;  // Max amount to rebalance per call
        uint256 cooldownBlocks;      // Minimum blocks between rebalances
        address validator;           // Validator for staking delegation
    }

    event RebalanceToStaking(uint256 amount, address validator);
    event RebalanceFromStaking(uint256 amount);
    event ConfigUpdated(RebalanceConfig config);
    event StrategistUpdated(address indexed oldStrategist, address indexed newStrategist);

    /// @notice Rebalance excess AMM reserves to HyperCore staking
    /// @param amount Amount to move to staking
    function rebalanceToStaking(uint256 amount) external;

    /// @notice Withdraw from staking back to AMM
    /// @param amount Amount to withdraw from staking
    function rebalanceFromStaking(uint256 amount) external;

    /// @notice Calculate how much should be rebalanced based on current state
    /// @return toStaking Amount that should be moved to staking (0 if none)
    /// @return fromStaking Amount that should be withdrawn from staking (0 if none)
    function calculateRebalanceAmount() external view returns (uint256 toStaking, uint256 fromStaking);

    /// @notice Update rebalancing configuration
    /// @param config New configuration
    function setConfig(RebalanceConfig calldata config) external;

    /// @notice Get current configuration
    function getConfig() external view returns (RebalanceConfig memory);

    /// @notice Check if rebalancing is allowed (cooldown passed)
    function canRebalance() external view returns (bool);
}
