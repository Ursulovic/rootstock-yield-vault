# Audit Scope

One-pager for audit quoting and kickoff. Updated for the LayerBank + Sovryn
architecture (post-Tropykus pivot).

## Commit & toolchain

- **Repo:** https://github.com/Ursulovic/rootstock-yield-vault
- **Scope commit:** pin to the latest `main` at quote time (this document
  committed alongside the code it describes)
- **Compiler:** solc 0.8.24, optimizer on (200 runs), EVM target `cancun`
- **Framework:** Foundry; dependencies vendored under `lib/` (no submodules)
- **Sole library dependency:** OpenZeppelin Contracts 5.x (ERC4626, ERC20,
  SafeERC20, ReentrancyGuard, Pausable, Ownable)

## In scope (~1140 nSLOC, Tier 1 feature set included)

| Contract | nSLOC | Role |
|---|---|---|
| `src/YieldVault.sol` | 409 | rBTC vault (ERC-4626, native wrap/unwrap, trustless, caps + vesting + in-kind) |
| `src/ERC20YieldVault.sol` | 380 | Generic ERC-20 vault with guardian pause |
| `src/VaultFactory.sol` | 73 | Vault deployer, adapter whitelist, registry |
| `src/adapters/LayerBankAdapter.sol` | 58 | LayerBank (Aave V3 fork) native adapter |
| `src/adapters/LayerBankERC20Adapter.sol` | 53 | LayerBank ERC-20 adapter |
| `src/adapters/SovrynERC20Adapter.sol` | 51 | Sovryn (bZx) ERC-20 adapter |
| `src/adapters/SovrynAdapter.sol` | 47 | Sovryn native adapter |
| `src/interfaces/*.sol` | 72 | Minimal protocol interfaces |

Tier 1 features are implemented and verified: immutable 60% per-adapter
concentration caps with waterfall allocation, 3-day linear profit unlock with
donation-proof checkpoint accounting, always-available in-kind redemption,
EIP-2612 permit on shares, adapter health views with failure isolation, and
Aave max-sentinel full withdrawals.

## Out of scope

- `test/**` (including mocks), `script/**`, `frontend/**`, vendored `lib/**`
- External protocols themselves: WRBTC, LayerBank Pool
  (`0x526D06c65777eA6D56d7a1Dd47cD79230dDf72E9` mainnet, Aave V3 fork behind
  EIP-1967 proxy), Sovryn iToken markets

## Deployments

- **Rootstock testnet (chain 31), Blockscout-verified, Tier 1 code:**
  YieldVault `0x6a200f30A63C3575472867498DB560574CC30cE2`, LayerBankAdapter
  `0xaF5743d854B4B638BCd0572e44c39949027AB37A`, SovrynAdapter
  `0x722F1D0E72E209488362C246A7acbc12b901bFd0`. Full lifecycle smoke-tested
  on-chain: deposit -> 60/40 waterfall across both live protocols ->
  full exit in one transaction.
- Parameters and their rationale are documented in `script/Deploy.s.sol`.

## Verification already performed

- 209 local tests: unit, function-level fuzz, factory negative paths,
  mutation-verified regression tests (every test was checked to actually
  kill the code mutation it pins)
- 9 stateful invariants across BOTH vaults (256 runs x 500 depth = 128k
  randomized calls each, fail_on_revert; handler-level cap and full-exit
  liveness assertions; config pinned in `foundry.toml`)
- 28 fork tests against real mainnet protocols (pinned block 8,935,125)
- 6 Halmos symbolic proofs (adapter-selection filter correctness, reward
  clamp at three deposit scales, receive() sender gating); solver-intractable
  properties documented under `noproof_` in `test/halmos/VaultSymbolic.t.sol`
- Slither: no findings after triage (remaining detector hits are
  by-design patterns documented in code comments)
- Two multi-agent adversarial review rounds with mutation testing; all
  confirmed findings fixed and regression-pinned (see `KNOWN_ISSUES.md`
  resolved sections)
- Live testnet deployment exercised end to end

## Known issues disclosed up front

See `KNOWN_ISSUES.md` — ten accepted/deferred items with analysis (plus the
resolved-items audit trail), so they don't consume audit hours on
re-discovery.

## Contact

Ivan Ursulovic — ivanursulovic@protonmail.com (see `SECURITY.md` for
disclosure policy).
