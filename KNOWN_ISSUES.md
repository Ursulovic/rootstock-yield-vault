# Known Issues & Accepted Limitations

Issues we know about, have analyzed, and have deliberately deferred or accepted.
Each entry says why it is acceptable today and what (if anything) fixes it later.
Auditors: these are disclosed up front so they don't need re-discovery.

## 1. Donations can inflate `yieldAccrued` (caller reward overpayment)

`rebalance()` measures yield as `totalAssets() - lastTotalAssets`. A direct
ERC-20 transfer of the underlying (WRBTC or the ERC-20 vault's asset) to the
vault inflates that delta, so the next rebalancer's reward (1% of "yield") is
computed from a partly fake figure.

- **Bounded:** the reward is clamped to what the rebalance actually withdrew
  from the adapter (proven for all donation sizes with Halmos), so the payout
  can never exceed real assets in motion. The donor strictly loses more than
  anyone gains; shareholders net-gain from the donation itself.
- **Native side:** direct rBTC transfers are rejected by the vault's gated
  `receive()` (proven for all senders). Only the ERC-20 transfer channel
  remains.
- **Planned fix:** Tier 1 linear profit unlock reworks yield accounting to a
  donation-proof internal baseline.

## 2. `yieldAccrued` overstated after withdrawals

`lastTotalAssets` is reduced by the full withdrawn amount (principal +
realized yield), so after large exits the baseline can undershoot and the next
rebalance counts some remaining principal as "yield" for the reward
calculation. Same root cause and same clamp/bounds as issue 1; same Tier 1
accounting rework fixes both.

## 3. Sub-index-wei withdrawals revert on LayerBank (dust edge)

Aave-style pools revert (`INVALID_BURN_AMOUNT`) when the requested amount
rounds to zero scaled units — i.e. pulls below ~1 "index-wei". A withdrawal
that needs such a dust pull from the adapter reverts; retrying with ±1 wei
succeeds.

- **Real-Aave parity:** real Aave behaves identically; this is not introduced
  by our adapter.
- **Magnitude:** matters only once the liquidity index materially exceeds 1.0
  (cumulative yield >100% — years away at observed rates) and only for
  wei-sized pull amounts.
- **Planned fix:** Tier 1 — use Aave's `type(uint256).max` full-withdraw
  sentinel in the LayerBank adapters for exact full exits.

## 4. Underlying protocol pause/freeze/cap can block deposits or rebalancing

If LayerBank pauses/freezes a reserve or a supply cap is hit, `supply()`
reverts; deposits routed to that adapter and rebalances into it fail until the
protocol recovers. Same class applies to Sovryn pausing its loan token.

- **Withdrawal-first design:** user exits only require the *active* protocol
  to honor withdrawals; the vault never blocks its own withdrawal path.
- **Planned mitigation:** Tier 1 adapter health-check view so rebalancers and
  UIs can detect unhealthy markets; per-adapter caps limit concentration.

## 5. A reverting `getRate()` bricks adapter selection

`_findBestRate()` calls every adapter's `getRate()` without try/catch; if an
underlying protocol's rate query starts reverting, `rebalance()` and
`initialDeposit()` revert with it. Withdrawals are unaffected (they never read
rates). Accepted as pre-existing architecture; the Tier 1 health-check work
will isolate per-adapter failures.

## 6. `maxWithdraw` can overstate by protocol liquidity

ERC-4626's `maxWithdraw` reflects the user's share value, not the underlying
market's *available* liquidity. If LayerBank utilization leaves less free
liquidity than a withdrawal needs, the pull reverts even though `maxWithdraw`
suggested it would succeed. This is protocol risk the vault cannot hedge
without holding idle buffers (a deliberate non-goal of the 100%-deployed
design); per-adapter caps (Tier 1) reduce exposure.

## 7. Unproven Halmos properties (`noproof_` prefix)

Three ERC-4626 round-trip properties and the two-symbolic-input reward-clamp
property time out in the SMT solver (OpenZeppelin's 512-bit `mulDiv` is
solver-hostile). **No counterexamples were found.** They are kept in
`test/halmos/VaultSymbolic.t.sol` under the `noproof_` prefix for future
solver attempts and are backstopped by:

- OpenZeppelin's battle-tested ERC-4626 implementation (the code under those
  properties is upstream, not ours),
- the stateful invariant suites (`sharesFullyBacked`, 128k random calls per
  invariant, both vaults),
- concrete-deposit Halmos instances (1 wei / 5 ether / max-uint96) of the
  reward clamp, each proven for all donation sizes.
