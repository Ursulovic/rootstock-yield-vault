// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {YieldVault} from "../../src/YieldVault.sol";
import {MockWRBTC} from "../mocks/MockWRBTC.sol";
import {MockLayerBankPool} from "../mocks/MockLayerBankPool.sol";
import {MockiToken} from "../mocks/MockiToken.sol";

/// @notice Drives the native rBTC vault through random sequences for invariant
///         testing: native and ERC-4626 deposits/withdrawals, rebalances, WRBTC
///         donations and yield accrual on both protocols. Mirrors Handler.sol
///         but exercises the native-only paths (wrap/unwrap, receive() filter,
///         native balance-delta accounting in rebalance).
contract NativeVaultHandler is Test {
    uint256 internal constant RAY = 1e27;

    YieldVault public immutable vault;
    MockWRBTC public immutable wrbtc;
    MockLayerBankPool public immutable lbPool;
    MockiToken public immutable iPool;
    uint256 public immutable cooldown;

    address[] public actors;
    uint256 public ghost_donated;

    constructor(
        YieldVault _vault,
        MockWRBTC _wrbtc,
        MockLayerBankPool _lbPool,
        MockiToken _iPool,
        uint256 _cooldown
    ) {
        vault = _vault;
        wrbtc = _wrbtc;
        lbPool = _lbPool;
        iPool = _iPool;
        cooldown = _cooldown;
        actors.push(makeAddr("ninv_alice"));
        actors.push(makeAddr("ninv_bob"));
        actors.push(makeAddr("ninv_carol"));
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// Tolerated failure band for LayerBank pulls: amounts whose scaled value
    /// rounds to zero revert "invalid burn amount" on real Aave too.
    function _dustLimit() internal view returns (uint256) {
        uint256 idx = lbPool.liquidityIndex(address(wrbtc));
        return idx / 1e27 * 2 + idx / (2 * 1e27) + 2;
    }

    function depositNative(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, 1, 1e24);
        vm.deal(actor, amount);

        uint256 beforeA = _adapterBalance(0);
        uint256 beforeB = _adapterBalance(1);

        vm.prank(actor);
        // No tolerance: the vault catches sub-dust slices internally, so a
        // deposit revert here is a real bug
        vault.depositNative{value: amount}(actor);

        if (address(vault.activeAdapter()) == address(0) && wrbtc.balanceOf(address(vault)) > 0) {
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
        return (iPool.tokenPrice() / 1e18 + lbPool.liquidityIndex(address(wrbtc)) / 1e27 + 2) * 4 + 16;
    }

    function _assertDepositRespectsCaps(uint256 beforeA, uint256 beforeB) internal view {
        uint256 idle = wrbtc.balanceOf(address(vault));
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
        uint256 idle = wrbtc.balanceOf(address(vault));
        uint256 a = _adapterBalance(0);
        uint256 b = _adapterBalance(1);
        uint256 cap = (idle + a + b) * vault.adapterCapBps() / 10_000;
        uint256 tol = _capTolerance() + (idle + a + b) / 1e6; // + negligible-dust allowance
        require(a <= cap + tol, "rebalance left adapter 0 above its cap");
        require(b <= cap + tol, "rebalance left adapter 1 above its cap");
    }

    function _adapterBalance(uint256 i) internal view returns (uint256) {
        (bool ok, bytes memory data) =
            address(vault.adapters(i)).staticcall(abi.encodeWithSignature("getBalance()"));
        return ok ? abi.decode(data, (uint256)) : 0;
    }

    function depositWrapped(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, 1, 1e24);
        vm.deal(actor, amount);

        uint256 beforeA = _adapterBalance(0);
        uint256 beforeB = _adapterBalance(1);

        vm.startPrank(actor);
        wrbtc.deposit{value: amount}();
        wrbtc.approve(address(vault), amount);
        vault.deposit(amount, actor);
        vm.stopPrank();
        _assertDepositRespectsCaps(beforeA, beforeB);
    }

    function withdrawNative(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        uint256 max = vault.maxWithdraw(actor);
        if (max == 0) return;
        amount = bound(amount, 1, max);
        uint256 idle = wrbtc.balanceOf(address(vault));

        vm.prank(actor);
        // Partial withdrawals may legitimately hit a sub-dust pull slice;
        // the hard liveness property is asserted in fullExit
        try vault.withdrawNative(amount, actor, actor) {} catch {}
    }

    function rebalance(uint256 rateSeed, uint256 timeJump) external {
        uint256 cap = vault.maxSaneRate();
        uint256 rateA = bound(rateSeed, 1e15, cap - 1);
        uint256 rateB = bound(uint256(keccak256(abi.encode(rateSeed))), 1e15, cap - 1);
        lbPool.setSupplyRate1e18(address(wrbtc), rateA);
        iPool.setSupplyInterestRate(rateB * 100); // Sovryn mock is percent-scaled

        vm.warp(block.timestamp + cooldown + bound(timeJump, 1, 30 days));
        uint256 lastBefore = vault.lastRebalanceTime();
        try vault.rebalance() {} catch {}
        if (vault.lastRebalanceTime() != lastBefore) {
            _assertRebalanceLandsWithinCaps();
        }
    }

    // Solvency/liveness with the same precisely-scoped dust exception as the
    // ERC20 handler: anything beyond the sub-index-wei band must succeed.
    function fullExit(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        uint256 max = vault.maxWithdraw(actor);
        if (max == 0) return;

        vm.prank(actor);
        try vault.withdrawNative(max, actor, actor) {}
        catch {
            // A full exit may fail only because the final pull slice rounds
            // below one protocol grain. Exiting within one dust margin of the
            // full entitlement must ALWAYS succeed — no try/catch.
            uint256 dl = _dustLimit();
            // A position smaller than one protocol grain may be unexitable in
            // full (real Aave parity) — nothing meaningful to assert
            if (max <= dl) return;
            vm.prank(actor);
            vault.withdrawNative(max - dl, actor, actor);
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

    /// WRBTC ERC-20 donation — the channel the receive() filter cannot block
    function donateWrbtc(uint256 amount) external {
        amount = bound(amount, 1, 1e24);
        vm.deal(address(this), amount);
        wrbtc.deposit{value: amount}();
        wrbtc.transfer(address(vault), amount);
        ghost_donated += amount;
    }

    /// Direct native send must ALWAYS revert — the donation filter at work
    function donateNativeMustRevert(uint256 amount) external {
        amount = bound(amount, 1, 1e24);
        address rando = makeAddr("ninv_rando");
        vm.deal(rando, amount);
        vm.prank(rando);
        (bool ok,) = address(vault).call{value: amount}("");
        require(!ok, "vault accepted rBTC from an arbitrary sender");
    }

    /// Yield accrual bounded to +50% of each pool's current balance per call:
    /// realistic lending yield cannot multiply a pool in one update, and
    /// unbounded growth drives mock token prices to magnitudes where token
    /// granularity (1 token-wei worth >> 1 wei) makes any allocation math
    /// meaningless — an artifact no real market exhibits.
    function accrue(uint256 amount) external {
        uint256 lbBal = wrbtc.balanceOf(address(lbPool));
        if (lbBal > 0) {
            uint256 gain = bound(amount, 0, lbBal / 2);
            if (gain > 0) {
                vm.deal(address(this), gain);
                wrbtc.deposit{value: gain}();
                wrbtc.transfer(address(lbPool), gain);
            }
            lbPool.accrueInterest(address(wrbtc));
        }
        uint256 iBal = address(iPool).balance;
        if (iBal > 0) {
            vm.deal(address(iPool), iBal + bound(amount, 0, iBal / 2));
            iPool.accrueInterest();
        }
    }

    receive() external payable {}
}
