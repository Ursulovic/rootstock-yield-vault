# Rootstock Yield Vault (ryRBTC)

An ERC-4626 yield optimizer vault for Rootstock. Deposits rBTC and routes it to whichever lending protocol (Tropykus or Sovryn) offers the best supply rate. A public `rebalance()` function lets anyone trigger fund reallocation and earn a small reward from accrued yield.

Built for Rootstock Builder Rootcamp Cohort 1 capstone.

## What the project does

Users deposit rBTC into the vault and receive ryRBTC shares. The vault deploys all funds to the lending protocol with the highest interest rate (Tropykus or Sovryn). When rates change, anyone can call `rebalance()` to move funds to the better protocol and earn 1% of accrued yield as a reward.

The project also includes a VaultFactory that can deploy ERC-20 yield vaults for other Rootstock tokens (DOC, USDRIF, etc.) using the same adapter pattern.

## Architecture

```
         ┌─────────────────────────────────┐
         │          YieldVault.sol          │
         │  (ERC-4626: shares, accounting) │
         │                                 │
         │  deposit / withdraw / rebalance │
         └──────────┬──────────┬───────────┘
                    │          │
           ┌────────▼──┐  ┌───▼─────────┐
           │ Tropykus  │  │   Sovryn    │
           │ Adapter   │  │   Adapter   │
           │           │  │             │
           │ mint()    │  │mintWithBTC()│
           │ redeem()  │  │burnToBTC()  │
           └────┬──────┘  └──────┬──────┘
                │                │
           ┌────▼──────┐  ┌─────▼───────┐
           │  kRBTC     │  │   iRBTC     │
           │ (Tropykus) │  │  (Sovryn)   │
           └────────────┘  └─────────────┘
```

At any time, only one adapter is active. All funds sit in one protocol. `rebalance()` moves everything to the other if the rate is better.

## Rules enforced

- **Minimum 2 adapters** required at construction
- **Rebalance cooldown**: 1 hour minimum between rebalances (prevents spam)
- **Rate threshold**: new rate must beat current by at least 0.05% APR (prevents pointless moves)
- **Caller reward cap**: maximum 5% of yield (set to 1% at deployment)
- **Withdrawals always work**: even when the vault is paused, users can exit
- **Adapter trust**: factory only deploys vaults with pre-approved adapters
- **Factory shutdown**: owner can permanently stop new vault creation if a bug is found
- **Guardian pause**: ERC-20 vaults can be paused by guardian to protect funds in emergencies

## Design choices

**Adapter pattern over direct integration**: Lending protocols on Rootstock use different interfaces (Tropykus is Compound V2, Sovryn is bZx). The adapter pattern abstracts these behind a unified interface, making it easy to add new protocols without changing the vault.

**Two vault types**: The rBTC vault (`YieldVault.sol`) handles native rBTC wrapping/unwrapping. The ERC-20 vault (`ERC20YieldVault.sol`) works with any ERC-20 token. This avoids a single complex contract trying to handle both patterns.

**Permissionless rebalance with incentives**: Instead of relying on a keeper or admin to rebalance, anyone can call `rebalance()` and earn 1% of yield as reward. This aligns incentives without centralization.

**No admin on rBTC vault**: The original rBTC vault has no owner, no pause, no upgrade path. Fully trustless by design. The ERC-20 vault adds a guardian for emergency pausing as a maturity improvement.

**SafeERC20 and infinite approvals**: All ERC-20 transfers use OpenZeppelin's SafeERC20. Adapters grant infinite approval to lending protocols at construction (saves ~15k-30k gas per deposit). The vault trusts its adapters implicitly since they only interact with pre-approved lending protocols.

**ERC-4626 compliance**: Both vaults implement the full ERC-4626 standard. The 3-decimal offset (`_decimalsOffset() = 3`) mitigates the inflation/first-depositor attack. `maxDeposit()` returns 0 when paused per spec.

