Deterministic Execution Architecture: Re-Engineering V-HLE for Fill-or-Kill on HyperEVM1. IntroductionThe decentralized finance (DeFi) ecosystem currently operates predominantly on a probabilistic execution paradigm. In the standard Automated Market Maker (AMM) model, users submit transactions expressing an intent to trade, but the final execution price is indeterminate at the moment of submission. To accommodate the asynchronous nature of blockchain state updates and the inherent latency between transaction signing and block inclusion, protocols have normalized the concept of "slippage tolerance"—a user-authorized margin of error that permits the protocol to execute trades at a price worse than the quoted market rate. While this mechanism ensures high transaction success rates in benign market conditions, it structurally embeds value leakage into the core of DeFi execution. It invites adversarial actors, specifically Maximum Extractable Value (MEV) searchers, to exploit this authorized variance through sandwich attacks and front-running, effectively taxing liquidity takers and degrading the quality of on-chain execution.This report presents a comprehensive architectural framework for re-engineering the Valantis Hyper Liquid Engine (V-HLE) protocol to abandon this probabilistic model in favor of a deterministic "Fill-or-Kill" (FoK) execution logic. By leveraging the unique dual-layer topology of the Hyperliquid network—specifically the low-latency interoperability between the HyperCore Layer 1 (L1) order book and the HyperEVM Layer 2 (L2) smart contract environment—we propose a system where execution is binary. A user's trade is either executed at the exact price they quoted, or it is atomically reverted.The proposed architecture introduces a fundamental shift in the role of the smart contract. Rather than passively accepting any trade that falls within a slippage bound, the V-HLE smart contract becomes an active gatekeeper. It utilizes L1Read precompiles to atomically verify local AMM prices against the global "truth" of the HyperCore L1 order book. Furthermore, it integrates an on-chain Two-Speed Exponentially Weighted Moving Average (EWMA) Volatility Oracle to detect market turbulence and volume anomalies, rejecting "toxic flow" that attempts to arbitrage stale AMM states against rapidly moving external markets. Crucially, this architecture inverts the economics of slippage: any positive deviation between the user's quoted price and the AMM's available price is not leaked to arbitragers but captured by the protocol as surplus, creating a new, sustainable revenue stream for liquidity providers.The following sections provide an exhaustive technical analysis of this re-architecture, detailing the integration of HyperEVM precompiles, the mathematical formulation of the volatility gating logic, the modular implementation within the Valantis Sovereign Pool framework, and the game-theoretic implications of surplus capture.2. The Deterministic Execution ParadigmTo appreciate the necessity of the Fill-or-Kill (FoK) model, one must first deconstruct the limitations of the incumbent "Slippage Tolerance" model and analyze how the FoK paradigm—borrowed from high-frequency traditional finance—can be adapted for the atomic environment of a smart contract.2.1 The Structural Inefficiencies of Slippage ToleranceIn the dominant Constant Product Market Maker (CPMM) design (e.g., Uniswap V2) and its concentrated liquidity successors (e.g., Uniswap V3), the user interaction model is inherently defensive. A user observes a price $P_{quote}$ in the frontend interface. However, recognizing that the on-chain state may change before their transaction is mined, they submit a transaction with a parameter amountOutMin, calculated as $P_{quote} \times (1 - \text{tolerance})$.This amountOutMin parameter functions as a pre-signed permission slip for value extraction. If a user sets a 1% slippage tolerance in a stable market, they are explicitly allowing the protocol (and any observer of the mempool) to give them 1% less value than the market rate. In an adversarial environment, MEV searchers automate the extraction of this value. By observing a pending transaction with a wide slippage tolerance, a searcher can "sandwich" the user—buying the asset immediately before the user to push the price up to the amountOutMin limit, and then selling immediately after to capture the difference. The user receives the worst possible price they authorized, and the "slippage" they tolerated becomes realized loss.Furthermore, this model creates execution uncertainty. The user does not know the final settlement price until the transaction is confirmed. In institutional contexts or complex hedging strategies, this uncertainty is unacceptable. A delta-neutral strategy, for example, relies on precise entry and exit prices; slippage introduces a delta drift that can break the hedge.2.2 The Fill-or-Kill (FoK) MechanismIn traditional central limit order books (CLOBs), a Fill-or-Kill order is a directive to execute a transaction immediately and completely at a specific limit price or better, or to cancel the order entirely.1 There are no partial fills, and there is no pricing ambiguity.Adapting this to the V-HLE smart contract environment requires a redefinition of "Kill." In a blockchain context, "Kill" translates to a transaction revert. The logic flow shifts from "Execute if $P_{exec} \geq P_{min}$" to "Execute if and only if $P_{exec} == P_{target}$ and Market Conditions are Valid."2.2.1 The Exact Price FlowIn the re-architected V-HLE, the user serves as a "Maker of Intent." They sign a transaction payload that specifies a targetPrice. This is not a minimum; it is the exact exchange rate the user agrees to.Submission: User submits "Buy 1 ETH at 2500 USDC."Verification: The contract checks if it can source 1 ETH for at most 2500 USDC.Execution: If the AMM can source 1 ETH for 2490 USDC (due to internal liquidity dynamics), the contract executes the swap. The user receives their 1 ETH at an effective cost of 2500 USDC. The 10 USDC difference is the Surplus.Rejection: If the AMM requires 2501 USDC to source the liquidity, or if the external market validation fails, the transaction reverts.This binary outcome ensures that the user never experiences negative slippage. Their trade is either successful at the agreed price, or it effectively never happened.2.3 Economic Inversion: Surplus CaptureThe most profound implication of this shift is the capture of "positive slippage." In the standard model, if a user submits a trade with 1% slippage but the market moves 1% in their favor, the AMM gives them the better price. While this seems beneficial, in practice, this positive slippage is often arbitraged away by back-running bots before the user can capture it, or it simply represents missed revenue for the Liquidity Provider (LP).By enforcing "Exact Price" execution, V-HLE captures this value. If the user is willing to pay 2500, and the AMM can provide it at 2490, the 10 USDC surplus is retained by the protocol. This mechanism:Monetizes Latency: It captures the value of the price information asymmetry between the user's submission time and the block's execution time.Protects LPs: It effectively acts as a dynamic fee. In volatile markets where spreads widen, the surplus capture increases, compensating LPs for the increased risk of holding inventory.Eliminates Sandwich Incentives: Since the execution price is fixed at the targetPrice, sandwich attackers cannot force the user's execution price lower. There is no amountOutMin gap to exploit.3. Hyperliquid Infrastructure AnalysisThe feasibility of this Fill-or-Kill architecture rests entirely on the capabilities of the underlying blockchain infrastructure. Generic EVM chains (like Ethereum Mainnet or Arbitrum) are unsuitable for this strict atomic verification due to the disconnect between on-chain oracle updates and real-time market data. Hyperliquid, however, employs a dual-layer architecture that bridges this gap.3.1 The Dual-Layer Topology: HyperCore and HyperEVMHyperliquid is built on a high-performance Layer 1 blockchain powered by HyperBFT, a custom consensus algorithm optimized for low latency and high throughput.3 This L1, known as HyperCore, hosts a fully on-chain CLOB (Central Limit Order Book). It is written in Rust and processes orders with sub-second finality, serving as the "backend" liquidity engine.Running in parallel is the HyperEVM, an Ethereum Virtual Machine compatible execution layer. Crucially, these two layers share the same validator set and consensus sequence. This allows for a unique interoperability feature: the HyperEVM can "read" the state of the HyperCore synchronously.3.2 The L1Read Precompile InterfaceThe bridge between HyperEVM smart contracts and HyperCore market data is implemented via Precompiles. These are special smart contract addresses that do not contain EVM bytecode but instead trigger the validator client to execute native code and return data from the HyperCore state.5The most critical precompile for the V-HLE FoK architecture is the Oracle Price Precompile, located at address 0x...807.Table 1: Key HyperEVM Precompile AddressesPrecompile NameAddressFunctionalityRelevance to V-HLEOracle Price0x...807Returns spot/perp oracle pricesPrimary Truth Source for VerificationPerp Asset Info0x...803Returns metadata (decimals, volume)Decimals Normalization & Asset IDSpot Balance0x...801Returns token balances on L1Bridging verification (if needed)3.2.1 Technical Mechanics of the Read OperationWhen a Solidity contract invokes a staticcall to 0x...807, the following sequence occurs atomically within the transaction execution trace:Invocation: The EVM halts bytecode execution and passes control to the validator's native execution client.State Lookup: The validator queries its local copy of the HyperCore state (which is guaranteed to be up-to-date for the current block height).Injection: The validator injects the requested data (e.g., the price of BTC) back into the EVM stack.Resumption: The EVM resumes execution with the returned data.This process incurs a fixed gas cost (approx. 2000 gas + overhead 5), which is negligible compared to the cost of storage reads on standard EVM chains. This efficiency enables V-HLE to query the L1 oracle for every single swap, essentially treating the L1 order book as a real-time reference oracle with zero latency relative to the block execution time.3.3 Data Normalization ChallengesDirect integration requires handling the specific data formats of HyperCore.Decimals: HyperCore prices are not standard 18-decimal fixed-point numbers. Perpetual futures prices are typically returned with 6 decimals ($10^6$), while spot prices often use 8 decimals ($10^8$).5Asset Indexing: HyperCore identifies assets by a uint32 index, not by their ERC20 contract address.The V-HLE architecture must therefore include an Adapter Layer that maps EVM token addresses to HyperCore asset indices and normalizes all values to the standard 18-decimal format (WAD) required for AMM mathematics.4. Re-Architecting V-HLE: The Modular FrameworkThe V-HLE implementation utilizes the Valantis protocol's modular "Sovereign Pool" design. Unlike monolithic AMMs where pricing, fees, and safety logic are hardcoded into a single contract, Valantis decouples these functions into interchangeable modules.6 This modularity is what makes the implementation of a complex FoK logic feasible without rewriting the core pool storage contract.4.1 System OverviewThe re-architected V-HLE system consists of three primary custom modules that replace the standard Valantis counterparts:The L1 Oracle Verifier (L1OracleVerifier): This module acts as the pre-swap gatekeeper. It enforces the "Kill" conditions by checking the L1Read price and the Volatility Oracle. It replaces the standard IVerifierModule.The Surplus Capture ALM (SurplusCaptureALM): This is the Algorithmic Liquidity Module. It replaces the standard SovereignALM (or HOT AMM). It calculates the swap amounts, enforcing the "Exact Price" constraint and effectively "skimming" the surplus tokens into the protocol reserves.The Volatility Oracle (TwoSpeedVolatility): A helper contract (or internal library within the Verifier) that tracks the Two-Speed EWMA metrics.4.2 Module 1: The L1 Oracle VerifierThe Verifier Module is the first line of defense. In the Valantis lifecycle, the verifySwap function is called before any liquidity calculations occur.Responsibilities:Context Decoding: It unpacks the swapContext passed by the user, which contains the targetPrice and the tokenIndex for the L1 lookup.Atomic L1 Verification: It calls the L1Read precompile.Deviation Check: It compares the L1Price against the user's targetPrice.Constraint: $| P_{L1} - P_{target} | / P_{L1} < \delta_{safe}$Here, $\delta_{safe}$ is a safety band (e.g., 0.1%). This is not slippage. It is a tolerance for the natural spread between the L1 CLOB (Spot/Perp) and the L2 AMM. If the user is quoting a price that is totally disconnected from the L1 reality, the trade is rejected as "Invalid" or "Stale."Volatility Gating: It queries the Volatility Oracle. If the market is in a "Turbulent" state (high volatility or volume anomaly), the trade is rejected.4.3 Module 2: The Surplus Capture ALMThe ALM contains the pricing math (the bonding curve). In a standard HOT AMM or Uniswap pool, the ALM returns the maximum output the pool can give. In the Surplus Capture ALM, we introduce a clamping logic.Logic Flow:Calculate Theoretical Output: $Out_{theoretical} = \text{BondingCurve}(In_{user})$.Calculate Target Output: $Out_{target} = In_{user} \times P_{target}$.Sufficiency Check:If $Out_{theoretical} < Out_{target}$, the pool cannot afford the user's price. REVERT ("Insufficient Liquidity").Surplus Capture:If $Out_{theoretical} \geq Out_{target}$:The User is sent exactly $Out_{target}$.The Pool retains $Out_{theoretical} - Out_{target}$.This retained amount is added to the fee growth accumulators or simply left in the reserves to appreciate the LP token value.4.4 Module 3: The Volatility OracleThis is a persistent state machine that updates on every interaction. It ensures that the "Kill" switch is not just based on price level, but on market dynamics. This is detailed in the next section.5. The Volatility and Volume OracleA simple price check is insufficient for robust safety. During a flash crash or a manipulative pump-and-dump event, the "Spot" price might momentarily align with a stale target price, allowing a user to exit a toxic position at the expense of LPs. To prevent this, V-HLE implements a Two-Speed EWMA (Exponentially Weighted Moving Average) Volatility Oracle.75.1 Mathematical Foundation: EWMAThe EWMA is chosen over simple moving averages (SMA) because it is gas-efficient (requiring only one storage slot per average) and reacts faster to recent data.The update formula for the oracle at block $t$ is:$$\mu_t = \alpha \cdot p_t + (1 - \alpha) \cdot \mu_{t-1}$$Where:$\mu_t$ is the current average.$p_t$ is the current L1Read price.$\alpha$ (alpha) is the smoothing factor ($0 < \alpha \leq 1$).5.2 Two-Speed ArchitectureThe oracle maintains two separate EWMA lines for each asset 8:Fast Filter ($\alpha_{fast} \approx 0.2$): This filter places ~80% of its weight on the most recent few blocks. It tracks the instantaneous market price very closely, reacting immediately to spikes or crashes.Slow Filter ($\alpha_{slow} \approx 0.01$): This filter places weight over a much longer period (approx. 100 blocks). It represents the "established" or "trend" price.Volatility Metric ($V$):We define volatility not as standard deviation (which is expensive to compute on-chain), but as the Normalized Divergence between the fast and slow filters:$$V_t = \frac{| \mu_{fast, t} - \mu_{slow, t} |}{\mu_{slow, t}}$$5.3 Volume Proxy LogicThe original request requires integrating Volume metrics. While HyperCore precompiles do not explicitly return a "24h Volume" integer, we can derive a Volume Proxy through the L1Read interface by observing the magnitude of price updates and potentially the "Open Interest" or "Liquidity Depth" if available via perpAssetInfo.5However, high volume is almost inextricably linked to high volatility (turbulence). In the absence of a direct "Trade Count" precompile, we use the Rate of Change (RoC) of the Fast EWMA as a proxy for Volume/Market Activity.Volume/Activity Metric ($A$):$$A_t = \frac{| p_t - p_{t-1} |}{p_{t-1}}$$If the price is jumping significantly between blocks, it implies high volume execution on the L1 order book is clearing levels.5.4 The Gating Logic (The "Kill" Condition)The Verifier Module combines these metrics into a binary "Safe/Unsafe" flag.Revert Condition:Transaction reverts if:$$(V_t > V_{threshold}) \quad \lor \quad (A_t > A_{threshold})$$$V_{threshold}$: e.g., 50 basis points (0.5%). If the fast trend deviates more than 0.5% from the slow trend, the market is trending too aggressively.$A_{threshold}$: e.g., 20 basis points (0.2%) per block. If the price jumps more than 0.2% in a single block, it implies a shock event.This logic effectively "freezes" the AMM during moments of extreme chaos, preventing LPs from selling assets at prices that might be stale milliseconds later. It forces users to wait for the filters to converge (market stabilization) before their "Fill" can be executed.6. Technical Implementation DetailsThis section provides the concrete Solidity logic required to implement the architecture described above. We utilize the Solady library for gas-optimized fixed-point arithmetic.106.1 The L1 Oracle AdapterFirst, we define the interface to the HyperCore precompiles and the normalization logic.Solidity// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// Solady for optimized math
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

