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
import {MockLayerBankPool, MockAToken} from "./mocks/MockLayerBankPool.sol";
import {MockiToken} from "./mocks/MockiToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockLoanToken} from "./mocks/MockLoanToken.sol";

/// @notice Pins the VALUE actually delivered by in-kind redemptions in both
///         vaults (idle slice + per-adapter receipt-token fractions, computed
///         on the UNDISCOUNTED raw holdings so locked profit stays behind),
///         the pro-rata trackedDeployed / rewardableYield shrink that follows,
///         and the ERC20 adapters' transferPosition fraction math.
contract InKindValueTest is Test {
    YieldVault vault;
    MockWRBTC wrbtc;
    MockLayerBankPool lbPool;
    MockiToken mockIToken;
    LayerBankAdapter lbAdapter;
    SovrynAdapter sovrynAdapter;

    ERC20YieldVault evault;
    MockERC20 doc;
    MockLayerBankPool lbPoolErc;
    MockLoanToken mockIDOC;
    LayerBankERC20Adapter lbErcAdapter;
    SovrynERC20Adapter sovErcAdapter;

    address alice = makeAddr("ikv_alice");
    address bob = makeAddr("ikv_bob");
    address carol = makeAddr("ikv_carol");

    uint256 constant COOLDOWN = 3600;
    uint256 constant THRESHOLD = 5e14;
    uint256 constant REWARD_BPS = 100;
    uint256 constant MAX_RATE = 0.5e18;
    uint256 constant CAP_BPS = 6000;
    uint256 constant TVL_CAP = type(uint256).max;

    function setUp() public {
        wrbtc = new MockWRBTC();
        lbPool = new MockLayerBankPool();
        lbPool.initReserve(address(wrbtc));
        mockIToken = new MockiToken();
        lbAdapter = new LayerBankAdapter(address(lbPool), address(wrbtc));
        sovrynAdapter = new SovrynAdapter(address(mockIToken));
        ILendingAdapter[] memory nAdapters = new ILendingAdapter[](2);
        nAdapters[0] = ILendingAdapter(address(lbAdapter));
        nAdapters[1] = ILendingAdapter(address(sovrynAdapter));
        vault = new YieldVault(address(wrbtc), nAdapters, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_RATE, CAP_BPS, TVL_CAP);

        doc = new MockERC20("Dollar on Chain", "DOC");
        lbPoolErc = new MockLayerBankPool();
        lbPoolErc.initReserve(address(doc));
        mockIDOC = new MockLoanToken(address(doc));
        lbErcAdapter = new LayerBankERC20Adapter(address(lbPoolErc), address(doc));
        sovErcAdapter = new SovrynERC20Adapter(address(mockIDOC), address(doc));
        IERC20LendingAdapter[] memory eAdapters = new IERC20LendingAdapter[](2);
        eAdapters[0] = IERC20LendingAdapter(address(lbErcAdapter));
        eAdapters[1] = IERC20LendingAdapter(address(sovErcAdapter));
        evault = new ERC20YieldVault(
            address(doc), eAdapters, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_RATE, CAP_BPS, TVL_CAP, "Test", "T", address(this)
        );

        // LayerBank primary (5%), Sovryn secondary (3%) in both stacks
        lbPool.setSupplyRate1e18(address(wrbtc), 5e16);
        mockIToken.setSupplyInterestRate(3e16 * 100); // percent scale
        lbPoolErc.setSupplyRate1e18(address(doc), 5e16);
        mockIDOC.setSupplyInterestRate(3e16 * 100);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _depositNative(address who, uint256 amount) internal {
        vm.deal(who, amount);
        vm.prank(who);
        vault.depositNative{value: amount}(who);
    }

    function _depositErc(address who, uint256 amount) internal {
        doc.mint(who, amount);
        vm.startPrank(who);
        doc.approve(address(evault), amount);
        evault.deposit(amount, who);
        vm.stopPrank();
    }

    function _accrueLbNative(uint256 gain) internal {
        vm.deal(address(this), gain);
        wrbtc.deposit{value: gain}();
        wrbtc.transfer(address(lbPool), gain);
        lbPool.accrueInterest(address(wrbtc));
    }

    function _accrueLbErc(uint256 gain) internal {
        doc.mint(address(lbPoolErc), gain);
        lbPoolErc.accrueInterest(address(doc));
    }

    /// Underlying value held by `who` across all in-kind delivery channels.
    function _receiverValueNative(address who) internal view returns (uint256) {
        uint256 aVal = lbPool.aTokens(address(wrbtc)).balanceOf(who);
        uint256 iVal = mockIToken.balanceOf(who) * mockIToken.tokenPrice() / 1e18;
        return aVal + iVal + wrbtc.balanceOf(who);
    }

    function _receiverValueErc(address who) internal view returns (uint256) {
        uint256 aVal = lbPoolErc.aTokens(address(doc)).balanceOf(who);
        uint256 iVal = mockIDOC.balanceOf(who) * mockIDOC.tokenPrice() / 1e18;
        return aVal + iVal + doc.balanceOf(who);
    }

    function _rawNative() internal view returns (uint256) {
        return wrbtc.balanceOf(address(vault)) + lbAdapter.getBalance() + sovrynAdapter.getBalance();
    }

    function _rawErc() internal view returns (uint256) {
        return doc.balanceOf(address(evault)) + lbErcAdapter.getBalance() + sovErcAdapter.getBalance();
    }

    // ------------------------------------------------------------------
    // Delivered value: vesting cannot be bypassed in kind
    // ------------------------------------------------------------------

    /// A sniper deposits right after an unrecognized balance jump and exits in
    /// kind. The RETURNED value is discounted by construction; what matters is
    /// that the TOKENS DELIVERED match it — a raw (undiscounted) denominator
    /// would hand the sniper a slice of the still-locked profit.
    function test_RedeemInKind_DeliveredValueRespectsVestingDiscount() public {
        _depositNative(alice, 5 ether);
        vault.initialDeposit(); // LB 3 / Sovryn 2

        _accrueLbNative(2 ether); // unrecognized jump: deployed 5 -> 7

        address sniper = makeAddr("ikv_sniper");
        vm.deal(sniper, 5 ether);
        vm.prank(sniper);
        uint256 shares = vault.depositNative{value: 5 ether}(sniper); // checkpoint locks the 2

        vm.prank(sniper);
        uint256 value = vault.redeemInKind(shares, sniper, sniper);

        assertLe(value, 5 ether, "returned value must not include locked profit");
        assertLe(_receiverValueNative(sniper), value + 2, "delivered tokens must not exceed the entitlement");
        assertApproxEqAbs(_receiverValueNative(sniper), 5 ether, 6, "sniper walks away with principal only");

        // The locked profit stays behind and vests to the pre-jump holder
        vm.warp(block.timestamp + vault.PROFIT_UNLOCK_PERIOD());
        assertGe(vault.maxWithdraw(alice) + 6, 7 ether, "remaining holder keeps the vested profit");
    }

    function test_ERC20_RedeemInKind_DeliveredValueRespectsVestingDiscount() public {
        _depositErc(alice, 5 ether);
        evault.initialDeposit(); // LB 3 / Sovryn 2

        _accrueLbErc(2 ether);

        address sniper = makeAddr("ikv_erc_sniper");
        doc.mint(sniper, 5 ether);
        vm.startPrank(sniper);
        doc.approve(address(evault), 5 ether);
        uint256 shares = evault.deposit(5 ether, sniper);
        uint256 value = evault.redeemInKind(shares, sniper, sniper);
        vm.stopPrank();

        assertLe(value, 5 ether, "returned value must not include locked profit");
        assertLe(_receiverValueErc(sniper), value + 2, "delivered tokens must not exceed the entitlement");
        assertApproxEqAbs(_receiverValueErc(sniper), 5 ether, 6, "sniper walks away with principal only");

        vm.warp(block.timestamp + evault.PROFIT_UNLOCK_PERIOD());
        assertGe(evault.maxWithdraw(alice) + 6, 7 ether, "remaining holder keeps the vested profit");
    }

    // ------------------------------------------------------------------
    // Delivered value: idle slice + per-position fractions
    // ------------------------------------------------------------------

    /// With idle, two live positions AND locked profit present at once, every
    /// component must be delivered at value/raw of the UNDISCOUNTED holdings.
    function test_RedeemInKind_DeliversIdleSliceAndPositionFractions() public {
        _depositNative(alice, 10 ether);
        vault.initialDeposit(); // LB 6 / Sovryn 4

        // Sovryn goes insane: the next deposit can only top LB up to its cap,
        // the remainder strands idle
        mockIToken.setSupplyInterestRate(0.6e18 * 100);
        _depositNative(alice, 5 ether); // LB 9 / Sovryn 4 / idle 2

        _accrueLbNative(1.5 ether); // recognized (and locked) by the redeem's own checkpoint

        uint256 idleBefore = wrbtc.balanceOf(address(vault));
        uint256 lbBefore = lbAdapter.getBalance();
        uint256 sovBefore = sovrynAdapter.getBalance();
        uint256 rawBefore = idleBefore + lbBefore + sovBefore;
        assertEq(idleBefore, 2 ether, "setup: cap remainder idles");

        address receiver = makeAddr("ikv_components");
        uint256 halfShares = vault.balanceOf(alice) / 2;
        vm.prank(alice);
        uint256 value = vault.redeemInKind(halfShares, receiver, alice);

        assertApproxEqAbs(wrbtc.balanceOf(receiver), idleBefore * value / rawBefore, 2, "idle WRBTC slice");
        assertApproxEqAbs(
            lbPool.aTokens(address(wrbtc)).balanceOf(receiver), lbBefore * value / rawBefore, 2, "aToken fraction"
        );
        assertApproxEqAbs(mockIToken.assetBalanceOf(receiver), sovBefore * value / rawBefore, 2, "iToken fraction");
        assertApproxEqAbs(_receiverValueNative(receiver), value, 6, "components sum to the entitlement");
    }

    function test_ERC20_RedeemInKind_DeliversIdleSliceAndPositionFractions() public {
        _depositErc(alice, 10 ether);
        evault.initialDeposit(); // LB 6 / Sovryn 4

        mockIDOC.setSupplyInterestRate(0.6e18 * 100);
        _depositErc(alice, 5 ether); // LB 9 / Sovryn 4 / idle 2

        _accrueLbErc(1.5 ether);

        uint256 idleBefore = doc.balanceOf(address(evault));
        uint256 lbBefore = lbErcAdapter.getBalance();
        uint256 sovBefore = sovErcAdapter.getBalance();
        uint256 rawBefore = idleBefore + lbBefore + sovBefore;
        assertEq(idleBefore, 2 ether, "setup: cap remainder idles");

        address receiver = makeAddr("ikv_erc_components");
        uint256 halfShares = evault.balanceOf(alice) / 2;
        vm.prank(alice);
        uint256 value = evault.redeemInKind(halfShares, receiver, alice);

        assertApproxEqAbs(doc.balanceOf(receiver), idleBefore * value / rawBefore, 2, "idle asset slice");
        assertApproxEqAbs(
            lbPoolErc.aTokens(address(doc)).balanceOf(receiver), lbBefore * value / rawBefore, 2, "aToken fraction"
        );
        assertApproxEqAbs(mockIDOC.assetBalanceOf(receiver), sovBefore * value / rawBefore, 2, "iToken fraction");
        assertApproxEqAbs(_receiverValueErc(receiver), value, 6, "components sum to the entitlement");
    }

    // ------------------------------------------------------------------
    // Baseline accounting after an in-kind exit
    // ------------------------------------------------------------------

    /// The deployed baseline must shrink with the exit; otherwise the next
    /// checkpoint records a phantom loss equal to the slice that left and
    /// silently wipes the remaining holders' vesting buffer.
    function test_RedeemInKind_ShrinksTrackedDeployedProRata() public {
        _depositNative(alice, 10 ether);
        vault.initialDeposit();

        _accrueLbNative(2 ether);
        _depositNative(bob, 1); // checkpoint: 2 ether locked

        uint256 tdBefore = vault.trackedDeployed();
        uint256 rawBefore = _rawNative();

        address receiver = makeAddr("ikv_td");
        uint256 halfShares = vault.balanceOf(alice) / 2;
        vm.prank(alice);
        uint256 value = vault.redeemInKind(halfShares, receiver, alice);

        assertApproxEqAbs(
            vault.trackedDeployed(), tdBefore - tdBefore * value / rawBefore, 2, "baseline shrinks pro-rata"
        );
        assertApproxEqAbs(
            vault.trackedDeployed(),
            lbAdapter.getBalance() + sovrynAdapter.getBalance(),
            4,
            "baseline matches the live deployed balance"
        );

        // A later checkpoint must not see a phantom loss
        _depositNative(bob, 1);
        assertGe(vault.lockedProfitStored() + 10, 2 ether, "no phantom loss may eat the vesting buffer");
    }

    function test_ERC20_RedeemInKind_ShrinksTrackedDeployedProRata() public {
        _depositErc(alice, 10 ether);
        evault.initialDeposit();

        _accrueLbErc(2 ether);
        _depositErc(bob, 1); // checkpoint: 2 ether locked

        uint256 tdBefore = evault.trackedDeployed();
        uint256 rawBefore = _rawErc();

        address receiver = makeAddr("ikv_erc_td");
        uint256 halfShares = evault.balanceOf(alice) / 2;
        vm.prank(alice);
        uint256 value = evault.redeemInKind(halfShares, receiver, alice);

        assertApproxEqAbs(
            evault.trackedDeployed(), tdBefore - tdBefore * value / rawBefore, 2, "baseline shrinks pro-rata"
        );
        assertApproxEqAbs(
            evault.trackedDeployed(),
            lbErcAdapter.getBalance() + sovErcAdapter.getBalance(),
            4,
            "baseline matches the live deployed balance"
        );

        _depositErc(bob, 1);
        assertGe(evault.lockedProfitStored() + 10, 2 ether, "no phantom loss may eat the vesting buffer");
    }

    /// Native twin of the ERC20 reward-base shrink pinned in Tier1Fixes: the
    /// in-kind exit carries its share of recognized yield out of the vault.
    function test_RedeemInKind_ShrinksRewardableYieldProRata() public {
        _depositNative(alice, 9 ether);
        _depositNative(bob, 1 ether);
        vault.initialDeposit();

        _accrueLbNative(2 ether);
        _depositNative(carol, 1); // checkpoint
        uint256 ry0 = vault.rewardableYield();
        assertApproxEqAbs(ry0, 2 ether, 2, "gain is the reward base");

        uint256 rawBefore = _rawNative();
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 value = vault.redeemInKind(aliceShares, alice, alice);

        assertApproxEqAbs(
            vault.rewardableYield(),
            ry0 - ry0 * value / rawBefore,
            2,
            "reward base shrinks pro-rata with the in-kind exit"
        );
    }

    // ------------------------------------------------------------------
    // ERC20 adapter transferPosition (direct, as the vault)
    // ------------------------------------------------------------------

    function test_LayerBankERC20Adapter_TransferPosition_MovesExactFraction() public {
        LayerBankERC20Adapter a = new LayerBankERC20Adapter(address(lbPoolErc), address(doc));
        a.setVault(address(this));
        doc.mint(address(this), 9 ether);
        doc.approve(address(a), 9 ether);
        a.deposit(9 ether);

        // Skew the index so aToken amounts diverge from scaled units
        doc.mint(address(lbPoolErc), 0.9 ether);
        lbPoolErc.accrueInterest(address(doc));

        MockAToken aTok = lbPoolErc.aTokens(address(doc));
        uint256 bal = a.getBalance();
        assertApproxEqAbs(bal, 9.9 ether, 2, "setup: position rebased");

        address recv = makeAddr("ikv_lbe_recv");
        a.transferPosition(recv, 1 ether, 3 ether); // value/raw = 1/3
        assertApproxEqAbs(aTok.balanceOf(recv), bal / 3, 2, "one third of the position moves");
        assertApproxEqAbs(a.getBalance(), bal - bal / 3, 2, "two thirds stay");

        // Full fraction empties the position up to rounding dust
        uint256 rest = a.getBalance();
        a.transferPosition(recv, 5 ether, 5 ether);
        assertLe(a.getBalance(), 2, "full fraction leaves only dust");
        assertApproxEqAbs(aTok.balanceOf(recv), bal / 3 + rest, 4, "receiver holds the whole position");
    }

    function test_SovrynERC20Adapter_TransferPosition_MovesExactFraction() public {
        SovrynERC20Adapter a = new SovrynERC20Adapter(address(mockIDOC), address(doc));
        a.setVault(address(this));
        doc.mint(address(this), 8 ether);
        doc.approve(address(a), 8 ether);
        a.deposit(8 ether);

        // tokenPrice 1.25: iToken units diverge from underlying value
        doc.mint(address(mockIDOC), 2 ether);
        mockIDOC.accrueInterest();
        assertEq(mockIDOC.tokenPrice(), 1.25e18, "setup: price moved");

        uint256 iBal = mockIDOC.balanceOf(address(a)); // 8e18 iTokens worth 10 ether
        address recv = makeAddr("ikv_sove_recv");
        a.transferPosition(recv, 1 ether, 4 ether); // value/raw = 1/4
        assertEq(mockIDOC.balanceOf(recv), iBal / 4, "a quarter of the iToken position moves");
        assertApproxEqAbs(mockIDOC.assetBalanceOf(recv), 2.5 ether, 2, "worth a quarter of the underlying");
        assertEq(mockIDOC.balanceOf(address(a)), iBal - iBal / 4, "the rest stays");
    }

    function test_ERC20Adapters_TransferPosition_ZeroAmountIsNoOp() public {
        LayerBankERC20Adapter lb = new LayerBankERC20Adapter(address(lbPoolErc), address(doc));
        lb.setVault(address(this));
        SovrynERC20Adapter sov = new SovrynERC20Adapter(address(mockIDOC), address(doc));
        sov.setVault(address(this));

        address recv = makeAddr("ikv_zero_recv");
        // Empty position: a positive fraction must be a clean no-op, not a revert
        lb.transferPosition(recv, 1, 2);
        sov.transferPosition(recv, 1, 2);

        doc.mint(address(this), 2 ether);
        doc.approve(address(lb), 1 ether);
        doc.approve(address(sov), 1 ether);
        lb.deposit(1 ether);
        sov.deposit(1 ether);

        // Zero numerator: nothing moves, nothing reverts
        lb.transferPosition(recv, 0, 5 ether);
        sov.transferPosition(recv, 0, 5 ether);

        assertEq(lbPoolErc.aTokens(address(doc)).balanceOf(recv), 0, "no aTokens delivered");
        assertEq(mockIDOC.balanceOf(recv), 0, "no iTokens delivered");
        assertEq(lb.getBalance(), 1 ether, "LayerBank position intact");
        assertEq(sov.getBalance(), 1 ether, "Sovryn position intact");
    }

    function test_ERC20Adapters_TransferPosition_OnlyVault() public {
        address stranger = makeAddr("ikv_stranger");

        vm.prank(stranger);
        vm.expectRevert("only vault");
        lbErcAdapter.transferPosition(stranger, 1, 1);

        vm.prank(stranger);
        vm.expectRevert("only vault");
        sovErcAdapter.transferPosition(stranger, 1, 1);
    }
}
