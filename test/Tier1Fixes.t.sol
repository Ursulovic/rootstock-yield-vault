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

/// @dev Native adapter whose supply rate reacts to its own liquidity the way a
///      real utilization-based market does: rate = k / (externalLiquidity +
///      held). Emptying it spikes the rate, filling it depresses the rate.
contract ReactiveRateAdapter is ILendingAdapter {
    uint256 public immutable k;
    uint256 public immutable ext;
    uint256 internal held;

    constructor(uint256 _k, uint256 _ext) {
        k = _k;
        ext = _ext;
    }

    function setVault(address) external {}

    function deposit() external payable {
        held += msg.value;
    }

    function withdraw(uint256 amount) external returns (uint256) {
        held -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "send failed");
        return amount;
    }

    function getBalance() external view returns (uint256) {
        return held;
    }

    function getRate() external view returns (uint256) {
        return k / (ext + held);
    }

    function getProtocolName() external pure returns (string memory) {
        return "Reactive";
    }

    function transferPosition(address, uint256, uint256) external {}
}

/// @dev Native adapter with a constant rate, for pairing with the reactive one.
contract FixedRateAdapter is ILendingAdapter {
    uint256 public immutable rate;
    uint256 internal held;

    constructor(uint256 _rate) {
        rate = _rate;
    }

    function setVault(address) external {}

    function deposit() external payable {
        held += msg.value;
    }

    function withdraw(uint256 amount) external returns (uint256) {
        held -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "send failed");
        return amount;
    }

    function getBalance() external view returns (uint256) {
        return held;
    }

    function getRate() external view returns (uint256) {
        return rate;
    }

    function getProtocolName() external pure returns (string memory) {
        return "Fixed";
    }

    function transferPosition(address, uint256, uint256) external {}
}

