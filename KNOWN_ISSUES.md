# Known Issues & Accepted Limitations

Issues we know about, have analyzed, and have deliberately deferred or accepted.
Each entry says why it is acceptable today and what (if anything) fixes it later.
Auditors: these are disclosed up front so they don't need re-discovery.

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
exit can drain the secondary entirely and leave everything in the primary —
above the 60% cap. Deposits never add to an over-cap adapter and the next
rebalance trues the allocation up; between those events the concentration
drift is accepted. Same applies to yield drift pushing the primary above cap.

### 3. Rebalance cannot fire to "evacuate" a worse secondary

The rebalance gate requires the best sane rate to beat the PRIMARY's rate by
the threshold. If the primary already has the best rate, no rebalance fires —
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
allocation slices into it fail (and stay idle) and rebalances into it abort.
Withdrawal-path pauses block normal exits from that adapter — this is what
`redeemInKind()` exists for: it delivers receipt tokens directly and needs
nothing from the protocol. `isAdapterHealthy`/`getAdapterHealth` give
rebalancers and UIs the signal.

### 6. A reverting `getBalance()` fails the vault closed

Share pricing must never silently undercount, so `totalAssets()` reverts if
any adapter's balance query reverts — blocking deposits, withdrawals AND
in-kind redemptions until the query recovers. Deliberate fail-closed design;
rate-query failures, by contrast, are isolated (selection skips the adapter).

### 7. `maxWithdraw` can overstate by protocol liquidity

ERC-4626's `maxWithdraw` reflects share value, not the underlying market's
available liquidity at high utilization. Per-adapter caps bound the exposure;
`redeemInKind()` is the trustless fallback.

### 8. Unproven Halmos properties (`noproof_` prefix)

OpenZeppelin's 512-bit `mulDiv` is SMT-solver-hostile; three ERC-4626
round-trip properties and the two-symbolic-input reward-clamp variant time
out (NO counterexamples). Backstopped by OZ's battle-tested implementation,
the invariant suites, and concrete-deposit Halmos instances (1 wei / 5 ether /
max-uint96 — each proven for all donation sizes).

## Resolved in Tier 1 (audit trail)

- **Donations inflating `yieldAccrued`** — fixed by checkpoint accounting:
  the reward base (`rewardableYield`) only ever reflects adapter balance
  growth. Pinned by unit tests and Halmos.
- **`yieldAccrued` overstated after withdrawals** — same fix; the baseline is
  re-measured against live adapter balances at every interaction.
- **Sub-index-wei dust on LayerBank full exits** — fixed by the
  `type(uint256).max` full-withdraw sentinel in both LayerBank adapters.
- **Single `getRate()` revert bricking selection** — fixed: selection and
  allocation skip adapters whose rate query reverts; rebalance treats a
  reverting active-adapter rate as zero so it can escape.
