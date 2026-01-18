import { ethers } from "hardhat";
import { updateNetworkDeployments, getNetworkName } from "./utils/deployments";

/**
 * HLE (Hyper Liquidity Engine) Deployment Script
 * 
 * Deploys the complete HLE system:
 * 1. Mock Tokens (for testing only)
 * 2. Sovereign Pool (from Valantis)
 * 3. HLEALM (spread-based pricing)
 * 4. HLEQuoter (on-chain quotes)
 * 5. LendingModule (yield optimization)
 * 
 * Usage:
 *   npx hardhat run scripts/deploy-hle.ts --network hardhat
 *   npx hardhat run scripts/deploy-hle.ts --network hyperliquid_testnet
 */

// Token indices for HyperCore (used for oracle price fetching)
const TOKEN0_INDEX = 0n;  // USDC index
const TOKEN1_INDEX = 1n;  // Token1 index

async function main() {
  const [deployer] = await ethers.getSigners();
  const { chainId } = await ethers.provider.getNetwork();
  const networkName = getNetworkName(chainId);
  
  console.log("╔════════════════════════════════════════════════════════════╗");
  console.log("║           HLE (Hyper Liquidity Engine) Deployment          ║");
  console.log("╚════════════════════════════════════════════════════════════╝\n");
  
  console.log(`Network: ${networkName} (chainId: ${chainId})`);
  console.log(`Deployer: ${deployer.address}`);
  const balance = await ethers.provider.getBalance(deployer.address);
  console.log(`Balance: ${ethers.formatEther(balance)} ETH\n`);

  // ═══════════════════════════════════════════════════════════════════════════
  // STEP 1: Deploy Mock Tokens (for testing/local only)
  // ═══════════════════════════════════════════════════════════════════════════
  
  console.log("Step 1: Deploying Mock Tokens...");
  
  const MockERC20 = await ethers.getContractFactory("MockERC20");
  
  // Deploy token0 (e.g., WETH)
  const token0 = await MockERC20.deploy("Wrapped Ether", "WETH", 18);
  await token0.waitForDeployment();
  const token0Address = await token0.getAddress();
  console.log(`  Token0 (WETH): ${token0Address}`);
  
  // Deploy token1 (e.g., USDC)
  const token1 = await MockERC20.deploy("USD Coin", "USDC", 18);
  await token1.waitForDeployment();
  const token1Address = await token1.getAddress();
  console.log(`  Token1 (USDC): ${token1Address}`);

  // Ensure token0 < token1 for Valantis ordering
  let finalToken0 = token0Address;
  let finalToken1 = token1Address;
  if (token0Address.toLowerCase() > token1Address.toLowerCase()) {
    finalToken0 = token1Address;
    finalToken1 = token0Address;
    console.log(`  Note: Swapped token order for Valantis compatibility`);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // STEP 2: Deploy Sovereign Pool
  // ═══════════════════════════════════════════════════════════════════════════
  
  console.log("\nStep 2: Deploying Sovereign Pool...");
  
  const SovereignPool = await ethers.getContractFactory("SovereignPool");
  
  // Construct pool args
  const poolArgs = {
    token0: finalToken0,
    token1: finalToken1,
    protocolFactory: deployer.address, // Using deployer as protocol factory for testing
    poolManager: deployer.address,
    sovereignVault: ethers.ZeroAddress, // Pool holds reserves itself
    verifierModule: ethers.ZeroAddress, // No verifier
    isToken0Rebase: false,
    isToken1Rebase: false,
    token0AbsErrorTolerance: 0,
    token1AbsErrorTolerance: 0,
    defaultSwapFeeBips: 0, // ALM handles fees
  };
  
  const sovereignPool = await SovereignPool.deploy(poolArgs);
  await sovereignPool.waitForDeployment();
  const poolAddress = await sovereignPool.getAddress();
  console.log(`  Sovereign Pool: ${poolAddress}`);

  // ═══════════════════════════════════════════════════════════════════════════
  // STEP 3: Deploy HLEALM
  // ═══════════════════════════════════════════════════════════════════════════
  
  console.log("\nStep 3: Deploying HLEALM...");
  
  const HLEALM = await ethers.getContractFactory("HLEALM");
  
  const hlealm = await HLEALM.deploy(
    poolAddress,
    TOKEN0_INDEX,
    TOKEN1_INDEX,
    deployer.address, // fee recipient
    deployer.address  // owner
  );
  await hlealm.waitForDeployment();
  const hlealmAddress = await hlealm.getAddress();
  console.log(`  HLEALM: ${hlealmAddress}`);

  // ═══════════════════════════════════════════════════════════════════════════
  // STEP 4: Deploy HLEQuoter
  // ═══════════════════════════════════════════════════════════════════════════
  
  console.log("\nStep 4: Deploying HLEQuoter...");
  
  const HLEQuoter = await ethers.getContractFactory("HLEQuoter");
  
  const hleQuoter = await HLEQuoter.deploy(poolAddress, hlealmAddress);
  await hleQuoter.waitForDeployment();
  const quoterAddress = await hleQuoter.getAddress();
  console.log(`  HLEQuoter: ${quoterAddress}`);

  // ═══════════════════════════════════════════════════════════════════════════
  // STEP 5: Deploy LendingModule
  // ═══════════════════════════════════════════════════════════════════════════
  
  console.log("\nStep 5: Deploying LendingModule...");
  
  const LendingModule = await ethers.getContractFactory("LendingModule");
  
  const lendingModule = await LendingModule.deploy(
    poolAddress,
    deployer.address, // strategist
    ethers.parseEther("0.01"), // min supply amount
    5 // cooldown blocks
  );
  await lendingModule.waitForDeployment();
  const lendingModuleAddress = await lendingModule.getAddress();
  console.log(`  LendingModule: ${lendingModuleAddress}`);

  // ═══════════════════════════════════════════════════════════════════════════
  // STEP 6: Configure Pool
  // ═══════════════════════════════════════════════════════════════════════════
  
  console.log("\nStep 6: Configuring Pool...");
  
  // Set ALM on pool
  const setAlmTx = await sovereignPool.setALM(hlealmAddress);
  await setAlmTx.wait();
  console.log(`  ALM set on pool ✓`);

  // ═══════════════════════════════════════════════════════════════════════════
  // STEP 7: Initialize HLEALM
  // ═══════════════════════════════════════════════════════════════════════════
  
  console.log("\nStep 7: Initializing HLEALM...");
  
  // Note: Initialize will fail without real precompiles
  // For local testing, we'll skip this or use a testable version
  if (chainId !== 31337n) {
    const initTx = await hlealm.initialize();
    await initTx.wait();
    console.log(`  HLEALM initialized ✓`);
  } else {
    console.log(`  Skipping initialize on local network (no precompiles)`);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SAVE DEPLOYMENTS
  // ═══════════════════════════════════════════════════════════════════════════
  
  console.log("\nSaving deployments...");
  
  updateNetworkDeployments(networkName, {
    token0: finalToken0,
    token1: finalToken1,
    sovereignPool: poolAddress,
    hlealm: hlealmAddress,
    hleQuoter: quoterAddress,
    lendingModule: lendingModuleAddress,
    deployer: deployer.address,
  });
  
  console.log(`  Deployments saved to deployments/deployments.json ✓`);

  // ═══════════════════════════════════════════════════════════════════════════
  // SUMMARY
  // ═══════════════════════════════════════════════════════════════════════════
  
  console.log("\n╔════════════════════════════════════════════════════════════╗");
  console.log("║                    Deployment Summary                       ║");
  console.log("╠════════════════════════════════════════════════════════════╣");
  console.log(`║ Token0:        ${finalToken0}   ║`);
  console.log(`║ Token1:        ${finalToken1}   ║`);
  console.log(`║ SovereignPool: ${poolAddress}   ║`);
  console.log(`║ HLEALM:        ${hlealmAddress}   ║`);
  console.log(`║ HLEQuoter:     ${quoterAddress}   ║`);
  console.log(`║ LendingModule: ${lendingModuleAddress}   ║`);
  console.log("╚════════════════════════════════════════════════════════════╝\n");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