interface IHyperCoreOracle {
    // Address: 0x...807
    function oraclePx(uint32 tokenIndex) external view returns (uint256);
}

library L1OracleAdapter {
    address constant ORACLE_PRECOMPILE = 0x0000000000000000000000000000000000000807;

    function getNormalizedPrice(uint32 tokenIndex, bool isSpot) internal view returns (uint256) {
        // Static call to precompile
        (bool success, bytes memory data) = ORACLE_PRECOMPILE.staticcall(
            abi.encode(tokenIndex)
        );
        require(success, "L1Read Failed");

        uint256 rawPrice = abi.decode(data, (uint256));

        // HyperCore decimals: Spot = 8, Perps = 6
        // Target: WAD (18)
        if (isSpot) {
            return rawPrice * 1e10; 
        } else {
            return rawPrice * 1e12;
        }
    }
}
6.2 The Volatility Oracle ContractThis contract maintains the state of the EWMAs. It is updated during every swap.Soliditycontract VolatilityOracle {
    using FixedPointMathLib for uint256;

    struct VolatilityState {
        uint128 fastFilter;
        uint128 slowFilter;
        uint256 lastPrice;
    }

    // Mapping: Token Index -> State
    mapping(uint32 => VolatilityState) public states;

    // Constants (WAD)
    uint256 constant ALPHA_FAST = 0.2e18; 
    uint256 constant ALPHA_SLOW = 0.01e18;
    
    // Thresholds
    uint256 constant VOL_THRESHOLD = 0.005e18; // 0.5% divergence
    uint256 constant ACTIVITY_THRESHOLD = 0.002e18; // 0.2% per update

    function updateAndCheck(uint32 tokenIndex, uint256 currentPrice) external returns (bool) {
        VolatilityState storage s = states[tokenIndex];
        
        // Initialize if empty
        if (s.fastFilter == 0) {
            s.fastFilter = uint128(currentPrice);
            s.slowFilter = uint128(currentPrice);
            s.lastPrice = currentPrice;
            return true;
        }

        uint256 prevFast = uint256(s.fastFilter);
        uint256 prevSlow = uint256(s.slowFilter);

        // 1. Check Activity (Volume Proxy)
        // |Price - LastPrice| / LastPrice
        uint256 priceDelta = currentPrice > s.lastPrice? 
                             currentPrice - s.lastPrice : 
                             s.lastPrice - currentPrice;
        
        if (priceDelta.divWadDown(s.lastPrice) > ACTIVITY_THRESHOLD) {
            return false; // Kill: Activity too high
        }

        // 2. Update EWMAs
        // fast = price*alpha + prev*(1-alpha)
        uint256 newFast = currentPrice.mulWadDown(ALPHA_FAST) + 
                          prevFast.mulWadDown(FixedPointMathLib.WAD - ALPHA_FAST);
        
        uint256 newSlow = currentPrice.mulWadDown(ALPHA_SLOW) + 
                          prevSlow.mulWadDown(FixedPointMathLib.WAD - ALPHA_SLOW);

        s.fastFilter = uint128(newFast);
        s.slowFilter = uint128(newSlow);
        s.lastPrice = currentPrice;

        // 3. Check Volatility
        // |Fast - Slow| / Slow
        uint256 volDelta = newFast > newSlow? newFast - newSlow : newSlow - newFast;
        if (volDelta.divWadDown(newSlow) > VOL_THRESHOLD) {
            return false; // Kill: Volatility too high
        }

        return true; // Fill: Market safe
    }
}
6.3 The Surplus Capture Logic (ALM)This segment effectively "overrides" the standard getLiquidityQuote logic in Valantis.6Solidity// Inside SurplusCaptureALM.sol

