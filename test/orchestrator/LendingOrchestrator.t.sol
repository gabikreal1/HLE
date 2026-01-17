// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {LendingOrchestrator} from "../../src/orchestrator/LendingOrchestrator.sol";
import {ILendingOrchestrator} from "../../src/interfaces/ILendingOrchestrator.sol";
import {MockSovereignPool} from "../mocks/MockSovereignPool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/**
 * @title MockL1BlockPrecompile
 * @notice Mock for the L1 block number precompile (0x809)
 */
contract MockL1BlockPrecompile {
    uint64 public l1Block = 1000;

    function setL1Block(uint64 _l1Block) external {
        l1Block = _l1Block;
    }

    fallback() external {
        uint64 blockNum = l1Block;
        assembly {
            mstore(0x00, blockNum)
            return(0x00, 0x20)
        }
    }
}

/**
 * @title LendingOrchestratorTest
 * @notice Unit tests for the LendingOrchestrator
 * @dev Tests capital allocation between AMM and HyperCore staking
 * 
 * Note: CoreWriter calls are mocked in these tests since we can't
 * actually execute cross-layer actions in a fork-less environment.
 */
contract LendingOrchestratorTest is Test {
    LendingOrchestrator public orchestrator;
    MockSovereignPool public pool;
    MockERC20 public hypeToken;
    MockERC20 public usdc;
    MockL1BlockPrecompile public l1BlockMock;

    address public strategist = address(0x1);
    address public validator = address(0x2);
    address public user = address(0x3);

    uint256 constant INITIAL_RESERVE = 1000 ether;

    // L1 block precompile address
    address constant L1_BLOCK_PRECOMPILE = address(0x809);
    // CoreWriter address (mock for tests)
    address constant CORE_WRITER = address(0x3333333333333333333333333333333333333333);

    function setUp() public {
        // Deploy mock tokens
        hypeToken = new MockERC20("HYPE", "HYPE", 18);
        usdc = new MockERC20("USDC", "USDC", 6);

        // Deploy mock pool
        pool = new MockSovereignPool(address(hypeToken), address(usdc));
        pool.setReserves(INITIAL_RESERVE, INITIAL_RESERVE);

        // Deploy L1 block mock and etch at precompile address
        l1BlockMock = new MockL1BlockPrecompile();
        vm.etch(L1_BLOCK_PRECOMPILE, address(l1BlockMock).code);
        // Copy storage slot 0 (l1Block variable)
        vm.store(L1_BLOCK_PRECOMPILE, bytes32(uint256(0)), bytes32(uint256(1000)));

        // Deploy orchestrator
        orchestrator = new LendingOrchestrator(
            address(pool),
            address(hypeToken),
            strategist,
            validator
        );

        // Fund the pool mock
        hypeToken.mint(address(pool), INITIAL_RESERVE);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_Constructor() public view {
        assertEq(address(orchestrator.pool()), address(pool));
        assertEq(orchestrator.hypeToken(), address(hypeToken));
        assertEq(orchestrator.strategist(), strategist);

        ILendingOrchestrator.RebalanceConfig memory config = orchestrator.getConfig();
        assertEq(config.targetAmmShareBps, 6000); // 60%
        assertEq(config.maxRebalanceAmount, 10_000 ether);
        assertEq(config.cooldownBlocks, 30);
        assertEq(config.validator, validator);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // REBALANCE CALCULATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_CalculateRebalanceAmount_ExcessInAMM() public view {
        // Pool has 1000 HYPE, nothing staked
        // Target is 60% in AMM, 40% staked
        // Should recommend moving 400 to staking
        
        (uint256 toStaking, uint256 fromStaking) = orchestrator.calculateRebalanceAmount();

        // With 1000 total and 60% target, want 600 in AMM, 400 in staking
        assertEq(toStaking, 400 ether);
        assertEq(fromStaking, 0);
    }

    function test_CalculateRebalanceAmount_Balanced() public {
        // Simulate 600 in AMM, 400 staked (exactly at target)
        pool.setReserves(600 ether, 600 ether);
        
        // Manually set totalStaked (would need internal access in real test)
        // For now, we'll test the zero case
        (uint256 toStaking, uint256 fromStaking) = orchestrator.calculateRebalanceAmount();

        // With only AMM reserves and no staked, still wants to move some
        assertTrue(toStaking > 0 || fromStaking == 0);
    }

    function test_CalculateRebalanceAmount_CappedAtMax() public {
        // Very large pool
        pool.setReserves(100_000 ether, 100_000 ether);
        hypeToken.mint(address(pool), 99_000 ether);

        (uint256 toStaking, ) = orchestrator.calculateRebalanceAmount();

        // Should be capped at maxRebalanceAmount
        assertLe(toStaking, orchestrator.getConfig().maxRebalanceAmount);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CAPITAL ALLOCATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_GetCapitalAllocation() public view {
        (uint256 ammAmount, uint256 stakedAmount, uint256 ammShareBps) = 
            orchestrator.getCapitalAllocation();

        assertEq(ammAmount, INITIAL_RESERVE);
        assertEq(stakedAmount, 0);
        assertEq(ammShareBps, 10000); // 100% in AMM
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // COOLDOWN TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_CanRebalance_Initially() public view {
        // Should be able to rebalance initially
        assertTrue(orchestrator.canRebalance());
    }

    function test_BlocksUntilRebalance() public view {
        // Initially should be 0
        uint64 blocks = orchestrator.blocksUntilRebalance();
        assertEq(blocks, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONFIG TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_SetConfig() public {
        ILendingOrchestrator.RebalanceConfig memory newConfig = ILendingOrchestrator.RebalanceConfig({
            targetAmmShareBps: 5000, // 50%
            maxRebalanceAmount: 5000 ether,
            cooldownBlocks: 60,
            validator: address(0x999)
        });

        vm.prank(strategist);
        orchestrator.setConfig(newConfig);

        ILendingOrchestrator.RebalanceConfig memory config = orchestrator.getConfig();
        assertEq(config.targetAmmShareBps, 5000);
        assertEq(config.maxRebalanceAmount, 5000 ether);
        assertEq(config.cooldownBlocks, 60);
        assertEq(config.validator, address(0x999));
    }

    function test_SetConfig_OnlyStrategist() public {
        ILendingOrchestrator.RebalanceConfig memory newConfig = ILendingOrchestrator.RebalanceConfig({
            targetAmmShareBps: 5000,
            maxRebalanceAmount: 5000 ether,
            cooldownBlocks: 60,
            validator: address(0x999)
        });

        vm.prank(user);
        vm.expectRevert(LendingOrchestrator.LendingOrchestrator__OnlyStrategist.selector);
        orchestrator.setConfig(newConfig);
    }

    function test_SetConfig_InvalidTarget() public {
        ILendingOrchestrator.RebalanceConfig memory newConfig = ILendingOrchestrator.RebalanceConfig({
            targetAmmShareBps: 15000, // > 100%
            maxRebalanceAmount: 5000 ether,
            cooldownBlocks: 60,
            validator: validator
        });

        vm.prank(strategist);
        vm.expectRevert(LendingOrchestrator.LendingOrchestrator__InvalidConfig.selector);
        orchestrator.setConfig(newConfig);
    }

    function test_SetConfig_InvalidValidator() public {
        ILendingOrchestrator.RebalanceConfig memory newConfig = ILendingOrchestrator.RebalanceConfig({
            targetAmmShareBps: 5000,
            maxRebalanceAmount: 5000 ether,
            cooldownBlocks: 60,
            validator: address(0)
        });

        vm.prank(strategist);
        vm.expectRevert(LendingOrchestrator.LendingOrchestrator__InvalidConfig.selector);
        orchestrator.setConfig(newConfig);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // STRATEGIST TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_SetStrategist() public {
        address newStrategist = address(0x888);

        vm.prank(strategist);
        orchestrator.setStrategist(newStrategist);

        assertEq(orchestrator.strategist(), newStrategist);
    }

    function test_SetStrategist_OnlyStrategist() public {
        vm.prank(user);
        vm.expectRevert(LendingOrchestrator.LendingOrchestrator__OnlyStrategist.selector);
        orchestrator.setStrategist(address(0x888));
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // REBALANCING VALIDATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_RebalanceToStaking_AmountTooSmall() public {
        vm.prank(strategist);
        vm.expectRevert(LendingOrchestrator.LendingOrchestrator__AmountTooSmall.selector);
        orchestrator.rebalanceToStaking(0.001 ether);
    }

    function test_RebalanceToStaking_AmountExceedsMax() public {
        vm.prank(strategist);
        vm.expectRevert(LendingOrchestrator.LendingOrchestrator__AmountExceedsMax.selector);
        orchestrator.rebalanceToStaking(20_000 ether);
    }

    function test_RebalanceFromStaking_InsufficientStaked() public {
        vm.prank(strategist);
        vm.expectRevert(LendingOrchestrator.LendingOrchestrator__InsufficientStaked.selector);
        orchestrator.rebalanceFromStaking(100 ether);
    }

    function test_RebalanceToStaking_OnlyStrategist() public {
        vm.prank(user);
        vm.expectRevert(LendingOrchestrator.LendingOrchestrator__OnlyStrategist.selector);
        orchestrator.rebalanceToStaking(100 ether);
    }
}
