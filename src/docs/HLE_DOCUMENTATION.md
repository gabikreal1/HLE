# HLE (Hyper Liquidity Engine) - Contract Documentation# HLE (Hyper Liquidity Engine) - Contract Documentation



## Overview## Overview



HLE is a **Fill-or-Kill AMM** built on Valantis Sovereign Pool infrastructure with:HLE is a Fill-or-Kill AMM built on Valantis Sovereign Pool infrastructure, using HyperCore L1 oracle prices for pricing and EWMA volatility gating for safety. It optimizes capital allocation between AMM liquidity and HyperCore lending.

- **L1 Oracle Pricing**: Uses HyperCore precompiles for real-time prices

- **Spread-Based Dynamic Fees**: Volatility + Price Impact spreads---

- **EWMA Volatility Gating**: Two-speed EWMA for safety

- **Yield Optimization**: Capital allocation between AMM and HyperCore lending## Architecture Flow



---```

┌─────────────────────────────────────────────────────────────────────────────┐

## Spread-Based Pricing Model│                              USER SWAP FLOW                                  │

├─────────────────────────────────────────────────────────────────────────────┤

### Formula│                                                                              │

│   User → SovereignPool.swap() → HLEALM.getLiquidityQuote()                  │

```│                                      ↓                                       │

totalSpread = volSpread + impactSpread│                              L1OracleAdapter.getSpotPriceByIndexWAD()        │

│                                      ↓                                       │

volSpread    = max(fastVar, slowVar) × K_VOL / WAD│                              TwoSpeedEWMA.update() → Volatility Check        │

impactSpread = amountIn × K_IMPACT / reserveIn│                                      ↓                                       │

│                              Calculate amountOut at oracle price             │

BUY  (token0 → token1): askPrice = oraclePrice × (1 + spread)│                                      ↓                                       │

                        amountOut = amountIn × oraclePrice / askPrice│                              Return ALMLiquidityQuote (Fill-or-Kill)         │

│                                                                              │

SELL (token1 → token0): bidPrice = oraclePrice × (1 - spread)  └─────────────────────────────────────────────────────────────────────────────┘

                        amountOut = amountIn × WAD / bidPrice

```┌─────────────────────────────────────────────────────────────────────────────┐

│                          YIELD OPTIMIZATION FLOW                             │

### Parameters├─────────────────────────────────────────────────────────────────────────────┤

│                                                                              │

| Parameter | Default | Max | Description |│   YieldOptimizer.checkRebalance()                                           │

|-----------|---------|-----|-------------|│           ↓                                                                  │

| `K_VOL` | 5% (5e16) | 100% | Volatility spread multiplier |│   YieldTracker.compareYields() ←→ L1OracleAdapter.getLendingAPY()           │

| `K_IMPACT` | 1% (1e16) | 10% | Price impact spread multiplier |│           ↓                                                                  │

| `MAX_SPREAD` | 50% (5e17) | - | Cap on total spread |│   If ALM yield > lending + threshold → Keep in ALM                          │

│   If lending yield > ALM + threshold → LendingModule.supply()               │

### Example│           ↓                                                                  │

│   CoreWriterLib.bridgeToCore() → CoreWriter.sendRawAction(ACTION_ID=15)     │

```│                                                                              │

Oracle Price: 1 ETH = 2000 USDC└─────────────────────────────────────────────────────────────────────────────┘

Trade: Buy 10 ETH with USDC```

Pool Reserve: 100 ETH

---

maxVariance = 0.001 (0.1% squared price movement)

K_VOL = 0.05, K_IMPACT = 0.01## Modules



volSpread = 0.001 × 0.05 = 0.00005 (0.005%)### 1. HLEALM.sol

impactSpread = 10 / 100 × 0.01 = 0.001 (0.1%)**Purpose:** Main ALM (Automated Liquidity Manager) implementing Fill-or-Kill execution at L1 oracle prices.

totalSpread = 0.00105 (0.105%)

| Function | Visibility | Returns | Description |

askPrice = 2000 × 1.00105 = 2002.10 USDC|----------|------------|---------|-------------|

amountOut = 10 ETH (less spread fee captured)| `constructor(pool, token0Index, token1Index, feeRecipient, owner)` | - | - | Initialize ALM with pool and token indices |

```| `initialize()` | external | - | Seed EWMA with current oracle price (MUST call before swaps) |

