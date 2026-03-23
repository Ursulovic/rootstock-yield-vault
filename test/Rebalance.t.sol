// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {YieldVault} from "../src/YieldVault.sol";
import {TropykusAdapter} from "../src/adapters/TropykusAdapter.sol";
import {SovrynAdapter} from "../src/adapters/SovrynAdapter.sol";
import {ILendingAdapter} from "../src/interfaces/ILendingAdapter.sol";
import {MockWRBTC} from "./mocks/MockWRBTC.sol";
import {MockkToken} from "./mocks/MockkToken.sol";
import {MockiToken} from "./mocks/MockiToken.sol";

contract RebalanceTest is Test {
    YieldVault public vault;
    MockWRBTC public wrbtc;
    MockkToken public mockKToken;
    MockiToken public mockIToken;
    TropykusAdapter public tropykusAdapter;
    SovrynAdapter public sovrynAdapter;

    address public alice = makeAddr("alice");
    address public rebalancer = makeAddr("rebalancer");

    uint256 constant COOLDOWN = 3600;
    uint256 constant THRESHOLD = 5e14; // 0.05%
    uint256 constant REWARD_BPS = 100; // 1%

    function setUp() public {
        wrbtc = new MockWRBTC();
        mockKToken = new MockkToken();
        mockIToken = new MockiToken();

        tropykusAdapter = new TropykusAdapter(address(mockKToken));
        sovrynAdapter = new SovrynAdapter(address(mockIToken));

        ILendingAdapter[] memory adapters = new ILendingAdapter[](2);
        adapters[0] = ILendingAdapter(address(tropykusAdapter));
        adapters[1] = ILendingAdapter(address(sovrynAdapter));

        vault = new YieldVault(
            address(wrbtc),
            adapters,
            COOLDOWN,
            THRESHOLD,
            REWARD_BPS
        );

        // Tropykus: 5%, Sovryn: 3%
        mockKToken.setSupplyRatePerBlock(47564687975);
        mockIToken.setSupplyInterestRate(3e16);

        vm.deal(alice, 10 ether);

        // Deposit and initialize
        vm.prank(alice);
        vault.depositNative{value: 5 ether}(alice);
        vault.initialDeposit();
    }

    function test_Rebalance_MovesFundsToHigherRate() public {
        // Flip rates: Sovryn now 8%, Tropykus still 5%
        mockIToken.setSupplyInterestRate(8e16);

        // Wait for cooldown
        vm.warp(block.timestamp + COOLDOWN + 1);

        // Simulate some yield accrued
        vm.deal(address(mockKToken), address(mockKToken).balance + 0.1 ether);
        mockKToken.accrueInterest();

        vm.prank(rebalancer);
        vault.rebalance();

        assertEq(address(vault.activeAdapter()), address(sovrynAdapter), "should move to Sovryn");
    }

    function test_Rebalance_CooldownEnforced() public {
        mockIToken.setSupplyInterestRate(8e16);

        vm.deal(address(mockKToken), address(mockKToken).balance + 0.1 ether);
        mockKToken.accrueInterest();

        // Don't wait — should revert
        vm.prank(rebalancer);
        vm.expectRevert("cooldown active");
        vault.rebalance();
    }

    function test_Rebalance_ThresholdEnforced() public {
        // Set Sovryn to barely above Tropykus — below threshold
        mockIToken.setSupplyInterestRate(5e16 + THRESHOLD / 2);

        vm.warp(block.timestamp + COOLDOWN + 1);

        vm.deal(address(mockKToken), address(mockKToken).balance + 0.1 ether);
        mockKToken.accrueInterest();

        vm.prank(rebalancer);
        vm.expectRevert("rate improvement too small");
        vault.rebalance();
    }

    function test_Rebalance_CallerGetsReward() public {
        mockIToken.setSupplyInterestRate(8e16);
        vm.warp(block.timestamp + COOLDOWN + 1);

        // Simulate yield of 0.1 ether
        vm.deal(address(mockKToken), address(mockKToken).balance + 0.1 ether);
        mockKToken.accrueInterest();

        uint256 rebalancerBefore = rebalancer.balance;

        vm.prank(rebalancer);
        vault.rebalance();

        uint256 rebalancerAfter = rebalancer.balance;
        assertGt(rebalancerAfter, rebalancerBefore, "rebalancer should get reward");
    }

    function test_Rebalance_RewardOnlyFromYield() public {
        mockIToken.setSupplyInterestRate(8e16);
        vm.warp(block.timestamp + COOLDOWN + 1);

        // Simulate yield of 0.05 ether
        vm.deal(address(mockKToken), address(mockKToken).balance + 0.05 ether);
        mockKToken.accrueInterest();

        uint256 rebalancerBefore = rebalancer.balance;

        vm.prank(rebalancer);
        vault.rebalance();

        uint256 reward = rebalancer.balance - rebalancerBefore;
        // Reward should be ~1% of 0.05 ether = ~0.0005 ether
        assertLe(reward, 0.001 ether, "reward too high");
    }

    function test_Rebalance_EmitsEvent() public {
        mockIToken.setSupplyInterestRate(8e16);
        vm.warp(block.timestamp + COOLDOWN + 1);

        vm.deal(address(mockKToken), address(mockKToken).balance + 0.1 ether);
        mockKToken.accrueInterest();

        vm.prank(rebalancer);
        vm.expectEmit(true, true, true, false);
        emit YieldVault.Rebalanced(
            address(tropykusAdapter),
            address(sovrynAdapter),
            0, 0, 0, // we don't check these values exactly
            rebalancer
        );
        vault.rebalance();
    }

    function test_Rebalance_DoubleRebalance() public {
        // First rebalance: Tropykus → Sovryn
        mockIToken.setSupplyInterestRate(8e16);
        vm.warp(block.timestamp + COOLDOWN + 1);
        vm.deal(address(mockKToken), address(mockKToken).balance + 0.1 ether);
        mockKToken.accrueInterest();
        vm.prank(rebalancer);
        vault.rebalance();
        assertEq(address(vault.activeAdapter()), address(sovrynAdapter));

        // Second rebalance: Sovryn → Tropykus
        mockKToken.setSupplyRatePerBlock(95129375950); // ~10%
        mockIToken.setSupplyInterestRate(3e16); // back to 3%
        vm.warp(block.timestamp + COOLDOWN + 1);
        vm.deal(address(mockIToken), address(mockIToken).balance + 0.1 ether);
        mockIToken.accrueInterest();
        vm.prank(rebalancer);
        vault.rebalance();
        assertEq(address(vault.activeAdapter()), address(tropykusAdapter));
    }

    function test_Rebalance_NoYield_ZeroReward() public {
        mockIToken.setSupplyInterestRate(8e16);
        vm.warp(block.timestamp + COOLDOWN + 1);

        // No yield accrued — just the original deposit
        uint256 rebalancerBefore = rebalancer.balance;

        vm.prank(rebalancer);
        vault.rebalance();

        uint256 reward = rebalancer.balance - rebalancerBefore;
        assertEq(reward, 0, "no yield means no reward");
    }
}
