const USE_LOCAL = true;

const LOCAL = {
  // rBTC vault
  WRBTC: "0x5FbDB2315678afecb367f032d93F642f64180aa3",
  MOCK_KTOKEN: "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512",
  MOCK_ITOKEN: "0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0",
  RBTC_TROPYKUS: "0x5FC8d32690cc91D4c39d9d3abcBD16989F875707",
  RBTC_SOVRYN: "0x0165878A594ca255338adfa4d48449f69242Eb8F",
  RBTC_VAULT: "0xa513E6E4b8f2a923D98304ec87F64353C4D5C853",
  // DOC vault
  DOC: "0x8A791620dd6260079BF849Dc5567aDC3F2FdC318",
  DOC_TROPYKUS: "0x9A676e781A523b5d0C0e43731313A708CB607508",
  DOC_SOVRYN: "0x0B306BF915C4d645ff596e518fAf3F9669b97016",
  DOC_VAULT: "0x94099942864EA81cCF197E9D71ac53310b1468D8",
  // USDRIF vault
  USDRIF: "0x4ed7c70F96B99c776995fB64377f0d4aB3B0e1C1",
  USDRIF_TROPYKUS: "0x09635F643e140090A9A8Dcd712eD6285858ceBef",
  USDRIF_SOVRYN: "0xc5a5C42992dECbae36851359345FE25997F5C42d",
  USDRIF_VAULT: "0x06B1D212B8da92b83AF328De5eef4E211Da02097",
  // Factory
  FACTORY: "0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6",
};

const TESTNET = {
  RBTC_TROPYKUS: "0x140B97453EA36743E0445D9D20b8b8DBba84Bc7D",
  RBTC_SOVRYN: "0x9d11f1CDE3a777868771f4840B180dF454d2080F",
  RBTC_VAULT: "0x195ed3BfD52Fb2Fc8153d0b9905A37c63141e2c6",
};

const ADDR = USE_LOCAL ? LOCAL : TESTNET;

export const VAULTS = [
  {
    address: ADDR.RBTC_VAULT,
    type: "native",
    tokenSymbol: "rBTC",
    shareSymbol: "ryRBTC",
    adapters: {
      [ADDR.RBTC_TROPYKUS]: "Tropykus",
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
            [ADDR.DOC_TROPYKUS]: "Tropykus",
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
            [ADDR.USDRIF_TROPYKUS]: "Tropykus",
            [ADDR.USDRIF_SOVRYN]: "Sovryn",
          },
        },
      ]
    : []),
];

export const ADDRESSES = ADDR;
