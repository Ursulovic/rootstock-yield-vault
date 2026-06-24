# Known Issues & Accepted Limitations

Limitations that have been analyzed and deliberately deferred or accepted.
Each entry says why it is acceptable today and what (if anything) fixes it later.
They are disclosed up front so they don't need re-discovery during an audit.

Resolved-by-Tier-1 items are kept at the bottom for the audit trail.

## Active

### 1. Pricing over-discounts after large exits (conservative, self-healing)

`trackedDeployed` can drop below the still-vesting `lockedProfit` after large
withdrawals (the exit pulls principal+profit while the locked buffer stays for
remaining holders). The priced deployed base then floors at zero until the
buffer decays, temporarily understating the share price. Always in the safe
direction (price never overstates; `totalAssets <= idle + deployed` is
invariant-fuzzed at 128k calls), and it heals as the 3-day vest runs off.

### 2. Withdrawals can leave 100% concentration until the next allocation

Withdrawals pull from the worst-rate adapter first (yield-optimal), so a large
exit can drain the secondary entirely and leave everything in the primary,
above the 60% cap. Deposits never add to an over-cap adapter and the next
rebalance trues the allocation up; between those events the concentration
drift is accepted. Same applies to yield drift pushing the primary above cap.

### 3. Rebalance cannot fire to "evacuate" a worse secondary

The rebalance gate requires the best sane rate to beat the PRIMARY's rate by
the threshold. If the primary already has the best rate, no rebalance fires,
even if the secondary's market turned insane (rate above `maxSaneRate`) or
unhealthy. The secondary's funds stay until rates flip or users withdraw
(pulls hit the worst adapter first, which helps). A dedicated evacuation
trigger is Tier 2 backlog.

### 4. Sub-protocol-grain positions can be unexitable in full (real-Aave parity)

Positions and withdrawal slices below one receipt-token grain (LayerBank:
`liquidityIndex/1e27` wei; Sovryn: `tokenPrice/1e18` wei) can revert on the
protocol side. The vault is robust to this (dust slices are skipped in
allocation; only material rebalance pull failures abort), but a user whose
final slice rounds sub-grain may need to retry with a marginally smaller
amount. Material only at large liquidity indexes (cumulative yield >100%).

### 5. Underlying protocol pause/freeze/cap can block deposits or rebalancing

If LayerBank pauses a reserve or a supply cap binds, `supply()` reverts;
allocation slices into it fail and stay idle (until a later deposit or
rebalance sweeps them back once capacity recovers) and rebalances into it abort.
Withdrawal-path pauses block normal exits from that adapter; this is what
`redeemInKind()` exists for: it delivers receipt tokens directly and needs
nothing from the protocol. `isAdapterHealthy`/`getAdapterHealth` give
rebalancers and UIs the signal.

### 6. A reverting `getBalance()` is handled ASYMMETRICALLY (entry fail-closed, exits fail-open)

A dark adapter view (e.g. Sovryn `assetBalanceOf` div-by-zero on a drained
market) makes the true deployed total unmeasurable. The vault therefore:
- **Entry is fail-closed.** `deposit`/`mint`/`depositNative` revert
  `"adapter view down"` if any adapter `getBalance()` reverts. Pricing new
  shares against an under-counted total would let a depositor mint cheap and
  steal from holders on recovery, so minting is blocked while a view is dark.
- **Profit recognition freezes.** `_checkpointProfit()` recognizes nothing
  while any view is dark (no phantom loss now, hence no phantom gain on
  recovery), and `rebalance()` is blocked the same way (it resyncs the
  baseline from a measurement a dark adapter would corrupt).
- **Exits stay fail-open.** `totalAssets()` (a view), `withdraw`, and
  `redeemInKind` treat a dark adapter as zero and keep working, so the
  escape hatch survives even a bricked receipt-token view. The under-count is
  conservative (price understates, never overstates).

This asymmetry is the resolution of the original fail-closed-everything design
(which bricked the escape hatch) and of the fail-open-everything regression it
was first "fixed" with (which enabled depressed-price minting, see the
resolved audit trail). Rate-query failures remain isolated (selection skips
the adapter).

### 7. `maxWithdraw` can overstate by protocol liquidity

ERC-4626's `maxWithdraw` reflects share value, not the underlying market's
available liquidity at high utilization. Per-adapter caps bound the exposure;
`redeemInKind()` is the trustless fallback.

### 8. Unproven Halmos properties (`noproof_` prefix)

OpenZeppelin's 512-bit `mulDiv` is SMT-solver-hostile; three ERC-4626
round-trip properties and the two-symbolic-input reward-clamp variant time
out (NO counterexamples). Backstopped by OZ's battle-tested implementation,
the invariant suites, and concrete-deposit Halmos instances (1 wei / 5 ether /
max-uint96, each proven for all donation sizes).

### 9. The reward base counts gross recognized gains, not net

`rewardableYield` accumulates each recognized gain and floors at zero on
losses, so across a +X / −X / +X window it reports X while net growth is
zero. Harmless by construction since the Tier 1 review fix: the payout is
clamped to the still-vesting buffer (real, present profit) and paying it
shrinks that buffer one-for-one, so the share price never moves. The only
effect is the caller's cut being computed against gross rather than net,
bounded by `callerRewardBps` (max 5%) of the buffer.