## How it works

1. User deposits rBTC (or WRBTC). Vault wraps native rBTC and deploys it to the active lending protocol.
2. Anyone calls `rebalance()` when rates shift -- funds move to the better protocol, caller gets a cut of the yield earned since last rebalance.
3. User withdraws to get their rBTC + yield back.

## Contracts

### rBTC Vault
| Contract | Description |
|---|---|
| `YieldVault.sol` | ERC-4626 vault for native rBTC |
| `TropykusAdapter.sol` | Adapter for Tropykus kRBTC (Compound V2 pattern) |
| `SovrynAdapter.sol` | Adapter for Sovryn iRBTC (bZx pattern) |

### ERC-20 Vault System
| Contract | Description |
|---|---|
| `ERC20YieldVault.sol` | ERC-4626 vault for any ERC-20 token, with guardian pause |
| `VaultFactory.sol` | Deploys ERC-20 vaults with adapter validation and registry |
| `TropykusERC20Adapter.sol` | Adapter for Tropykus ERC-20 markets (kDOC, kUSDRIF) |
| `SovrynERC20Adapter.sol` | Adapter for Sovryn ERC-20 markets (iDOC, iXUSD) |

## Rootstock-specific considerations

- Block time is 30 seconds (not 12s like Ethereum)
- `blocksPerYear = 1,051,200` for rate normalization (matches Compound V2 convention)
- No EIP-1559 -- use `--legacy` flag for all transactions
- Tropykus uses `.transfer()` (2300 gas stipend) for rBTC sends -- adapter `receive()` must be empty
- Sovryn uses `mintWithBTC`/`burnToBTC` for native rBTC (not `mint`/`burn`)

## Deployed contracts (Testnet, Chain ID 31)

| Contract | Address | Verified |
|---|---|---|
| WRBTC (existing) | `0x69FE5cEC81D5eF92600c1A0dB1F11986AB3758Ab` | - |
| kRBTC - Tropykus (existing) | `0x5b35072cd6110606C8421E013304110fA04A32A3` | - |
| iRBTC - Sovryn (existing) | `0xe67Fe227e0504e8e96A34C3594795756dC26e14B` | - |
| TropykusAdapter | [`0x140B97453EA36743E0445D9D20b8b8DBba84Bc7D`](https://rootstock-testnet.blockscout.com/address/0x140b97453ea36743e0445d9d20b8b8dbba84bc7d) | Yes |
| SovrynAdapter | [`0x9d11f1CDE3a777868771f4840B180dF454d2080F`](https://rootstock-testnet.blockscout.com/address/0x9d11f1cde3a777868771f4840b180df454d2080f) | Yes |
| YieldVault | [`0x195ed3BfD52Fb2Fc8153d0b9905A37c63141e2c6`](https://rootstock-testnet.blockscout.com/address/0x195ed3bfd52fb2fc8153d0b9905a37c63141e2c6) | Yes |

## Build and test

```bash
forge install
forge build
forge test           # 93 unit tests
forge test -vvv      # with verbosity
```

## Deploy

```bash
cp .env.example .env
# Fill in DEPLOYER_PRIVATE_KEY

# Rootstock Testnet
forge script script/Deploy.s.sol \
  --rpc-url https://public-node.testnet.rsk.co \
  --broadcast --legacy

# Local (Anvil)
anvil
forge script script/DeployLocal.s.sol \
  --rpc-url http://localhost:8545 --broadcast
```

## Frontend

```bash
cd frontend
npm install
npm run dev
```

Connect wallet via RainbowKit, deposit rBTC, initialize vault, withdraw. Deployed on Rootstock Testnet.

## Known limitations

- Only two lending protocols (adapter interface allows adding more)
- No keeper automation (rebalance is manual/bot-triggered)
- Rate comparison is point-in-time, not time-weighted
- Tropykus testnet rate is currently near 0% (low testnet activity)
