# Security

## Trust model

**rBTC vault (`YieldVault.sol`) — trustless.** No admin, no pause, no upgrade
path, no parameter setters. The adapter set and all knobs (cooldown, rate
threshold, caller reward, rate sanity cap) are fixed at deployment. The only
state-changing actors are depositors (their own funds) and permissionless
rebalancers (bounded by cooldown, threshold, sanity cap, and a reward clamped
to actually-withdrawn assets).

**ERC-20 vaults (`ERC20YieldVault.sol`) — one narrow role.** A `guardian`
(set at deployment; the factory owner for factory-deployed vaults) can pause
and unpause **deposits, mints and rebalancing only**. Withdrawals and
redemptions can never be paused. The guardian cannot move funds, change
parameters, or add adapters.

**Factory (`VaultFactory.sol`).** The owner curates the adapter whitelist,
can delist vaults from the registry (does not affect the vault itself), and
can permanently shut down new deployments. `createVault` is permissionless but
restricted to whitelisted adapters. The owner becomes guardian of created
vaults.

## External dependencies (trusted contracts)

| Dependency | Trust assumption |
|---|---|
| OpenZeppelin 5.x (ERC4626, SafeERC20, ReentrancyGuard, Pausable, Ownable) | Audited upstream library |
| WRBTC (canonical WETH9 fork) | Immutable, no admin |
| LayerBank Pool (Aave V3 fork, proxy) | **Upgradeable by LayerBank governance** — adapter trusts `supply/withdraw/getReserveData` semantics and aToken accounting |
| Sovryn iToken markets | **Upgradeable by Sovryn governance** — adapter trusts `mint/burn/tokenPrice/supplyInterestRate` semantics |

A malicious or broken upgrade of an underlying protocol can lose the funds
deployed there. That is inherent to yield aggregation; mitigations are the
defensive withdrawal bounds checks in every adapter, the rate sanity cap
(refuses manipulated/illiquid markets during selection), and the planned Tier 1
per-adapter caps.

## Key safety properties (machine-checked)

- Reentrancy guards on every deposit/withdraw/rebalance path.
- 3-decimal virtual share offset against first-depositor inflation.
- The vault's `receive()` accepts native rBTC only from WRBTC and registered
  adapters — proven for **all** senders with symbolic execution (Halmos).
- The rebalance caller reward can never exceed what the rebalance actually
  withdrew — proven for all donation sizes at three deposit scales.
- Adapter selection never picks a rate above the immutable sanity cap —
  proven for all rate pairs.
- Stateful invariants (128k randomized calls each, both vaults): assets
  always equal idle + deployed, shares always fully backed, funds never split
  across adapters, no loose native rBTC or tokens stranded in vault/adapters,
  full exits always succeed outside a documented real-Aave dust edge.

See `KNOWN_ISSUES.md` for accepted limitations and `README.md` for the full
verification inventory.

## Reporting a vulnerability

Please report suspected vulnerabilities privately to
**ivanursulovic@protonmail.com**. You should receive a response within 48
hours. Do not open public issues for security reports. There is no bug bounty
program at this time; testnet deployment only — no user funds are at risk yet.
