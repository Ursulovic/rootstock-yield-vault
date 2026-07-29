# No-Patch Policy

What "immutable" means for this vault, what nobody can do to it after
deployment, and exactly how you get your funds out if something goes wrong.
Written for depositors and for delegates reviewing the proposal; auditors get
the same facts with line numbers in the code and in `KNOWN_ISSUES.md`. If
anything here conflicts with the deployed bytecode, the bytecode
wins, and the conflict itself is a bug: report it (see
[Reporting a bug](#reporting-a-bug)).

## Can the vault be changed after deployment?

No. Neither vault contract (`YieldVault.sol` for rBTC, `ERC20YieldVault.sol`
for ERC-20 assets like DOC) has a proxy or an upgrade path. All six parameters
(cooldown, rate threshold, caller reward, rate sanity cap, per-venue cap, TVL
cap) are constructor arguments marked `immutable`; the share accounting and
the deposit, withdrawal and rebalancing logic are the bytecode itself. There
is no setter and no owner; governance never touches these contracts. Once a
vault is live, no one can reach any of this. Not me, not the multisig, not
the DAO.

The direct consequence: **a bug that slips past the audit cannot be patched
in place.** This is the cost of the vault's core property: no admin key
exists that could take your deposit either. An upgradeable proxy was
considered and thrown out, because whoever holds the upgrade key holds
exactly the power this vault promises nobody has.

## What powers exist at all?

The rBTC vault has none. There is no admin surface at all, not even a pause.
The only accounts
that can change its state are depositors moving their own funds, and whoever
calls the permissionless `initialDeposit()` (works once) or `rebalance()`.
Both are boxed in by the immutable parameters; the rebalancer mechanics,
including the caller reward and its clamps, are spelled out with numbers in
the [README](../README.md#rebalancing-in-detail).

Each ERC-20 vault has a guardian, and the guardian has one switch. The
guardian address is set at deployment and is itself `immutable`: it cannot be
handed over, and for factory-deployed vaults it is whoever owned the factory
at creation time. A paused vault rejects deposits and mints and blocks both
`rebalance()` and the one-time `initialDeposit()`. It does not touch exits:
`withdraw`, `redeem` and `redeemInKind` carry no pause check. The guardian
can't move funds or change a parameter, and there is no path for it to add
or remove adapters or to upgrade anything. The worst a hostile or lost
guardian can do is freeze new deposits and rebalancing forever; your exit
never needs the guardian.

The factory owner curates which adapters future vaults may use
(`trustAdapter` / `distrustAdapter`), can delist a vault from the registry
(clears a flag in a list; the vault itself keeps running), and can stop new
vault creation permanently (`shutdownFactory` is one-way, there is no
un-shutdown). Distrusting an adapter does not reach vaults that already use
it: a deployed vault never reads the factory again, its adapter set was
frozen at construction. Two more owner powers that are easy to miss. The
owner can transfer factory ownership, which changes who becomes guardian of
future vaults (never of existing ones); renouncing ownership instead bricks
the factory for good, since `createVault` would pass the zero address as
guardian and revert, and every owner function goes unreachable, an
irreversible shutdown by another name. And because `createVault` is
permissionless, the owner automatically becomes guardian of vaults that
other people deploy through the factory.

Both the guardian and the factory owner are one 2-of-3 Gnosis Safe from the
first mainnet deployment. The bytecode cannot enforce that, so verify it against the
deployed addresses, and check the Safe's signer set while you are at it: the
guardian address can never change, but a multisig's owners can.

## Trust layers

| Layer | What it is | Who can change it |
|---|---|---|
| The vault | Your deposit accounting and exit logic | Nobody. Immutable. |
| The factory and the pause | Adapter allowlist for future vaults; ERC-20 deposit pause | The 2-of-3 Safe, within the limits above |
| The venues | LayerBank and Sovryn, where the yield comes from | Their own governance. Outside this project. |

The bottom row is the one this project cannot make safe for you. Both venues
run upgradeable contracts, and a malicious or broken upgrade on their side
can lose whatever the vault deployed there. What bounds the damage: the
per-venue cap (60% in the Phase 0 parameters), the rate sanity cap that
refuses to allocate into markets quoting manipulated or illiquid-looking
rates, and the utilization ceiling that ships with the Phase 0 deployment to
stop new allocation into markets that are already close to fully borrowed.
All three cap the damage; none removes it. The failure case is covered under
[How you exit](#how-you-exit).

## What happens if a bug is found?

The vault cannot be patched, so remediation is a procedure: disclose, keep
the exits open, and ship a corrected vault people can move to.

1. No matter who finds it (me, an auditor, a whitehat, a user), an advisory
   goes to the project's thread on the [RootstockCollective forum](https://gov.rootstockcollective.xyz/t/idea-sanity-check-multi-protocol-erc-4626-yield-vault-for-rootstock-strategic-tier-pre-rfc-walkthrough/894)
   and to this repository (`SECURITY.md` plus a pinned advisory), saying in
   plain terms which vaults and assets are affected and what to do.
2. If the bug is exploitable, the advisory withholds the exploit detail and
   leads with the exit instruction.
3. If I am unreachable, any one Safe signer can publish the advisory on their
   own. Pausing an ERC-20 vault's deposits takes two of the three signers,
   because a Safe only executes at its threshold. The rBTC vault has no pause,
   so there the advisory and the always-open exits are the whole response.

For a confirmed bug the fix is a new deployment: a corrected vault at a new
address, and depositors move themselves. The old vault keeps running with
withdrawals open, because nothing can shut it off. Nobody can migrate you,
which cuts both ways, and it is the design.

This lifecycle has run in production before, just not here. Ajna, an
immutable lending protocol with no governance, went through it after a
griefing vector was reported in September 2023: a public advisory told users
to close their positions, the fix was audited four more times, and the
corrected version went live in January 2024, with liquidity returning to it
after most users had exited at advisory time. The vector was never exploited
and no losses were reported
([advisory](https://blog.summer.fi/ajna-possible-attack-vector/),
[relaunch](https://www.newswire.com/news/ajna-protocol-completes-audits-and-relaunches-on-mainnet-and-l2s-22082362)).

## How you exit

While the venues are healthy, which is the normal case:

1. Call `withdraw()` or `redeem()`. The vault pays from its idle balance
   first and pulls any shortfall from the venues, lowest-rate venue first.
   On the rBTC vault these return WRBTC; call `withdrawNative()` if you want
   native rBTC. None of this is pausable, on either vault.

If a venue will not release funds, or the vault can no longer measure its
own positions:

2. Call `redeemInKind()`. It burns your shares and transfers you a pro-rata
   slice of the vault's idle balance (WRBTC on the rBTC vault) plus each
   adapter's receipt tokens: `lRooWRBTC` from LayerBank (their Aave-style
   aToken; symbol verified on-chain), `iRBTC` from Sovryn, or the DOC-market
   equivalents. It makes no deposit or withdrawal call to the venues and
   tolerates their balance views being broken, so it keeps working when a
   normal withdrawal reverts.
3. Redeem the receipt tokens with the venues directly, on your own schedule,
   the same way any direct lender would. A venue that is merely illiquid
   (everything lent out, nothing free to withdraw) still owes you the full
   amount: the receipt keeps accruing at the high rate a maxed-out market
   pays, and you pull funds out as borrowers repay.

Read this before using `redeemInKind()`:

- It delivers the redeem value of your shares, not a naive share-count
  fraction. Profit still inside the 3-day vesting window stays behind, and
  during the rare window where an adapter's balance query reverts you receive
  less than fair pro-rata; the difference stays in the vault for the
  remaining holders (KNOWN_ISSUES #11). Waiting for the view to recover
  avoids that haircut.
- Delivery needs each venue's receipt token to still transfer as a plain
  ERC-20. Sovryn's iToken transfers carry no pause hook at all (its
  per-function pause only gates the borrowing paths), so those receipts keep
  moving. LayerBank is an Aave V3 fork, and a full Aave-style reserve pause
  blocks aToken transfers. `redeemInKind()` skips a venue whose transfer
  reverts, and your shares burn before the transfers run, so a skipped slice
  is forfeited to the remaining holders. If LayerBank is fully paused, do
  not redeem in kind; wait for the unpause.
- Against a venue that has been drained or exploited it recovers nothing.
  Those receipt tokens point at a pool whose assets are gone, and this vault
  cannot make them whole. The caps and the ceiling only lower the odds of
  ending up here. Size your deposit accordingly.

## Reporting a bug

Report privately first: **ivanursulovic@protonmail.com** (response within 48
hours; full process in [SECURITY.md](../SECURITY.md)). For anything
exploitable, private disclosure is what buys depositors an exit window before
the details go public. Please do not open a GitHub issue for it.

---

*This policy describes the contracts as deployed at Phase 0. The vault cannot
change, so for a given deployment this document does not change either; a new
deployment ships its own copy.*
