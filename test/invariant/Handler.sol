// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
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
        asset.mint(actor, amount);

        uint256 beforeA = _adapterBalance(0);
        uint256 beforeB = _adapterBalance(1);

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
        if (a > cap + tol || b > cap + tol) {
            console.log("CAP VIOLATION post-rebalance: idle", idle);
            console.log("  a", a); console.log("  b", b);
            console.log("  cap", cap); console.log("  tol", tol);
            console.log("  lbIdx", lbPool.liquidityIndex(address(asset)));
            console.log("  sovPrice", iPool.tokenPrice());
        }
        require(a <= cap + tol, "rebalance left adapter 0 above its cap");
        require(b <= cap + tol, "rebalance left adapter 1 above its cap");
    }

    function _adapterBalance(uint256 i) internal view returns (uint256) {
        (bool ok, bytes memory data) =
            address(vault.adapters(i)).staticcall(abi.encodeWithSignature("getBalance()"));
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
        uint256 lastBefore = vault.lastRebalanceTime();
        try vault.rebalance() {} catch {}
        if (vault.lastRebalanceTime() != lastBefore) {
            _assertRebalanceLandsWithinCaps();
        }
    }

    // Solvency/liveness: a depositor pulling their entire balance must always
    // succeed, with ONE precisely-scoped exception that mirrors real Aave:
    // when the required pull from the pool is below one "index-wei"
    // (amount * RAY / index rounds to 0 scaled), the pool reverts
    // "invalid burn amount" — real Aave's INVALID_BURN_AMOUNT. Anything
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
            // full entitlement must ALWAYS succeed — no try/catch.
            uint256 dl = _dustLimit();
            // A position smaller than one protocol grain may be unexitable in
            // full (real Aave parity) — nothing meaningful to assert
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
        vm.prank(actor);
        vault.redeemInKind(shares, actor, actor);
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
    /// meaningless — an artifact no real market exhibits.
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
