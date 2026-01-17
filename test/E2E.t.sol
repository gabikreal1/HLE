// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {HOTAMM} from "../src/modules/HOTAMM.sol";
import {DynamicFeeModule} from "../src/modules/DynamicFeeModule.sol";
import {QuoteValidator} from "../src/quote/QuoteValidator.sol";
import {IQuoteValidator} from "../src/interfaces/IQuoteValidator.sol";
import {IOracleModule} from "../src/interfaces/IOracleModule.sol";
import {MockSovereignPool} from "./mocks/MockSovereignPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @title MockOracleModuleE2E
 */
contract MockOracleModuleE2E is IOracleModule {
    uint256 public currentPrice;

    constructor(uint256 _price) {
        currentPrice = _price;
    }

    function setPrice(uint256 _price) external {
        currentPrice = _price;
    }

    function getCurrentPrice(address, address) external view override returns (uint256) {
        return currentPrice;
    }

    function snapshotPrice(address, address) external view override returns (OracleSnapshot memory) {
        return OracleSnapshot({
            priceX96: currentPrice,
            l1BlockNumber: 1000,
            timestamp: block.timestamp
        });
    }

    function getLatestSnapshot(address, address) external view override returns (OracleSnapshot memory) {
        return OracleSnapshot({
            priceX96: currentPrice,
            l1BlockNumber: 1000,
            timestamp: block.timestamp
        });
    }

    function isPriceValid(address, address, uint256 priceX96, uint256 maxDeviationBps) 
        external view override returns (bool) 
    {
        uint256 deviation;
        if (priceX96 > currentPrice) {
            deviation = ((priceX96 - currentPrice) * 10000) / currentPrice;
        } else {
            deviation = ((currentPrice - priceX96) * 10000) / currentPrice;
        }
        return deviation <= maxDeviationBps;
    }
}

/**
 * @title E2ETest
 * @notice End-to-end integration tests for the HOT AMM system
 * @dev Tests the complete flow: quote → validate → swap → fee calculation
 */
