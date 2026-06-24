// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {YieldVault} from "../src/YieldVault.sol";
import {LayerBankAdapter} from "../src/adapters/LayerBankAdapter.sol";
import {SovrynAdapter} from "../src/adapters/SovrynAdapter.sol";
import {ILendingAdapter} from "../src/interfaces/ILendingAdapter.sol";
import {MockWRBTC} from "./mocks/MockWRBTC.sol";
import {MockLayerBankPool} from "./mocks/MockLayerBankPool.sol";
import {MockiToken} from "./mocks/MockiToken.sol";

contract RebalanceTest is Test {
    YieldVault public vault;
    MockWRBTC public wrbtc;
    MockLayerBankPool public lbPool;
    MockiToken public mockIToken;
    LayerBankAdapter public layerBankAdapter;
    SovrynAdapter public sovrynAdapter;

    address public alice = makeAddr("alice");
    address public rebalancer = makeAddr("rebalancer");

    uint256 constant COOLDOWN = 3600;
    uint256 constant THRESHOLD = 5e14; // 0.05%
    uint256 constant REWARD_BPS = 100; // 1%
    uint256 constant MAX_RATE = 0.5e18; // 50% APR sanity cap
    uint256 constant CAP_BPS = 6000; // 60% per-adapter cap
    uint256 constant TVL_CAP = type(uint256).max;

    function setUp() public {
        wrbtc = new MockWRBTC();
        lbPool = new MockLayerBankPool();
        lbPool.initReserve(address(wrbtc));
        mockIToken = new MockiToken();

        layerBankAdapter = new LayerBankAdapter(address(lbPool), address(wrbtc));
        sovrynAdapter = new SovrynAdapter(address(mockIToken));

        ILendingAdapter[] memory adapters = new ILendingAdapter[](2);
        adapters[0] = ILendingAdapter(address(layerBankAdapter));
        adapters[1] = ILendingAdapter(address(sovrynAdapter));

        vault = new YieldVault(
            address(wrbtc),
            adapters,
            COOLDOWN,
            THRESHOLD,
            REWARD_BPS,
            MAX_RATE, CAP_BPS, TVL_CAP
        );

        // LayerBank: 5%, Sovryn: 3%
        lbPool.setSupplyRate1e18(address(wrbtc), 5e16);
        mockIToken.setSupplyInterestRate((3e16) * 100);

        vm.deal(alice, 10 ether);

        // Deposit and initialize
        vm.prank(alice);
        vault.depositNative{value: 5 ether}(alice);
        vault.initialDeposit();
    }

    /// Simulate LayerBank yield: add WRBTC to the pool, recompute the index
    function _accrueLayerBankYield(uint256 amount) internal {
        vm.deal(address(this), amount);
        wrbtc.deposit{value: amount}();
        wrbtc.transfer(address(lbPool), amount);
        lbPool.accrueInterest(address(wrbtc));
    }

    function test_Rebalance_MovesFundsToHigherRate() public {
        // Flip rates: Sovryn now 8%, LayerBank still 5%
        mockIToken.setSupplyInterestRate((8e16) * 100);

        // Wait for cooldown
        vm.warp(block.timestamp + COOLDOWN + 1);

        // Simulate some yield accrued
        _accrueLayerBankYield(0.1 ether);

        uint256 rawBefore = wrbtc.balanceOf(address(vault)) + layerBankAdapter.getBalance() + sovrynAdapter.getBalance();
        uint256 rebalancerBefore = rebalancer.balance;

        vm.prank(rebalancer);
        vault.rebalance();

        assertEq(address(vault.activeAdapter()), address(sovrynAdapter), "should move to Sovryn");

        uint256 rewardPaid = rebalancer.balance - rebalancerBefore;
        uint256 rawAfter = wrbtc.balanceOf(address(vault)) + layerBankAdapter.getBalance() + sovrynAdapter.getBalance();
        assertApproxEqAbs(rawAfter, rawBefore - rewardPaid, 2, "rebalance must conserve raw funds minus reward");

        // Recognized profit vests: price reflects principal now, full yield after 3 days
        assertApproxEqAbs(vault.totalAssets(), 5 ether, 2, "yield is locked right after the rebalance");
        vm.warp(block.timestamp + vault.PROFIT_UNLOCK_PERIOD());
        assertApproxEqAbs(vault.totalAssets(), rawAfter, 2, "yield fully unlocks after the vesting period");
    }

    function test_Rebalance_CooldownEnforced() public {
        mockIToken.setSupplyInterestRate((8e16) * 100);

        _accrueLayerBankYield(0.1 ether);

        // Don't wait, should revert
        vm.prank(rebalancer);
        vm.expectRevert("cooldown active");
        vault.rebalance();
    }

    function test_Rebalance_ThresholdEnforced() public {
        // Set Sovryn to barely above LayerBank, below threshold
        mockIToken.setSupplyInterestRate((5e16 + THRESHOLD / 2) * 100);

        vm.warp(block.timestamp + COOLDOWN + 1);

        _accrueLayerBankYield(0.1 ether);

        vm.prank(rebalancer);
        vm.expectRevert("rate improvement too small");
        vault.rebalance();
    }

    function test_Rebalance_CallerGetsReward() public {
        mockIToken.setSupplyInterestRate((8e16) * 100);
        vm.warp(block.timestamp + COOLDOWN + 1);

        // Simulate yield of 0.1 ether
        _accrueLayerBankYield(0.1 ether);

        uint256 rebalancerBefore = rebalancer.balance;

        vm.prank(rebalancer);
        vault.rebalance();

        uint256 rebalancerAfter = rebalancer.balance;
        assertGt(rebalancerAfter, rebalancerBefore, "rebalancer should get reward");
    }

    function test_Rebalance_RewardOnlyFromYield() public {
        mockIToken.setSupplyInterestRate((8e16) * 100);
        vm.warp(block.timestamp + COOLDOWN + 1);

        // Simulate yield of 0.05 ether
        _accrueLayerBankYield(0.05 ether);

        uint256 rebalancerBefore = rebalancer.balance;

        vm.prank(rebalancer);
        vault.rebalance();

        uint256 reward = rebalancer.balance - rebalancerBefore;
        // Reward should be ~1% of 0.05 ether = ~0.0005 ether
        assertLe(reward, 0.001 ether, "reward too high");
    }

    function test_Rebalance_EmitsEvent() public {
        mockIToken.setSupplyInterestRate((8e16) * 100);
        vm.warp(block.timestamp + COOLDOWN + 1);

        _accrueLayerBankYield(0.1 ether);

        vm.prank(rebalancer);
        vm.expectEmit(true, true, true, false);
        emit YieldVault.Rebalanced(
            address(layerBankAdapter),
            address(sovrynAdapter),
            0, 0, 0, // these values not checked exactly
            rebalancer
        );
        vault.rebalance();
    }

    function test_Rebalance_DoubleRebalance() public {
        // First rebalance: LayerBank → Sovryn
        mockIToken.setSupplyInterestRate((8e16) * 100);
        vm.warp(block.timestamp + COOLDOWN + 1);
        _accrueLayerBankYield(0.1 ether);
        vm.prank(rebalancer);
        vault.rebalance();
        assertEq(address(vault.activeAdapter()), address(sovrynAdapter));

        // Second rebalance: Sovryn → LayerBank
        lbPool.setSupplyRate1e18(address(wrbtc), 10e16); // 10%
        mockIToken.setSupplyInterestRate((3e16) * 100); // back to 3%
        vm.warp(block.timestamp + COOLDOWN + 1);
        vm.deal(address(mockIToken), address(mockIToken).balance + 0.1 ether);
        mockIToken.accrueInterest();
        vm.prank(rebalancer);
        vault.rebalance();
        assertEq(address(vault.activeAdapter()), address(layerBankAdapter));
    }

    function test_Rebalance_NoYield_ZeroReward() public {
        mockIToken.setSupplyInterestRate((8e16) * 100);
        vm.warp(block.timestamp + COOLDOWN + 1);

        // No yield accrued, just the original deposit
        uint256 rebalancerBefore = rebalancer.balance;

        vm.prank(rebalancer);
        vault.rebalance();

        uint256 reward = rebalancer.balance - rebalancerBefore;
        assertEq(reward, 0, "no yield means no reward");
    }

    function test_Rebalance_EmptyActiveAdapter_SwitchesCleanly() public {
        // Everyone exits, active adapter balance drops to exactly 0
        vm.startPrank(alice);
        vault.withdrawNative(vault.maxWithdraw(alice), alice, alice);
        vm.stopPrank();
        assertEq(layerBankAdapter.getBalance(), 0, "adapter should be empty");

        // Sovryn becomes better; rebalance must not call withdraw(0), Aave
        // pools revert on zero-amount withdrawals (error 26)
        mockIToken.setSupplyInterestRate((8e16) * 100);
        vm.warp(block.timestamp + COOLDOWN + 1);
        vm.prank(rebalancer);
        vault.rebalance();

        assertEq(address(vault.activeAdapter()), address(sovrynAdapter), "pointer should move");
    }

    function test_Rebalance_IgnoresRateAboveSanityCap() public {
        // Sovryn rate manipulated way above any real rBTC lending rate,
        // it stops being a candidate, leaving no improvement over LayerBank
        mockIToken.setSupplyInterestRate((0.6e18) * 100); // 60% APR
        vm.warp(block.timestamp + COOLDOWN + 1);

        vm.prank(rebalancer);
        vm.expectRevert("rate improvement too small");
        vault.rebalance();
    }

    function test_Rebalance_AllowsRateAtSanityCap() public {
        mockIToken.setSupplyInterestRate((0.5e18) * 100); // exactly the cap
        vm.warp(block.timestamp + COOLDOWN + 1);

        vm.prank(rebalancer);
        vault.rebalance();

        assertEq(address(vault.activeAdapter()), address(sovrynAdapter), "should move at exactly the cap");
    }

    function test_Rebalance_EmitsRewardPaidEvent() public {
        mockIToken.setSupplyInterestRate((8e16) * 100);
        vm.warp(block.timestamp + COOLDOWN + 1);

        _accrueLayerBankYield(0.1 ether);

        // Expected values derive from actual deployed growth (60/40 split
        // floors can shave a wei off the nominal 0.1 ether)
        uint256 expYield = layerBankAdapter.getBalance() + sovrynAdapter.getBalance() - 5 ether;
        uint256 expReward = expYield * REWARD_BPS / 10_000;
        vm.prank(rebalancer);
        vm.expectEmit(true, false, false, true);
        emit YieldVault.RebalancerRewardPaid(rebalancer, expReward, expYield);
        vault.rebalance();
    }

    function test_Rebalance_ActiveAdapterAboveCap_StaysPut() public {
        // Active LayerBank rate spikes above the cap: the filtered bestRate can
        // never beat the raw current rate, so the vault deliberately stays put
        // (fail closed) until the market normalizes
        lbPool.setSupplyRate1e18(address(wrbtc), 0.6e18); // 60% APR
        mockIToken.setSupplyInterestRate((0.4e18) * 100); // sane and attractive
        vm.warp(block.timestamp + COOLDOWN + 1);

        vm.prank(rebalancer);
        vm.expectRevert("rate improvement too small");
        vault.rebalance();
    }

    function test_Rebalance_DonationDoesNotInflateReward() public {
        mockIToken.setSupplyInterestRate((8e16) * 100);
        vm.warp(block.timestamp + COOLDOWN + 1);

        // Direct WRBTC transfer used to inflate the naive yield measure; the
        // checkpoint accounting only counts adapter growth, so the rebalancer
        // gets nothing from it
        vm.deal(alice, 600 ether);
        vm.startPrank(alice);
        wrbtc.deposit{value: 600 ether}();
        wrbtc.transfer(address(vault), 600 ether);
        vm.stopPrank();

        uint256 rebalancerBefore = rebalancer.balance;

        vm.prank(rebalancer);
        vault.rebalance();

        assertEq(rebalancer.balance - rebalancerBefore, 0, "donations must not produce a caller reward");
        assertEq(address(vault.activeAdapter()), address(sovrynAdapter), "rebalance should still complete");
    }

    function test_Rebalance_RewardClampedToReceived() public {
        // Recognize a large real gain, then drain most of the deployed funds:
        // the reward base survives but the withdrawable amount shrinks below it
        _accrueLayerBankYield(4 ether); // deployed: 5 -> 9
        // alice exits almost everything; the withdrawal itself checkpoints the
        // gain (rewardableYield) and then drains most of the adapter
        uint256 maxW = vault.maxWithdraw(alice);
        vm.prank(alice);
        vault.withdrawNative(maxW, alice, alice);

        // Sovryn becomes better and the rebalance pays from what little is left
        mockIToken.setSupplyInterestRate((8e16) * 100);
        vm.warp(block.timestamp + COOLDOWN + 1);

        uint256 deployedLeft = layerBankAdapter.getBalance();
        uint256 rewardBase = vault.rewardableYield();
        assertGt(rewardBase * REWARD_BPS / 10_000, 0, "reward base should be nonzero");

        uint256 rebalancerBefore = rebalancer.balance;
        vm.prank(rebalancer);
        vault.rebalance();
        uint256 paid = rebalancer.balance - rebalancerBefore;

        assertLe(paid, deployedLeft, "reward can never exceed what the rebalance withdrew");
        assertEq(address(vault.activeAdapter()), address(sovrynAdapter), "rebalance completes");
    }
}
