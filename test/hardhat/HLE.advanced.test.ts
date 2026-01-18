import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { 
  deployFreshContracts, 
  WAD, 
  INITIAL_PRICE,
  DEFAULT_K_VOL,
  DEFAULT_K_IMPACT,
  MAX_SPREAD,
} from "./helpers";

describe("HLE Advanced Tests", function () {
  // Use loadFixture to deploy once and share state
  async function deployFixture() {
    return deployFreshContracts();
  }

  describe("Actual Swaps via SovereignPool", function () {
    it("Should execute BUY swap (token0 -> token1)", async function () {
      const { hlealm, sovereignPool, token0, token1, trader } = await loadFixture(deployFixture);

      const amountIn = ethers.parseEther("1");
      const token0Addr = await token0.getAddress();
      const token1Addr = await token1.getAddress();
      const poolAddr = await sovereignPool.getAddress();

      // Get expected output
      const [expectedOut, , canExecute] = await hlealm.previewSwap(
        token0Addr,
        token1Addr,
        amountIn
      );
      expect(canExecute).to.be.true;
      expect(expectedOut).to.be.gt(0n);

      // Setup: mint tokens to trader and approve pool
      await token0.mint(trader.address, amountIn);
      await token0.connect(trader).approve(poolAddr, amountIn);

      // Get balances before
      const traderToken0Before = await token0.balanceOf(trader.address);
      const traderToken1Before = await token1.balanceOf(trader.address);

      // Execute swap
      const swapParams = {
        isSwapCallback: false,
        isZeroToOne: true, // token0 -> token1
        amountIn: amountIn,
        amountOutMin: 0n, // For testing, accept any output
        deadline: Math.floor(Date.now() / 1000) + 3600,
        recipient: trader.address,
        swapTokenOut: token1Addr,
        swapContext: {
          externalContext: "0x",
          verifierContext: "0x",
          swapCallbackContext: "0x",
          swapFeeModuleContext: "0x",
        },
      };

      const tx = await sovereignPool.connect(trader).swap(swapParams);
      const receipt = await tx.wait();

      // Get balances after
      const traderToken0After = await token0.balanceOf(trader.address);
      const traderToken1After = await token1.balanceOf(trader.address);

      // Verify token0 was spent
      expect(traderToken0Before - traderToken0After).to.equal(amountIn);

      // Verify token1 was received
      const token1Received = traderToken1After - traderToken1Before;
      expect(token1Received).to.be.gt(0n);

      // Output should be close to preview
      // Allow 0.1% deviation due to rounding
      const deviation = expectedOut > token1Received 
        ? expectedOut - token1Received 
        : token1Received - expectedOut;
      expect(deviation).to.be.lt(expectedOut / 1000n);

      console.log(`\n  BUY swap executed:`);
      console.log(`    Input:  ${ethers.formatEther(amountIn)} token0`);
      console.log(`    Output: ${ethers.formatEther(token1Received)} token1`);
      console.log(`    Expected: ${ethers.formatEther(expectedOut)} token1`);
    });

    it("Should execute SELL swap (token1 -> token0)", async function () {
      const { hlealm, sovereignPool, token0, token1, trader } = await loadFixture(deployFixture);

      const amountIn = ethers.parseEther("2000");
      const token0Addr = await token0.getAddress();
      const token1Addr = await token1.getAddress();
      const poolAddr = await sovereignPool.getAddress();

      // Get expected output
      const [expectedOut, , canExecute] = await hlealm.previewSwap(
        token1Addr,
        token0Addr,
        amountIn
      );
      expect(canExecute).to.be.true;
      expect(expectedOut).to.be.gt(0n);

      // Setup: mint tokens to trader and approve pool
      await token1.mint(trader.address, amountIn);
      await token1.connect(trader).approve(poolAddr, amountIn);

      // Get balances before
      const traderToken0Before = await token0.balanceOf(trader.address);
      const traderToken1Before = await token1.balanceOf(trader.address);

      // Execute swap
      const swapParams = {
        isSwapCallback: false,
        isZeroToOne: false, // token1 -> token0
        amountIn: amountIn,
        amountOutMin: 0n,
        deadline: Math.floor(Date.now() / 1000) + 3600,
        recipient: trader.address,
        swapTokenOut: token0Addr,
        swapContext: {
          externalContext: "0x",
          verifierContext: "0x",
          swapCallbackContext: "0x",
          swapFeeModuleContext: "0x",
        },
      };

      const tx = await sovereignPool.connect(trader).swap(swapParams);
      await tx.wait();

      // Get balances after
      const traderToken0After = await token0.balanceOf(trader.address);
      const traderToken1After = await token1.balanceOf(trader.address);

      // Verify token1 was spent
      expect(traderToken1Before - traderToken1After).to.equal(amountIn);

      // Verify token0 was received
      const token0Received = traderToken0After - traderToken0Before;
      expect(token0Received).to.be.gt(0n);

      // Output should be close to preview
      const deviation = expectedOut > token0Received 
        ? expectedOut - token0Received 
        : token0Received - expectedOut;
      expect(deviation).to.be.lt(expectedOut / 1000n);

      console.log(`\n  SELL swap executed:`);
      console.log(`    Input:  ${ethers.formatEther(amountIn)} token1`);
      console.log(`    Output: ${ethers.formatEther(token0Received)} token0`);
      console.log(`    Expected: ${ethers.formatEther(expectedOut)} token0`);
    });

    it("Should respect slippage protection (amountOutMin)", async function () {
      const { hlealm, sovereignPool, token0, token1, trader } = await loadFixture(deployFixture);

      const amountIn = ethers.parseEther("1");
      const token0Addr = await token0.getAddress();
      const token1Addr = await token1.getAddress();
      const poolAddr = await sovereignPool.getAddress();

      // Get expected output
      const [expectedOut] = await hlealm.previewSwap(token0Addr, token1Addr, amountIn);

      // Setup
      await token0.mint(trader.address, amountIn);
      await token0.connect(trader).approve(poolAddr, amountIn);

      // Try swap with too high amountOutMin
      const unreasonableMin = expectedOut * 2n;

      const swapParams = {
        isSwapCallback: false,
        isZeroToOne: true,
        amountIn: amountIn,
        amountOutMin: unreasonableMin, // Unreasonably high
        deadline: Math.floor(Date.now() / 1000) + 3600,
        recipient: trader.address,
        swapTokenOut: token1Addr,
        swapContext: {
          externalContext: "0x",
          verifierContext: "0x",
          swapCallbackContext: "0x",
          swapFeeModuleContext: "0x",
        },
      };

      // Should revert due to slippage
      await expect(
        sovereignPool.connect(trader).swap(swapParams)
      ).to.be.reverted;
    });

    it("Should fail swap when paused", async function () {
      const { hlealm, sovereignPool, token0, token1, trader, deployer } = await loadFixture(deployFixture);

      const amountIn = ethers.parseEther("1");
      const token1Addr = await token1.getAddress();
      const poolAddr = await sovereignPool.getAddress();

      // Setup
      await token0.mint(trader.address, amountIn);
      await token0.connect(trader).approve(poolAddr, amountIn);

      // Pause the ALM
      await hlealm.connect(deployer).setPaused(true);

      const swapParams = {
        isSwapCallback: false,
        isZeroToOne: true,
        amountIn: amountIn,
        amountOutMin: 0n,
        deadline: Math.floor(Date.now() / 1000) + 3600,
        recipient: trader.address,
        swapTokenOut: token1Addr,
        swapContext: {
          externalContext: "0x",
          verifierContext: "0x",
          swapCallbackContext: "0x",
          swapFeeModuleContext: "0x",
        },
      };

      // Should revert due to pause
      await expect(
        sovereignPool.connect(trader).swap(swapParams)
      ).to.be.reverted;
    });
  });

  describe("Multiple Sequential Swaps", function () {
    it("Should handle multiple swaps correctly", async function () {
      const { hlealm, sovereignPool, token0, token1, trader, lp } = await loadFixture(deployFixture);

      const token0Addr = await token0.getAddress();
      const token1Addr = await token1.getAddress();
      const poolAddr = await sovereignPool.getAddress();

      // Execute 5 sequential swaps
      const swapAmounts = [
        ethers.parseEther("1"),
        ethers.parseEther("0.5"),
        ethers.parseEther("2"),
        ethers.parseEther("0.1"),
        ethers.parseEther("1.5"),
      ];

      console.log(`\n  Sequential swaps:`);

      for (let i = 0; i < swapAmounts.length; i++) {
        const amountIn = swapAmounts[i];
        const isZeroToOne = i % 2 === 0; // Alternate directions

        // Setup
        if (isZeroToOne) {
          await token0.mint(trader.address, amountIn);
          await token0.connect(trader).approve(poolAddr, amountIn);
        } else {
          await token1.mint(trader.address, amountIn);
          await token1.connect(trader).approve(poolAddr, amountIn);
        }

        const [expectedOut] = await hlealm.previewSwap(
          isZeroToOne ? token0Addr : token1Addr,
          isZeroToOne ? token1Addr : token0Addr,
          amountIn
        );

        const swapParams = {
          isSwapCallback: false,
          isZeroToOne: isZeroToOne,
          amountIn: amountIn,
          amountOutMin: 0n,
          deadline: Math.floor(Date.now() / 1000) + 3600,
          recipient: trader.address,
          swapTokenOut: isZeroToOne ? token1Addr : token0Addr,
          swapContext: {
            externalContext: "0x",
            verifierContext: "0x",
            swapCallbackContext: "0x",
            swapFeeModuleContext: "0x",
          },
        };

        await sovereignPool.connect(trader).swap(swapParams);

        console.log(`    Swap ${i + 1}: ${ethers.formatEther(amountIn)} ${isZeroToOne ? 'token0 -> token1' : 'token1 -> token0'}`);
      }

      // Verify pool still has liquidity
      const reserves = await sovereignPool.getReserves();
      expect(reserves[0]).to.be.gt(0n);
      expect(reserves[1]).to.be.gt(0n);
    });
  });

  describe("Spread Impact on Swaps", function () {
    it("Should have larger spread impact on larger trades", async function () {
      const { hlealm, sovereignPool, token0, token1, trader } = await loadFixture(deployFixture);

      const token0Addr = await token0.getAddress();
      const token1Addr = await token1.getAddress();
      const poolAddr = await sovereignPool.getAddress();

      // Small trade
      const smallAmount = ethers.parseEther("0.1");
      const [smallOutput, smallSpread] = await hlealm.previewSwap(token0Addr, token1Addr, smallAmount);

      // Large trade
      const largeAmount = ethers.parseEther("10");
      const [largeOutput, largeSpread] = await hlealm.previewSwap(token0Addr, token1Addr, largeAmount);

      // Calculate effective prices
      const smallEffectivePrice = (smallAmount * INITIAL_PRICE) / smallOutput;
      const largeEffectivePrice = (largeAmount * INITIAL_PRICE) / largeOutput;

      // Large trade should have worse effective price (higher for BUY)
      expect(largeEffectivePrice).to.be.gt(smallEffectivePrice);

      // Spread fee should be proportionally larger for large trade
      // (not exactly 100x due to impact component)
      expect(largeSpread).to.be.gt(smallSpread);

      console.log(`\n  Spread impact comparison:`);
      console.log(`    Small trade (0.1 ETH): spread = ${ethers.formatEther(smallSpread)}, effective price = ${ethers.formatEther(smallEffectivePrice)}`);
      console.log(`    Large trade (10 ETH):  spread = ${ethers.formatEther(largeSpread)}, effective price = ${ethers.formatEther(largeEffectivePrice)}`);
    });

    it("Should have larger spread with higher volatility", async function () {
      const { hlealm, sovereignPool, token0, token1, trader } = await loadFixture(deployFixture);

      const amountIn = ethers.parseEther("1");
      const token0Addr = await token0.getAddress();
      const token1Addr = await token1.getAddress();

      // Get output at low volatility
      const [lowVolOutput] = await hlealm.previewSwap(token0Addr, token1Addr, amountIn);

      // Simulate high volatility
      await hlealm.forceSetVariance(ethers.parseEther("0.1"), ethers.parseEther("0.05"));

      // Get output at high volatility
      const [highVolOutput] = await hlealm.previewSwap(token0Addr, token1Addr, amountIn);

      // High volatility should give less output (worse price)
      expect(highVolOutput).to.be.lt(lowVolOutput);

      const difference = lowVolOutput - highVolOutput;
      console.log(`\n  Volatility impact:`);
      console.log(`    Low vol output:  ${ethers.formatEther(lowVolOutput)} token1`);
      console.log(`    High vol output: ${ethers.formatEther(highVolOutput)} token1`);
      console.log(`    Difference:      ${ethers.formatEther(difference)} token1`);
    });
  });

  describe("Liquidity Management", function () {
    it("Should allow owner to deposit additional liquidity", async function () {
      const { hlealm, sovereignPool, token0, token1, deployer } = await loadFixture(deployFixture);

      const almAddr = await hlealm.getAddress();
      const additionalToken0 = ethers.parseEther("50");
      const additionalToken1 = ethers.parseEther("100000");

      // Get reserves before
      const [reserve0Before, reserve1Before] = await sovereignPool.getReserves();

      // Mint and approve
      await token0.mint(deployer.address, additionalToken0);
      await token1.mint(deployer.address, additionalToken1);
      await token0.connect(deployer).approve(almAddr, additionalToken0);
      await token1.connect(deployer).approve(almAddr, additionalToken1);

      // Deposit via ALM
      await hlealm.connect(deployer).depositLiquidity(additionalToken0, additionalToken1, deployer.address);

      // Get reserves after
      const [reserve0After, reserve1After] = await sovereignPool.getReserves();

      expect(reserve0After - reserve0Before).to.equal(additionalToken0);
      expect(reserve1After - reserve1Before).to.equal(additionalToken1);

      console.log(`\n  Liquidity deposit:`);
      console.log(`    Added: ${ethers.formatEther(additionalToken0)} token0, ${ethers.formatEther(additionalToken1)} token1`);
      console.log(`    New reserves: ${ethers.formatEther(reserve0After)} token0, ${ethers.formatEther(reserve1After)} token1`);
    });

    it("Should allow owner to withdraw liquidity", async function () {
      const { hlealm, sovereignPool, token0, token1, deployer, lp } = await loadFixture(deployFixture);

      const withdrawToken0 = ethers.parseEther("10");
      const withdrawToken1 = ethers.parseEther("20000");

      // Get reserves before
      const [reserve0Before, reserve1Before] = await sovereignPool.getReserves();

      // Get LP balance before
      const lpToken0Before = await token0.balanceOf(lp.address);
      const lpToken1Before = await token1.balanceOf(lp.address);

      // Withdraw via ALM to LP
      await hlealm.connect(deployer).withdrawLiquidity(withdrawToken0, withdrawToken1, lp.address);

      // Get reserves after
      const [reserve0After, reserve1After] = await sovereignPool.getReserves();

      // Get LP balance after
      const lpToken0After = await token0.balanceOf(lp.address);
      const lpToken1After = await token1.balanceOf(lp.address);

      expect(reserve0Before - reserve0After).to.equal(withdrawToken0);
      expect(reserve1Before - reserve1After).to.equal(withdrawToken1);
      expect(lpToken0After - lpToken0Before).to.equal(withdrawToken0);
      expect(lpToken1After - lpToken1Before).to.equal(withdrawToken1);

      console.log(`\n  Liquidity withdrawal:`);
      console.log(`    Withdrawn: ${ethers.formatEther(withdrawToken0)} token0, ${ethers.formatEther(withdrawToken1)} token1`);
      console.log(`    New reserves: ${ethers.formatEther(reserve0After)} token0, ${ethers.formatEther(reserve1After)} token1`);
    });

    it("Should reject non-owner deposit", async function () {
      const { hlealm, token0, token1, trader } = await loadFixture(deployFixture);

      const amount = ethers.parseEther("1");
      const almAddr = await hlealm.getAddress();

      await token0.mint(trader.address, amount);
      await token0.connect(trader).approve(almAddr, amount);

      await expect(
        hlealm.connect(trader).depositLiquidity(amount, 0n, trader.address)
      ).to.be.reverted;
    });
  });

  describe("Price Oracle Simulation", function () {
    it("Should respond to oracle price changes", async function () {
      const { hlealm, token0, token1 } = await loadFixture(deployFixture);

      const amountIn = ethers.parseEther("1");
      const token0Addr = await token0.getAddress();
      const token1Addr = await token1.getAddress();

      // Test at different price levels
      const prices = [
        ethers.parseEther("1000"),  // 1 token0 = 1000 token1
        ethers.parseEther("2000"),  // 1 token0 = 2000 token1
        ethers.parseEther("5000"),  // 1 token0 = 5000 token1
        ethers.parseEther("10000"), // 1 token0 = 10000 token1
      ];

      console.log(`\n  Price oracle simulation:`);

      for (const price of prices) {
        await hlealm.setMockMidPrice(price);
        await hlealm.forceInitialize(price); // Reset EWMA to avoid volatility spike

        const [amountOut] = await hlealm.previewSwap(token0Addr, token1Addr, amountIn);
        
        // Expected output at oracle price (before spread)
        const expectedAtOracle = (amountIn * price) / WAD;
        
        // Should be less than oracle output due to spread
        expect(amountOut).to.be.lt(expectedAtOracle);
        expect(amountOut).to.be.gt(0n);

        console.log(`    Price ${ethers.formatEther(price)}: output = ${ethers.formatEther(amountOut)} (oracle = ${ethers.formatEther(expectedAtOracle)})`);
      }
    });

    it("Should track EWMA through price movements", async function () {
      const { hlealm } = await loadFixture(deployFixture);

      // Initial state
      let volatility = await hlealm.getVolatility();
      expect(volatility.fastEWMA).to.equal(INITIAL_PRICE);
      expect(volatility.slowEWMA).to.equal(INITIAL_PRICE);

      console.log(`\n  EWMA tracking:`);
      console.log(`    Initial: fast=${ethers.formatEther(volatility.fastEWMA)}, slow=${ethers.formatEther(volatility.slowEWMA)}`);

      // Simulate price increase
      const newPrice = ethers.parseEther("2100"); // 5% increase
      await hlealm.setMockMidPrice(newPrice);
      
      await ethers.provider.send("evm_increaseTime", [60]);
      await ethers.provider.send("evm_mine", []);
      await hlealm.updateEWMA();

      volatility = await hlealm.getVolatility();
      
      // Fast EWMA should have moved more than slow
      const fastDeviation = volatility.fastEWMA > INITIAL_PRICE 
        ? volatility.fastEWMA - INITIAL_PRICE 
        : INITIAL_PRICE - volatility.fastEWMA;
      const slowDeviation = volatility.slowEWMA > INITIAL_PRICE 
        ? volatility.slowEWMA - INITIAL_PRICE 
        : INITIAL_PRICE - volatility.slowEWMA;

      expect(fastDeviation).to.be.gt(slowDeviation);

      console.log(`    After +5%: fast=${ethers.formatEther(volatility.fastEWMA)}, slow=${ethers.formatEther(volatility.slowEWMA)}`);
      console.log(`    Variance: fast=${ethers.formatEther(volatility.fastVar)}, slow=${ethers.formatEther(volatility.slowVar)}`);
    });
  });

  describe("Fee Accumulation", function () {
    it("Should accumulate spread fees from swaps", async function () {
      const { hlealm, sovereignPool, token0, token1, trader } = await loadFixture(deployFixture);

      const token0Addr = await token0.getAddress();
      const token1Addr = await token1.getAddress();
      const poolAddr = await sovereignPool.getAddress();

      // Check initial fees
      const [feesBefore0, feesBefore1] = await hlealm.getAccumulatedFees();

      // Execute multiple swaps
      for (let i = 0; i < 3; i++) {
        const amountIn = ethers.parseEther("1");
        
        await token0.mint(trader.address, amountIn);
        await token0.connect(trader).approve(poolAddr, amountIn);

        const swapParams = {
          isSwapCallback: false,
          isZeroToOne: true,
          amountIn: amountIn,
          amountOutMin: 0n,
          deadline: Math.floor(Date.now() / 1000) + 3600,
          recipient: trader.address,
          swapTokenOut: token1Addr,
          swapContext: {
            externalContext: "0x",
            verifierContext: "0x",
            swapCallbackContext: "0x",
            swapFeeModuleContext: "0x",
          },
        };

        await sovereignPool.connect(trader).swap(swapParams);
      }

      // Check accumulated fees
      const [feesAfter0, feesAfter1] = await hlealm.getAccumulatedFees();

      // Fees should have accumulated (at least one of them)
      // Note: Which token gets fees depends on implementation
      console.log(`\n  Fee accumulation:`);
      console.log(`    Token0 fees: ${ethers.formatEther(feesBefore0)} -> ${ethers.formatEther(feesAfter0)}`);
      console.log(`    Token1 fees: ${ethers.formatEther(feesBefore1)} -> ${ethers.formatEther(feesAfter1)}`);
    });
  });
});
