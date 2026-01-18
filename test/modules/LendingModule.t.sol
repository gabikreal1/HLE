// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {LendingModule, ICoreWriter} from "../../src/modules/LendingModule.sol";
import {TestableLendingModule} from "../mocks/TestableLendingModule.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockSovereignPool} from "../mocks/MockSovereignPool.sol";

/**
 * @title MockCoreWriter
 * @notice Mock CoreWriter for testing lending module
 */
contract MockCoreWriter is ICoreWriter {
    bytes public lastAction;
    address public lastSender;
    uint256 public callCount;

    event RawAction(address indexed sender, bytes data);

    function sendRawAction(bytes calldata data) external override {
        lastAction = data;
        lastSender = msg.sender;
        callCount++;
        emit RawAction(msg.sender, data);
    }

    function getLastActionHeader() external view returns (bytes4) {
        if (lastAction.length < 4) return bytes4(0);
        return bytes4(lastAction[0]) | (bytes4(lastAction[1]) >> 8) | (bytes4(lastAction[2]) >> 16) | (bytes4(lastAction[3]) >> 24);
    }

    function decodeLastAction() external view returns (
        uint8 version,
        uint8 actionId,
        uint8 operation,
        uint64 tokenIndex,
        uint64 weiAmount
    ) {
        require(lastAction.length >= 4, "No action recorded");
        version = uint8(lastAction[0]);
        actionId = uint8(lastAction[3]);
        
        if (lastAction.length > 4) {
            // Decode the parameters (skip 4 byte header)
            bytes memory params = new bytes(lastAction.length - 4);
            for (uint256 i = 0; i < params.length; i++) {
                params[i] = lastAction[4 + i];
            }
            (operation, tokenIndex, weiAmount) = abi.decode(params, (uint8, uint64, uint64));
        }
    }

    function reset() external {
        delete lastAction;
        lastSender = address(0);
        callCount = 0;
    }
}

/**
 * @title LendingModuleTest
 * @notice Unit tests for the LendingModule
 * @dev Tests supply/withdraw operations via CoreWriter using TestableLendingModule
 */