| `initializeWithAlphas(fastAlpha, slowAlpha)` | external | - | Initialize with custom EWMA smoothing factors |

---| `getLiquidityQuote(input, context, verifier)` | external | `ALMLiquidityQuote` | **CORE**: Called by pool during swap, returns Fill-or-Kill quote |

| `onSwapCallback(isZeroToOne, amountIn, amountOut)` | external | - | Post-swap callback (unused) |

## Architecture| `onDepositLiquidityCallback(amount0, amount1, data)` | external | - | Called when liquidity deposited |

| `getQuote(tokenIn, tokenOut, amountIn)` | view | `uint256 amountOut` | **Off-chain quote preview** - specify tokens explicitly |

```| `previewSwap(tokenIn, tokenOut, amountIn)` | view | `(amountOut, fee, canExecute)` | Detailed preview with execution check |

┌─────────────────────────────────────────────────────────────────────────────┐| `getOracleMidPrice()` | view | `uint256 price` | Current L1 oracle price (WAD) |

│                              SWAP FLOW                                       │| `getVolatility()` | view | `VolatilityReading` | Current EWMA volatility state |

├─────────────────────────────────────────────────────────────────────────────┤| `canTrade()` | view | `bool` | Whether volatility allows trading |

│                                                                              │| `getTotalLiquidity()` | view | `uint256` | Total liquidity in token0 terms |

│   User → SovereignPool.swap()                                               │| `getAccumulatedFees()` | view | `(fees0, fees1)` | Accumulated fees awaiting collection |

│                ↓                                                             │| `setConfig(volatilityThresholdBps, feeBps)` | external | - | Update volatility threshold and fee |

│          HLEALM.getLiquidityQuote()                                         │| `setYieldOptimizer(optimizer)` | external | - | Set YieldOptimizer for fee tracking |

│                ↓                                                             │| `setFeeRecipient(recipient)` | external | - | Update fee recipient |

│   ┌────────────────────────────────────────────┐                            │| `collectFees()` | external | - | Collect accumulated fees |

│   │ 1. Get oracle price (L1OracleAdapter)      │                            │| `collectSurplus()` | external | - | Collect captured surplus |

│   │ 2. Update EWMA + variance                  │                            │| `setPaused(paused)` | external | - | Emergency pause/unpause |

│   │ 3. Check volatility gate                   │                            │| `setTokenIndices(token0Index, token1Index)` | external | - | Update HyperCore token indices |

│   │ 4. Calculate spread (vol + impact)         │                            │

│   │ 5. Calculate amountOut with spread         │                            │**Key Logic:**

│   │ 6. Track fees, notify YieldOptimizer       │                            │- `getLiquidityQuote`: Updates EWMA → checks volatility → calculates output at oracle price → applies fee → returns FoK quote

│   │ 7. Return Fill-or-Kill quote               │                            │- `getQuote(tokenIn, tokenOut, amountIn)`: View function for off-chain quote - specify actual token addresses for clarity

│   └────────────────────────────────────────────┘                            │- Reverts with `HLEALM__VolatilityTooHigh` if fast/slow EWMA deviation exceeds threshold

│                ↓                                                             │

│   Pool executes swap → Tokens transferred                                   │---

│                                                                              │

└─────────────────────────────────────────────────────────────────────────────┘### 2. LendingModule.sol

**Purpose:** Supply/withdraw tokens to HyperCore lending via CoreWriter (0x333...333). Follows Valantis modular architecture - reads `poolManager` from the Sovereign Pool.

┌─────────────────────────────────────────────────────────────────────────────┐

│                          QUOTE FLOW (Pre-Swap)                              │| Function | Visibility | Returns | Description |

├─────────────────────────────────────────────────────────────────────────────┤|----------|------------|---------|-------------|

│                                                                              │| `constructor(pool, strategist, minSupplyAmount, cooldownBlocks)` | - | - | Initialize module with pool reference |

│   User → HLEQuoter.quote(tokenIn, tokenOut, amountIn)                       │| `supplyToLending(token, amount)` | external | - | Bridge tokens to Core, then supply to lending |

│                ↓                                                             │| `withdrawFromLending(token, amount)` | external | - | Withdraw from lending, bridge back to EVM |

│   ┌────────────────────────────────────────────┐                            │| `supply(token, amount)` | external | - | Alias for YieldOptimizer integration |

│   │ 1. Get oracle price                        │                            │| `withdraw(token, amount, recipient)` | external | - | Withdraw to specific recipient |

│   │ 2. Get variance from ALM                   │                            │| `canOperate()` | view | `bool` | Whether cooldown has passed |

│   │ 3. Calculate spread components             │                            │| `getSuppliedAmount(token)` | view | `uint256` | Tracked supply for token |

│   │ 4. Apply spread to get amountOut           │                            │| `getTokenIndex(token)` | view | `uint64` | HyperCore token index |

│   │ 5. Return expected output                  │                            │| `previewSupplyAction(token, amount)` | view | `bytes` | Preview encoded supply action |

│   └────────────────────────────────────────────┘                            │| `previewWithdrawAction(token, amount)` | view | `bytes` | Preview encoded withdraw action |

│                ↓                                                             │| `setTokenIndex(token, tokenIndex)` | external | - | Map ERC20 to HyperCore index |

│   Use amountOut as amountOutMin in swap (native FoK)                        │| `setTokenIndices(tokens[], indices[])` | external | - | Batch set indices |

│                                                                              │| `setStrategist(newStrategist)` | external | - | Update strategist |

└─────────────────────────────────────────────────────────────────────────────┘| `setPoolManager(newManager)` | external | - | Update pool manager |

| `setConfig(minSupplyAmount, cooldownBlocks)` | external | - | Update config |

┌─────────────────────────────────────────────────────────────────────────────┐| `pause()` / `unpause()` | external | - | Emergency controls |

│                          YIELD OPTIMIZATION                                  │| `rescueTokens(token, to, amount)` | external | - | Emergency token rescue |

├─────────────────────────────────────────────────────────────────────────────┤

│                                                                              │**Key Logic:**

│   YieldOptimizer.checkRebalance()                                           │- **Action ID 15** for lending (NOT in hyper-evm-lib)

│           ↓                                                                  │- Flow: `bridgeToCore()` → `sendRawAction(LENDING_ACTION_ID=15)` → lending position

│   Compare: ALM yield (from swap fees) vs Lending APY (from L1)              │- Tracks `totalSupplied` per token for accounting

│           ↓                                                                  │- Cooldown prevents rapid operations

│   If lending > ALM + threshold → LendingModule.supplyToLending()            │

│   If ALM > lending + threshold → LendingModule.withdrawFromLending()        │---

│           ↓                                                                  │

│   CoreWriterLib.bridgeToCore() → CoreWriter.sendRawAction(ACTION=15)        │### 3. YieldOptimizer.sol

│                                                                              │**Purpose:** Compare ALM yield vs HyperCore lending APY to optimize capital allocation.

└─────────────────────────────────────────────────────────────────────────────┘

```| Function | Visibility | Returns | Description |

