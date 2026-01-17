import { ethers } from "hardhat";

/**
 * HOT AMM Deployment Script
 * 
 * Deploys the complete HOT AMM system:
 * 1. Oracle Module (reads HyperCore prices)
 * 2. Dynamic Fee Module (imbalance-based fees)
 * 3. HOT ALM (CFMM pricing)
 * 4. Quote Validator (oracle-backed validation)
 * 5. Lending Orchestrator (capital allocation)
 * 
 * Prerequisites:
 * - Sovereign Pool deployed via Valantis Protocol Factory
 * - HYPE and USDC token addresses
 * - Validator address for staking
 */

// Hyperliquid Testnet Constants
const TESTNET_HYPE = "0x..."; // TODO: Replace with actual testnet HYPE address
const TESTNET_USDC = "0x2B3370eE501B4a559b57D449569354196457D8Ab";
const TESTNET_VALIDATOR = "0x..."; // TODO: Replace with validator address

// Hyperliquid Mainnet Constants  
const MAINNET_HYPE = "0x..."; // TODO: Replace with actual mainnet HYPE address
const MAINNET_USDC = "0xb88339CB7199b77E23DB6E890353E22632Ba630f";
const MAINNET_VALIDATOR = "0x..."; // TODO: Replace with validator address

interface DeploymentAddresses {
  pool: string;
  oracleModule: string;
  feeModule: string;
  alm: string;
  quoteValidator: string;
  lendingOrchestrator: string;
}

async function main() {
  const [deployer] = await ethers.getSigners();
  const chainId = (await ethers.provider.getNetwork()).chainId;
  
  console.log("Deploying HOT AMM contracts...");
  console.log("Deployer:", deployer.address);
  console.log("Chain ID:", chainId);
  console.log("Balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "HYPE");
  console.log("");

  // Get network-specific addresses
  const isTestnet = chainId === 998n;
  const hypeToken = isTestnet ? TESTNET_HYPE : MAINNET_HYPE;
  const usdcToken = isTestnet ? TESTNET_USDC : MAINNET_USDC;
  const validator = isTestnet ? TESTNET_VALIDATOR : MAINNET_VALIDATOR;

  // For this example, we'll deploy a mock pool
  // In production, use Valantis Protocol Factory
  console.log("Step 1: Deploying Mock Sovereign Pool...");
  const MockPool = await ethers.getContractFactory("MockSovereignPool");
  const pool = await MockPool.deploy(hypeToken, usdcToken);
  await pool.waitForDeployment();
  console.log("  Pool deployed to:", await pool.getAddress());

  // Deploy Oracle Module
  console.log("\nStep 2: Deploying HyperCore Oracle Module...");
  const OracleModule = await ethers.getContractFactory("HyperCoreOracleModule");
  const oracleModule = await OracleModule.deploy(await pool.getAddress());
  await oracleModule.waitForDeployment();
  console.log("  Oracle Module deployed to:", await oracleModule.getAddress());

  // Deploy Dynamic Fee Module
  console.log("\nStep 3: Deploying Dynamic Fee Module...");
  const FeeModule = await ethers.getContractFactory("DynamicFeeModule");
  const feeModule = await FeeModule.deploy(await pool.getAddress(), deployer.address);
  await feeModule.waitForDeployment();
  console.log("  Fee Module deployed to:", await feeModule.getAddress());

  // Deploy HOTAMM (ALM)
  console.log("\nStep 4: Deploying HOT ALM...");
  const ALM = await ethers.getContractFactory("HOTAMM");
  const alm = await ALM.deploy(await pool.getAddress(), deployer.address);
  await alm.waitForDeployment();
  console.log("  ALM deployed to:", await alm.getAddress());

  // Deploy Quote Validator
  console.log("\nStep 5: Deploying Quote Validator...");
  const QuoteValidator = await ethers.getContractFactory("QuoteValidator");
  const quoteValidator = await QuoteValidator.deploy(
    await pool.getAddress(),
    await oracleModule.getAddress(),
    deployer.address
  );
  await quoteValidator.waitForDeployment();
  console.log("  Quote Validator deployed to:", await quoteValidator.getAddress());

  // Deploy Lending Orchestrator
  console.log("\nStep 6: Deploying Lending Orchestrator...");
  const LendingOrchestrator = await ethers.getContractFactory("LendingOrchestrator");
  const lendingOrchestrator = await LendingOrchestrator.deploy(
    await pool.getAddress(),
    hypeToken,
    deployer.address,
    validator
  );
  await lendingOrchestrator.waitForDeployment();
  console.log("  Lending Orchestrator deployed to:", await lendingOrchestrator.getAddress());

  // Configure pool with modules
  console.log("\nStep 7: Configuring pool with modules...");
  
  // Set ALM on pool
  const setALMTx = await pool.setALM(await alm.getAddress());
  await setALMTx.wait();
  console.log("  ALM set on pool");

  // Set Fee Module on pool
  const setFeeTx = await pool.setSwapFeeModule(await feeModule.getAddress());
  await setFeeTx.wait();
  console.log("  Fee Module set on pool");

  // Set Oracle on pool
  const setOracleTx = await pool.setSovereignOracle(await oracleModule.getAddress());
  await setOracleTx.wait();
  console.log("  Oracle Module set on pool");

  // Summary
  const addresses: DeploymentAddresses = {
    pool: await pool.getAddress(),
    oracleModule: await oracleModule.getAddress(),
    feeModule: await feeModule.getAddress(),
    alm: await alm.getAddress(),
    quoteValidator: await quoteValidator.getAddress(),
    lendingOrchestrator: await lendingOrchestrator.getAddress(),
  };

  console.log("\n" + "═".repeat(60));
  console.log("DEPLOYMENT COMPLETE");
  console.log("═".repeat(60));
  console.log("\nDeployed Addresses:");
  console.log(JSON.stringify(addresses, null, 2));
  console.log("\n" + "═".repeat(60));

  // Write addresses to file
  const fs = await import("fs");
  const deploymentFile = `deployments/${chainId}.json`;
  fs.writeFileSync(deploymentFile, JSON.stringify(addresses, null, 2));
  console.log(`\nAddresses saved to ${deploymentFile}`);

  return addresses;
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
