// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {YieldVault} from "../src/YieldVault.sol";
import {ERC20YieldVault} from "../src/ERC20YieldVault.sol";
import {LayerBankAdapter} from "../src/adapters/LayerBankAdapter.sol";
import {LayerBankERC20Adapter} from "../src/adapters/LayerBankERC20Adapter.sol";
import {SovrynAdapter} from "../src/adapters/SovrynAdapter.sol";
import {SovrynERC20Adapter} from "../src/adapters/SovrynERC20Adapter.sol";
import {ILendingAdapter} from "../src/interfaces/ILendingAdapter.sol";
import {IERC20LendingAdapter} from "../src/interfaces/IERC20LendingAdapter.sol";
import {MockWRBTC} from "./mocks/MockWRBTC.sol";
import {MockLayerBankPool} from "./mocks/MockLayerBankPool.sol";
import {MockiToken} from "./mocks/MockiToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockLoanToken} from "./mocks/MockLoanToken.sol";
import {MockBrokenAdapter} from "./mocks/MockBrokenAdapter.sol";

/// @notice Tests for the Tier 1 feature set: EIP-2612 permit, adapter health
///         checks with failure isolation, and the LayerBank full-withdraw
///         sentinel.
contract Tier1Test is Test {
    YieldVault vault;
    MockWRBTC wrbtc;
    MockLayerBankPool lbPool;
    MockiToken mockIToken;
    LayerBankAdapter lbAdapter;
    SovrynAdapter sovrynAdapter;

    address alice;
    uint256 alicePk;
    address bob = makeAddr("t1_bob");
    address rebalancer = makeAddr("t1_rebalancer");

    uint256 constant COOLDOWN = 3600;
    uint256 constant THRESHOLD = 5e14;
    uint256 constant REWARD_BPS = 100;
    uint256 constant MAX_RATE = 0.5e18;
    uint256 constant CAP_BPS = 6000; // 60% per-adapter cap
    uint256 constant TVL_CAP = type(uint256).max;

    function setUp() public {
        (alice, alicePk) = makeAddrAndKey("t1_alice");

        wrbtc = new MockWRBTC();
        lbPool = new MockLayerBankPool();
        lbPool.initReserve(address(wrbtc));
        mockIToken = new MockiToken();

        lbAdapter = new LayerBankAdapter(address(lbPool), address(wrbtc));
        sovrynAdapter = new SovrynAdapter(address(mockIToken));

        ILendingAdapter[] memory adapters = new ILendingAdapter[](2);
        adapters[0] = ILendingAdapter(address(lbAdapter));
        adapters[1] = ILendingAdapter(address(sovrynAdapter));
        vault = new YieldVault(address(wrbtc), adapters, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_RATE, CAP_BPS, TVL_CAP);

        lbPool.setSupplyRate1e18(address(wrbtc), 5e16);
        mockIToken.setSupplyInterestRate(3e16 * 100); // percent scale

        vm.deal(alice, 10 ether);
    }

    // ------------------------------------------------------------------
    // EIP-2612 permit
    // ------------------------------------------------------------------

    function test_Permit_SetsAllowanceFromSignature() public {
        vm.prank(alice);
        uint256 shares = vault.depositNative{value: 1 ether}(alice);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                alice,
                bob,
                shares,
                vault.nonces(alice),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

        // Gasless approval: bob submits alice's signature, then spends
        vm.prank(bob);
        vault.permit(alice, bob, shares, deadline, v, r, s);
        assertEq(vault.allowance(alice, bob), shares, "permit should set allowance");

        vm.prank(bob);
        vault.withdrawNative(1 ether, bob, alice);
        assertEq(bob.balance, 1 ether, "spender should withdraw via permit allowance");
    }

    function test_Permit_RejectsWrongSigner() public {
        (, uint256 evePk) = makeAddrAndKey("t1_eve");
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                alice,
                bob,
                1 ether,
                vault.nonces(alice),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(evePk, digest);

        vm.expectRevert();
        vault.permit(alice, bob, 1 ether, deadline, v, r, s);
    }

    // ------------------------------------------------------------------
    // Adapter health + failure isolation
    // ------------------------------------------------------------------

    function _vaultWithBrokenAdapter()
        internal
        returns (YieldVault v, MockBrokenAdapter broken, LayerBankAdapter healthy)
    {
        broken = new MockBrokenAdapter();
        healthy = new LayerBankAdapter(address(lbPool), address(wrbtc));

        ILendingAdapter[] memory adapters = new ILendingAdapter[](2);
        adapters[0] = ILendingAdapter(address(broken));
        adapters[1] = ILendingAdapter(address(healthy));
        v = new YieldVault(address(wrbtc), adapters, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_RATE, CAP_BPS, TVL_CAP);
    }

    function test_AdapterHealth_ReportsBrokenAdapter() public {
        (YieldVault v, MockBrokenAdapter broken,) = _vaultWithBrokenAdapter();

        bool[] memory health = v.getAdapterHealth();
        assertFalse(health[0], "broken adapter must report unhealthy");
        assertTrue(health[1], "healthy adapter must report healthy");

        broken.setBroken(false, false);
        assertTrue(v.isAdapterHealthy(0), "recovered adapter reports healthy again");
    }

    function test_Selection_SkipsAdapterWithRevertingRate() public {
        (YieldVault v, MockBrokenAdapter broken, LayerBankAdapter healthy) = _vaultWithBrokenAdapter();
        // Rate query bricked, balance still readable — the realistic partial
        // failure. (A reverting getBalance fails the whole vault closed by
        // design: share pricing must never silently undercount.)
        broken.setBroken(true, false);

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        v.depositNative{value: 1 ether}(alice);
        v.initialDeposit();

        assertEq(address(v.activeAdapter()), address(healthy), "selection must skip the broken adapter");
    }

    function test_TotalAssets_FailsClosedOnBrokenBalance() public {
        (YieldVault v, MockBrokenAdapter broken,) = _vaultWithBrokenAdapter();
        broken.setBroken(false, true);

        // Fail-closed: a balance query that reverts must brick pricing rather
        // than silently undercount and let exits drain at a wrong share price
        vm.expectRevert("protocol down");
        v.totalAssets();
    }

    // ------------------------------------------------------------------
    // In-kind redemption
    // ------------------------------------------------------------------

    function _receiverValue(address who) internal view returns (uint256) {
        address aTokenAddr = address(lbPool.aTokens(address(wrbtc)));
        (, bytes memory d) = aTokenAddr.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        uint256 aVal = abi.decode(d, (uint256));
        uint256 iVal = mockIToken.balanceOf(who) * mockIToken.tokenPrice() / 1e18;
        return aVal + iVal + wrbtc.balanceOf(who);
    }

    function test_RedeemInKind_DeliversProRataPositions() public {
        vm.prank(alice);
        uint256 shares = vault.depositNative{value: 10 ether}(alice);
        vault.initialDeposit(); // LB 6 / Sovryn 4

        address receiver = makeAddr("t1_inkind_receiver");
        vm.prank(alice);
        uint256 value = vault.redeemInKind(shares / 2, receiver, alice);

        assertApproxEqAbs(value, 5 ether, 4, "half the shares redeem half the value");
        assertApproxEqAbs(_receiverValue(receiver), value, 8, "receiver holds the value in receipt tokens");
        assertApproxEqAbs(vault.totalAssets(), 5 ether, 8, "vault keeps the other half");
    }

    function test_RedeemInKind_WorksWhenPoolPaused() public {
        vm.prank(alice);
        uint256 shares = vault.depositNative{value: 10 ether}(alice);
        vault.initialDeposit();

        // The pool pauses: normal exit paths die, in-kind keeps working
        lbPool.setPaused(true);
        vm.prank(alice);
        vm.expectRevert();
        vault.withdrawNative(8 ether, alice, alice);

        address receiver = makeAddr("t1_paused_receiver");
        vm.prank(alice);
        uint256 value = vault.redeemInKind(shares, receiver, alice);

        assertGt(value, 9.9 ether, "full in-kind exit while the pool is paused");
        assertEq(vault.balanceOf(alice), 0, "all shares burned");
    }

    function test_RedeemInKind_CannotBypassVesting() public {
        vm.prank(alice);
        vault.depositNative{value: 5 ether}(alice);
        vault.initialDeposit();

        // Big unvested jump lands
        _accrueGain(2 ether);

        address sniper = makeAddr("t1_inkind_sniper");
        vm.deal(sniper, 5 ether);
        vm.prank(sniper);
        uint256 shares = vault.depositNative{value: 5 ether}(sniper);

        vm.prank(sniper);
        uint256 value = vault.redeemInKind(shares, sniper, sniper);

        assertLe(value, 5 ether, "in-kind exit must not capture locked profit");
    }

    function test_RedeemInKind_AllowanceAndZeroChecks() public {
        vm.prank(alice);
        uint256 shares = vault.depositNative{value: 1 ether}(alice);

        vm.expectRevert("zero shares");
        vault.redeemInKind(0, bob, alice);

        // No allowance: bob cannot redeem alice's shares
        vm.prank(bob);
        vm.expectRevert();
        vault.redeemInKind(shares, bob, alice);

        // With allowance it works
        vm.prank(alice);
        vault.approve(bob, shares);
        vm.prank(bob);
        uint256 value = vault.redeemInKind(shares, bob, alice);
        assertApproxEqAbs(value, 1 ether, 2, "allowance-based in-kind redemption");
    }

    // ------------------------------------------------------------------
    // Per-adapter concentration caps (60%)
    // ------------------------------------------------------------------

    function test_Caps_InitialDepositSplits6040() public {
        vm.prank(alice);
        vault.depositNative{value: 10 ether}(alice);
        vault.initialDeposit();

        // LayerBank (5%) is primary at the 60% cap, Sovryn takes the spill
        assertApproxEqAbs(lbAdapter.getBalance(), 6 ether, 2, "primary fills to its cap");
        assertApproxEqAbs(sovrynAdapter.getBalance(), 4 ether, 2, "spill goes to the next-best adapter");
        assertLe(wrbtc.balanceOf(address(vault)), 2, "nothing should stay idle with two sane adapters");
    }

    function test_Caps_DepositTopsUpByRateOrder() public {
        vm.prank(alice);
        vault.depositNative{value: 10 ether}(alice);
        vault.initialDeposit(); // 6/4

        vm.deal(bob, 10 ether);
        vm.prank(bob);
        vault.depositNative{value: 10 ether}(bob);

        // New total 20: primary cap 12, secondary 8
        assertApproxEqAbs(lbAdapter.getBalance(), 12 ether, 4, "primary tops up to the new cap");
        assertApproxEqAbs(sovrynAdapter.getBalance(), 8 ether, 4, "secondary takes the remainder");
    }

    function test_Caps_WithdrawDrainsWorstRateFirst() public {
        vm.prank(alice);
        vault.depositNative{value: 10 ether}(alice);
        vault.initialDeposit(); // LB 6 / Sovryn 4 (Sovryn is the worse rate)

        vm.prank(alice);
        vault.withdrawNative(3 ether, alice, alice);

        assertApproxEqAbs(lbAdapter.getBalance(), 6 ether, 2, "best-rate allocation untouched");
        assertApproxEqAbs(sovrynAdapter.getBalance(), 1 ether, 2, "worst-rate allocation drained first");
    }

    function test_Caps_SingleSaneAdapter_RemainderStaysIdle() public {
        // Sovryn insane from the start: only LayerBank is usable
        mockIToken.setSupplyInterestRate(0.6e18 * 100); // 60% — above the 50% cap
        vm.prank(alice);
        vault.depositNative{value: 10 ether}(alice);
        vault.initialDeposit();

        assertApproxEqAbs(lbAdapter.getBalance(), 6 ether, 2, "single sane adapter capped at 60%");
        assertEq(sovrynAdapter.getBalance(), 0, "insane adapter gets nothing");
        assertApproxEqAbs(wrbtc.balanceOf(address(vault)), 4 ether, 2, "cap remainder stays idle");
    }

    function test_Caps_RebalanceSwapsAllocation() public {
        vm.prank(alice);
        vault.depositNative{value: 10 ether}(alice);
        vault.initialDeposit(); // LB 6 / Sovryn 4

        mockIToken.setSupplyInterestRate(8e16 * 100); // Sovryn now best
        vm.warp(block.timestamp + COOLDOWN + 1);
        vm.prank(rebalancer);
        vault.rebalance();

        assertEq(address(vault.activeAdapter()), address(sovrynAdapter), "primary flips");
        assertApproxEqAbs(sovrynAdapter.getBalance(), 6 ether, 4, "new primary fills to its cap");
        assertApproxEqAbs(lbAdapter.getBalance(), 4 ether, 4, "old primary keeps the spill");
    }

    function test_Caps_ConstructorValidation() public {
        ILendingAdapter[] memory adapters = new ILendingAdapter[](2);
        adapters[0] = ILendingAdapter(address(new LayerBankAdapter(address(lbPool), address(wrbtc))));
        adapters[1] = ILendingAdapter(address(new SovrynAdapter(address(mockIToken))));

        vm.expectRevert("bad adapter cap");
        new YieldVault(address(wrbtc), adapters, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_RATE, 0, TVL_CAP);

        vm.expectRevert("bad adapter cap");
        new YieldVault(address(wrbtc), adapters, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_RATE, 10_001, TVL_CAP);

        // 2 adapters x 40% = 80% < 100% — deposits could never be fully placed
        vm.expectRevert("caps cannot cover deposits");
        new YieldVault(address(wrbtc), adapters, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_RATE, 4000, TVL_CAP);
    }

    // ------------------------------------------------------------------
    // Linear profit unlock (3 days)
    // ------------------------------------------------------------------

    function _accrueGain(uint256 amount) internal {
        vm.deal(address(this), amount);
        wrbtc.deposit{value: amount}();
        wrbtc.transfer(address(lbPool), amount);
        lbPool.accrueInterest(address(wrbtc));
    }

    function test_ProfitUnlock_VestsLinearly() public {
        vm.prank(alice);
        vault.depositNative{value: 5 ether}(alice);
        vault.initialDeposit(); // LayerBank

        _accrueGain(0.3 ether); // deployed 5 -> 5.3, unrecognized

        // Unrecognized gain is invisible to the price
        assertEq(vault.totalAssets(), 5 ether, "unrecognized gain must not move the price");

        // Any interaction checkpoints it; it then vests linearly
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vault.depositNative{value: 1 ether}(bob);

        assertApproxEqAbs(vault.totalAssets(), 6 ether, 2, "locked profit stays out of the price at t0");
        assertApproxEqAbs(vault.lockedProfit(), 0.3 ether, 2, "full gain locked at checkpoint");

        vm.warp(block.timestamp + vault.PROFIT_UNLOCK_PERIOD() / 2);
        assertApproxEqAbs(vault.lockedProfit(), 0.15 ether, 2, "half vested at half period");
        assertApproxEqAbs(vault.totalAssets(), 6.15 ether, 2, "price reflects vested half");

        vm.warp(block.timestamp + vault.PROFIT_UNLOCK_PERIOD() / 2);
        assertEq(vault.lockedProfit(), 0, "fully vested");
        assertApproxEqAbs(vault.totalAssets(), 6.3 ether, 2, "price reflects the full gain");
    }

    function test_ProfitUnlock_SnipeAfterJumpDoesNotProfit() public {
        vm.prank(alice);
        vault.depositNative{value: 5 ether}(alice);
        vault.initialDeposit();

        // A big balance jump lands (lazy index update / airdrop style)
        _accrueGain(2 ether);

        // Sniper deposits right after the jump and exits immediately
        address sniper = makeAddr("t1_sniper");
        vm.deal(sniper, 5 ether);
        vm.prank(sniper);
        uint256 shares = vault.depositNative{value: 5 ether}(sniper);
        vm.prank(sniper);
        uint256 outAssets = vault.redeem(shares, sniper, sniper);

        assertLe(outAssets, 5 ether, "sniping a balance jump must not profit");
    }

    function test_Loss_AbsorbedByLockedBufferFirst() public {
        vm.prank(alice);
        vault.depositNative{value: 5 ether}(alice);
        vault.initialDeposit(); // LayerBank at 5%

        // Recognize a gain so a locked buffer exists
        _accrueGain(0.3 ether);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vault.depositNative{value: 1 ether}(bob); // checkpoint: 0.3 locked

        // Underlying loses 0.2 — less than the buffer
        uint256 poolBal = wrbtc.balanceOf(address(lbPool));
        vm.prank(address(lbPool));
        wrbtc.transfer(address(0xdead), 0.2 ether);
        assertLt(wrbtc.balanceOf(address(lbPool)), poolBal);
        lbPool.accrueInterest(address(wrbtc));

        // The loss eats vesting profit, not principal
        assertGe(vault.totalAssets(), 6 ether, "principal must be intact while the buffer absorbs the loss");
    }

    // ------------------------------------------------------------------
    // LayerBank full-withdraw sentinel (dust-free exits)
    // ------------------------------------------------------------------

    function test_Sentinel_FullPullLeavesNoScaledDust() public {
        // Deposit through the adapter directly (as the vault), skew the index
        // to a value where an exact-amount withdrawal would round below the
        // full scaled balance, then withdraw the entire reported balance
        vm.deal(address(vault), 1 ether);
        vm.prank(address(vault));
        lbAdapter.deposit{value: 1 ether}();

        vm.deal(address(this), 0.123456789 ether);
        wrbtc.deposit{value: 0.123456789 ether}();
        wrbtc.transfer(address(lbPool), 0.123456789 ether);
        lbPool.accrueInterest(address(wrbtc));

        uint256 held = lbAdapter.getBalance();
        vm.prank(address(vault));
        uint256 received = lbAdapter.withdraw(held);
        assertGe(received, held, "full pull must deliver the full balance");

        address aTokenAddr = address(lbPool.aTokens(address(wrbtc)));
        (bool ok, bytes memory data) =
            aTokenAddr.staticcall(abi.encodeWithSignature("scaledBalanceOf(address)", address(lbAdapter)));
        assertTrue(ok);
        assertEq(abi.decode(data, (uint256)), 0, "no scaled dust may remain after a full pull");
    }
}
