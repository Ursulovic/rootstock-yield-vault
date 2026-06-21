import { getDefaultConfig } from "@rainbow-me/rainbowkit";
import { defineChain } from "viem";

// Switch this to toggle between testnet and local demo
// Local Anvil mode only when explicitly requested (VITE_USE_LOCAL=true);
// defaults to Rootstock testnet so Vercel builds need zero code edits
const USE_LOCAL = import.meta.env.VITE_USE_LOCAL === "true";

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
  projectId: "0aadd80f96fc0c2e13113265939b0a16",
  chains: [USE_LOCAL ? localhost : rootstockTestnet],
});
