# Rootstock Yield Vault (ryRBTC)

ERC-4626 vault that deposits rBTC into whichever Rootstock lending protocol (Tropykus or Sovryn) has the best rate. Anyone can call `rebalance()` to move funds when rates shift and get 1% of accrued yield as a reward.

Capstone project for Rootstock Builder Rootcamp Cohort 1.

## Why

There's no yield aggregator on Rootstock yet. You have Tropykus (Compound V2 fork) and Sovryn (bZx fork) offering supply rates on rBTC, but you have to manually check which one is better and move funds yourself. This vault automates that.

## How it works

1. Deposit rBTC. Vault wraps it and sends it to the active lending protocol.
2. Rates change? Anyone calls `rebalance()`. Funds move to the better protocol, caller gets paid.
3. Withdraw whenever. You get your rBTC + yield back.

Only one adapter is active at a time. All funds sit in one protocol.

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
           └────┬──────┘  └──────┬──────┘
                │                │
           ┌────▼──────┐  ┌─────▼───────┐
           │  kRBTC     │  │   iRBTC     │
           └────────────┘  └─────────────┘
```

There's also a `VaultFactory` + `ERC20YieldVault` for non-rBTC tokens (DOC, USDRIF, etc.) using the same adapter pattern.

## Design choices

**Why adapters?** Tropykus and Sovryn have completely different interfaces. Tropykus uses `mint() payable` (Compound V2 cETH style), Sovryn uses `mintWithBTC(address, bool)`. The adapter pattern wraps each one so the vault doesn't care which protocol it's talking to. Adding a new protocol means writing one ~50 line adapter.

**Why two vault contracts?** The rBTC vault deals with native currency wrapping/unwrapping (`WRBTC.deposit()`, `WRBTC.withdraw()`). An ERC-20 vault doesn't need any of that -- just `transferFrom` and `transfer`. Trying to cram both into one contract makes it harder to reason about. The rBTC vault was built first, the ERC-20 vault came after.

**No admin on the rBTC vault.** Once deployed, nobody can pause it, upgrade it, or change parameters. The ERC-20 vault adds a guardian who can pause deposits (but withdrawals always work, even when paused). This was a deliberate progression -- started simple and trustless, then added safety rails for the factory-deployed version.

**Rebalance incentives instead of keepers.** Rather than running a bot or trusting an admin to rebalance, anyone can call it. The 1% yield reward makes it worth their gas. Cooldown (1 hour) and rate threshold (0.05% APR improvement required) prevent spam.

**Gas optimization.** Adapters set `type(uint256).max` approval to the lending protocol in their constructor. Saves ~15k gas per deposit vs approving each time. The vault does the same for its adapters.

## Rules the contracts enforce

- At least 2 adapters required
- 1 hour cooldown between rebalances
- New rate must beat current by 0.05%+ to rebalance
- Caller reward capped at 5% of yield (set to 1%)
- Withdrawals work even when paused
- Factory only deploys vaults with pre-approved adapters
- Factory owner can permanently shut down new deployments

## Rootstock specifics

Rootstock has 30-second blocks (not 12s like Ethereum). `blocksPerYear = 1,051,200` -- same convention Compound V2 uses (365 days). No EIP-1559, so `--legacy` flag on all txs.

Tropykus sends rBTC back via `.transfer()` with a 2300 gas stipend. The adapter's `receive()` has to be empty or it runs out of gas. Learned this the hard way during research.

Sovryn uses `mintWithBTC`/`burnToBTC` for native rBTC -- different from their ERC-20 `mint`/`burn` functions. The spec had wrong addresses for both protocols on mainnet, had to verify everything on Blockscout.

## Security

- `ReentrancyGuard` on all deposit, withdraw, rebalance, and initialDeposit functions
- `SafeERC20` for all token transfers (handles non-standard tokens like USDT)
- `Pausable` on ERC-20 vault -- guardian can freeze deposits but withdrawals always work
- 3-decimal virtual share offset to prevent first-depositor inflation attack
- `forceApprove` instead of `approve` to handle tokens that require resetting to zero
- Balance-delta tracking in rebalance (not total balance) to prevent idle funds from being swept
- 93 unit tests covering deposits, withdrawals, rebalance, edge cases, adapter access control, pause mechanics, factory admin functions

## Contracts

| Contract | What it does |
|---|---|
| `YieldVault.sol` | rBTC vault (ERC-4626, native wrapping) |
| `ERC20YieldVault.sol` | Generic ERC-20 vault with guardian pause |
| `VaultFactory.sol` | Deploys ERC-20 vaults, adapter whitelist, registry |
| `TropykusAdapter.sol` | Wraps Tropykus kRBTC (Compound V2) |
| `SovrynAdapter.sol` | Wraps Sovryn iRBTC (bZx) |
| `TropykusERC20Adapter.sol` | Wraps Tropykus kDOC/kUSDRIF |
| `SovrynERC20Adapter.sol` | Wraps Sovryn iDOC/iXUSD |

## Deployed on Rootstock Testnet (chain 31)

| Contract | Address |
|---|---|
| TropykusAdapter | [`0x140B...Bc7D`](https://rootstock-testnet.blockscout.com/address/0x140b97453ea36743e0445d9d20b8b8dbba84bc7d) |
| SovrynAdapter | [`0x9d11...080F`](https://rootstock-testnet.blockscout.com/address/0x9d11f1cde3a777868771f4840b180df454d2080f) |
| YieldVault | [`0x195e...e2c6`](https://rootstock-testnet.blockscout.com/address/0x195ed3bfd52fb2fc8153d0b9905a37c63141e2c6) |

All verified on Blockscout. Uses existing testnet WRBTC (`0x69FE...58Ab`), kRBTC (`0x5b35...32A3`), and iRBTC (`0xe67F...14B`).

## Run it

```bash
forge install && forge build
forge test                     # 93 tests
```

Deploy to testnet:
```bash
cp .env.example .env           # add your private key
forge script script/Deploy.s.sol \
  --rpc-url https://public-node.testnet.rsk.co \
  --broadcast --legacy
```

Frontend:
```bash
cd frontend && npm install && npm run dev
```

## Limitations

- Two lending protocols only (but adding more is just a new adapter)
- No keeper bot -- rebalance is manual
- Tropykus testnet rate is near 0% right now (no activity)
- Rate comparison is point-in-time, not TWAPed
