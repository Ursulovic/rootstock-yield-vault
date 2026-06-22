// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20YieldVault} from "../src/ERC20YieldVault.sol";
import {LayerBankERC20Adapter} from "../src/adapters/LayerBankERC20Adapter.sol";
import {SovrynERC20Adapter} from "../src/adapters/SovrynERC20Adapter.sol";
import {IERC20LendingAdapter} from "../src/interfaces/IERC20LendingAdapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockLayerBankPool} from "./mocks/MockLayerBankPool.sol";
import {MockLoanToken} from "./mocks/MockLoanToken.sol";

/// @notice ERC20YieldVault mirrors of the Tier 1 unit tests. The vault
///         duplicates the native Tier 1 logic (profit unlock, checkpoint
///         gain/loss state writes, reward clamp + buffer shrink, waterfall
///         cap math and sort order) — each branch is pinned here against the
///         ERC20 contract specifically.
contract ERC20Tier1Test is Test {
    MockERC20 doc;
    MockLayerBankPool lbPool;
    MockLoanToken mockIDOC;
    LayerBankERC20Adapter lb;
    SovrynERC20Adapter sov;

    address alice = makeAddr("e20t1_alice");
    address bob = makeAddr("e20t1_bob");
    address carol = makeAddr("e20t1_carol");
    address rebalancer = makeAddr("e20t1_rebalancer");

    uint256 constant COOLDOWN = 3600;
    uint256 constant THRESHOLD = 5e14;
    uint256 constant MAX_RATE = 0.5e18;
    uint256 constant TVL_CAP = type(uint256).max;

    function setUp() public {
        doc = new MockERC20("Dollar on Chain", "DOC");
        lbPool = new MockLayerBankPool();
        lbPool.initReserve(address(doc));
        mockIDOC = new MockLoanToken(address(doc));

        lbPool.setSupplyRate1e18(address(doc), 5e16); // LayerBank 5%
        mockIDOC.setSupplyInterestRate(3e16 * 100); // Sovryn 3%, percent scale
    }

    function _vault(uint256 capBps, uint256 rewardBps) internal returns (ERC20YieldVault v) {
        lb = new LayerBankERC20Adapter(address(lbPool), address(doc));
        sov = new SovrynERC20Adapter(address(mockIDOC), address(doc));
        IERC20LendingAdapter[] memory adapters = new IERC20LendingAdapter[](2);
        adapters[0] = IERC20LendingAdapter(address(lb));
        adapters[1] = IERC20LendingAdapter(address(sov));
        v = new ERC20YieldVault(
            address(doc), adapters, COOLDOWN, THRESHOLD, rewardBps, MAX_RATE, capBps, TVL_CAP, "Test", "T", address(this)
        );
    }

    function _deposit(ERC20YieldVault v, address who, uint256 amount) internal {
        doc.mint(who, amount);
        vm.startPrank(who);
        doc.approve(address(v), amount);
        v.deposit(amount, who);
        vm.stopPrank();
    }

    function _accrueLb(uint256 gain) internal {
        doc.mint(address(lbPool), gain);
        lbPool.accrueInterest(address(doc));
    }

    function _loseLb(uint256 amount) internal {
        vm.prank(address(lbPool));
        doc.transfer(address(0xdead), amount);
        lbPool.accrueInterest(address(doc));
    }

    // ------------------------------------------------------------------
    // Linear profit unlock
    // ------------------------------------------------------------------

    function test_ProfitUnlock_VestsLinearly() public {
        ERC20YieldVault vault = _vault(6000, 100);
        _deposit(vault, alice, 5 ether);
        vault.initialDeposit(); // LB 3 / Sovryn 2

        _accrueLb(0.3 ether);
        assertEq(vault.totalAssets(), 5 ether, "unrecognized gain must not move the price");

        _deposit(vault, bob, 1 ether); // checkpoint

        // Small unrecognized accrual keeps the view in its gain branch
        // (deployment rounding can leave raw a wei below the baseline)
        _accrueLb(0.05 ether);

        // t0: the full gain is locked and stays out of the price
        assertApproxEqAbs(vault.lockedProfit(), 0.3 ether, 2, "full gain locked at checkpoint");
        assertApproxEqAbs(vault.totalAssets(), 6 ether, 2, "locked profit stays out of the price at t0");

        vm.warp(block.timestamp + vault.PROFIT_UNLOCK_PERIOD() / 2);
        assertApproxEqAbs(vault.lockedProfit(), 0.15 ether, 2, "half vested at half period");
        assertApproxEqAbs(vault.totalAssets(), 6.15 ether, 2, "price reflects vested half");

        vm.warp(block.timestamp + vault.PROFIT_UNLOCK_PERIOD() / 2);
        assertEq(vault.lockedProfit(), 0, "fully vested");
        assertApproxEqAbs(vault.totalAssets(), 6.3 ether, 2, "price reflects the full gain");
    }

    // ------------------------------------------------------------------
    // Checkpoint gain branch
    // ------------------------------------------------------------------

    function test_Checkpoint_GainAddsToRemainingBuffer() public {
        ERC20YieldVault vault = _vault(6000, 100);
        _deposit(vault, alice, 5 ether);
        vault.initialDeposit();

        _accrueLb(0.4 ether);
        _deposit(vault, bob, 1 ether); // checkpoint: 0.4 locked
        assertApproxEqAbs(vault.lockedProfitStored(), 0.4 ether, 4, "first gain stored");

        // Halfway through vesting a second gain lands: the new buffer must be
        // the STILL-LOCKED remainder plus the new gain, not the new gain alone
        vm.warp(block.timestamp + vault.PROFIT_UNLOCK_PERIOD() / 2);
        _accrueLb(0.1 ether);
        _deposit(vault, carol, 1); // checkpoint

        assertApproxEqAbs(vault.lockedProfitStored(), 0.3 ether, 8, "buffer = remaining 0.2 + new gain 0.1");
        assertApproxEqAbs(vault.lockedProfit(), 0.3 ether, 8, "checkpoint restarts vesting on the whole buffer");
    }

    function test_Checkpoint_ResetsVestingClock() public {
        ERC20YieldVault vault = _vault(6000, 100);
        _deposit(vault, alice, 5 ether);
        vault.initialDeposit();

        // Long after the previous checkpoint fully vested, a gain lands:
        // the checkpoint must restart the clock or it vests instantly
        vm.warp(block.timestamp + vault.PROFIT_UNLOCK_PERIOD() + 10);
        _accrueLb(0.3 ether);
        _deposit(vault, bob, 1 ether); // checkpoint

        assertEq(vault.lastProfitCheckpoint(), block.timestamp, "checkpoint must reset the vesting clock");
        assertApproxEqAbs(vault.lockedProfit(), 0.3 ether, 2, "fresh gain fully locked, not pre-vested");
        assertApproxEqAbs(vault.totalAssets(), 6 ether, 2, "fresh gain stays out of the price");
    }

    // ------------------------------------------------------------------
    // Loss handling: view path and checkpoint state writes
    // ------------------------------------------------------------------

    function test_TotalAssets_UnrecognizedLossEatsBufferBeforePrincipal() public {
        ERC20YieldVault vault = _vault(6000, 100);
        _deposit(vault, alice, 5 ether);
        vault.initialDeposit();

        _accrueLb(0.3 ether);
        _deposit(vault, bob, 1 ether); // checkpoint: 0.3 locked

        // 0.2 loss, smaller than the buffer: price must show exactly
        // principal — neither the stale buffer (5.8) nor the raw value (6.1)
        _loseLb(0.2 ether);
        assertApproxEqAbs(vault.totalAssets(), 6 ether, 4, "loss must consume the locked buffer, not principal");
    }

    function test_Checkpoint_LossShrinksBufferAndRewardBase() public {
        ERC20YieldVault vault = _vault(6000, 100);
        _deposit(vault, alice, 5 ether);
        vault.initialDeposit();

        _accrueLb(0.3 ether);
        _deposit(vault, bob, 1 ether); // checkpoint: 0.3 locked, 0.3 rewardable
        assertApproxEqAbs(vault.rewardableYield(), 0.3 ether, 2, "gain accrues to the reward base");

        _loseLb(0.15 ether);
        _deposit(vault, carol, 1); // checkpoint the loss

        // The recognized loss must come out of BOTH the vesting buffer and
        // the caller-reward base, or rebalancers get paid for vanished yield
        assertApproxEqAbs(vault.lockedProfitStored(), 0.15 ether, 4, "loss checkpoint shrinks the stored buffer");
        assertApproxEqAbs(vault.rewardableYield(), 0.15 ether, 4, "loss checkpoint shrinks the reward base");
    }

    // ------------------------------------------------------------------
    // Rebalance reward: clamp to the unvested buffer, buffer shrink, resync
    // ------------------------------------------------------------------

    function test_Rebalance_RewardClampedToUnvestedBuffer() public {
        ERC20YieldVault vault = _vault(10_000, 500);
        _deposit(vault, alice, 100 ether);
        vault.initialDeposit(); // all to LayerBank at the 100% cap

        // Large vested gain (10) plus a small fresh one (0.1): the 5% formula
        // claims ~0.5 but only 0.1 is still locked
        _accrueLb(10 ether);
        _deposit(vault, carol, 1);
        vm.warp(block.timestamp + 3 days + 1);
        _accrueLb(0.1 ether);

        mockIDOC.setSupplyInterestRate(8e16 * 100);
        uint256 priceBefore = vault.previewRedeem(1e21);
        vm.prank(rebalancer);
        vault.rebalance();

        assertApproxEqAbs(doc.balanceOf(rebalancer), 0.1 ether, 2, "reward should clamp to the locked buffer");
        assertEq(vault.lockedProfitStored(), 0, "paying the reward consumes the buffer");
        assertApproxEqAbs(vault.previewRedeem(1e21), priceBefore, 2, "paying the reward must not move the price");
        assertEq(
            vault.trackedDeployed(),
            lb.getBalance() + sov.getBalance(),
            "baseline must resync to the post-move reality"
        );
    }

    // ------------------------------------------------------------------
    // Waterfall cap math and sort order
    // ------------------------------------------------------------------

    function test_Caps_InitialDepositSplits6040() public {
        ERC20YieldVault vault = _vault(6000, 100);
        _deposit(vault, alice, 10 ether);
        vault.initialDeposit();

        // LayerBank (5%) is primary at the 60% cap, Sovryn takes the spill
        assertApproxEqAbs(lb.getBalance(), 6 ether, 2, "primary fills to its cap");
        assertApproxEqAbs(sov.getBalance(), 4 ether, 2, "spill goes to the next-best adapter");
        assertLe(doc.balanceOf(address(vault)), 2, "nothing should stay idle with two sane adapters");
    }

    function test_Caps_WithdrawDrainsWorstRateFirst() public {
        ERC20YieldVault vault = _vault(6000, 100);
        _deposit(vault, alice, 10 ether);
        vault.initialDeposit(); // LB 6 / Sovryn 4 (Sovryn is the worse rate)

        vm.prank(alice);
        vault.withdraw(3 ether, alice, alice);

        assertApproxEqAbs(lb.getBalance(), 6 ether, 2, "best-rate allocation untouched");
        assertApproxEqAbs(sov.getBalance(), 1 ether, 2, "worst-rate allocation drained first");
    }

    function test_Caps_SingleSaneAdapter_RemainderStaysIdle() public {
        ERC20YieldVault vault = _vault(6000, 100);
        mockIDOC.setSupplyInterestRate(0.6e18 * 100); // 60% — above the 50% sanity cap

        _deposit(vault, alice, 10 ether);
        vault.initialDeposit();

        assertApproxEqAbs(lb.getBalance(), 6 ether, 2, "single sane adapter capped at 60%");
        assertEq(sov.getBalance(), 0, "insane adapter gets nothing");
        assertApproxEqAbs(doc.balanceOf(address(vault)), 4 ether, 2, "cap remainder stays idle");
    }

    function test_Caps_ConstructorValidation() public {
        IERC20LendingAdapter[] memory adapters = new IERC20LendingAdapter[](2);
        adapters[0] = IERC20LendingAdapter(address(new LayerBankERC20Adapter(address(lbPool), address(doc))));
        adapters[1] = IERC20LendingAdapter(address(new SovrynERC20Adapter(address(mockIDOC), address(doc))));

        vm.expectRevert("bad adapter cap");
        new ERC20YieldVault(
            address(doc), adapters, COOLDOWN, THRESHOLD, 100, MAX_RATE, 0, TVL_CAP, "Test", "T", address(this)
        );

        vm.expectRevert("bad adapter cap");
        new ERC20YieldVault(
            address(doc), adapters, COOLDOWN, THRESHOLD, 100, MAX_RATE, 10_001, TVL_CAP, "Test", "T", address(this)
        );

        // 2 adapters x 40% = 80% < 100% — deposits could never be fully placed
        vm.expectRevert("caps cannot cover deposits");
        new ERC20YieldVault(
            address(doc), adapters, COOLDOWN, THRESHOLD, 100, MAX_RATE, 4000, TVL_CAP, "Test", "T", address(this)
        );
    }
}