contract E2ETest is Test {
    // Contracts
    HOTAMM public alm;
    DynamicFeeModule public feeModule;
    QuoteValidator public quoteValidator;
    MockOracleModuleE2E public oracle;
    MockSovereignPool public pool;
    
    // Tokens
    MockERC20 public hype;
    MockERC20 public usdc;

    // Addresses
    address public poolManager = address(0x1);
    address public strategist = address(0x2);
    address public lp = address(0x3);
    address public trader = address(0x4);

    // Constants
    uint256 constant Q96 = 2**96;
    uint256 constant INITIAL_PRICE = 2500 * Q96 / 1e8; // $2500

    function setUp() public {
        // Deploy tokens
        hype = new MockERC20("HYPE", "HYPE", 18);
        usdc = new MockERC20("USDC", "USDC", 6);

        // Deploy pool
        pool = new MockSovereignPool(address(hype), address(usdc));

        // Deploy modules
        alm = new HOTAMM(address(pool), poolManager);
        feeModule = new DynamicFeeModule(address(pool), poolManager);
        oracle = new MockOracleModuleE2E(INITIAL_PRICE);
        quoteValidator = new QuoteValidator(address(pool), address(oracle), strategist);

        // Setup pool
        pool.setALM(address(alm));
        pool.setSwapFeeModule(address(feeModule));

        // Fund accounts
        hype.mint(lp, 10_000 ether);
        usdc.mint(lp, 10_000_000e6);
        hype.mint(trader, 1_000 ether);
        usdc.mint(trader, 1_000_000e6);

        // Approve
        vm.prank(lp);
        hype.approve(address(pool), type(uint256).max);
        vm.prank(lp);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(trader);
        hype.approve(address(quoteValidator), type(uint256).max);
        vm.prank(trader);
        usdc.approve(address(quoteValidator), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // E2E FLOW TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_E2E_AddLiquidity_Swap_RemoveLiquidity() public {
        // 1. Add initial liquidity
        vm.prank(address(pool));
        alm.onDepositLiquidityCallback(1000 ether, 1000 ether, abi.encode(lp));

        // Verify liquidity added
        (uint256 r0, uint256 r1) = alm.getReserves();
        assertEq(r0, 1000 ether);
        assertEq(r1, 1000 ether);
        assertTrue(alm.balanceOf(lp) > 0);

        // 2. Execute swap via pool callback
        vm.prank(address(pool));
        alm.onSwapCallback(true, 100 ether, 90 ether);

        // Verify reserves changed
        (r0, r1) = alm.getReserves();
        assertEq(r0, 1100 ether); // +100 in
        assertEq(r1, 910 ether);  // -90 out

        // 3. Verify fee increased due to imbalance
        pool.setReserves(r0, r1);
        uint256 fee = feeModule.getCurrentFee();
        assertGt(fee, 30, "Fee should increase after imbalance");

        // 4. LP can withdraw
        uint256 lpBalance = alm.balanceOf(lp);
        vm.prank(lp);
        alm.withdrawLiquidity(lpBalance / 2, lp);

        assertEq(alm.balanceOf(lp), lpBalance / 2, "LP balance should decrease");
    }

    function test_E2E_QuoteValidation_Flow() public {
        // Setup pool with liquidity
        pool.setReserves(1000 ether, 1000 ether);
        vm.prank(address(pool));
        alm.onDepositLiquidityCallback(1000 ether, 1000 ether, abi.encode(lp));

        // Create a valid quote
        IQuoteValidator.Quote memory quote = IQuoteValidator.Quote({
            tokenIn: address(hype),
            tokenOut: address(usdc),
            amountIn: 10 ether,
            amountOutMin: 9 ether,
            executionPriceX96: INITIAL_PRICE,
            oracleSnapshotPriceX96: INITIAL_PRICE,
            oracleL1Block: 1000,
            expirationBlock: block.number + 100,
            intendedUser: trader,
            maxDeviationBps: 100,
            quoteId: keccak256("test_quote_1")
        });

        // Validate quote
        vm.prank(trader);
        (bool valid, string memory reason) = quoteValidator.validateQuote(quote);
        assertTrue(valid, string(abi.encodePacked("Quote should be valid: ", reason)));

        // Execute quote
        vm.prank(trader);
        uint256 amountOut = quoteValidator.executeQuote(quote);
        assertGe(amountOut, quote.amountOutMin);
    }

    function test_E2E_OracleProtection() public {
        // Setup
        pool.setReserves(1000 ether, 1000 ether);

        // Create quote at current price
        IQuoteValidator.Quote memory quote = IQuoteValidator.Quote({
            tokenIn: address(hype),
            tokenOut: address(usdc),
            amountIn: 10 ether,
            amountOutMin: 9 ether,
            executionPriceX96: INITIAL_PRICE,
            oracleSnapshotPriceX96: INITIAL_PRICE,
            oracleL1Block: 1000,
            expirationBlock: block.number + 100,
            intendedUser: trader,
            maxDeviationBps: 100, // 1%
            quoteId: keccak256("test_quote_2")
        });

        // Oracle drifts by 5%
        oracle.setPrice(INITIAL_PRICE * 105 / 100);

        // Quote should now be invalid
        vm.prank(trader);
        (bool valid, string memory reason) = quoteValidator.validateQuote(quote);
        assertFalse(valid, "Quote should be invalid after oracle drift");
        assertEq(reason, "Oracle drifted");
    }

    function test_E2E_DynamicFeeAdjustment() public {
        // Start with balanced pool
        pool.setReserves(1000 ether, 1000 ether);
        uint256 balancedFee = feeModule.getCurrentFee();
        assertEq(balancedFee, 30, "Balanced pool should have base fee");

        // After several swaps, pool becomes imbalanced
        pool.setReserves(800 ether, 1200 ether);
        uint256 imbalancedFee = feeModule.getCurrentFee();
        assertGt(imbalancedFee, balancedFee, "Imbalanced pool should have higher fee");

        // Severe imbalance
        pool.setReserves(500 ether, 1500 ether);
        uint256 severeFee = feeModule.getCurrentFee();
        assertGt(severeFee, imbalancedFee, "Severe imbalance should have even higher fee");

        emit log_named_uint("Balanced fee (bps)", balancedFee);
        emit log_named_uint("Imbalanced fee (bps)", imbalancedFee);
        emit log_named_uint("Severe fee (bps)", severeFee);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // SCENARIO TESTS FROM WHITEPAPER
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_Scenario_HighVolatility() public {
        // High volatility: fee increases, protects LPs
        pool.setReserves(1000 ether, 1000 ether);
        
        // Simulate rapid swaps in one direction
        vm.prank(address(pool));
        alm.onDepositLiquidityCallback(1000 ether, 1000 ether, abi.encode(lp));

        // Multiple swaps increasing imbalance
        for (uint i = 0; i < 5; i++) {
            vm.prank(address(pool));
            alm.onSwapCallback(true, 50 ether, 45 ether);
        }

        (uint256 r0, uint256 r1) = alm.getReserves();
        pool.setReserves(r0, r1);

        uint256 fee = feeModule.getCurrentFee();
        assertGt(fee, 30, "Fee should increase during high activity");
    }

    function test_Scenario_ArbitrageRebalances() public {
        // Start imbalanced
        pool.setReserves(600 ether, 1400 ether);
        uint256 imbalancedFee = feeModule.getCurrentFee();

        // Arbitrage trades rebalance pool
        pool.setReserves(900 ether, 1100 ether);
        uint256 partialRebalanceFee = feeModule.getCurrentFee();

        // Back to balanced
        pool.setReserves(1000 ether, 1000 ether);
        uint256 rebalancedFee = feeModule.getCurrentFee();

        assertGt(imbalancedFee, partialRebalanceFee, "Fee should decrease as balance improves");
        assertGt(partialRebalanceFee, rebalancedFee, "Fee should continue decreasing");
        assertEq(rebalancedFee, 30, "Fully balanced should return to base fee");
    }

    function test_Scenario_LargeSwapSlippage() public {
        // Setup pool
        vm.prank(address(pool));
        alm.onDepositLiquidityCallback(1000 ether, 1000 ether, abi.encode(lp));

        // Small swap - low slippage
        uint256 smallSwapOut = alm.previewSwap(10 ether, true);
        uint256 smallSlippage = 10 ether - smallSwapOut;

        // Large swap - higher slippage
        uint256 largeSwapOut = alm.previewSwap(200 ether, true);
        uint256 largeSlippage = 200 ether - largeSwapOut;

        // Large swap should have proportionally more slippage
        uint256 smallSlippagePct = (smallSlippage * 10000) / 10 ether;
        uint256 largeSlippagePct = (largeSlippage * 10000) / 200 ether;

        assertGt(largeSlippagePct, smallSlippagePct, "Larger swaps should have more slippage");
    }
}
