import hardhatToolboxViemPlugin from "@nomicfoundation/hardhat-toolbox-viem";
import { existsSync, readFileSync } from "node:fs";
import { configVariable, defineConfig } from "hardhat/config";

const besuAccounts = ["validator1", "validator2", "validator3", "validator4"]
  .map((name) => new URL(`./besu-test-network/config/nodes/${name}/accountPrivateKey`, import.meta.url))
  .filter((file) => existsSync(file))
  .map((file) => {
    const value = readFileSync(file, "utf8").trim().replace(/^0x/, "");
    if (!/^[0-9a-fA-F]{64}$/.test(value)) throw new Error("Invalid local Besu test account key");
    return `0x${value}`;
  });

export default defineConfig({
  plugins: [hardhatToolboxViemPlugin],
  solidity: {
    profiles: {
      default: {
        version: "0.8.34",
        settings: {
          evmVersion: "cancun",
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
      production: {
        version: "0.8.34",
        settings: {
          evmVersion: "cancun",
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
    },
  },
  networks: {
    besu: {
      type: "http",
      chainType: "l1",
      url: "http://127.0.0.1:8545",
      chainId: 1337,
      gasPrice: 0,
      accounts: besuAccounts,
    },
    hardhatMainnet: {
      type: "edr-simulated",
      chainType: "l1",
    },
    hardhatOp: {
      type: "edr-simulated",
      chainType: "op",
    },
    sepolia: {
      type: "http",
      chainType: "l1",
      url: configVariable("SEPOLIA_RPC_URL"),
      accounts: [configVariable("SEPOLIA_PRIVATE_KEY")],
    },
  },
});