|----------|------------|---------|-------------|

---| `constructor(token, tokenIndex, lendingModule, alm, owner)` | - | - | Initialize optimizer |

| `initializeTracking(initialLiquidity)` | external | - | Start yield tracking |

## Modules| `recordSwapFees(feeAmount, newLiquidity)` | external | - | **ALM callback**: Record fee income |

| `updateLiquidity(newLiquidity)` | external | - | **ALM callback**: Update liquidity tracking |

### 1. HLEALM.sol| `checkRebalance()` | view | `(shouldRebalance, moveToLending, suggestedAmount)` | Check if rebalance recommended |

| `executeRebalance()` | external | - | Execute rebalancing based on yield comparison |

**Main ALM with spread-based Fill-or-Kill execution.**| `getYieldComparison()` | view | `YieldComparison` | Current ALM vs lending yield |

| `getCurrentALMYield()` | view | `uint256 yieldBps` | Current period ALM yield |

#### Key Functions| `getSmoothedALMYield()` | view | `uint256 yieldBps` | EWMA-smoothed ALM yield |

| `getLendingYield()` | view | `uint256 yieldBps` | Current lending APY from L1 |

| Function | Description || `getTotalCapital()` | view | `uint256` | ALM + lending balance |

|----------|-------------|| `getTrackingStats()` | view | `(totalFees, avgLiquidity, duration)` | Yield tracking statistics |

| `getLiquidityQuote(input, ...)` | **CORE**: Called by pool, returns spread-adjusted FoK quote || `setRebalanceThreshold(thresholdBps)` | external | - | Update rebalance threshold |