/// @notice Regression tests for the Tier 1 review fixes:
///         (1) the rebalance caller reward is funded strictly by the unvested
///             profit buffer — it can never dip the share price, let alone
///             principal, and the reward base shrinks when yield exits;
///         (2) allocation waterfalls the FULL idle balance, so funds stranded
///             while an adapter was unavailable return to yield;
///         (3) the recorded primary after a rebalance is the actual largest
///             holder, not the pre-withdrawal rate pick.
contract Tier1FixesTest is Test {
    MockWRBTC wrbtc;
    MockLayerBankPool lbPool;
    MockiToken mockIToken;
    LayerBankAdapter lbAdapter;
    SovrynAdapter sovrynAdapter;

    MockERC20 doc;
    MockLayerBankPool lbPoolErc;
    MockLoanToken mockIDOC;

    address alice = makeAddr("fix_alice");
    address bob = makeAddr("fix_bob");
    address carol = makeAddr("fix_carol");
    address rebalancer = makeAddr("fix_rebalancer");

    uint256 constant COOLDOWN = 3600;
    uint256 constant THRESHOLD = 5e14;
    uint256 constant MAX_RATE = 0.5e18;
    uint256 constant TVL_CAP = type(uint256).max;

    function setUp() public {
        wrbtc = new MockWRBTC();
        lbPool = new MockLayerBankPool();
        lbPool.initReserve(address(wrbtc));
        mockIToken = new MockiToken();

        doc = new MockERC20("Dollar on Chain", "DOC");
        lbPoolErc = new MockLayerBankPool();
        lbPoolErc.initReserve(address(doc));
        mockIDOC = new MockLoanToken(address(doc));

        lbPool.setSupplyRate1e18(address(wrbtc), 5e16);
        mockIToken.setSupplyInterestRate(3e16 * 100); // percent scale
        lbPoolErc.setSupplyRate1e18(address(doc), 5e16);
        mockIDOC.setSupplyInterestRate(3e16 * 100);
    }

    // ------------------------------------------------------------------
    // Builders
    // ------------------------------------------------------------------

    /// 100% cap = single-effective-adapter (everything lands in the best
    /// market) — the shape of the review PoC. 500 bps = max caller reward.
    function _nativeVault(uint256 capBps, uint256 rewardBps) internal returns (YieldVault v) {
        lbAdapter = new LayerBankAdapter(address(lbPool), address(wrbtc));
        sovrynAdapter = new SovrynAdapter(address(mockIToken));
        ILendingAdapter[] memory adapters = new ILendingAdapter[](2);
        adapters[0] = ILendingAdapter(address(lbAdapter));
        adapters[1] = ILendingAdapter(address(sovrynAdapter));
        v = new YieldVault(address(wrbtc), adapters, COOLDOWN, THRESHOLD, rewardBps, MAX_RATE, capBps, TVL_CAP);
    }

    function _erc20Vault(uint256 capBps, uint256 rewardBps) internal returns (ERC20YieldVault v) {
        LayerBankERC20Adapter lb = new LayerBankERC20Adapter(address(lbPoolErc), address(doc));
        SovrynERC20Adapter sov = new SovrynERC20Adapter(address(mockIDOC), address(doc));
        IERC20LendingAdapter[] memory adapters = new IERC20LendingAdapter[](2);
        adapters[0] = IERC20LendingAdapter(address(lb));
        adapters[1] = IERC20LendingAdapter(address(sov));
        v = new ERC20YieldVault(
            address(doc), adapters, COOLDOWN, THRESHOLD, rewardBps, MAX_RATE, capBps, TVL_CAP, "Test", "T", address(this)
        );
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

    function _depositNative(YieldVault v, address who, uint256 amount) internal {
        vm.deal(who, amount);
        vm.prank(who);
        v.depositNative{value: amount}(who);
    }

    function _depositErc(ERC20YieldVault v, address who, uint256 amount) internal {
        doc.mint(who, amount);
        vm.startPrank(who);
        doc.approve(address(v), amount);
        v.deposit(amount, who);
        vm.stopPrank();
    }

    function _rawNative(YieldVault v) internal view returns (uint256) {
        return wrbtc.balanceOf(address(v)) + lbAdapter.getBalance() + sovrynAdapter.getBalance();
    }

    // ------------------------------------------------------------------
    // Fix 1: reward funded strictly by the unvested buffer
    // ------------------------------------------------------------------

    /// The review PoC: whale exits after full vesting (taking its yield with
    /// it), then a rebalance fires. The old code paid 5% of the LONG-GONE
    /// yield to the caller, dipping the remaining holder below principal.
    function test_RewardCannotDipRemainingHolderBelowPrincipal() public {
        YieldVault vault = _nativeVault(10_000, 500);
        _depositNative(vault, alice, 960 ether);
        _depositNative(vault, bob, 40 ether);
        vault.initialDeposit();

        // 100 ether of real yield, recognized, then fully vested
        _accrueLbNative(100 ether);
        _depositNative(vault, carol, 1); // any interaction checkpoints
        vm.warp(block.timestamp + 3 days + 1);

        // Whale leaves with principal + her share of the vested yield
        uint256 aliceMax = vault.maxWithdraw(alice);
        vm.prank(alice);
        vault.withdrawNative(aliceMax, alice, alice);

        uint256 bobBefore = vault.maxWithdraw(bob);
        assertGe(bobBefore, 40 ether - 2, "bob should be above principal before rebalance");

        // A better rate appears and anyone rebalances
        mockIToken.setSupplyInterestRate(8e16 * 100);
        vm.prank(rebalancer);
        vault.rebalance();

        // Fully vested profit belongs to the holders — no buffer, no reward
        assertEq(rebalancer.balance, 0, "no unvested profit -> no reward");
        assertGe(vault.maxWithdraw(bob), 40 ether - 2, "reward must never come out of principal");
    }

    function test_ERC20_RewardCannotDipRemainingHolderBelowPrincipal() public {
        ERC20YieldVault vault = _erc20Vault(10_000, 500);
        _depositErc(vault, alice, 960 ether);
        _depositErc(vault, bob, 40 ether);
        vault.initialDeposit();

        _accrueLbErc(100 ether);
        _depositErc(vault, carol, 1);
        vm.warp(block.timestamp + 3 days + 1);

        uint256 aliceMax = vault.maxWithdraw(alice);
        vm.prank(alice);
        vault.withdraw(aliceMax, alice, alice);

        mockIDOC.setSupplyInterestRate(8e16 * 100);
        vm.prank(rebalancer);
        vault.rebalance();

        assertEq(doc.balanceOf(rebalancer), 0, "no unvested profit -> no reward");
        assertGe(vault.maxWithdraw(bob), 40 ether - 2, "reward must never come out of principal");
    }

    /// When the raw reward formula exceeds the still-locked buffer, the payout
    /// is clamped to the buffer — and paying it never moves the share price.
    function test_RewardClampedToUnvestedBuffer() public {
        YieldVault vault = _nativeVault(10_000, 500);
        _depositNative(vault, alice, 100 ether);
        vault.initialDeposit();

        // Large vested gain (10) plus a small fresh one (0.1): the 5% formula
        // claims ~0.5 but only 0.1 is still locked
        _accrueLbNative(10 ether);
        _depositNative(vault, carol, 1);
        vm.warp(block.timestamp + 3 days + 1);
        _accrueLbNative(0.1 ether);

        mockIToken.setSupplyInterestRate(8e16 * 100);
        uint256 priceBefore = vault.previewRedeem(1e21);
        vm.prank(rebalancer);
        vault.rebalance();

        assertApproxEqAbs(rebalancer.balance, 0.1 ether, 1e6, "reward should clamp to the locked buffer");
        assertApproxEqAbs(vault.previewRedeem(1e21), priceBefore, 2, "paying the reward must not move the price");
    }

    /// Withdrawals carry their pro-rata share of recognized yield out of the
    /// vault; the reward base must shrink with them.
    function test_RewardableYieldShrinksOnWithdraw() public {
        YieldVault vault = _nativeVault(10_000, 500);
        _depositNative(vault, alice, 100 ether);
        vault.initialDeposit();

        _accrueLbNative(10 ether);
        _depositNative(vault, carol, 1);
        uint256 ry0 = vault.rewardableYield();
        assertApproxEqAbs(ry0, 10 ether, 2, "gain should be the reward base");

        uint256 raw = _rawNative(vault);
        uint256 assets = 50 ether;
        vm.prank(alice);
        vault.withdrawNative(assets, alice, alice);

        assertApproxEqAbs(
            vault.rewardableYield(), ry0 - ry0 * assets / raw, 2, "reward base should shrink pro-rata with the exit"
        );
    }

    function test_ERC20_RewardableYieldShrinksOnRedeemInKind() public {
        ERC20YieldVault vault = _erc20Vault(10_000, 500);
        _depositErc(vault, alice, 9 ether);
        _depositErc(vault, bob, 1 ether);
        vault.initialDeposit();

        _accrueLbErc(2 ether);
        _depositErc(vault, carol, 1);
        uint256 ry0 = vault.rewardableYield();
        assertApproxEqAbs(ry0, 2 ether, 2, "gain should be the reward base");

        uint256 raw = doc.balanceOf(address(vault)) + 12 ether; // idle + deployed (9+1 principal, +2 gain)
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 value = vault.redeemInKind(aliceShares, alice, alice);

        assertApproxEqAbs(
            vault.rewardableYield(),
            ry0 - ry0 * value / raw,
            2,
            "reward base should shrink pro-rata with the in-kind exit"
        );
    }

    // ------------------------------------------------------------------
    // Fix 2: stranded idle returns to yield
    // ------------------------------------------------------------------

    /// Deposit lands while one market is insane -> cap remainder stays idle.
    /// Once the market recovers, the NEXT deposit must sweep that remainder
    /// back into yield, not just place its own amount.
    function test_StrandedIdleSweptByNextDeposit() public {
        YieldVault vault = _nativeVault(6000, 100);

        mockIToken.setSupplyInterestRate(0.6e18 * 100); // insane: above maxSaneRate
        _depositNative(vault, alice, 10 ether);
        vault.initialDeposit();
        assertEq(wrbtc.balanceOf(address(vault)), 4 ether, "cap remainder should strand while market is insane");

        mockIToken.setSupplyInterestRate(3e16 * 100); // market recovers
        _depositNative(vault, bob, 1 ether);

        assertLe(wrbtc.balanceOf(address(vault)), 2, "recovered capacity should absorb the stranded idle");
        assertApproxEqAbs(
            lbAdapter.getBalance() + sovrynAdapter.getBalance(), 11 ether, 2, "everything should be deployed"
        );
        uint256 cap = 11 ether * 6000 / 10_000;
        assertLe(lbAdapter.getBalance(), cap + 2, "cap still respected");
        assertLe(sovrynAdapter.getBalance(), cap + 2, "cap still respected");
    }

    function test_StrandedIdleSweptByRebalance() public {
        YieldVault vault = _nativeVault(6000, 100);

        mockIToken.setSupplyInterestRate(0.6e18 * 100);
        _depositNative(vault, alice, 10 ether);
        vault.initialDeposit();
        assertEq(wrbtc.balanceOf(address(vault)), 4 ether);

        // Market recovers with a rate that clears the improvement gate
        mockIToken.setSupplyInterestRate((5e16 + 1e15) * 100);
        vm.warp(block.timestamp + COOLDOWN + 1);
        vault.rebalance();

        assertLe(wrbtc.balanceOf(address(vault)), 2, "rebalance should redeploy the stranded idle");
        assertApproxEqAbs(lbAdapter.getBalance() + sovrynAdapter.getBalance(), 10 ether, 2);
    }

    function test_ERC20_StrandedIdleSweptByNextDeposit() public {
        ERC20YieldVault vault = _erc20Vault(6000, 100);

        mockIDOC.setSupplyInterestRate(0.6e18 * 100);
        _depositErc(vault, alice, 10 ether);
        vault.initialDeposit();
        assertEq(doc.balanceOf(address(vault)), 4 ether, "cap remainder should strand while market is insane");

        mockIDOC.setSupplyInterestRate(3e16 * 100);
        _depositErc(vault, bob, 1 ether);

        assertLe(doc.balanceOf(address(vault)), 2, "recovered capacity should absorb the stranded idle");
    }

    // ------------------------------------------------------------------
    // Fix 3: recorded primary is the actual largest holder
    // ------------------------------------------------------------------

    /// Utilization-driven rates: emptying the reactive market spikes its rate,
    /// so the waterfall (which sorts AFTER the mass withdrawal) fills it first.
    /// The recorded primary must be that actual 60% holder — the old code kept
    /// the pre-withdrawal pick and mislabeled the allocation.
    function test_ActiveAdapterIsLargestHolderAfterRebalance() public {
        FixedRateAdapter fixedA = new FixedRateAdapter(3e16); // constant 3%
        // k/ext = 7.7% when empty; k/(ext+60) = 1.1% when holding the cap
        ReactiveRateAdapter reactiveB = new ReactiveRateAdapter(7.7e35, 10 ether);

        ILendingAdapter[] memory adapters = new ILendingAdapter[](2);
        adapters[0] = ILendingAdapter(address(fixedA));
        adapters[1] = ILendingAdapter(address(reactiveB));
        YieldVault vault = new YieldVault(address(wrbtc), adapters, COOLDOWN, THRESHOLD, 100, MAX_RATE, 6000, TVL_CAP);

        // Initial allocation: B quotes 7.7% while empty, so it is picked and
        // filled to the 60% cap — dropping its live rate to 1.1%
        _depositNative(vault, alice, 100 ether);
        vault.initialDeposit();
        assertEq(reactiveB.getBalance(), 60 ether);
        assertEq(fixedA.getBalance(), 40 ether);

        // Gate passes on pre-withdrawal rates (A 3% beats primary B's 1.1%).
        // The mass withdrawal then spikes B back to 7.7%, so the waterfall
        // favors B again: B ends up the 60% holder.
        vm.warp(block.timestamp + COOLDOWN + 1);
        vault.rebalance();

        assertEq(reactiveB.getBalance(), 60 ether, "waterfall fills the post-withdrawal best first");
        assertEq(fixedA.getBalance(), 40 ether);
        assertEq(
            address(vault.activeAdapter()),
            address(reactiveB),
            "recorded primary must be the actual largest holder, not the pre-withdrawal pick"
        );
    }

    /// Equal caps (5000 bps x 2) leave the two holders exactly tied after
    /// every allocation. The tie must resolve to the HIGHER-rate holder: if it
    /// resolved by registration index to the lower-rate one, the improvement
    /// gate would re-open every cooldown and pay for no-op rebalances forever.
    function test_TiedHoldersResolveToHigherRateAndCloseTheGate() public {
        lbAdapter = new LayerBankAdapter(address(lbPool), address(wrbtc));
        sovrynAdapter = new SovrynAdapter(address(mockIToken));
        ILendingAdapter[] memory adapters = new ILendingAdapter[](2);
        adapters[0] = ILendingAdapter(address(lbAdapter)); // index 0: starts best
        adapters[1] = ILendingAdapter(address(sovrynAdapter));
        YieldVault vault = new YieldVault(address(wrbtc), adapters, COOLDOWN, THRESHOLD, 500, MAX_RATE, 5000, TVL_CAP);

        _depositNative(vault, alice, 10 ether);
        vault.initialDeposit(); // exact 5/5 split, label = LayerBank (5% beats 3%)

        // Rates flip: LayerBank degrades, a legitimate rebalance fires
        lbPool.setSupplyRate1e18(address(wrbtc), 1e16);
        vm.warp(block.timestamp + COOLDOWN + 1);
        vault.rebalance();

        // Still an exact 5/5 tie — the label must be the 3% market (index 1),
        // not the 1% market that happens to sit at index 0
        assertApproxEqAbs(lbAdapter.getBalance(), 5 ether, 2);
        assertApproxEqAbs(sovrynAdapter.getBalance(), 5 ether, 2);
        assertEq(
            address(vault.activeAdapter()),
            address(sovrynAdapter),
            "tie must resolve to the higher-rate holder"
        );

        // With the honest label the gate is closed: no perpetual no-op churn
        vm.warp(block.timestamp + COOLDOWN + 1);
        vm.expectRevert("rate improvement too small");
        vault.rebalance();
    }
}
