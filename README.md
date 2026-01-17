# HOT AMM on Hyperliquid

**Hybrid Order Type AMM with Oracle-Backed Quotes & Precompile-Driven Lending Integration**

Built on [Valantis Sovereign Pools](https://docs.valantis.xyz/design-space) for the Hyperliquid London Hackathon.

---

## What Is This?

An AMM that uses Hyperliquid's native infrastructure (precompiles + CoreWriter) to solve two problems:

1. **LP Protection** — Quotes are validated against HyperCore oracle prices on-chain. No signed quotes from centralized services.
2. **Capital Efficiency** — Idle reserves can be deployed to HyperCore staking/lending via CoreWriter.

### Key Difference from Arrakis HOT

| | Arrakis HOT | This Implementation |
|---|---|---|
| Quote validation | Signed by off-chain Liquidity Manager | Oracle-backed (precompile reads) |
| Infrastructure | Centralized quoting service | Fully on-chain |
| Capital allocation | Manual | Programmable via CoreWriter |

---

## Architecture

```
┌─────────────────── HyperEVM ───────────────────┐
│                                                │
│   Sovereign Pool (Valantis)                    │
│   ├── HyperCoreOracleModule  ← precompile      │
│   ├── DynamicFeeModule       ← imbalance-based │
│   ├── LiquidityModule        ← CFMM pricing    │
│   └── QuoteValidator         ← oracle guards   │
│                                                │
│   LendingOrchestrator ──────→ CoreWriter       │
│                                                │
└────────────────────┬───────────────────────────┘
                     │
                     ▼
              ┌─────────────┐
              │  HyperCore  │
              │  - Oracle   │
              │  - Staking  │
              │  - Lending  │
              └─────────────┘
```

---

## Core Components (u)

### 1. Oracle Module (`src/modules/HyperCoreOracleModule.sol`)
Reads prices directly from HyperCore via precompile (`0x0000000000000000000000000000000000000807`). Caches snapshots for quote validation.

### 2. Dynamic Fee Module (`src/modules/DynamicFeeModule.sol`)
Fees scale with pool imbalance:
```
fee = 0.3% + sqrt(imbalance_ratio) * 0.1%
```
Balanced pool → low fees. Imbalanced → higher fees incentivize arbitrage.

### 3. HOT ALM (`src/modules/HOTAMM.sol`)
Constant product AMM (x*y=k) implementing Valantis ISovereignALM interface.

### 4. Quote Validator (`src/quote/QuoteValidator.sol`)
Rejects swaps if execution price deviates >X% from oracle snapshot. No signatures needed — oracle is public consensus data.

### 5. Lending Orchestrator (`src/orchestrator/LendingOrchestrator.sol`)
Moves excess reserves to HyperCore staking via CoreWriter (`0x3333333333333333333333333333333333333333`). Actions execute async (2-3 seconds).

---

## Project Structure

```
├── src/
│   ├── interfaces/           # Contract interfaces
│   │   ├── IOracleModule.sol
│   │   ├── IQuoteValidator.sol
│   │   └── ILendingOrchestrator.sol
│   ├── modules/              # Core AMM modules
│   │   ├── HyperCoreOracleModule.sol
│   │   ├── DynamicFeeModule.sol
│   │   └── HOTAMM.sol
│   ├── quote/                # Quote validation
│   │   └── QuoteValidator.sol
│   └── orchestrator/         # Capital allocation
│       └── LendingOrchestrator.sol
├── test/
│   ├── mocks/                # Test mocks
│   ├── modules/              # Module unit tests
│   ├── quote/                # Quote validator tests
│   ├── orchestrator/         # Orchestrator tests
│   └── E2E.t.sol             # Integration tests
├── scripts/
│   └── deploy.ts             # Hardhat deployment
├── lib/
│   ├── hyper-evm-lib/        # Precompile & CoreWriter utilities
│   └── valantis-core/        # Sovereign Pool framework
├── foundry.toml              # Foundry config
├── hardhat.config.ts         # Hardhat config
└── HYPE AMM.md               # Full whitepaper
```

---

## How to Run

### Prerequisites
- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- [Node.js](https://nodejs.org/) v18+
- Hyperliquid testnet RPC: `https://rpc.hyperliquid-testnet.xyz/evm`


### Install
```bash
git clone <repo>
cd Hype-AMM
forge install
npm install  # For Hardhat deployment
```

### Build
```bash
forge build
```

### Test
```bash
forge test -vvv
```

### Deploy (Testnet via Hardhat)
```bash
cp .env.example .env
# Edit .env with your private key and RPC URL
npx hardhat run scripts/deploy.ts --network hyperliquid_testnet
```

### Deploy (Testnet via Foundry)
```bash
forge script script/Deploy.s.sol --rpc-url https://rpc.hyperliquid-testnet.xyz/evm --broadcast
```

---

## Constants

| Name | Value |
|------|-------|
| CoreWriter | `0x3333333333333333333333333333333333333333` |
| HYPE System Address | `0x2222222222222222222222222222222222222222` |
| HYPE Token Index | 1105 |
| USDC Token Index | 0 |
| Testnet Chain ID | 998 |
| Mainnet Chain ID | 999 |

---

## Why Hyperliquid?

- **Precompiles**: Direct on-chain oracle reads (~2k gas). No Chainlink, no keepers.
- **CoreWriter**: Trustless cross-layer actions. Move capital to staking without bridges.
- **HyperBFT**: ~100ms block times. Fast enough for reactive systems.
- **Fair ordering**: Prevents order-flow MEV at consensus level.

---

## Security Notes

1. **Oracle manipulation** — Mitigated by HyperBFT consensus (can't be spiked by individual swaps)
2. **Stale quotes** — Explicit block expiration + oracle validation
3. **Rebalancing spam** — Strategist-only, cooldown enforced, max amount capped
4. **CoreWriter failures** — Actions are async; failures don't lose capital (stays in AMM)

---

## Documentation

- [Full Whitepaper](./HYPE%20AMM.md) — Architecture, security analysis, competitive comparison
- [Valantis Docs](https://docs.valantis.xyz/design-space) — Sovereign Pool framework
- [Hyperliquid Precompiles](http://defiplot.com/blog/hyperliquid-precompiles-and-corewriter/) — Technical deep-dive
- [hyper-evm-lib](./lib/hyper-evm-lib/README.md) — Precompile & CoreWriter library

---

## License

MIT
