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

## In scope (~705 nSLOC)

| Contract | nSLOC | Role |
|---|---|---|
| `src/YieldVault.sol` | 201 | rBTC vault (ERC-4626, native wrap/unwrap, trustless) |
| `src/ERC20YieldVault.sol` | 182 | Generic ERC-20 vault with guardian pause |
| `src/VaultFactory.sol` | 71 | Vault deployer, adapter whitelist, registry |
| `src/adapters/LayerBankAdapter.sol` | 51 | LayerBank (Aave V3 fork) native adapter |
| `src/adapters/LayerBankERC20Adapter.sol` | 46 | LayerBank ERC-20 adapter |
| `src/adapters/SovrynERC20Adapter.sol` | 45 | Sovryn (bZx) ERC-20 adapter |
| `src/adapters/SovrynAdapter.sol` | 41 | Sovryn native adapter |
| `src/interfaces/*.sol` | 68 | Minimal protocol interfaces |

Planned before audit start: ~125 additional LOC of Tier 1 features
(per-adapter caps, linear profit unlock, in-kind redemption, EIP-2612 permit,
adapter health view). Quote for post-Tier-1 scope.

## Out of scope

- `test/**` (including mocks), `script/**`, `frontend/**`, vendored `lib/**`
- External protocols themselves: WRBTC, LayerBank Pool
  (`0x526D06c65777eA6D56d7a1Dd47cD79230dDf72E9` mainnet, Aave V3 fork behind
  EIP-1967 proxy), Sovryn iToken markets

## Deployments

- **Rootstock testnet (chain 31), Blockscout-verified:** YieldVault
  `0x1881ff54d76C74Beb76C92B00781b54bFCD19647`, LayerBankAdapter
  `0x1bf916e2fe19183Ba06a33616b34B8876b575088`, SovrynAdapter
  `0x2668857D675eAd4b4CAD7f7aBD9d99d77cbBdd94`. Full lifecycle smoke-tested
  on-chain.
- Parameters and their rationale are documented in `script/Deploy.s.sol`.

## Verification already performed

- 142+ local tests: unit, function-level fuzz, factory negative paths
- 11 stateful invariants across BOTH vaults (256 runs x 500 depth = 128k
  randomized calls each; config pinned in `foundry.toml`)
- 28 fork tests against real mainnet protocols (pinned block 8,935,125)
- 6 Halmos symbolic proofs (adapter-selection filter correctness, reward
  clamp at three deposit scales, receive() sender gating); solver-intractable
  properties documented under `noproof_` in `test/halmos/VaultSymbolic.t.sol`
- Slither: no findings after triage (remaining detector hits are
  by-design patterns documented in code comments)
- Live testnet deployment exercised end to end

## Known issues disclosed up front

See `KNOWN_ISSUES.md` — seven accepted/deferred items with analysis, so they
don't consume audit hours on re-discovery.

## Contact

Ivan Ursulovic — ivanursulovic@protonmail.com (see `SECURITY.md` for
disclosure policy).