### 10. A whale round-trip can shrink the rebalance caller's reward

The reward base shrinks pro-rata on every exit (deliberate: exiting holders
carry their yield share out). A large holder can withdraw and immediately
re-deposit right before a rebalance, cutting the caller's reward by their
pro-rata share (measured: 80% ownership strips ~76% of the payout). Capital
-gated, price-neutral, no fund loss, the unpaid cut vests back to all
holders, and self-healing as new yield rebuilds the base. Dust-exit
griefing does not work: floor rounding makes sub-wei shrinks free for the
base. Accepted as the adversarial reading of the exit-shrink mechanism.

### 11. In-kind redemption UNDER-claims during a `getBalance()`-revert window

`redeemInKind()` prices the delivered fraction as `value/raw`, where `value`
uses the fail-open `totalAssets()` (a dark adapter reads 0) and `raw` uses the
checkpoint baseline (frozen at the full pre-brick value on a dark view). So
during a rare window where an adapter's `getBalance()` reverts but its receipt
token still transfers (the Sovryn `assetBalanceOf` vs `balanceOf` asymmetry),
`value/raw <= shares/supply` and the redeemer receives LESS than their fair
pro-rata. The unclaimed slice STAYS in the vault for the remaining holders and
is recoverable once the view heals; it is never over-distributed, and never
lost to an attacker (`redeemInKind` is owner/allowance-gated, so no one can
force a victim to redeem during an outage). Conservative direction, fully
self-inflicted and avoidable by waiting for recovery. Chosen over a fail-open
`raw` that delivered exact value but broke the 128k invariant suite with an
overflow in extreme multi-brick sequences (verified by bisection).

## Resolved in the post-Phase-0 adversarial review (audit trail)

These were introduced by the Phase-0 batch (TVL cap + adapter-view hardening)
and caught by three rounds of multi-agent adversarial review with PoCs before
any deploy:

- **Fail-open share-pricing let depositors mint at a depressed price.** The
  first hardening made every `getBalance()` fail-open, including the deposit
  pricing path; a depositor could enter while an adapter view was dark
  (`totalAssets` under-counted) and capture holders' principal on recovery.
  Fixed by the asymmetric design (issue #6): entry fail-closed, exits
  fail-open. PoC-reproduced, regression-pinned (`test_Deposit_RevertsWhenAdapterViewDark`).
- **Phantom-yield reward drain across a brick→recover cycle.** `_checkpointProfit`
  booked a dark adapter as a loss then re-booked it as a fresh gain on recovery,
  inflating `rewardableYield` for a rebalancer to harvest. Fixed by freezing
  the checkpoint on a dark view and gating `rebalance()` on adapter health.
  Pinned by `test_PhantomYield_NotRecognizedAcrossBrick` and `test_Rebalance_RevertsWhenAdapterViewDark`.
- **Read-only reentrancy in native `rebalance()`.** The reward `.call` fired
  mid-drain when `totalAssets()` read ~0. Fixed by paying the reward last,
  after re-allocation and the baseline resync.
- **`mulDiv` overflow in proportional shrinks.** The exit/in-kind reward-base
  and baseline shrinks used plain `a * b / c`, which the 128k fuzzer overflowed
  at extreme balances. Fixed with OZ `Math.mulDiv` (512-bit) plus a clamp.

## Resolved in the Tier 1 adversarial review (audit trail)

- **Rebalance reward could be paid out of principal.** `rewardableYield`
  kept counting yield that had vested and left with exiting holders; with the
  buffer empty, the reward came straight off the share price (reproduced:
  a remaining holder dipped below principal). Fixed: the reward is clamped to
  the unvested buffer and the reward base shrinks pro-rata on every exit
  (cash and in-kind). Pinned by `test/Tier1Fixes.t.sol`.
- **Idle stranded while an adapter was unavailable was never re-deployed.**
  Deposits and rebalances only waterfalled their own increment. Fixed: every
  allocation event waterfalls the full idle balance.
- **`activeAdapter` recorded from pre-withdrawal rates.** On utilization-
  driven markets the mass withdrawal shifts rates, so the label could diverge
  from the actual primary and feed the next rebalance gate a stale reference.
  Fixed: the recorded primary is the largest post-allocation holder, with
  near-ties (equal-cap configs split allocations exactly) resolving to the
  highest-rate holder; a registration-index tie-break would let the gate
  re-open against the lower-rate twin every cooldown and pay for no-op
  rebalances forever (caught by the post-fix skeptic pass, regression-pinned).

## Resolved in Tier 1 (audit trail)

- **Donations inflating `yieldAccrued`.** Fixed by checkpoint accounting:
  the reward base (`rewardableYield`) only ever reflects adapter balance
  growth. Pinned by unit tests and Halmos.
- **`yieldAccrued` overstated after withdrawals.** Same fix; the baseline is
  re-measured against live adapter balances at every interaction.
- **Sub-index-wei dust on LayerBank full exits.** Fixed by the
  `type(uint256).max` full-withdraw sentinel in both LayerBank adapters.
- **Single `getRate()` revert bricking selection.** Fixed: selection and
  allocation skip adapters whose rate query reverts; rebalance treats a
  reverting active-adapter rate as zero so it can escape.