contract LendingModuleTest is Test {
    TestableLendingModule public module;
    MockCoreWriter public coreWriter;
    MockSovereignPool public mockPool;
    MockERC20 public hypeToken;
    MockERC20 public usdcToken;

    address public poolManager = address(0x1);
    address public strategist = address(0x2);
    address public user = address(0x3);

    uint64 constant HYPE_TOKEN_INDEX = 1105;
    uint64 constant USDC_TOKEN_INDEX = 0;
    uint256 constant MIN_SUPPLY = 0.01 ether;
    uint256 constant COOLDOWN = 5;

    function setUp() public {
        // Deploy mock CoreWriter at the expected address
        coreWriter = new MockCoreWriter();
        
        // We need to deploy at the exact address 0x3333...3333
        // For testing, we'll etch the mock code to that address
        vm.etch(
            0x3333333333333333333333333333333333333333,
            address(coreWriter).code
        );
        
        // Deploy mock tokens
        hypeToken = new MockERC20("HYPE", "HYPE", 18);
        usdcToken = new MockERC20("USDC", "USDC", 18);

        // Deploy mock pool and set pool manager
        mockPool = new MockSovereignPool(address(hypeToken), address(usdcToken));
        mockPool.setPoolManager(poolManager);

        // Deploy testable module (skips hyper-evm-lib dependencies)
        module = new TestableLendingModule(
            address(mockPool),
            strategist,
            MIN_SUPPLY,
            COOLDOWN
        );

        // Set token indices
        vm.startPrank(poolManager);
        module.setTokenIndex(address(hypeToken), HYPE_TOKEN_INDEX);
        module.setTokenIndex(address(usdcToken), USDC_TOKEN_INDEX);
        vm.stopPrank();

        // Mint tokens to module for testing
        hypeToken.mint(address(module), 1000 ether);
        usdcToken.mint(address(module), 1000 ether);

        // Advance block number past initial cooldown (tests start at block 1)
        vm.roll(COOLDOWN + 10);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_Constructor() public view {
        assertEq(address(module.pool()), address(mockPool));
        assertEq(module.strategist(), strategist);
        assertEq(module.minSupplyAmount(), MIN_SUPPLY);
        assertEq(module.cooldownBlocks(), COOLDOWN);
        assertEq(module.paused(), false);
    }

    function test_Constructor_RevertZeroAddress() public {
        vm.expectRevert(LendingModule.LendingModule__ZeroAddress.selector);
        new LendingModule(address(0), strategist, MIN_SUPPLY, COOLDOWN);

        vm.expectRevert(LendingModule.LendingModule__ZeroAddress.selector);
        new LendingModule(address(mockPool), address(0), MIN_SUPPLY, COOLDOWN);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // SUPPLY TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_SupplyToLending() public {
        uint256 supplyAmount = 100 ether;
        
        vm.prank(strategist);
        module.supplyToLending(address(hypeToken), supplyAmount);

        // Check state updates
        assertEq(module.getSuppliedAmount(address(hypeToken)), supplyAmount);
        assertEq(module.lastOperationBlock(), block.number);

        // Verify the action was encoded correctly
        bytes memory expectedAction = module.previewSupplyAction(address(hypeToken), supplyAmount);
        
        // Decode and verify the action parameters
        MockCoreWriter writer = MockCoreWriter(0x3333333333333333333333333333333333333333);
        (
            uint8 version,
            uint8 actionId,
            uint8 operation,
            uint64 tokenIndex,
            uint64 weiAmount
        ) = writer.decodeLastAction();
        
        assertEq(version, 0x01);
        assertEq(actionId, 15); // LENDING_ACTION_ID
        assertEq(operation, 0); // OP_SUPPLY
        assertEq(tokenIndex, HYPE_TOKEN_INDEX);
        assertEq(weiAmount, uint64(supplyAmount / 1e10)); // Converted to 8 decimals
    }

    function test_SupplyToLending_RevertNotStrategist() public {
        vm.prank(user);
        vm.expectRevert(LendingModule.LendingModule__OnlyStrategist.selector);
        module.supplyToLending(address(hypeToken), 100 ether);
    }

    function test_SupplyToLending_RevertAmountTooSmall() public {
        vm.prank(strategist);
        vm.expectRevert(LendingModule.LendingModule__AmountTooSmall.selector);
        module.supplyToLending(address(hypeToken), 0.001 ether); // Less than MIN_SUPPLY
    }

    function test_SupplyToLending_RevertCooldown() public {
        // First supply
        vm.prank(strategist);
        module.supplyToLending(address(hypeToken), 100 ether);

        // Try immediate second supply
        vm.prank(strategist);
        vm.expectRevert(LendingModule.LendingModule__CooldownNotPassed.selector);
        module.supplyToLending(address(hypeToken), 100 ether);

        // Advance blocks past cooldown
        vm.roll(block.number + COOLDOWN + 1);

        // Now it should work
        vm.prank(strategist);
        module.supplyToLending(address(hypeToken), 100 ether);
    }

    function test_SupplyToLending_RevertTokenNotSupported() public {
        MockERC20 unknownToken = new MockERC20("UNKNOWN", "UNK", 18);
        
        vm.prank(strategist);
        vm.expectRevert(LendingModule.LendingModule__TokenNotSupported.selector);
        module.supplyToLending(address(unknownToken), 100 ether);
    }

    function test_SupplyToLending_RevertWhenPaused() public {
        vm.prank(poolManager);
        module.pause();

        vm.prank(strategist);
        vm.expectRevert(LendingModule.LendingModule__Paused.selector);
        module.supplyToLending(address(hypeToken), 100 ether);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // WITHDRAW TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_WithdrawFromLending() public {
        // First supply
        vm.prank(strategist);
        module.supplyToLending(address(hypeToken), 100 ether);

        // Advance past cooldown
        vm.roll(block.number + COOLDOWN + 1);

        // Withdraw
        vm.prank(strategist);
        module.withdrawFromLending(address(hypeToken), 50 ether);

        // Check state
        assertEq(module.getSuppliedAmount(address(hypeToken)), 50 ether);

        // Verify action
        MockCoreWriter writer = MockCoreWriter(0x3333333333333333333333333333333333333333);
        (,, uint8 operation,,) = writer.decodeLastAction();
        assertEq(operation, 1); // OP_WITHDRAW
    }

    function test_WithdrawFromLending_MaxWithdraw() public {
        // First supply
        vm.prank(strategist);
        module.supplyToLending(address(hypeToken), 100 ether);

        // Advance past cooldown
        vm.roll(block.number + COOLDOWN + 1);

        // Withdraw with amount=0 (max)
        vm.prank(strategist);
        module.withdrawFromLending(address(hypeToken), 0);

        // Check state - should be cleared
        assertEq(module.getSuppliedAmount(address(hypeToken)), 0);

        // Verify weiAmount is 0 (max withdrawal)
        MockCoreWriter writer = MockCoreWriter(0x3333333333333333333333333333333333333333);
        (,,,, uint64 weiAmount) = writer.decodeLastAction();
        assertEq(weiAmount, 0);
    }

    function test_WithdrawFromLending_RevertInsufficientSupplied() public {
        // Try to withdraw without having supplied
        vm.prank(strategist);
        vm.expectRevert(LendingModule.LendingModule__InsufficientSupplied.selector);
        module.withdrawFromLending(address(hypeToken), 100 ether);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTION TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_CanOperate() public {
        assertTrue(module.canOperate());

        vm.prank(strategist);
        module.supplyToLending(address(hypeToken), 100 ether);

        assertFalse(module.canOperate());

        vm.roll(block.number + COOLDOWN + 1);
        assertTrue(module.canOperate());
    }

    function test_PreviewSupplyAction() public view {
        bytes memory action = module.previewSupplyAction(address(hypeToken), 100 ether);
        
        // Should have 4 byte header + encoded params
        assertTrue(action.length > 4);
        
        // Check header
        assertEq(uint8(action[0]), 0x01); // version
        assertEq(uint8(action[3]), 15);   // action ID
    }

    function test_PreviewWithdrawAction() public view {
        bytes memory action = module.previewWithdrawAction(address(hypeToken), 100 ether);
        
        assertTrue(action.length > 4);
        assertEq(uint8(action[0]), 0x01); // version
        assertEq(uint8(action[3]), 15);   // action ID
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTION TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_SetTokenIndex() public {
        MockERC20 newToken = new MockERC20("NEW", "NEW", 18);
        
        vm.prank(poolManager);
        module.setTokenIndex(address(newToken), 999);

        assertEq(module.getTokenIndex(address(newToken)), 999);
    }

    function test_SetTokenIndices_Batch() public {
        MockERC20 token1 = new MockERC20("T1", "T1", 18);
        MockERC20 token2 = new MockERC20("T2", "T2", 18);
        
        address[] memory tokens = new address[](2);
        tokens[0] = address(token1);
        tokens[1] = address(token2);
        
        uint64[] memory indices = new uint64[](2);
        indices[0] = 100;
        indices[1] = 200;
        
        vm.prank(poolManager);
        module.setTokenIndices(tokens, indices);

        assertEq(module.getTokenIndex(address(token1)), 100);
        assertEq(module.getTokenIndex(address(token2)), 200);
    }

    function test_SetStrategist() public {
        address newStrategist = address(0x999);
        
        vm.prank(poolManager);
        module.setStrategist(newStrategist);

        assertEq(module.strategist(), newStrategist);
    }

    function test_SetStrategist_RevertZeroAddress() public {
        vm.prank(poolManager);
        vm.expectRevert(LendingModule.LendingModule__ZeroAddress.selector);
        module.setStrategist(address(0));
    }

    function test_SetConfig() public {
        uint256 newMinSupply = 1 ether;
        uint256 newCooldown = 100;
        
        vm.prank(poolManager);
        module.setConfig(newMinSupply, newCooldown);

        assertEq(module.minSupplyAmount(), newMinSupply);
        assertEq(module.cooldownBlocks(), newCooldown);
    }

    function test_PauseUnpause() public {
        assertFalse(module.paused());
        
        vm.prank(poolManager);
        module.pause();
        assertTrue(module.paused());
        
        vm.prank(poolManager);
        module.unpause();
        assertFalse(module.paused());
    }

    function test_RescueTokens() public {
        address recipient = address(0x777);
        uint256 amount = 100 ether;
        
        vm.prank(poolManager);
        module.rescueTokens(address(hypeToken), recipient, amount);

        assertEq(hypeToken.balanceOf(recipient), amount);
    }

    function test_RescueTokens_RevertZeroAddress() public {
        vm.prank(poolManager);
        vm.expectRevert(LendingModule.LendingModule__ZeroAddress.selector);
        module.rescueTokens(address(hypeToken), address(0), 100 ether);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // ACCESS CONTROL TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_OnlyPoolManager_Functions() public {
        vm.startPrank(user);
        
        vm.expectRevert(LendingModule.LendingModule__OnlyPoolManager.selector);
        module.setTokenIndex(address(hypeToken), 100);
        
        vm.expectRevert(LendingModule.LendingModule__OnlyPoolManager.selector);
        module.setStrategist(user);
        
        vm.expectRevert(LendingModule.LendingModule__OnlyPoolManager.selector);
        module.setConfig(1 ether, 100);
        
        vm.expectRevert(LendingModule.LendingModule__OnlyPoolManager.selector);
        module.pause();
        
        vm.expectRevert(LendingModule.LendingModule__OnlyPoolManager.selector);
        module.rescueTokens(address(hypeToken), user, 100 ether);
        
        vm.stopPrank();
    }

    function test_PoolManagerCanActAsStrategist() public {
        // Pool manager should also be able to call strategist functions
        vm.prank(poolManager);
        module.supplyToLending(address(hypeToken), 100 ether);

        assertEq(module.getSuppliedAmount(address(hypeToken)), 100 ether);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // ENCODING VERIFICATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_ActionEncoding_Supply() public {
        uint256 amount = 100 ether;
        uint64 expectedWei = uint64(amount / 1e10); // Convert to 8 decimals
        
        vm.prank(strategist);
        module.supplyToLending(address(hypeToken), amount);

        MockCoreWriter writer = MockCoreWriter(0x3333333333333333333333333333333333333333);
        (
            uint8 version,
            uint8 actionId,
            uint8 operation,
            uint64 tokenIndex,
            uint64 weiAmount
        ) = writer.decodeLastAction();

        assertEq(version, 0x01, "Version should be 0x01");
        assertEq(actionId, 15, "Action ID should be 15");
        assertEq(operation, 0, "Operation should be 0 (Supply)");
        assertEq(tokenIndex, HYPE_TOKEN_INDEX, "Token index mismatch");
        assertEq(weiAmount, expectedWei, "Wei amount mismatch");
    }

    function test_ActionEncoding_Withdraw() public {
        // First supply
        vm.prank(strategist);
        module.supplyToLending(address(hypeToken), 100 ether);

        vm.roll(block.number + COOLDOWN + 1);

        uint256 withdrawAmount = 50 ether;
        uint64 expectedWei = uint64(withdrawAmount / 1e10);

        vm.prank(strategist);
        module.withdrawFromLending(address(hypeToken), withdrawAmount);

        MockCoreWriter writer = MockCoreWriter(0x3333333333333333333333333333333333333333);
        (
            uint8 version,
            uint8 actionId,
            uint8 operation,
            uint64 tokenIndex,
            uint64 weiAmount
        ) = writer.decodeLastAction();

        assertEq(version, 0x01, "Version should be 0x01");
        assertEq(actionId, 15, "Action ID should be 15");
        assertEq(operation, 1, "Operation should be 1 (Withdraw)");
        assertEq(tokenIndex, HYPE_TOKEN_INDEX, "Token index mismatch");
        assertEq(weiAmount, expectedWei, "Wei amount mismatch");
    }

    function test_ActionEncoding_MaxWithdraw() public {
        // First supply
        vm.prank(strategist);
        module.supplyToLending(address(hypeToken), 100 ether);

        vm.roll(block.number + COOLDOWN + 1);

        // Max withdraw (amount = 0)
        vm.prank(strategist);
        module.withdrawFromLending(address(hypeToken), 0);

        MockCoreWriter writer = MockCoreWriter(0x3333333333333333333333333333333333333333);
        (,,,, uint64 weiAmount) = writer.decodeLastAction();

        assertEq(weiAmount, 0, "Wei amount should be 0 for max withdrawal");
    }
}