| `getQuote(tokenIn, tokenOut, amountIn)` | Off-chain quote preview || `setALM(newALM)` | external | - | Update ALM address |

| `previewSwap(tokenIn, tokenOut, amountIn)` | Detailed preview with fee and execution check || `setLendingModule(newLendingModule)` | external | - | Update lending module |

| `getSpread(amountIn, tokenIn)` | Get spread breakdown (vol, impact, total) || `setActive(active)` | external | - | Pause/unpause optimizer |

| `getVariance()` | Get current EWMA variance (fast, slow, max) |

| `getSpreadConfig()` | Get kVol and kImpact |**Key Logic:**

| `setSpreadConfig(kVol, kImpact)` | Update spread parameters |- `checkRebalance()`: Compares smoothed ALM yield vs lending APY ± threshold

| `setVolatilityThreshold(bps)` | Update volatility gate threshold |- `executeRebalance()`: Moves up to 50% of capital per rebalance

| `initialize()` | Seed EWMA with oracle price (MUST call before swaps) |- Uses `YieldTracker` for time-weighted yield calculation

- 1 hour minimum between rebalances

#### State Variables

---

```solidity

uint256 public kVol;                    // Volatility spread multiplier### 4. DynamicFeeModule.sol

uint256 public kImpact;                 // Impact spread multiplier**Purpose:** Calculate swap fees based on pool reserve imbalance. Follows Valantis modular architecture - reads `poolManager` from the Sovereign Pool.

uint256 public volatilityThresholdBps;  // Volatility gate (default 100 bps)

TwoSpeedEWMA.EWMAState public priceEWMA; // EWMA with variance tracking| Function | Visibility | Returns | Description |

```|----------|------------|---------|-------------|

| `constructor(pool)` | - | - | Initialize fee module with pool reference |

---| `getSwapFeeInBips(tokenIn, tokenOut, amountIn, user, context)` | external | `SwapFeeModuleData` | Calculate dynamic fee |

| `callbackOnSwapEnd(...)` | external | - | Post-swap callback |

### 2. HLEQuoter.sol| `setBaseFee(baseFee)` | external | - | Set custom base fee |

| `resetBaseFee()` | external | - | Reset to default (30 bps) |

**On-chain quoter module for pre-swap quotes.**| `getImbalanceRatio()` | view | `uint256` | Current imbalance ratio |



```solidity**Key Logic:**

// Simple quote- Formula: `fee = baseFee + sqrt(imbalance_ratio) * 10bps`

uint256 amountOut = quoter.quote(tokenIn, tokenOut, amountIn);- Base fee: 30 bps (0.3%)

- Max fee: 500 bps (5%)

// Detailed quote with spread breakdown- Imbalance = |reserve0 - reserve1| / (reserve0 + reserve1)

(amountOut, volSpread, impactSpread, effectivePrice) = 

    quoter.quoteDetailed(tokenIn, tokenOut, amountIn);---



// Get current spread for trade size### 5. HyperCoreOracleModule.sol

uint256 spread = quoter.getSpread(amountIn, tokenIn);**Purpose:** Oracle module for QuoteValidator integration (reads from PrecompileLib).

```

| Function | Visibility | Returns | Description |

---|----------|------------|---------|-------------|

| `constructor(pool)` | - | - | Initialize with pool |

### 3. LendingModule.sol| `getCurrentPrice(tokenIn, tokenOut)` | view | `uint256 priceX96` | Get oracle price in X96 format |

| `getTokenPrice(token)` | view | `uint256 price` | Get individual token price |

**Supply/withdraw to HyperCore lending via CoreWriter.**| `registerPair(token0, token1, index0, index1)` | external | - | Register token pair with indices |

| `getPairHash(token0, token1)` | pure | `bytes32` | Get pair identifier |

| Function | Description |

|----------|-------------|---

| `supplyToLending(token, amount)` | Bridge + supply to lending |

| `withdrawFromLending(token, amount)` | Withdraw + bridge back |## Libraries

| `getSuppliedAmount(token)` | Tracked supply balance |

| `setTokenIndex(token, index)` | Map ERC20 → HyperCore index |### 1. L1OracleAdapter.sol

**Purpose:** Wrapper around hyper-evm-lib's PrecompileLib with additional borrow/lend precompile reads.

---

| Function | Returns | Description |

### 4. YieldOptimizer.sol|----------|---------|-------------|

| `getSpotPriceWAD(tokenAddress)` | `uint256` | Spot price in WAD (18 decimals) |