function onSwap(
    SovereignPoolSwapParams calldata params,
    //... other args
) external returns (uint256 amountOut, uint256 surplus) {
    
    // 1. Decode Context
    (uint256 targetPrice, uint32 tokenIndex) = abi.decode(
        params.swapContext, (uint256, uint32)
    );

    // 2. Verify L1 (External call to Verifier/Oracle)
    // In practice, this is done in the Verifier module, but ALM doubles checks the math
    
    // 3. Calculate Theoretical Output (Standard AMM Math)
    uint256 theoreticalOut = calculateAMMOutput(params.amountIn,...);
    
    // 4. Calculate Required Output (User Intent)
    // required = amountIn * targetPrice (adjusted for decimals)
    uint256 requiredOut = params.amountIn.mulWadDown(targetPrice);

    // 5. Fill or Kill Check
    if (theoreticalOut < requiredOut) {
        revert("FoK: Insufficient Liquidity");
    }

    // 6. Surplus Capture
    surplus = theoreticalOut - requiredOut;
    amountOut = requiredOut; // User gets exactly what they asked for

    // 7. Update Internal State
    // The pool keeps 'surplus' in its balance but owes user 'amountOut'
    // Effectively, the K-constant of the pool grows by 'surplus'
    _updateReserves(params.amountIn, theoreticalOut); // Burn full amount from curve logic
    
    return (amountOut, surplus);
}
7. Economic Implications and Game TheoryThe shift to a Surplus Capture model fundamentally alters the incentive structure for all participants in the V-HLE ecosystem.7.1 Arbitrage Dynamics: The "Anti-Arb" MechanismIn a standard AMM, arbitrageurs (arbs) are essential but parasitic. They align the AMM price with the global market, but they extract value from LPs to do so. They buy when the AMM is cheap and sell when it is expensive, capturing the spread.In the V-HLE FoK model, the "Exact Price" constraint coupled with L1 Verification effectively creates an Anti-Arb mechanism.If the AMM price lags behind the L1 price (e.g., AMM is cheap), an arb cannot buy the asset at the cheap AMM price.The L1OracleVerifier will see that the L1 price has moved.If the Arb submits the "Cheap" price as their targetPrice, the Verifier rejects it because it deviates from the L1 price.If the Arb submits the "Correct" L1 price as their targetPrice, the AMM executes the trade, but the Surplus Capture mechanism strips the profit. The AMM sells at the cheap internal price but charges the Arb the expensive L1 price, keeping the difference.Result: The value that usually goes to Arbs is internalized by the Protocol/LPs. The AMM price aligns with L1 not through extraction, but through "taxed" alignment.7.2 Toxic Flow Mitigation"Toxic Flow" refers to orders that have high adverse selection—trades executed by informed actors (like HFT firms) who know the price is about to change.The Two-Speed Volatility Oracle serves as a shield against this. HFT strategies typically rely on volatility spikes or momentum ignition. By detecting the divergence between Fast and Slow EWMAs, V-HLE shuts the door exactly when these predatory flows are most active. This preserves LP inventory for "uninformed" or "retail" flow, which is statistically more profitable for market makers.7.3 User IncentivesFor the retail user, the FoK model offers a superior UX: Certainty.No "Bad Fills": A user never looks at a transaction and wonders, "Why did I get 1% less than I expected?"Trust: The protocol guarantees the price.Trade-off: The revert rate will be higher. During chaotic market conditions, users will see "Transaction Failed: Market Volatile." While frustrating, this is financially protective, preventing them from entering positions at distorted prices.8. Risks and Future Outlook8.1 The Availability Risk (DoS)The strictness of the L1Read verification means that if the HyperCore L1 goes offline or experiences extreme latency, the V-HLE L2 pools become unusable.Mitigation: The protocol could implement a "Fallback Mode" (triggered by governance or a circuit breaker) that reverts to standard Slippage logic if the L1 Oracle is stale for > 10 blocks.8.2 Oracle Latency and Block TimesHyperEVM blocks are produced roughly every 1 second.11 HyperCore orders match in milliseconds. There is a theoretical window where the L1 price moves, but the EVM block has not yet been constructed.Analysis: Since the L1Read happens during block construction, the data is fresh. The risk is not stale data, but Sequencer Ordering. A validator could theoretically reorder transactions to maximize surplus capture for the protocol (which is arguably aligned with LP interests, unlike sandwiching which hurts LPs).8.3 Future Integration: Intent SolversThe FoK architecture naturally complements "Intent-Based" architectures (e.g., UniswapX, CowSwap). Solvers can treat V-HLE as a deterministic liquidity source. A Solver knows exactly what price V-HLE will give (the L1 price). This makes V-HLE a preferred venue for Solvers who need guaranteed execution to settle their own off-chain bundles.9. ConclusionThe re-architecture of the V-HLE protocol to a Fill-or-Kill execution model represents a definitive maturation of DeFi market structure. By abandoning the primitive and exploitable "Slippage Tolerance" model, V-HLE leverages the unique, high-performance capabilities of the Hyperliquid dual-layer stack to offer institutional-grade execution certainty.The integration of the Atomic L1 Oracle Verifier, the Two-Speed Volatility/Volume Gate, and the Surplus Capture ALM creates a synergistic system where:Users gain price certainty.LPs gain revenue from surplus and protection from toxic flow.The Protocol internalizes value that was previously leaked to MEV and arbitrageurs.This architecture serves as a blueprint for the next generation of L1-integrated DeFi applications, proving that with the right infrastructure, smart contracts can enforce "Best Execution" rather than just "Available Execution."