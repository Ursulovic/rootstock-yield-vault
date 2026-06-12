# Rootstock Yield Vault (ryRBTC)

ERC-4626 vault that deposits rBTC into whichever Rootstock lending protocol (LayerBank or Sovryn) has the best rate. Anyone can call `rebalance()` to move funds when rates shift and get 1% of accrued yield as a reward.

Capstone project for Rootstock Builder Rootcamp Cohort 1.

## Why

There's no yield aggregator on Rootstock yet. You have LayerBank (Aave V3 fork) and Sovryn (bZx fork) offering supply rates on rBTC, but you have to manually check which one is better and move funds yourself. This vault automates that.

The vault originally routed between Tropykus and Sovryn. When Tropykus announced its shutdown (April 2026), swapping it out took exactly one new adapter and zero vault changes — which is the whole point of the adapter pattern.

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
           │ LayerBank │  │   Sovryn    │
           │ Adapter   │  │   Adapter   │
           └────┬──────┘  └──────┬──────┘
                │                │
           ┌────▼──────┐  ┌─────▼───────┐
           │ LB Pool    │  │   iRBTC     │
           │ (aWRBTC)   │  │             │
           └────────────┘  └─────────────┘
```

There's also a `VaultFactory` + `ERC20YieldVault` for non-rBTC tokens (DOC, USDRIF, etc.) using the same adapter pattern.

## Design choices

**Why adapters?** LayerBank and Sovryn have completely different interfaces. LayerBank is an Aave V3 fork (`supply`/`withdraw` against a pool, rebasing aTokens, ERC-20 WRBTC market), Sovryn uses `mintWithBTC(address, bool)` on a native-rBTC loan token. The adapter pattern wraps each one so the vault doesn't care which protocol it's talking to. Adding a new protocol means writing one ~70 line adapter — proven when Tropykus shut down and was replaced by LayerBank without touching the vault.

**Why two vault contracts?** The rBTC vault deals with native currency wrapping/unwrapping (`WRBTC.deposit()`, `WRBTC.withdraw()`). An ERC-20 vault doesn't need any of that -- just `transferFrom` and `transfer`. Trying to cram both into one contract makes it harder to reason about. The rBTC vault was built first, the ERC-20 vault came after.

**No admin on the rBTC vault.** Once deployed, nobody can pause it, upgrade it, or change parameters. The ERC-20 vault adds a guardian who can pause deposits (but withdrawals always work, even when paused). This was a deliberate progression -- started simple and trustless, then added safety rails for the factory-deployed version.

**Rebalance incentives instead of keepers.** Rather than running a bot or trusting an admin to rebalance, anyone can call it. The 1% yield reward makes it worth their gas. Cooldown (1 hour) and rate threshold (0.05% APR improvement required) prevent spam.

**Gas optimization.** Adapters set `type(uint256).max` approval to the lending protocol in their constructor. Saves ~15k gas per deposit vs approving each time. The vault does the same for its adapters.

## Rules the contracts enforce

- At least 2 adapters required
- 1 hour cooldown between rebalances
- New rate must beat current by 0.05%+ to rebalance
- Adapter rates above the sanity cap (`maxSaneRate`, immutable) are never selected
- No adapter may receive more than 60% of total assets (`adapterCapBps`, immutable) — allocation spills to the next-best market, the rest stays idle until the next deposit or rebalance sweeps it back into yield
- Profit vests linearly over 3 days before entering the share price — balance jumps can't be sniped
- Caller reward is 1% of *recognized adapter yield only* (donations never count), funded strictly by the still-vesting profit buffer — paying it never moves the share price — and never more than what the rebalance actually withdrew; the reward base shrinks pro-rata as holders exit
- `redeemInKind()` is always available: burn shares, receive receipt tokens directly — works even when the underlying protocols pause
- Vault shares support EIP-2612 permit (gasless approvals)
- Vault only accepts native rBTC from WRBTC and its own adapters
- Withdrawals work even when paused
- Factory only deploys vaults with pre-approved adapters
- Factory owner can permanently shut down new deployments

## Rootstock specifics

Rootstock has 30-second blocks (not 12s like Ethereum). No EIP-1559, so `--legacy` flag on all txs.

WRBTC (a WETH9 fork) pays out via `.transfer()` with a 2300 gas stipend when unwrapping. Any `receive()` on that path — the vault's and the adapters' — has to stay near-empty or it runs out of gas. Learned this the hard way during research.

Sovryn uses `mintWithBTC`/`burnToBTC` for native rBTC -- different from their ERC-20 `mint`/`burn` functions. Its `supplyInterestRate()` is also percent-scaled (1e18 = 1%), unlike LayerBank's fraction-scaled ray rate -- the adapters normalize both to one scale, verified against real on-chain `tokenPrice` growth. The spec had wrong addresses for both protocols on mainnet, had to verify everything on Blockscout.

## Security

- `ReentrancyGuard` on all deposit, withdraw, rebalance, and initialDeposit functions
- `SafeERC20` for all token transfers (handles non-standard tokens like USDT)
- `Pausable` on ERC-20 vault -- guardian can freeze deposits but withdrawals always work
- 3-decimal virtual share offset to prevent first-depositor inflation attack
- `forceApprove` instead of `approve` to handle tokens that require resetting to zero
- Caller reward derives from checkpoint-recognized adapter growth only, clamped to the unvested profit buffer — donations and idle balances can never inflate it
- Rate sanity cap (`maxSaneRate`, immutable per deployment) -- rates above it are ignored when picking an adapter, so a flash-loan utilization spike can't bait the vault into a manipulated or illiquid market
- `receive()` on the rBTC vault only accepts rBTC from WRBTC and registered adapters -- direct donations can't inflate the yield figure used for caller rewards
- All adapters revert if the protocol returns less than the requested withdrawal amount
- 209 local tests (unit + function-level fuzz + stateful invariants across both vaults at 128k randomized calls each, fail-on-revert), plus Halmos symbolic proofs for the rate filter, reward clamp and donation guard; regression tests are mutation-verified (each one demonstrably kills the code mutation it pins)
- Known/accepted limitations documented in [KNOWN_ISSUES.md](KNOWN_ISSUES.md); trust model and disclosure policy in [SECURITY.md](SECURITY.md)

## Contracts

| Contract | What it does |
|---|---|
| `YieldVault.sol` | rBTC vault (ERC-4626, native wrapping) |
| `ERC20YieldVault.sol` | Generic ERC-20 vault with guardian pause |
| `VaultFactory.sol` | Deploys ERC-20 vaults, adapter whitelist, registry |
| `LayerBankAdapter.sol` | Wraps LayerBank WRBTC market (Aave V3 fork) |
| `SovrynAdapter.sol` | Wraps Sovryn iRBTC (bZx) |
| `LayerBankERC20Adapter.sol` | Wraps LayerBank DOC/USDRIF markets |
| `SovrynERC20Adapter.sol` | Wraps Sovryn iDOC/iXUSD |

## Deployed on Rootstock Testnet (chain 31)

LayerBank + Sovryn architecture, all verified on Blockscout:

| Contract | Address |
|---|---|
| YieldVault | [`0x6a20...0cE2`](https://rootstock-testnet.blockscout.com/address/0x6a200f30a63c3575472867498db560574cc30ce2) |
| LayerBankAdapter | [`0xaF57...B37A`](https://rootstock-testnet.blockscout.com/address/0xaf5743d854b4b638bcd0572e44c39949027ab37a) |
| SovrynAdapter | [`0x722F...bFd0`](https://rootstock-testnet.blockscout.com/address/0x722f1d0e72e209488362c246a7acbc12b901bfd0) |

Testnet dependencies: WRBTC (`0x69FE...58Ab`), LayerBank Pool (`0xF972...f536`), Sovryn iRBTC (`0xe67F...14B`). This deployment runs the full Tier 1 feature set (caps, profit vesting, in-kind redemption). The deposit -> initialDeposit -> full-exit lifecycle is exercised live: the waterfall split landed 60/40 across both protocols and the exit pulled from both in one transaction.

Previous deployments remain verified for reference: pre-Tier-1 LayerBank+Sovryn [`0x1881...9647`](https://rootstock-testnet.blockscout.com/address/0x1881ff54d76c74beb76c92b00781b54bfcd19647), original capstone (Tropykus+Sovryn) [`0x195e...e2c6`](https://rootstock-testnet.blockscout.com/address/0x195ed3bfd52fb2fc8153d0b9905a37c63141e2c6).

## Run it

Dependencies are vendored in `lib/` — clone and build, no `forge install` needed.

```bash
forge build
forge test                     # unit + fuzz + invariant (fork suites skip without a fork)
```

Fork tests against real mainnet protocols (pinned block, cached after first run):
```bash
forge test --match-path "test/Fork*" \
  --fork-url https://public-node.rsk.co --fork-block-number 8935125
```

Symbolic proofs (requires [halmos](https://github.com/a16z/halmos), `pipx install halmos`):
```bash
forge clean && forge build --ast
halmos --contract VaultSymbolicTest --solver-threads 2
```

Invariant runs are pinned in `foundry.toml` (256 runs x 500 depth = 128k calls
per invariant).

Deploy to testnet (addresses + parameter rationale in `script/Deploy.s.sol`):
```bash
cp .env.example .env           # add your private key
forge script script/Deploy.s.sol \
  --rpc-url https://public-node.testnet.rsk.co \
  --broadcast --legacy
```
Post-deploy: verify on Blockscout (`forge verify-contract ... --verifier blockscout
--verifier-url https://rootstock-testnet.blockscout.com/api/`), then smoke-test
depositNative -> initialDeposit -> withdrawNative with dust amounts.

Frontend (defaults to testnet; `VITE_USE_LOCAL=true` for local Anvil mode):
```bash
cd frontend && npm install && npm run dev
```

## Limitations

- Two lending protocols only (but adding more is just a new adapter)
- No keeper bot -- rebalance is manual
- LayerBank testnet market is tiny (0.01 WRBTC supplied), so testnet rates are near 0%
- Rate comparison is point-in-time, not TWAPed
