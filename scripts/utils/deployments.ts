import * as fs from "fs";
import * as path from "path";

export interface DeploymentAddresses {
  token0?: string;
  token1?: string;
  sovereignPool?: string;
  hlealm?: string;
  hleQuoter?: string;
  lendingModule?: string;
  timestamp?: number;
  deployer?: string;
}

export interface Deployments {
  hardhat: DeploymentAddresses;
  hyperliquid_testnet: DeploymentAddresses;
  hyperliquid_mainnet: DeploymentAddresses;
  [key: string]: DeploymentAddresses;
}

const DEPLOYMENTS_PATH = path.join(__dirname, "../deployments/deployments.json");

/**
 * Load deployments from JSON file
 */
export function loadDeployments(): Deployments {
  try {
    const data = fs.readFileSync(DEPLOYMENTS_PATH, "utf8");
    return JSON.parse(data);
  } catch (error) {
    return {
      hardhat: {},
      hyperliquid_testnet: {},
      hyperliquid_mainnet: {},
    };
  }
}

/**
 * Save deployments to JSON file
 */
export function saveDeployments(deployments: Deployments): void {
  fs.writeFileSync(DEPLOYMENTS_PATH, JSON.stringify(deployments, null, 2));
}

/**
 * Get deployments for a specific network
 */
export function getNetworkDeployments(networkName: string): DeploymentAddresses {
  const deployments = loadDeployments();
  return deployments[networkName] || {};
}

/**
 * Update deployments for a specific network
 */
export function updateNetworkDeployments(
  networkName: string,
  addresses: Partial<DeploymentAddresses>
): void {
  const deployments = loadDeployments();
  deployments[networkName] = {
    ...deployments[networkName],
    ...addresses,
    timestamp: Date.now(),
  };
  saveDeployments(deployments);
}

/**
 * Clear deployments for a specific network
 */
export function clearNetworkDeployments(networkName: string): void {
  const deployments = loadDeployments();
  deployments[networkName] = {};
  saveDeployments(deployments);
}

/**
 * Check if all required contracts are deployed
 */
export function areContractsDeployed(networkName: string): boolean {
  const addresses = getNetworkDeployments(networkName);
  return !!(
    addresses.token0 &&
    addresses.token1 &&
    addresses.sovereignPool &&
    addresses.hlealm
  );
}

/**
 * Network name mapping for Hardhat
 */
export function getNetworkName(chainId: bigint): string {
  switch (chainId) {
    case 31337n:
      return "hardhat";
    case 998n:
      return "hyperliquid_testnet";
    case 999n:
      return "hyperliquid_mainnet";
    default:
      return "unknown";
  }
}
