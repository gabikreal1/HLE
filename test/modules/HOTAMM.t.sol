// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {HOTAMM} from "../../src/modules/HOTAMM.sol";
import {MockSovereignPool} from "../mocks/MockSovereignPool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ALMLiquidityQuoteInput, ALMLiquidityQuote} from "@valantis-core/ALM/structs/SovereignALMStructs.sol";

/**
 * @title HOTAMMTest
 * @notice Unit tests for the HOTAMM (Liquidity Module)
 * @dev Tests constant product AMM mechanics
 */
contract HOTAMMTest is Test {
    HOTAMM public alm;
    MockSovereignPool public pool;
    MockERC20 public token0;
    MockERC20 public token1;

    address public poolManager = address(0x1);
    address public lp1 = address(0x2);
    address public lp2 = address(0x3);
    address public trader = address(0x4);

    uint256 constant INITIAL_LIQUIDITY = 1000 ether;

    function setUp() public {
        // Deploy mock tokens
        token0 = new MockERC20("HYPE", "HYPE", 18);
        token1 = new MockERC20("USDC", "USDC", 18);

        // Deploy mock pool
        pool = new MockSovereignPool(address(token0), address(token1));

        // Deploy ALM
        alm = new HOTAMM(address(pool), poolManager);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_Constructor() public view {
        assertEq(address(alm.pool()), address(pool));
        assertEq(alm.poolManager(), poolManager);
        assertEq(alm.token0(), address(token0));
        assertEq(alm.token1(), address(token1));
        assertEq(alm.totalSupply(), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // LIQUIDITY TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_FirstDeposit() public {
        // Simulate first deposit callback from pool
        vm.prank(address(pool));
        alm.onDepositLiquidityCallback(
            100 ether,
            100 ether,
            abi.encode(lp1)
        );

        // Check LP tokens minted (sqrt(100 * 100) - MINIMUM_LIQUIDITY = 100 - 1000)
        uint256 expectedLiquidity = 100 ether - alm.MINIMUM_LIQUIDITY();
        assertEq(alm.balanceOf(lp1), expectedLiquidity);
        assertEq(alm.totalSupply(), expectedLiquidity + alm.MINIMUM_LIQUIDITY());
        
        // Check reserves
        (uint256 r0, uint256 r1) = alm.getReserves();
        assertEq(r0, 100 ether);
        assertEq(r1, 100 ether);
    }

    function test_SubsequentDeposit() public {
        // First deposit
        vm.prank(address(pool));
        alm.onDepositLiquidityCallback(100 ether, 100 ether, abi.encode(lp1));

        // Second deposit (proportional)
        vm.prank(address(pool));
        alm.onDepositLiquidityCallback(50 ether, 50 ether, abi.encode(lp2));

        // lp2 should get proportional LP tokens
        // 50 * totalSupply / 100 = 50% of current supply
        uint256 lp2Balance = alm.balanceOf(lp2);
        assertTrue(lp2Balance > 0, "LP2 should have tokens");
    }

    function test_OnlyPoolCanDeposit() public {
        vm.prank(lp1);
        vm.expectRevert(HOTAMM.HOTAMM__OnlyPool.selector);
        alm.onDepositLiquidityCallback(100 ether, 100 ether, abi.encode(lp1));
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // SWAP TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_GetLiquidityQuote_ZeroToOne() public {
        // Setup: Add liquidity
        vm.prank(address(pool));
        alm.onDepositLiquidityCallback(100 ether, 100 ether, abi.encode(lp1));

        // Create swap input
        ALMLiquidityQuoteInput memory input = ALMLiquidityQuoteInput({
            isZeroToOne: true,
            amountInMinusFee: 10 ether,
            feeInBips: 30,
            sender: trader,
            recipient: trader,
            tokenOutSwap: address(token1)
        });

        // Get quote
        vm.prank(address(pool));
        ALMLiquidityQuote memory quote = alm.getLiquidityQuote(input, "", "");

        // Expected: 100 * 10 / (100 + 10) ≈ 9.09 ether
        // Constant product: (100 + 10) * (100 - amountOut) = 100 * 100
        // amountOut = 100 - 10000/110 = 100 - 90.909 = 9.0909
        assertGt(quote.amountOut, 9 ether);
        assertLt(quote.amountOut, 10 ether);
        assertEq(quote.amountInFilled, 10 ether);
        assertTrue(quote.isCallbackOnSwap);
    }

    function test_GetLiquidityQuote_OneToZero() public {
        // Setup: Add liquidity
        vm.prank(address(pool));
        alm.onDepositLiquidityCallback(100 ether, 100 ether, abi.encode(lp1));

        // Create swap input (reverse direction)
        ALMLiquidityQuoteInput memory input = ALMLiquidityQuoteInput({
            isZeroToOne: false,
            amountInMinusFee: 10 ether,
            feeInBips: 30,
            sender: trader,
            recipient: trader,
            tokenOutSwap: address(token0)
        });

        // Get quote
        vm.prank(address(pool));
        ALMLiquidityQuote memory quote = alm.getLiquidityQuote(input, "", "");

        assertGt(quote.amountOut, 9 ether);
        assertLt(quote.amountOut, 10 ether);
    }

    function test_SwapCallback_UpdatesReserves() public {
        // Setup
        vm.prank(address(pool));
        alm.onDepositLiquidityCallback(100 ether, 100 ether, abi.encode(lp1));

        // Simulate swap callback
        vm.prank(address(pool));
        alm.onSwapCallback(true, 10 ether, 9 ether);

        // Check reserves updated
        (uint256 r0, uint256 r1) = alm.getReserves();
        assertEq(r0, 110 ether); // +10 in
        assertEq(r1, 91 ether);  // -9 out
    }

    function test_OnlyPoolCanSwap() public {
        ALMLiquidityQuoteInput memory input = ALMLiquidityQuoteInput({
            isZeroToOne: true,
            amountInMinusFee: 10 ether,
            feeInBips: 30,
            sender: trader,
            recipient: trader,
            tokenOutSwap: address(token1)
        });

        vm.prank(trader);
        vm.expectRevert(HOTAMM.HOTAMM__OnlyPool.selector);
        alm.getLiquidityQuote(input, "", "");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTION TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_GetK() public {
        vm.prank(address(pool));
        alm.onDepositLiquidityCallback(100 ether, 200 ether, abi.encode(lp1));

        uint256 k = alm.getK();
        assertEq(k, 100 ether * 200 ether);
    }

    function test_PreviewSwap() public {
        vm.prank(address(pool));
        alm.onDepositLiquidityCallback(100 ether, 100 ether, abi.encode(lp1));

        uint256 amountOut = alm.previewSwap(10 ether, true);
        
        // Same calculation as quote
        assertGt(amountOut, 9 ether);
        assertLt(amountOut, 10 ether);
    }

    function test_GetSpotPrice() public {
        vm.prank(address(pool));
        alm.onDepositLiquidityCallback(100 ether, 200 ether, abi.encode(lp1));

        uint256 priceX96 = alm.getSpotPrice();
        
        // price = reserve1/reserve0 = 200/100 = 2 in Q96
        uint256 expectedPrice = (200 ether * (2**96)) / 100 ether;
        assertEq(priceX96, expectedPrice);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // FUZZ TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function testFuzz_ConstantProductHolds(uint256 amountIn) public {
        // Setup with large reserves
        vm.prank(address(pool));
        alm.onDepositLiquidityCallback(1000 ether, 1000 ether, abi.encode(lp1));

        // Bound input to reasonable range
        amountIn = bound(amountIn, 0.001 ether, 100 ether);

        uint256 kBefore = alm.getK();
        
        // Get quote
        ALMLiquidityQuoteInput memory input = ALMLiquidityQuoteInput({
            isZeroToOne: true,
            amountInMinusFee: amountIn,
            feeInBips: 0,
            sender: trader,
            recipient: trader,
            tokenOutSwap: address(token1)
        });

        vm.prank(address(pool));
        ALMLiquidityQuote memory quote = alm.getLiquidityQuote(input, "", "");

        // Simulate swap
        vm.prank(address(pool));
        alm.onSwapCallback(true, amountIn, quote.amountOut);

        uint256 kAfter = alm.getK();

        // K should stay constant or increase slightly (due to rounding)
        assertGe(kAfter, kBefore, "K should not decrease");
    }

    function testFuzz_NoArbitrage(uint256 reserve0, uint256 reserve1, uint256 amountIn) public {
        // Bound reserves
        reserve0 = bound(reserve0, 100 ether, 1e24);
        reserve1 = bound(reserve1, 100 ether, 1e24);
        amountIn = bound(amountIn, 0.01 ether, reserve0 / 10);

        vm.prank(address(pool));
        alm.onDepositLiquidityCallback(reserve0, reserve1, abi.encode(lp1));

        // Quote should never return more than input (after accounting for price)
        uint256 amountOut = alm.previewSwap(amountIn, true);
        
        // amountOut should be less than what constant price would give
        // This ensures no arbitrage opportunity
        assertTrue(amountOut < amountIn * reserve1 / reserve0 || reserve0 >= reserve1);
    }
}
