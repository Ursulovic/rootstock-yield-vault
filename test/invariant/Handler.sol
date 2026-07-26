// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20YieldVault} from "../../src/ERC20YieldVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockLayerBankPool} from "../mocks/MockLayerBankPool.sol";
import {MockLoanToken} from "../mocks/MockLoanToken.sol";

/// @notice Drives the vault through random deposit/withdraw/rebalance/donate/accrue
///         sequences for invariant testing. Reverts inside actions are swallowed
///         so a single illegal call doesn't abort the whole run; the invariants
///         (asserted in the test contract) are what must always hold.
contract VaultHandler is Test {
    ERC20YieldVault public immutable vault;
    MockERC20 public immutable asset;
    MockLayerBankPool public immutable lbPool; // LayerBank (Aave-style) pool
    MockLoanToken public immutable iPool; // Sovryn-style pool
    uint256 public immutable cooldown;

    address[] public actors;
    uint256 public ghost_donated; // total adversarial donations (never counted as principal)

    constructor(
        ERC20YieldVault _vault,
        MockERC20 _asset,
        MockLayerBankPool _lbPool,
        MockLoanToken _iPool,
        uint256 _cooldown
    ) {
        vault = _vault;
        asset = _asset;
        lbPool = _lbPool;
        iPool = _iPool;
        cooldown = _cooldown;
        actors.push(makeAddr("inv_alice"));
        actors.push(makeAddr("inv_bob"));
        actors.push(makeAddr("inv_carol"));
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// One "token-wei" of each protocol's receipt token: LayerBank scaled
    /// units are worth index/1e27 underlying wei, Sovryn iTokens are worth
    /// tokenPrice/1e18. Requests below these granularities can revert on
    /// the protocol side (real Aave parity).
    function _dustLimit() internal view returns (uint256) {
        uint256 idx = lbPool.liquidityIndex(address(asset));
        uint256 price = iPool.tokenPrice();
        return idx / 1e27 * 2 + idx / (2 * 1e27) + price / 1e18 + 2;
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, 1, 1e24);
        // Respect the TVL cap exactly as a real user would: never try to
        // deposit past the headroom (uncapped vaults return type(uint).max)
        uint256 room = vault.maxDeposit(actor);
        if (room == 0) return;
        if (amount > room) amount = room;
        asset.mint(actor, amount);

        uint256 beforeA = _adapterBalance(0);
        uint256 beforeB = _adapterBalance(1);
        bool underA = _underCeiling(0);
        bool underB = _underCeiling(1);

        vm.startPrank(actor);
        asset.approve(address(vault), amount);
        // No tolerance: the vault catches sub-dust slices internally, so a
        // deposit revert here is a real bug
        vault.deposit(amount, actor);
        vm.stopPrank();

        // Bootstrap the active adapter once funds are idle
        if (address(vault.activeAdapter()) == address(0) && asset.balanceOf(address(vault)) > 0) {
            try vault.initialDeposit() {} catch {}
        }
        _assertDepositRespectsCaps(beforeA, beforeB);
        _assertCeilingRespected(underA, underB, beforeA, beforeB);
        _assertUnderTvlCap();
    }

    /// Push each venue's utilization anywhere in 0..120% of its current
    /// supply, so allocation is fuzzed on both sides of the entry gate.
    function setUtilization(uint256 seedA, uint256 seedB) external {
        uint256 lbSupply = lbPool.aTokens(address(asset)).totalSupply();
        lbPool.setTotalDebt(address(asset), lbSupply * bound(seedA, 0, 12_000) / 10_000);
        uint256 iSupply = iPool.totalAssetSupply();
        iPool.setTotalAssetBorrow(iSupply * bound(seedB, 0, 12_000) / 10_000);
    }

    /// Entry gate as the vault computes it, read through the adapter.
    function _underCeiling(uint256 i) internal view returns (bool) {
        (bool ok, bytes memory data) =
            address(vault.adapters(i)).staticcall(abi.encodeWithSignature("getUtilization()"));
        if (!ok) return false;
        return abi.decode(data, (uint256)) < vault.utilizationCeilingBps() * 1e14;
    }

    /// A venue at or above the ceiling before the deposit must not have
    /// received a single wei of it (deposits change no market state before
    /// the gate check, so pre-call utilization is what the vault saw).
    function _assertCeilingRespected(bool underA, bool underB, uint256 beforeA, uint256 beforeB) internal view {
        if (!underA) require(_adapterBalance(0) == beforeA, "deposit fed adapter 0 at the utilization ceiling");
        if (!underB) require(_adapterBalance(1) == beforeB, "deposit fed adapter 1 at the utilization ceiling");
    }

    /// Deposits must never push an adapter ABOVE its cap with new money;
    /// pre-existing yield drift above the cap is allowed (only a rebalance
    /// trues it up). A successful rebalance must land exactly within caps.
    /// Allocation cannot be finer than one token-wei of each protocol's
    /// receipt token: Sovryn iToken granularity is tokenPrice/1e18 underlying
    /// wei, LayerBank aToken granularity is liquidityIndex/1e27. The tolerance
    /// scales with both so long fuzz runs with compounding yield stay honest.
    function _capTolerance() internal view returns (uint256) {
        return (iPool.tokenPrice() / 1e18 + lbPool.liquidityIndex(address(asset)) / 1e27 + 2) * 4 + 16;
    }

    function _assertDepositRespectsCaps(uint256 beforeA, uint256 beforeB) internal view {
        uint256 idle = asset.balanceOf(address(vault));
        uint256 a = _adapterBalance(0);
        uint256 b = _adapterBalance(1);
        uint256 cap = (idle + a + b) * vault.adapterCapBps() / 10_000;
        uint256 tol = _capTolerance();
        uint256 limitA = beforeA > cap ? beforeA : cap;
        uint256 limitB = beforeB > cap ? beforeB : cap;
        require(a <= limitA + tol, "deposit pushed adapter 0 above its cap");
        require(b <= limitB + tol, "deposit pushed adapter 1 above its cap");
    }

    function _assertRebalanceLandsWithinCaps() internal view {
        uint256 idle = asset.balanceOf(address(vault));
        uint256 a = _adapterBalance(0);
        uint256 b = _adapterBalance(1);
        uint256 cap = (idle + a + b) * vault.adapterCapBps() / 10_000;
        uint256 tol = _capTolerance() + (idle + a + b) / 1e6; // + negligible-dust allowance
        require(a <= cap + tol, "rebalance left adapter 0 above its cap");
        require(b <= cap + tol, "rebalance left adapter 1 above its cap");
    }

    /// A deposit can never carry totalAssets past the immutable TVL cap (vested
    /// yield may later exceed it, that is not new exposure, so this only fires
    /// right after a deposit). Skipped for uncapped vaults.
    function _assertUnderTvlCap() internal view {
        uint256 cap = vault.tvlCap();
        if (cap == type(uint256).max) return;
        require(vault.totalAssets() <= cap + _capTolerance(), "deposit breached tvl cap");
    }

    function _adapterBalance(uint256 i) internal view returns (uint256) {
        (bool ok, bytes memory data) = address(vault.adapters(i)).staticcall(abi.encodeWithSignature("getBalance()"));
        return ok ? abi.decode(data, (uint256)) : 0;
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        uint256 max = vault.maxWithdraw(actor);
        if (max == 0) return;
        amount = bound(amount, 1, max);

        vm.prank(actor);
        // Partial withdrawals may legitimately hit a sub-dust pull slice;
        // the hard liveness property is asserted in fullExit
        try vault.withdraw(amount, actor, actor) {} catch {}
    }

    function rebalance(uint256 rateSeed, uint256 timeJump) external {
        // Keep both rates strictly under the vault's sane cap so the fuzzer
        // actually exercises rebalances rather than always hitting the filter
        uint256 cap = vault.maxSaneRate();
        uint256 rateA = bound(rateSeed, 1e15, cap - 1);
        uint256 rateB = bound(uint256(keccak256(abi.encode(rateSeed))), 1e15, cap - 1);
        lbPool.setSupplyRate1e18(address(asset), rateA);
        iPool.setSupplyInterestRate((rateB) * 100);

        vm.warp(block.timestamp + cooldown + bound(timeJump, 1, 30 days));
        bool underA = _underCeiling(0);
        bool underB = _underCeiling(1);
        uint256 extA = _externalLbSupply();
        uint256 extB = _externalSovSupply();
        uint256 lastBefore = vault.lastRebalanceTime();
        try vault.rebalance() {} catch {}
        if (vault.lastRebalanceTime() != lastBefore) {
            _assertRebalanceLandsWithinCaps();
            _assertRebalanceDrainsGatedVenues(underA, underB, extA, extB);
        }
    }

    /// Receipt-token supply the vault CANNOT pull (in-kind redeemers keep
    /// their aTokens/iTokens). Only while this exists does a gated venue
    /// provably stay gated through a rebalance: the pull cannot empty the
    /// market, so the empty-market 0% utilization read cannot fire mid-call.
    function _externalLbSupply() internal view returns (uint256) {
        return lbPool.aTokens(address(asset)).totalSupply() - _adapterBalance(0);
    }

    function _externalSovSupply() internal view returns (uint256) {
        return iPool.totalAssetSupply() - iPool.assetBalanceOf(address(vault.adapters(1)));
    }

    /// A successful rebalance pulls everything and redeploys only below the
    /// ceiling. Pulling supply RAISES utilization (debt is unchanged), so a
    /// venue gated before the call stays gated at redeploy time and may keep
    /// at most the sub-dust remainder the pull loop tolerates. Vacuous when
    /// the vault is the market's only supplier (see _externalLbSupply).
    function _assertRebalanceDrainsGatedVenues(bool underA, bool underB, uint256 extA, uint256 extB) internal view {
        uint256 total = asset.balanceOf(address(vault)) + _adapterBalance(0) + _adapterBalance(1);
        uint256 tol = _capTolerance() + total / 1e6;
        if (!underA && extA > 0) require(_adapterBalance(0) <= tol, "rebalance redeployed into gated adapter 0");
        if (!underB && extB > 0) require(_adapterBalance(1) <= tol, "rebalance redeployed into gated adapter 1");
    }

    // Solvency/liveness: a depositor pulling their entire balance must always
    // succeed, with ONE precisely-scoped exception that mirrors real Aave:
    // when the required pull from the pool is below one "index-wei"
    // (amount * RAY / index rounds to 0 scaled), the pool reverts
    // "invalid burn amount", real Aave's INVALID_BURN_AMOUNT. Anything
    // beyond that dust band must succeed or the invariant run fails.
    // (Tier 1 backlog: use Aave's type(uint256).max full-withdraw sentinel
    // in the adapters to close even the dust band.)
    function fullExit(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        uint256 max = vault.maxWithdraw(actor);
        if (max == 0) return;

        vm.prank(actor);
        try vault.withdraw(max, actor, actor) {}
        catch {
            // A full exit may fail only because the final pull slice rounds
            // below one protocol grain. Exiting within one dust margin of the
            // full entitlement must ALWAYS succeed, no try/catch.
            uint256 dl = _dustLimit();
            // A position smaller than one protocol grain may be unexitable in
            // full (real Aave parity), nothing meaningful to assert
            if (max <= dl) return;
            vm.prank(actor);
            vault.withdraw(max - dl, actor, actor);
        }
    }

    /// In-kind exits must always succeed for any meaningful share amount:
    /// they need nothing from the protocols beyond ERC-20 transfers.
    function redeemInKindExit(uint256 actorSeed, uint256 shareSeed) external {
        address actor = _actor(actorSeed);
        uint256 bal = vault.balanceOf(actor);
        if (bal == 0) return;
        uint256 shares = bound(shareSeed, 1, bal);
        if (vault.previewRedeem(shares) == 0) return;
        // One run in three, brick a random adapter's balance view: the in-kind
        // escape hatch must STILL succeed (the hardening treats it as zero,
        // never reverts). Window is one call, cleared right after.
        bool bricked = shareSeed % 3 == 0;
        if (bricked) {
            vm.mockCallRevert(address(vault.adapters(shareSeed % 2)), abi.encodeWithSignature("getBalance()"), "frozen");
            if (vault.previewRedeem(shares) == 0) {
                vm.clearMockedCalls();
                return;
            }
        }
        vm.prank(actor);
        vault.redeemInKind(shares, actor, actor);
        if (bricked) vm.clearMockedCalls();
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 1, 1e24);
        asset.mint(address(vault), amount);
        ghost_donated += amount;
    }

    /// Yield accrual bounded to +50% of each pool's current balance per call:
    /// realistic lending yield cannot multiply a pool in one update, and
    /// unbounded growth drives mock token prices to magnitudes where token
    /// granularity (1 token-wei worth >> 1 wei) makes any allocation math
    /// meaningless, an artifact no real market exhibits.
    function accrue(uint256 amount) external {
        uint256 lbBal = asset.balanceOf(address(lbPool));
        if (lbBal > 0) {
            asset.mint(address(lbPool), bound(amount, 0, lbBal / 2));
            lbPool.accrueInterest(address(asset));
        }
        uint256 iBal = asset.balanceOf(address(iPool));
        if (iBal > 0) {
            asset.mint(address(iPool), bound(amount, 0, iBal / 2));
            iPool.accrueInterest();
        }
    }
}
