import { getDefaultConfig } from "@rainbow-me/rainbowkit";
import { defineChain } from "viem";

// Switch this to toggle between testnet and local demo
const USE_LOCAL = true;

const localhost = defineChain({
  id: 31337,
  name: "Anvil (Local)",
  nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: ["http://127.0.0.1:8545"] },
  },
});

const rootstockTestnet = defineChain({
  id: 31,
  name: "Rootstock Testnet",
  nativeCurrency: { name: "tRBTC", symbol: "tRBTC", decimals: 18 },
  rpcUrls: {
    default: { http: ["https://public-node.testnet.rsk.co"] },
  },
  blockExplorers: {
    default: {
      name: "Blockscout",
      url: "https://rootstock-testnet.blockscout.com",
    },
  },
});

export const config = getDefaultConfig({
  appName: "ryRBTC Yield Vault",
  projectId: "b1e8ad89a0d5cc25c12e0e65b0e1d84e",
  chains: [USE_LOCAL ? localhost : rootstockTestnet],
});
