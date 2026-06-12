const USE_LOCAL = true;

const LOCAL = {
  // rBTC vault
  WRBTC: "0x5FbDB2315678afecb367f032d93F642f64180aa3",
  MOCK_LBPOOL: "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512",
  MOCK_ITOKEN: "0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9",
  RBTC_LAYERBANK: "0x0165878A594ca255338adfa4d48449f69242Eb8F",
  RBTC_SOVRYN: "0xa513E6E4b8f2a923D98304ec87F64353C4D5C853",
  RBTC_VAULT: "0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6",
  // DOC vault
  DOC: "0x610178dA211FEF7D417bC0e6FeD39F05609AD788",
  DOC_LAYERBANK: "0x959922bE3CAee4b8Cd9a407cc3ac1C251C2007B1",
  DOC_SOVRYN: "0x9A9f2CCfdE556A7E9Ff0848998Aa4a0CFD8863AE",
  DOC_VAULT: "0x8aCd85898458400f7Db866d53FCFF6f0D49741FF",
  // USDRIF vault
  USDRIF: "0xa85233C63b9Ee964Add6F2cffe00Fd84eb32338f",
  USDRIF_LAYERBANK: "0xE6E340D132b5f46d1e472DebcD681B2aBc16e57E",
  USDRIF_SOVRYN: "0xc3e53F4d16Ae77Db1c982e75a937B9f60FE63690",
  USDRIF_VAULT: "0xe082b26cEf079a095147F35c9647eC97c2401B83",
  // Factory
  FACTORY: "0x8A791620dd6260079BF849Dc5567aDC3F2FdC318",
};

// LayerBank + Sovryn architecture, deployed 2026-06-12, verified on Blockscout
const TESTNET = {
  RBTC_LAYERBANK: "0x1bf916e2fe19183Ba06a33616b34B8876b575088",
  RBTC_SOVRYN: "0x2668857D675eAd4b4CAD7f7aBD9d99d77cbBdd94",
  RBTC_VAULT: "0x1881ff54d76C74Beb76C92B00781b54bFCD19647",
};

const ADDR = USE_LOCAL ? LOCAL : TESTNET;

export const VAULTS = [
  {
    address: ADDR.RBTC_VAULT,
    type: "native",
    tokenSymbol: "rBTC",
    shareSymbol: "ryRBTC",
    adapters: {
      [ADDR.RBTC_LAYERBANK]: "LayerBank",
      [ADDR.RBTC_SOVRYN]: "Sovryn",
    },
  },
  ...(USE_LOCAL
    ? [
        {
          address: ADDR.DOC_VAULT,
          type: "erc20",
          tokenAddress: ADDR.DOC,
          tokenSymbol: "DOC",
          shareSymbol: "ryDOC",
          adapters: {
            [ADDR.DOC_LAYERBANK]: "LayerBank",
            [ADDR.DOC_SOVRYN]: "Sovryn",
          },
        },
        {
          address: ADDR.USDRIF_VAULT,
          type: "erc20",
          tokenAddress: ADDR.USDRIF,
          tokenSymbol: "USDRIF",
          shareSymbol: "ryUSDRIF",
          adapters: {
            [ADDR.USDRIF_LAYERBANK]: "LayerBank",
            [ADDR.USDRIF_SOVRYN]: "Sovryn",
          },
        },
      ]
    : []),
];

export const ADDRESSES = ADDR;
