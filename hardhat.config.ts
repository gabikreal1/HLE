import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "dotenv/config";

const PRIVATE_KEY = process.env.PRIVATE_KEY || "0x0000000000000000000000000000000000000000000000000000000000000001";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      viaIR: false,
    },
  },
  
  networks: {
    // Hyperliquid Testnet
    hyperliquid_testnet: {
      url: "https://rpc.hyperliquid-testnet.xyz/evm",
      chainId: 998,
      accounts: [PRIVATE_KEY],
      gasPrice: "auto",
    },
    
    // Hyperliquid Mainnet
    hyperliquid_mainnet: {
      url: "https://rpc.hyperliquid.xyz/evm",
      chainId: 999,
      accounts: [PRIVATE_KEY],
      gasPrice: "auto",
    },
    
    // Local Hardhat for testing
    hardhat: {
      chainId: 31337,
      forking: {
        url: "https://rpc.hyperliquid-testnet.xyz/evm",
        enabled: false, // Enable for fork testing
      },
    },
  },
  
  paths: {
    sources: "./src",
    tests: "./test/hardhat",
    cache: "./cache_hardhat",
    artifacts: "./artifacts",
  },
  
  // TypeChain config for type-safe contract interactions
  typechain: {
    outDir: "typechain-types",
    target: "ethers-v6",
  },
  
  // Gas reporter for deployment cost analysis
  gasReporter: {
    enabled: process.env.REPORT_GAS === "true",
    currency: "USD",
    coinmarketcap: process.env.COINMARKETCAP_API_KEY,
  },
  
  // Mocha test settings
  mocha: {
    timeout: 100000,
  },
};

export default config;
