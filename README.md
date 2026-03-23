# Rootstock Yield Vault

An ERC-4626 yield optimizer vault for Rootstock. Deposits rBTC and routes it to whichever lending protocol (Tropykus or Sovryn) offers the best supply rate. A public `rebalance()` function lets anyone trigger fund reallocation and earn a small reward from accrued yield.

Built for Rootstock Builder Rootcamp Cohort 1 capstone.

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

## How it works

1. User deposits rBTC via `depositNative()` or WRBTC via `deposit()`
2. Vault wraps rBTC to WRBTC for ERC-4626 accounting, then deploys to the active lending protocol
3. Anyone calls `rebalance()` when rates change -- funds move to the better protocol
4. Caller gets a small reward from accrued yield (not principal)
5. User withdraws via `withdrawNative()` or `withdraw()` to get rBTC + yield

## Rebalance mechanics

- **Cooldown**: minimum 1 hour between rebalances (prevents spam)
- **Threshold**: rate improvement must exceed 0.05% annual to justify the move
- **Reward**: 1% of accrued yield since last rebalance goes to the caller
- **No admin, no oracle**: rates read directly from on-chain lending contracts

## Rootstock-specific considerations

- Block time is 30 seconds (not 12s like Ethereum)
- `blocksPerYear = 1,051,200` for rate normalization
- No EIP-1559 -- use `--legacy` flag for all transactions
- Tropykus uses `.transfer()` (2300 gas stipend) for rBTC sends -- adapter `receive()` must be empty
- Sovryn uses `mintWithBTC`/`burnToBTC` for native rBTC (not `mint`/`burn`)

## Build and test

```bash
# Install dependencies
forge install

# Build
forge build

# Run tests
forge test

# Run tests with verbosity
forge test -vvv
```

## Deploy to Rootstock Testnet

```bash
# Copy .env.example to .env and fill in your private key
cp .env.example .env

# Deploy
forge script script/Deploy.s.sol \
  --rpc-url https://public-node.testnet.rsk.co \
  --broadcast \
  --legacy

# Verify contracts on Blockscout
forge verify-contract --chain-id 31 \
  --verifier blockscout \
  --verifier-url https://rootstock-testnet.blockscout.com/api/ \
  <CONTRACT_ADDRESS> src/YieldVault.sol:YieldVault
```

## Contract addresses

### Testnet (Chain ID 31)

| Contract | Address |
|---|---|
| WRBTC (existing) | `0x69FE5cEC81D5eF92600c1A0dB1F11986AB3758Ab` |
| kRBTC - Tropykus (existing) | `0x5b35072cd6110606C8421E013304110fA04A32A3` |
| iRBTC - Sovryn (existing) | `0xe67Fe227e0504e8e96A34C3594795756dC26e14B` |
| TropykusAdapter | TBD after deployment |
| SovrynAdapter | TBD after deployment |
| YieldVault | TBD after deployment |

## Known limitations

- Single-asset vault (rBTC only) -- multi-asset support via VaultFactory planned
- Only two lending protocols -- adapter interface allows adding more
- No keeper automation -- rebalance is manual/bot-triggered
- Rate comparison is point-in-time, not time-weighted

## Future work

- VaultFactory for deploying vaults for any ERC-20 asset
- Additional protocol adapters (LayerBank, etc.)
- Keeper bot for automated rebalancing
- Frontend for deposits and monitoring
