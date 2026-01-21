# HLE — Hyper Liquidity Engine# HLE — Hyper Liquidity Engine



**Spread-Based AMM with L1 Oracle Pricing & Variance-Driven Volatility Protection****Spread-Based AMM with L1 Oracle Pricing & Variance-Driven Volatility Protection**



Built on [Valantis Sovereign Pools](https://docs.valantis.xyz/design-space) for Hyperliquid.Built on [Valantis Sovereign Pools](https://docs.valantis.xyz/design-space) for Hyperliquid.



------



## What Is This?## What Is This?



A market-making AMM that uses Hyperliquid's L1 oracle (via precompiles) for pricing, with dynamic spreads based on:A market-making AMM that uses Hyperliquid's L1 oracle (via precompiles) for pricing, with dynamic spreads based on:



1. **Volatility Spread** — Derived from Two-Speed EWMA variance tracking1. **Volatility Spread** — Derived from Two-Speed EWMA variance tracking

2. **Impact Spread** — Proportional to trade size relative to reserves2. **Impact Spread** — Proportional to trade size relative to reserves



### Key Features### Key Features



| Feature | Description || Feature | Description |

|---------|-------------||---------|-------------|

| **Oracle-Based Pricing** | Reads HyperCore L1 oracle prices on-chain via precompile || **Oracle-Based Pricing** | Reads HyperCore L1 oracle prices on-chain via precompile |

| **Dynamic Spreads** | Spread = volatilitySpread + impactSpread (capped at 50%) || **Dynamic Spreads** | Spread = volatilitySpread + impactSpread (capped at 50%) |

| **Variance Tracking** | Fast/slow EWMA with variance for volatility detection || **Variance Tracking** | Fast/slow EWMA with variance for volatility detection |

| **Directional Quotes** | BUY: askPrice = oracle × (1 + spread), SELL: bidPrice = oracle × (1 - spread) || **Directional Quotes** | BUY: askPrice = oracle × (1 + spread), SELL: bidPrice = oracle × (1 - spread) |

| **Fill-or-Kill** | Native Valantis FoK via `amountOutMin` parameter || **Fill-or-Kill** | Native Valantis FoK via `amountOutMin` parameter |

| **Manual Price Mode** | For testing without L1 precompiles |

---

---

## Architecture

## Architecture

```

```┌─────────────────── HyperEVM ───────────────────┐

┌─────────────────── HyperEVM ───────────────────┐│                                                │

│                                                ││   Sovereign Pool (Valantis)                    │

│   Sovereign Pool (Valantis)                    ││   ├── HLEALM            ← spread-based pricing │

│   ├── HLEALM            ← spread-based pricing ││   │   └── TwoSpeedEWMA  ← variance tracking    │

│   │   └── TwoSpeedEWMA  ← variance tracking    ││   ├── HLEQuoter         ← on-chain quotes      │

│   ├── HLEQuoter         ← on-chain quotes      ││   └── LendingModule     ← yield optimization   │

│   └── LendingModule     ← yield optimization   ││                                                │

│                                                ││   PrecompileLib ─────────→ L1 Oracle Read      │

│   PrecompileLib ─────────→ L1 Oracle Read      ││                                                │

│                                                │└────────────────────┬───────────────────────────┘

└────────────────────┬───────────────────────────┘                     │

                     │                     ▼

                     ▼              ┌─────────────┐

              ┌─────────────┐              │  HyperCore  │

              │  HyperCore  │              │  (L1 Oracle)│

              │  (L1 Oracle)│              └─────────────┘

              └─────────────┘```

```

---

---

## Core Components

## Core Components

### 1. HLEALM (`src/modules/HLEALM.sol`)

### 1. HLEALM (`src/modules/HLEALM.sol`)The main ALM implementing spread-based pricing:

The main ALM implementing spread-based pricing:

```

```totalSpread = volSpread + impactSpread

totalSpread  = volSpread + impactSpreadvolSpread   = max(fastVariance, slowVariance) × kVol / WAD

volSpread    = max(fastVariance, slowVariance) × kVol / WADimpactSpread = amountIn × kImpact / reserveIn

impactSpread = amountIn × kImpact / reserveIn```

```

- **BUY (zeroToOne)**: `askPrice = oraclePrice × (1 + totalSpread)`

- **BUY (zeroToOne)**: `askPrice = oraclePrice × (1 + totalSpread)`- **SELL (oneToZero)**: `bidPrice = oraclePrice × (1 - totalSpread)`

- **SELL (oneToZero)**: `bidPrice = oraclePrice × (1 - totalSpread)`

### 2. TwoSpeedEWMA (`src/libraries/TwoSpeedEWMA.sol`)

### 2. TwoSpeedEWMA (`src/libraries/TwoSpeedEWMA.sol`)Two-speed exponential moving average with variance tracking:

Two-speed exponential moving average with variance tracking:

```

```fastEWMA = αFast × price + (1 - αFast) × oldFast

fastEWMA = αFast × price + (1 - αFast) × oldFastslowEWMA = αSlow × price + (1 - αSlow) × oldSlow

slowEWMA = αSlow × price + (1 - αSlow) × oldSlowvariance = α × (price - ewma)² + (1 - α) × oldVariance

variance = α × (price - ewma)² + (1 - α) × oldVariance```

```

### 3. HLEQuoter (`src/modules/HLEQuoter.sol`)

### 3. HLEQuoter (`src/modules/HLEQuoter.sol`)On-chain quoter for getting spread-based quotes:

On-chain quoter for getting spread-based quotes.- `quote()` — Returns expected output amount

- `quoteDetailed()` — Returns full breakdown (spread, volatility, impact)

### 4. LendingModule (`src/modules/LendingModule.sol`)

Tracks deployed capital and yield for idle reserves sent to HyperCore.### 4. LendingModule (`src/modules/LendingModule.sol`)

Tracks deployed capital and yield for idle reserves sent to HyperCore.

---

---

## Project Structure

## Project Structure

```

├── src/```

│   ├── interfaces/           # Contract interfaces├── src/

│   │   ├── IHLEALM.sol│   ├── interfaces/           # Contract interfaces

│   │   ├── ILendingModule.sol│   │   ├── IHLEALM.sol       # ALM interface with spread pricing

│   │   └── IYieldOptimizer.sol│   │   ├── ILendingModule.sol

│   ├── modules/              # Core AMM modules│   │   └── IYieldOptimizer.sol

│   │   ├── HLEALM.sol        # Main ALM with spread pricing│   ├── modules/              # Core AMM modules

│   │   ├── HLEQuoter.sol     # On-chain quoter│   │   ├── HLEALM.sol        # Main ALM with spread pricing

│   │   ├── LendingModule.sol│   │   ├── HLEQuoter.sol     # On-chain quoter

│   │   └── YieldOptimizer.sol│   │   ├── LendingModule.sol # Lending tracking

│   ├── libraries/            # Utility libraries│   │   └── YieldOptimizer.sol

│   │   ├── TwoSpeedEWMA.sol  # Variance-tracking EWMA│   ├── libraries/            # Utility libraries

│   │   ├── YieldTracker.sol│   │   ├── TwoSpeedEWMA.sol  # Variance-tracking EWMA

│   │   └── L1OracleAdapter.sol│   │   ├── YieldTracker.sol  # APY calculation

│   └── mocks/│   │   └── L1OracleAdapter.sol

│       └── MockERC20.sol│   └── docs/

├── test/│       └── HLE_DOCUMENTATION.md

│   ├── hardhat/              # Hardhat E2E tests├── test/

│   │   ├── HLE.test.ts       # 24 E2E tests│   ├── mocks/                # Test mocks

│   │   └── helpers.ts│   ├── modules/              # Module unit tests

│   ├── mocks/                # Test mocks│   ├── E2E.t.sol             # Integration tests

│   └── modules/              # Foundry unit tests│   └── HLE_E2E.t.sol         # Full HLE E2E tests

├── scripts/├── script/

│   ├── deploy-local.ts       # Hardhat local deployment│   └── DeployHLE.s.sol       # Foundry deployment

│   ├── deploy.ts             # Production deployment├── lib/

│   └── utils/│   ├── hyper-evm-lib/        # Precompile & CoreWriter utilities

│       └── deployments.ts    # Deployment tracking│   └── valantis-core/        # Sovereign Pool framework

├── script/└── foundry.toml              # Foundry config

│   └── DeployHLE.s.sol       # Foundry deployment```

├── lib/

│   ├── hyper-evm-lib/        # Precompile & CoreWriter utilities---

│   └── valantis-core/        # Sovereign Pool framework

├── deployments/## Quick Start

│   └── deployments.json      # Deployed addresses per network

├── foundry.toml### Prerequisites

├── hardhat.config.ts- [Foundry](https://book.getfoundry.sh/getting-started/installation)

└── package.json- Hyperliquid testnet RPC: `https://rpc.hyperliquid-testnet.xyz/evm`

```

### Install

---```bash

git clone <repo>

## Quick Startcd Hype-AMM

forge install

### Prerequisites```

- [Node.js](https://nodejs.org/) v18+

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (optional, for Foundry tests)### Build

```bash

### Installforge build

```bash```

git clone <repo>

cd Hype-AMM### Test

npm install```bash

forge install  # If using Foundry# Run all tests

```forge test -vvv



### Build# Run specific test files

```bashforge test --match-contract HLEE2ETest -vvv     # E2E tests

# Hardhatforge test --match-contract HLEALMTest -vvv      # ALM unit tests

npx hardhat compileforge test --match-contract LendingModuleTest -vvv

```

# Foundry

forge build---

```

## Deployment

### Test (Hardhat - Recommended)

```bash### Local/Fork Deployment

# Run all HLE E2E tests (24 tests)```bash

npx hardhat test test/hardhat/HLE.test.ts# Deploy to local anvil or fork

forge script script/DeployHLE.s.sol --rpc-url http://localhost:8545 --broadcast

# Run with verbose output

npx hardhat test test/hardhat/HLE.test.ts --verbose# With verbose output

```forge script script/DeployHLE.s.sol --rpc-url http://localhost:8545 --broadcast -vvvv

```

### Test (Foundry)

```bash### Testnet Deployment

forge test -vvv```bash

```# Set your private key

export PRIVATE_KEY=0x...

---

# Deploy to Hyperliquid testnet

## Deploymentforge script script/DeployHLE.s.sol \

  --rpc-url https://rpc.hyperliquid-testnet.xyz/evm \

### Local Hardhat Deployment  --broadcast \

```bash  --verify

# Deploy to local Hardhat network```

npx hardhat run scripts/deploy-local.ts

### Mainnet Deployment

# Output saved to deployments/deployments.json```bash

```forge script script/DeployHLE.s.sol \

  --rpc-url https://rpc.hyperliquid.xyz/evm \

### Testnet Deployment  --broadcast \

```bash  --verify

# Deploy to Hyperliquid testnet```

npx hardhat run scripts/deploy.ts --network hyperliquid-testnet

```---



### Mainnet Deployment## Bootstrap Liquidity

```bash

npx hardhat run scripts/deploy.ts --network hyperliquidAfter deployment, bootstrap the pool with initial liquidity:

```

```solidity

---// 1. Approve tokens to pool

token0.approve(address(pool), amount0);

## Configurationtoken1.approve(address(pool), amount1);



### Oracle Mode// 2. Deposit liquidity (only pool manager can do this)

pool.depositLiquidity(

HLEALM supports two oracle modes:    amount0,           // token0 amount

    amount1,           // token1 amount

| Mode | Use Case | Configuration |    poolManager,       // recipient of LP position

|------|----------|---------------|    "",               // verification context

| **L1 Oracle** | Production on HyperEVM | `setOracleMode(true)` |    ""                // deposit data

| **Manual Price** | Local testing | `setOracleMode(false)` + `setManualPrice(price)` |);

```

```solidity

// Production: Use L1 oracle precompilesOr via Foundry script:

hlealm.setOracleMode(true);```bash

forge script script/DeployHLE.s.sol:BootstrapLiquidity \

// Testing: Use manual price  --rpc-url https://rpc.hyperliquid-testnet.xyz/evm \

hlealm.setManualPrice(2000e18);  // 1 token0 = 2000 token1  --broadcast

hlealm.setOracleMode(false);```

hlealm.initializeEWMA();

```---



### Spread Parameters## Execute Swaps



| Parameter | Default | Description |### Via Contract

|-----------|---------|-------------|```solidity

| `kVol` | 5e16 (5%) | Volatility multiplier |// Prepare swap params

| `kImpact` | 1e16 (1%) | Impact multiplier |SovereignPoolSwapParams memory params = SovereignPoolSwapParams({

| `MAX_SPREAD` | 5e17 (50%) | Maximum total spread cap |    isSwapCallback: false,

    isZeroToOne: true,        // true = buy token1, false = sell token1

### EWMA Parameters    amountIn: 1000e18,        // input amount

    amountOutMin: 990e18,     // minimum output (slippage protection / FoK)

| Parameter | Default | Description |    deadline: block.timestamp + 300,

|-----------|---------|-------------|    recipient: msg.sender,

| `alphaFast` | 5e16 (5%) | Fast EWMA decay (higher = more reactive) |    swapTokenOut: token1,

| `alphaSlow` | 1e16 (1%) | Slow EWMA decay (lower = more stable) |    swapContext: ""

});

```solidity

// Update spread multipliers (owner only)// Execute swap

hlealm.setSpreadConfig(newKVol, newKImpact);(uint256 amountInUsed, uint256 amountOut) = pool.swap(params);

``````



---### Get Quote First

```solidity

## Usage// Get quote with spread breakdown

(uint256 expectedOutput, uint256 volSpread, uint256 impactSpread) = 

### Deposit Liquidity    quoter.quoteDetailed(

```solidity        address(pool),

// Approve tokens to ALM        true,           // isZeroToOne

token0.approve(address(hlealm), amount0);        1000e18        // amountIn

token1.approve(address(hlealm), amount1);    );

```

// Deposit via ALM (owner only)

hlealm.depositLiquidity(amount0, amount1, depositor);---

```

## Configuration

### Get Quote

```solidity### Spread Parameters

// Preview swap output

(uint256 amountOut, bool executable) = hlealm.previewSwap(| Parameter | Default | Description |

    tokenIn,|-----------|---------|-------------|

    tokenOut,| `kVol` | 5e16 (5%) | Volatility multiplier |

    amountIn| `kImpact` | 1e16 (1%) | Impact multiplier |

);| `MAX_SPREAD` | 5e17 (50%) | Maximum total spread cap |

```

### EWMA Parameters

### Execute Swap

```solidity| Parameter | Default | Description |

SovereignPoolSwapParams memory params = SovereignPoolSwapParams({|-----------|---------|-------------|

    isSwapCallback: false,| `alphaFast` | 5e16 (5%) | Fast EWMA decay (higher = more reactive) |

    isZeroToOne: true,        // true = buy token1, false = sell token1| `alphaSlow` | 1e16 (1%) | Slow EWMA decay (lower = more stable) |

    amountIn: 1000e18,

    amountOutMin: 990e18,     // slippage protection### Adjust Parameters (Pool Manager Only)

    deadline: block.timestamp + 300,```solidity

    recipient: msg.sender,// Update spread multipliers

    swapTokenOut: token1,hlealm.setSpreadParams(newKVol, newKImpact);

    swapContext: SovereignPoolSwapContextData({

        externalContext: "",// Update EWMA parameters  

        verifierContext: "",hlealm.setEWMAParams(newAlphaFast, newAlphaSlow);

        swapCallbackContext: "",```

        swapFeeModuleContext: ""

    })---

});

## Constants

(uint256 amountInUsed, uint256 amountOut) = pool.swap(params);

```| Name | Value |

|------|-------|

---| L1 Oracle Precompile | `0x0000000000000000000000000000000000000807` |

| CoreWriter | `0x3333333333333333333333333333333333333333` |

## Spread Calculation Example| HYPE System Address | `0x2222222222222222222222222222222222222222` |

| Testnet Chain ID | 998 |

For a **BUY** (zeroToOne) trade of 1000 USDC:| Mainnet Chain ID | 999 |



```---

Oracle Price:     $2000/ETH

Reserve0 (USDC):  100,000 USDC## Spread Calculation Example

Fast Variance:    0.001 (0.1%)

Slow Variance:    0.0005 (0.05%)For a **BUY** (zeroToOne) trade of 1000 USDC:



Volatility Metric = max(0.001, 0.0005) = 0.001```

Vol Spread        = 0.001 × 0.05 = 0.00005 (0.005%)Oracle Price:     $2000/ETH

Impact Spread     = 1000 / 100,000 × 0.01 = 0.0001 (0.01%)Reserve0 (USDC):  100,000 USDC

Total Spread      = 0.015%Fast Variance:    0.001 (0.1%)

Slow Variance:    0.0005 (0.05%)

Ask Price         = $2000 × 1.00015 = $2000.30

Expected Output   = 1000 / 2000.30 = 0.4999 ETHVolatility Metric = max(0.001, 0.0005) = 0.001

```Vol Spread        = 0.001 × 0.05 = 0.00005 (0.005%)

Impact Spread     = 1000 / 100,000 × 0.01 = 0.0001 (0.01%)

---Total Spread      = 0.015%



## Test CoverageAsk Price         = $2000 × 1.00015 = $2000.30

Expected Output   = 1000 / 2000.30 = 0.4999 ETH

### E2E Tests (24 passing)```



| Category | Tests |---

|----------|-------|

| Deployment | 5 tests |## Why Hyperliquid?

| Pool State | 2 tests |

| Spread Calculation | 4 tests |- **Precompiles**: Direct on-chain L1 oracle reads (~2k gas). No Chainlink, no keepers.

| Quote Generation | 3 tests |- **HyperBFT**: ~100ms block times. Fast enough for reactive systems.

| Preview Swap | 2 tests |- **CoreWriter**: Trustless cross-layer capital deployment for yield.

| Volatility & EWMA | 2 tests |- **Fair ordering**: Prevents order-flow MEV at consensus level.

| Admin Functions | 3 tests |

| Manual Price Changes | 2 tests |---

| Integration Flow | 1 test |

## Security Considerations

```bash

npx hardhat test test/hardhat/HLE.test.ts1. **Oracle Reliance** — Prices come from HyperCore L1 consensus (manipulate-resistant)

2. **Spread Protection** — MAX_SPREAD (50%) prevents extreme pricing during volatility

  HLE E2E Tests3. **Variance Tracking** — Detects rapid price movements and increases spreads

    Deployment4. **Fill-or-Kill** — Native Valantis FoK via `amountOutMin` protects traders

      ✔ Should deploy all contracts correctly5. **Pool Manager Only** — Parameter changes restricted to pool manager

      ✔ Should set correct pool references

      ✔ Should initialize EWMA with correct price---

      ✔ Should have correct default spread parameters

      ✔ Should be able to trade after initialization## Documentation

    Pool State

      ✔ Should have correct initial reserves- [HLE Technical Docs](./src/docs/HLE_DOCUMENTATION.md) — Full architecture & pricing model

      ✔ Should have ALM set correctly- [Valantis Docs](https://docs.valantis.xyz/design-space) — Sovereign Pool framework

    Spread Calculation- [hyper-evm-lib](./lib/hyper-evm-lib/README.md) — Precompile & CoreWriter library

      ✔ Should have only impact spread with zero variance

      ✔ Should include volatility spread when variance is set---

      ✔ Should increase impact spread with larger trades

      ✔ Should cap spread at MAX_SPREAD## License

    ...

  24 passingMIT

```

---

## Constants

| Name | Value |
|------|-------|
| L1 Oracle Precompile | `0x0000000000000000000000000000000000000807` |
| CoreWriter | `0x3333333333333333333333333333333333333333` |
| HYPE System Address | `0x2222222222222222222222222222222222222222` |
| Testnet Chain ID | 998 |
| Mainnet Chain ID | 999 |

---

## Why Hyperliquid?

- **Precompiles**: Direct on-chain L1 oracle reads (~2k gas). No Chainlink, no keepers.
- **HyperBFT**: ~100ms block times. Fast enough for reactive systems.
- **CoreWriter**: Trustless cross-layer capital deployment for yield.
- **Fair ordering**: Prevents order-flow MEV at consensus level.

---

## Security Considerations

1. **Oracle Reliance** — Prices come from HyperCore L1 consensus (manipulation-resistant)
2. **Spread Protection** — MAX_SPREAD (50%) prevents extreme pricing during volatility
3. **Variance Tracking** — Detects rapid price movements and increases spreads
4. **Fill-or-Kill** — Native Valantis FoK via `amountOutMin` protects traders
5. **Owner Only** — Critical parameter changes restricted to owner

---

## NPM Scripts

```bash
npm run compile      # Compile contracts
npm run test         # Run Hardhat tests
npm run deploy:local # Deploy to local Hardhat
npm run deploy:test  # Deploy to testnet
```

---

## Documentation

- [HLE Technical Docs](./src/docs/HLE_DOCUMENTATION.md) — Full architecture & pricing model
- [Valantis Docs](https://docs.valantis.xyz/design-space) — Sovereign Pool framework
- [hyper-evm-lib](./lib/hyper-evm-lib/README.md) — Precompile & CoreWriter library

---

## License

MIT
