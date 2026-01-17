// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {DynamicFeeModule} from "../../src/modules/DynamicFeeModule.sol";
import {MockSovereignPool} from "../mocks/MockSovereignPool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/**
 * @title DynamicFeeModuleTest
 * @notice Unit tests for the DynamicFeeModule
 * @dev Tests the imbalance-based fee formula from the whitepaper:
 *      fee = baseFee + sqrt(imbalance_ratio) * imbalanceMultiplier
 */
contract DynamicFeeModuleTest is Test {
    DynamicFeeModule public feeModule;
    MockSovereignPool public pool;
    MockERC20 public token0;
    MockERC20 public token1;

    address public poolManager = address(0x1);
    address public user = address(0x2);

    function setUp() public {
        // Deploy mock tokens
        token0 = new MockERC20("HYPE", "HYPE", 18);
        token1 = new MockERC20("USDC", "USDC", 6);

        // Deploy mock pool
        pool = new MockSovereignPool(address(token0), address(token1));

        // Deploy fee module
        feeModule = new DynamicFeeModule(address(pool), poolManager);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // BASIC TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_Constructor() public view {
        assertEq(address(feeModule.pool()), address(pool));
        assertEq(feeModule.poolManager(), poolManager);
        assertEq(feeModule.BASE_FEE_BPS(), 30);
        assertEq(feeModule.IMBALANCE_MULTIPLIER_BPS(), 10);
    }

    function test_BaseFeeWithBalancedReserves() public {
        // Set balanced reserves: 100 each
        pool.setReserves(100 ether, 100 ether);

        uint256 fee = feeModule.previewFee(100 ether, 100 ether);
        
        // With balanced reserves, should be close to base fee (30 bps)
        assertEq(fee, 30, "Balanced reserves should have base fee only");
    }

    function test_FeeIncreasesWithImbalance() public {
        // Test increasing imbalance
        uint256 balancedFee = feeModule.previewFee(100 ether, 100 ether);
        uint256 slightImbalance = feeModule.previewFee(100 ether, 120 ether);
        uint256 moderateImbalance = feeModule.previewFee(100 ether, 150 ether);
        uint256 severeImbalance = feeModule.previewFee(100 ether, 200 ether);

        // Fee should increase with imbalance
        assertGe(slightImbalance, balancedFee, "Slight imbalance should increase fee");
        assertGe(moderateImbalance, slightImbalance, "Moderate imbalance should increase fee more");
        assertGe(severeImbalance, moderateImbalance, "Severe imbalance should increase fee even more");
    }

    function test_FeeCalculation_Whitepaper_Example() public {
        // From whitepaper:
        // Reserves: 100 USDC, 150 HYPE
        // Imbalance ratio = |100-150| / (100+150) = 0.2
        // sqrt(0.2) ≈ 0.447
        // imbalanceFee = 0.447 * 0.1% = 0.0447%
        // Total fee = 0.3% + 0.0447% ≈ 0.345%

        pool.setReserves(100 ether, 150 ether);
        uint256 fee = feeModule.getCurrentFee();

        // Fee should be between 30 and 35 bps (0.3% to 0.35%)
        assertGe(fee, 30, "Fee should be at least base fee");
        assertLe(fee, 40, "Fee should not exceed expected range");
        
        emit log_named_uint("Calculated fee (bps)", fee);
    }

    function test_FeeCappedAtMaximum() public {
        // Extreme imbalance
        pool.setReserves(1 ether, 1000 ether);
        
        uint256 fee = feeModule.getCurrentFee();
        
        assertLe(fee, feeModule.MAX_FEE_BPS(), "Fee should not exceed max");
    }

    function test_ZeroReservesReturnBaseFee() public {
        pool.setReserves(0, 0);
        
        uint256 fee = feeModule.previewFee(0, 0);
        assertEq(fee, feeModule.BASE_FEE_BPS(), "Zero reserves should return base fee");
    }

    function test_OneZeroReserveReturnBaseFee() public {
        uint256 fee = feeModule.previewFee(100 ether, 0);
        assertEq(fee, feeModule.BASE_FEE_BPS(), "One zero reserve should return base fee");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // ADMIN TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_SetCustomBaseFee() public {
        vm.prank(poolManager);
        feeModule.setBaseFee(50);

        pool.setReserves(100 ether, 100 ether);
        uint256 fee = feeModule.getCurrentFee();
        
        assertEq(fee, 50, "Custom base fee should be applied");
    }

    function test_SetBaseFee_OnlyPoolManager() public {
        vm.prank(user);
        vm.expectRevert(DynamicFeeModule.DynamicFeeModule__OnlyPoolManager.selector);
        feeModule.setBaseFee(50);
    }

    function test_SetBaseFee_CannotExceedMax() public {
        vm.prank(poolManager);
        vm.expectRevert(DynamicFeeModule.DynamicFeeModule__FeeTooHigh.selector);
        feeModule.setBaseFee(600); // Max is 500
    }

    function test_ResetBaseFee() public {
        vm.prank(poolManager);
        feeModule.setBaseFee(50);

        vm.prank(poolManager);
        feeModule.resetBaseFee();

        pool.setReserves(100 ether, 100 ether);
        uint256 fee = feeModule.getCurrentFee();
        
        assertEq(fee, 30, "Base fee should reset to default");
    }

    function test_SetPoolManager() public {
        address newManager = address(0x999);
        
        vm.prank(poolManager);
        feeModule.setPoolManager(newManager);

        assertEq(feeModule.poolManager(), newManager);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTION TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_GetImbalanceRatio() public {
        // Set imbalanced reserves: 100, 150 → ratio = 50/250 = 0.2 = 20% = 0.2e18
        pool.setReserves(100 ether, 150 ether);
        
        uint256 ratio = feeModule.getImbalanceRatio();
        
        // Expected: 0.2 * 1e18 = 2e17
        assertEq(ratio, 0.2e18, "Imbalance ratio calculation incorrect");
    }

    function test_GetImbalanceRatio_Balanced() public {
        pool.setReserves(100 ether, 100 ether);
        
        uint256 ratio = feeModule.getImbalanceRatio();
        assertEq(ratio, 0, "Balanced pool should have 0 imbalance ratio");
    }

    function test_GetImbalanceRatio_Empty() public {
        pool.setReserves(0, 0);
        
        uint256 ratio = feeModule.getImbalanceRatio();
        assertEq(ratio, 0, "Empty pool should have 0 imbalance ratio");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // FUZZ TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function testFuzz_FeeAlwaysWithinBounds(uint256 reserve0, uint256 reserve1) public {
        // Bound to reasonable values
        reserve0 = bound(reserve0, 0, 1e30);
        reserve1 = bound(reserve1, 0, 1e30);

        uint256 fee = feeModule.previewFee(reserve0, reserve1);

        assertGe(fee, feeModule.BASE_FEE_BPS(), "Fee should be at least base fee");
        assertLe(fee, feeModule.MAX_FEE_BPS(), "Fee should not exceed max");
    }

    function testFuzz_FeeSymmetric(uint256 reserve0, uint256 reserve1) public {
        reserve0 = bound(reserve0, 1 ether, 1e24);
        reserve1 = bound(reserve1, 1 ether, 1e24);

        // Fee should be same regardless of which reserve is larger
        uint256 fee1 = feeModule.previewFee(reserve0, reserve1);
        uint256 fee2 = feeModule.previewFee(reserve1, reserve0);

        assertEq(fee1, fee2, "Fee should be symmetric");
    }
}