**Compare ALM yield vs lending APY for capital optimization.**| `getSpotPriceByIndexWAD(spotIndex)` | `uint256` | Spot price by index in WAD |

| `getOraclePriceWAD(perpIndex)` | `uint256` | Oracle/perp price in WAD |

| Function | Description || `getMarkPriceWAD(perpIndex)` | `uint256` | Mark price in WAD |

|----------|-------------|| `getNormalizedSpotPx(spotIndex)` | `uint256` | Normalized spot price (8 decimals) |

| `checkRebalance()` | Check if rebalance recommended || `getBorrowLendUserState(user, tokenIndex)` | `BorrowLendUserState` | User's supply/borrow position |

| `executeRebalance()` | Move capital based on yield comparison || `getBorrowLendReserveState(tokenIndex)` | `BorrowLendReserveState` | Reserve pool state (APYs) |

| `getYieldComparison()` | Current ALM vs lending yield || `getLendingAPY(tokenIndex)` | `uint64` | Lending APY in bps |

| `recordSwapFees(fee, liquidity)` | Callback from ALM to track fees || `getBorrowAPY(tokenIndex)` | `uint64` | Borrow APY in bps |

| `getUserSupplied(user, tokenIndex)` | `uint64` | User's supplied amount (8 decimals) |

---| `getUserSuppliedEVM(user, tokenIndex)` | `uint256` | User's supplied amount (18 decimals) |

| `calculateDeviationBps(price1, price2)` | `uint256` | Price deviation in bps |

## Libraries| `isPriceValid(targetPrice, oraclePrice, maxDeviationBps)` | `bool` | Check price within bounds |

| `getMidPrice(price0, price1)` | `uint256` | Calculate mid price (WAD) |

### TwoSpeedEWMA.sol| `getSpotBalanceEVM(user, tokenAddress)` | `uint256` | User's spot balance (18 decimals) |

| `l1BlockNumber()` | `uint64` | Current L1 block number |

**Two-speed EWMA with variance tracking.**

**Key Precompiles (NOT in hyper-evm-lib):**

```solidity- `0x811`: Borrow/Lend User State

struct EWMAState {- `0x812`: Borrow/Lend Reserve State

    uint256 fastEWMA;    // Fast-moving average

    uint256 slowEWMA;    // Slow-moving average---

    uint256 fastVar;     // Fast variance (squared deviation)

    uint256 slowVar;     // Slow variance### 2. TwoSpeedEWMA.sol

    uint256 fastAlpha;   // Fast smoothing (default 0.1)**Purpose:** Two-speed EWMA for volatility detection (fast/slow comparison).

    uint256 slowAlpha;   // Slow smoothing (default 0.01)

    bool initialized;| Function | Returns | Description |

}|----------|---------|-------------|

```| `initialize(state, initialPrice)` | - | Initialize with default alphas (0.1/0.01) |

| `initializeWithAlphas(state, price, fastAlpha, slowAlpha)` | - | Initialize with custom alphas |

Key functions:| `update(state, newPrice)` | `VolatilityReading` | Update EWMAs and return volatility |

- `update(state, price)` → Updates EWMA and variance| `updateTimeWeighted(state, newPrice, expectedInterval)` | `VolatilityReading` | Time-adjusted update |

- `getMaxVariance(state)` → Returns max(fastVar, slowVar)| `getVolatility(state, thresholdBps)` | `VolatilityReading` | Get current volatility (view) |

- `isVolatile(state, threshold)` → Check if trading should be gated| `previewUpdate(state, newPrice)` | `(fastEWMA, slowEWMA, deviationBps)` | Preview what update would produce |

| `isVolatile(state, thresholdBps)` | `bool` | Check if deviation exceeds threshold |

### L1OracleAdapter.sol| `timeSinceUpdate(state)` | `uint256` | Seconds since last update |



**Wrapper for HyperCore precompiles.****Key Logic:**

- EWMA formula: `new = α * price + (1-α) * old`

```solidity- Volatility signal: `|fastEWMA - slowEWMA| / slowEWMA * 10000` (bps)

// Price reads- Default: fast α=0.1 (responsive), slow α=0.01 (stable)

L1OracleAdapter.getSpotPriceByIndexWAD(tokenIndex) → price

L1OracleAdapter.getMidPrice(price0, price1) → midPrice---



// Lending reads### 3. YieldTracker.sol

L1OracleAdapter.getLendingAPY(tokenIndex) → apy**Purpose:** Track ALM yield using time-weighted liquidity and EWMA smoothing.

L1OracleAdapter.getUserSuppliedEVM(user, tokenIndex) → supplied

```| Function | Returns | Description |

