# Audit Scope

One-pager for audit quoting and kickoff. Updated for the LayerBank + Sovryn
architecture (post-Tropykus pivot).

## Commit & toolchain

- **Repo:** https://github.com/Ursulovic/rootstock-yield-vault
- **Scope commit:** the annotated tag `audit-2026-07` on `main`. Everything in
  this document describes exactly that commit; resolve it with
  `git rev-parse audit-2026-07^{commit}`. The code is frozen: no functional
  changes land on `main` while an audit is in progress.
- **Compiler:** solc 0.8.24, optimizer on (200 runs), EVM target `cancun`
- **Framework:** Foundry; dependencies vendored under `lib/` (no submodules)
- **Sole library dependency:** OpenZeppelin Contracts 5.x (ERC4626, ERC20,
  SafeERC20, ReentrancyGuard, Pausable, Ownable)

## Two scopes

Quotes are requested for both, priced separately.

**Reduced scope, 670 nSLOC** is exactly what the first mainnet deployment runs:
the native rBTC vault, its two adapters, and the interfaces they use.
`script/Deploy.s.sol` constructs `YieldVault` directly, so `VaultFactory` is not
involved in that deployment and is excluded. The factory only ever constructs
`ERC20YieldVault`, so it is scoped together with the ERC-20 vault, not apart
from it.

| Contract | nSLOC |
|---|---|
| `src/YieldVault.sol` | 496 |
| `src/adapters/LayerBankAdapter.sol` | 67 |
| `src/adapters/SovrynAdapter.sol` | 52 |
| `src/interfaces/ILendingAdapter.sol` | 11 |
| `src/interfaces/ILayerBankPool.sol` | 26 |
| `src/interfaces/IiToken.sol` | 12 |
| `src/interfaces/IWRBTC.sol` | 6 |
| **Total** | **670** |

**Full scope, ~1360 nSLOC** adds the ERC-20 vault, its two adapters, the factory
and the two ERC-20 interfaces. The table below is the full scope.

## In scope, full (~1360 nSLOC, Tier 1 + Phase-0 feature set included)

| Contract | nSLOC | Role |
|---|---|---|
| `src/YieldVault.sol` | 496 | rBTC vault (ERC-4626, native wrap/unwrap, trustless, caps + vesting + in-kind + TVL cap + utilization ceiling + asymmetric view hardening) |
| `src/ERC20YieldVault.sol` | 466 | Generic ERC-20 vault with guardian pause |
| `src/VaultFactory.sol` | 79 | Vault deployer, adapter whitelist, registry |
| `src/adapters/LayerBankAdapter.sol` | 67 | LayerBank (Aave V3 fork) native adapter |
| `src/adapters/LayerBankERC20Adapter.sol` | 62 | LayerBank ERC-20 adapter |
| `src/adapters/SovrynERC20Adapter.sol` | 56 | Sovryn (bZx) ERC-20 adapter |
| `src/adapters/SovrynAdapter.sol` | 52 | Sovryn native adapter |
| `src/interfaces/*.sol` | 78 | Minimal protocol interfaces |

Tier 1 features are implemented and verified: immutable 60% per-adapter
concentration caps with waterfall allocation, 3-day linear profit unlock with
donation-proof checkpoint accounting, never-pausable in-kind redemption with
fail-open exit paths,
EIP-2612 permit on shares, adapter health views with failure isolation, and
Aave max-sentinel full withdrawals. The Phase-0 batch adds an immutable
per-venue utilization ceiling (90% at deploy): entry-gate only, checked in
the allocation waterfall and rebalance target selection, fail-closed on a
reverting utilization view, never consulted by any exit path.

## Out of scope

- `test/**` (including mocks), `script/**`, `frontend/**`, vendored `lib/**`
- External protocols themselves: WRBTC, LayerBank Pool
  (`0x526D06c65777eA6D56d7a1Dd47cD79230dDf72E9` mainnet, Aave V3 fork behind
  EIP-1967 proxy), Sovryn iToken markets

## Deployments

- **No mainnet deployment exists.** The first one happens after this audit and
  its remediation, as a capped pilot.
- **Superseded testnet deployment (chain 31), Blockscout-verified:** YieldVault
  `0x6a200f30A63C3575472867498DB560574CC30cE2`, LayerBankAdapter
  `0xaF5743d854B4B638BCd0572e44c39949027AB37A`, SovrynAdapter
  `0x722F1D0E72E209488362C246A7acbc12b901bFd0`. **This bytecode is older than
  the audited commit and is not in scope.** It predates both the utilization
  ceiling and the `totalAssets` vesting-discount fix, and the vesting defect is
  live in it. It is listed only because the addresses are public and the full
  lifecycle was exercised against them on-chain (deposit, 60/40 waterfall across
  both live protocols, full exit in one transaction). Testnet will be redeployed
  from the audited commit.
- Parameters and their rationale are documented in `script/Deploy.s.sol`.

## Verification already performed

- 256 local tests: unit, function-level fuzz, factory negative paths,
  mutation-verified regression tests (every test was checked to actually
  kill the code mutation it pins)
- 9 stateful invariants across BOTH vaults (256 runs x 500 depth = 128k
  randomized calls each, fail_on_revert; handler-level cap, TVL-cap,
  utilization-ceiling and full-exit liveness assertions with randomized
  venue utilization, plus a dark-adapter brick injection on the in-kind
  path; config pinned in `foundry.toml`)
- 34 fork tests against real mainnet protocols (pinned block 8,935,125),
  including live utilization reads and a ceiling pinned at live market
  utilization
- 7 Halmos symbolic proofs (adapter-selection filter correctness including
  the utilization ceiling, reward clamp at three deposit scales, receive()
  sender gating); solver-intractable properties documented under `noproof_`
  in `test/halmos/VaultSymbolic.t.sol`
- Slither: no findings after triage (remaining detector hits are
  by-design patterns documented in code comments)
- Five multi-agent adversarial review rounds with PoC verification across the
  Tier 1 and Phase-0 work. The Phase-0 batch (TVL cap + adapter-view
  hardening) took three rounds to converge: each round found real
  PoC-reproduced issues in the prior fix (depressed-price minting,
  phantom-yield drain, in-kind stranding, a mulDiv overflow), all fixed and
  regression-pinned before deploy; see the `KNOWN_ISSUES.md` resolved trail
- Live testnet deployment exercised end to end

## Known issues disclosed up front

See `KNOWN_ISSUES.md`: eleven accepted/deferred items with analysis (plus the
resolved-items audit trail), so they don't consume audit hours on
re-discovery.

## Contact

Ivan Ursulovic, ivanursulovic@protonmail.com (see `SECURITY.md` for
disclosure policy).
