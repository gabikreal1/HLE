import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "hardhat-preprocessor";
import "dotenv/config";
import fs from "fs";

const PRIVATE_KEY = process.env.PRIVATE_KEY || "0x0000000000000000000000000000000000000000000000000000000000000001";

// Read remappings from remappings.txt
function getRemappings() {
  return fs
    .readFileSync("remappings.txt", "utf8")
    .split("\n")
    .filter(Boolean)
    .map((line) => line.trim().split("="));
}

const config: HardhatUserConfig = {
  solidity: {
    compilers: [
      {
        version: "0.8.19",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
          viaIR: false,
        },
      },
    ],
    overrides: {
      // Force all Valantis contracts to use 0.8.19
      "node_modules/@valantis/valantis-core/src/**/*.sol": {
        version: "0.8.19",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
    },
  },
  
  networks: {
    hyperliquid_testnet: {
      url: "https://rpc.hyperliquid-testnet.xyz/evm",
      chainId: 998,
      accounts: [PRIVATE_KEY],
      gasPrice: "auto",
    },
    hyperliquid_mainnet: {
      url: "https://rpc.hyperliquid.xyz/evm",
      chainId: 999,
      accounts: [PRIVATE_KEY],
      gasPrice: "auto",
    },
    hardhat: {
      chainId: 31337,
      forking: {
        url: "https://rpc.hyperliquid-testnet.xyz/evm",
        enabled: false,
      },
    },
  },
  
  paths: {
    sources: "./src",
    tests: "./test/hardhat",
    cache: "./cache_hardhat",
    artifacts: "./artifacts",
    // Include Valantis sources for compilation
    // Note: Hardhat doesn't support multiple source folders directly,
    // but we can use the solidity settings to compile from node_modules
  },
  
  preprocess: {
    eachLine: (hre) => ({
      transform: (line: string) => {
        if (line.match(/^\s*import/)) {
          for (const [from, to] of getRemappings()) {
            if (line.includes(from)) {
              line = line.replace(from, to);
            }
          }
        }
        return line;
      },
    }),
  },
  
  typechain: {
    outDir: "typechain-types",
    target: "ethers-v6",
  },
  
  gasReporter: {
    enabled: process.env.REPORT_GAS === "true",
    currency: "USD",
    coinmarketcap: process.env.COINMARKETCAP_API_KEY,
  },
  
  mocha: {
    timeout: 100000,
  },
};

export default config;