|----------|---------|-------------|

---| `initialize(state, initialLiquidity)` | - | Start tracking |

| `recordFees(state, feeAmount)` | - | Record fee income |

## Key Constants| `updateLiquidity(state, newLiquidity)` | - | Update liquidity level |

| `recordSwap(state, feeAmount, newLiquidity)` | - | Record fee + update liquidity |

| Constant | Value | Description || `updateYieldEWMA(state)` | `uint256 currentYieldBps` | Update yield EWMA |

|----------|-------|-------------|| `resetPeriod(state)` | - | Reset tracking (after rebalance) |

| `WAD` | 1e18 | 18 decimal precision || `calculateCurrentYield(state)` | `uint256 yieldBps` | Calculate annualized yield |

| `BPS` | 10,000 | Basis points || `getSmoothedYield(state)` | `uint256 smoothedYieldBps` | Get EWMA-smoothed yield |

| `DEFAULT_K_VOL` | 5e16 | 5% volatility multiplier || `compareYields(state, lendingYieldBps)` | `YieldComparison` | Compare ALM vs lending |

| `DEFAULT_K_IMPACT` | 1e16 | 1% impact multiplier || `getAverageLiquidity(state)` | `uint256` | Time-weighted average liquidity |

| `MAX_SPREAD` | 5e17 | 50% max spread || `getTotalFees(state)` | `uint256` | Total fees in period |

| `DEFAULT_VOLATILITY_THRESHOLD` | 100 bps | 1% volatility gate || `getTrackingDuration(state)` | `uint256` | Period duration (seconds) |

| `CORE_WRITER` | 0x333...333 | HyperCore CoreWriter |

| `LENDING_ACTION_ID` | 15 | Lending action |**Key Logic:**

- Yield = (fees / avgLiquidity) * (365 days / elapsed) * 10000 bps

---- Time-weighted liquidity: sum(liquidity * duration) / total_time

- Min period: 1 hour before yield calculation

## Valantis Integration

---

HLE uses **Valantis Sovereign Pool** architecture:

## Orchestrator

1. **Pool Creation**: Deploy SovereignPool with HLEALM as the ALM

2. **Swap Flow**: Pool calls `alm.getLiquidityQuote()` during swaps### LendingOrchestrator.sol

3. **Native FoK**: Use `amountOutMin` in `SovereignPoolSwapParams` for slippage protection**Purpose:** Manage capital allocation between AMM and HyperCore staking (for HYPE token).

4. **Modular Design**: LendingModule reads `pool.poolManager()` dynamically

| Function | Visibility | Returns | Description |

---|----------|------------|---------|-------------|

| `constructor(pool, hypeToken, strategist, validator)` | - | - | Initialize orchestrator |

## Test Coverage| `rebalanceToStaking(amount)` | external | - | Move HYPE from AMM to staking |

| `rebalanceFromStaking(amount)` | external | - | Withdraw from staking to AMM |

All tests passing:| `calculateRebalanceAmount()` | view | `(toStaking, fromStaking)` | Calculate recommended rebalance |

- `LendingModule.t.sol`: 27 tests| `canRebalance()` | view | `bool` | Whether cooldown passed |

- `HYPEAMM.t.sol`: 13 tests  | `setConfig(config)` | external | - | Update rebalance config |

- `DynamicFeeModule.t.sol`: 16 tests| `getConfig()` | view | `RebalanceConfig` | Get current config |

- `QuoteValidator.t.sol`: 16 tests| `setStrategist(newStrategist)` | external | - | Update strategist |

- `E2E.t.sol`: 7+ tests| `getCapitalAllocation()` | view | `(ammAmount, stakedAmount, ammShareBps)` | Current allocation |

| `blocksUntilRebalance()` | view | `uint64` | Remaining cooldown |

Run: `forge test -vvv`| `getDelegations()` | view | `Delegation[]` | Read staking delegations from L1 |

| `getDelegatorSummary()` | view | `DelegatorSummary` | Read delegation summary from L1 |

**Key Logic:**
- Default target: 60% AMM, 40% staking
- Flow: `bridgeToCore()` → `depositStake()` → `delegateToken(validator)`
- Uses PrecompileLib for L1 reads

---

## Quote Validator

### QuoteValidator.sol
**Purpose:** Oracle-backed quote validation for HOT AMM pattern (no signatures needed).

| Function | Visibility | Returns | Description |
|----------|------------|---------|-------------|
| `constructor(pool, oracleModule, strategist)` | - | - | Initialize validator |
| `executeQuote(quote)` | external | `uint256 amountOut` | Validate and execute quote |
| `validateQuote(quote)` | view | `(bool valid, string reason)` | Validate without executing |
| `hasOracleDrifted(quote)` | view | `bool` | Check if oracle drifted from snapshot |
| `generateQuoteId(tokenIn, tokenOut, amountIn, user, nonce)` | pure | `bytes32` | Generate unique quote ID |
| `getOracleSnapshot(tokenIn, tokenOut)` | view | `(priceX96, l1Block)` | Get current oracle state |
| `setMaxDeviation(maxDeviationBps)` | external | - | Update max allowed deviation |
| `setStrategist(newStrategist)` | external | - | Update strategist |
| `isQuoteUsed(quoteId)` | view | `bool` | Check if quote already used |

**Validation Checks:**
1. Caller == intendedUser
2. Quote not already used
3. Block number <= expirationBlock
4. Oracle deviation <= maxDeviationBps (default 1%)
5. Execution price within bounds

---

## Interfaces

| Interface | Purpose |
|-----------|---------|
| `IHLEALM.sol` | Interface for HLEALM |
| `ILendingModule.sol` | Interface for LendingModule |
| `ILendingOrchestrator.sol` | Interface for LendingOrchestrator |
| `IOracleModule.sol` | Interface for oracle modules |
| `IQuoteValidator.sol` | Interface for QuoteValidator |
| `IYieldOptimizer.sol` | Interface for YieldOptimizer |

---

## Key Constants

| Constant | Value | Location | Description |
|----------|-------|----------|-------------|
| `CORE_WRITER` | `0x333...333` | LendingModule | HyperCore CoreWriter address |
| `LENDING_ACTION_ID` | `15` | LendingModule | Lending action ID |
| `WAD` | `1e18` | Multiple | 18 decimal precision |
| `BPS` | `10_000` | Multiple | Basis points precision |
| `DECIMAL_SCALE` | `1e10` | L1OracleAdapter | 8→18 decimal conversion |
| `DEFAULT_VOLATILITY_THRESHOLD_BPS` | `100` | HLEALM | 1% volatility gate |
| `DEFAULT_FEE_BPS` | `5` | HLEALM | 0.05% ALM fee |
| `MAX_FEE_BPS` | `100` | HLEALM | 1% max fee |
| `MIN_REBALANCE_INTERVAL` | `1 hours` | YieldOptimizer | Rebalance cooldown |
| `DEFAULT_REBALANCE_THRESHOLD_BPS` | `50` | YieldOptimizer | 0.5% yield threshold |

---

## Dependencies

- **Valantis Core:** `ISovereignALM`, `ISovereignPool`, `ALMLiquidityQuote`
- **hyper-evm-lib:** `PrecompileLib`, `CoreWriterLib`, `HLConversions`, `HLConstants`
- **OpenZeppelin:** `IERC20`, `SafeERC20`, `Ownable2Step`, `ReentrancyGuard`

---

## Test Coverage

All 96 tests passing:
- `LendingModule.t.sol`: 27 tests
- `LendingOrchestrator.t.sol`: 17 tests
- `QuoteValidator.t.sol`: 16 tests
- `DynamicFeeModule.t.sol`: 16 tests
- `HYPEAMM.t.sol`: 13 tests
- `E2E.t.sol`: 7 tests

---

## Valantis Modular Architecture

The HLE follows Valantis modular architecture:

1. **Pool Manager**: Modules read `poolManager` from `pool.poolManager()` instead of storing their own
2. **LendingModule**: Takes `pool` as constructor arg, reads manager dynamically  
3. **DynamicFeeModule**: Takes `pool` as constructor arg, reads manager dynamically
4. **HLEALM**: Uses `Ownable2Step` pattern (owner-managed)
5. **YieldOptimizer**: Uses `Ownable2Step` pattern (separate optimization module)

This ensures modules stay in sync with pool governance changes.
