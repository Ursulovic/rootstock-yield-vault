// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20YieldVault} from "../src/ERC20YieldVault.sol";
import {TropykusERC20Adapter} from "../src/adapters/TropykusERC20Adapter.sol";
import {SovrynERC20Adapter} from "../src/adapters/SovrynERC20Adapter.sol";
import {IERC20LendingAdapter} from "../src/interfaces/IERC20LendingAdapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockCErc20} from "./mocks/MockCErc20.sol";
import {MockLoanToken} from "./mocks/MockLoanToken.sol";

contract ERC20EdgeCasesTest is Test {
    ERC20YieldVault public vault;
    MockERC20 public doc;
    MockCErc20 public mockKDOC;
    MockLoanToken public mockIDOC;
    TropykusERC20Adapter public tropykusAdapter;
    SovrynERC20Adapter public sovrynAdapter;

    address public alice = makeAddr("alice");
    address public bob   = makeAddr("bob");

    uint256 constant COOLDOWN = 3600;
    uint256 constant THRESHOLD = 5e14;
    uint256 constant REWARD_BPS = 100;

    function setUp() public {
        doc = new MockERC20("Dollar on Chain", "DOC");
        mockKDOC = new MockCErc20(address(doc));
        mockIDOC = new MockLoanToken(address(doc));

        tropykusAdapter = new TropykusERC20Adapter(address(mockKDOC), address(doc));
        sovrynAdapter = new SovrynERC20Adapter(address(mockIDOC), address(doc));

        IERC20LendingAdapter[] memory adapters = new IERC20LendingAdapter[](2);
        adapters[0] = IERC20LendingAdapter(address(tropykusAdapter));
        adapters[1] = IERC20LendingAdapter(address(sovrynAdapter));

        vault = new ERC20YieldVault(
            address(doc), adapters, COOLDOWN, THRESHOLD, REWARD_BPS,
            "DOC Yield Vault", "yvDOC"
        );

        mockKDOC.setSupplyRatePerBlock(47564687975); // ~5%
        mockIDOC.setSupplyInterestRate(3e16);         // 3%

        doc.mint(alice, 1000 ether);
        doc.mint(bob, 1000 ether);
    }

    // ---- Withdraw edge cases ----

    function test_WithdrawAll_SharesGoToZero() public {
        vm.startPrank(alice);
        doc.approve(address(vault), 10 ether);
        vault.deposit(10 ether, alice);
        vm.stopPrank();

        vault.initialDeposit();

        // Withdraw everything
        vm.startPrank(alice);
        uint256 maxWithdraw = vault.maxWithdraw(alice);
        vault.withdraw(maxWithdraw, alice, alice);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0, "shares should be zero");
        assertApproxEqRel(doc.balanceOf(alice), 1000 ether, 0.01e18, "should get all DOC back");
    }

    function test_WithdrawMoreThanBalance_Reverts() public {
        vm.startPrank(alice);
        doc.approve(address(vault), 10 ether);
        vault.deposit(10 ether, alice);
        vm.stopPrank();

        vm.startPrank(alice);
        vm.expectRevert();
        vault.withdraw(20 ether, alice, alice);
        vm.stopPrank();
    }

    function test_MultipleUsersWithdrawSequentially() public {
        // Alice deposits 10, Bob deposits 20
        vm.startPrank(alice);
        doc.approve(address(vault), 10 ether);
        vault.deposit(10 ether, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        doc.approve(address(vault), 20 ether);
        vault.deposit(20 ether, bob);
        vm.stopPrank();

        vault.initialDeposit();

        // Alice withdraws all
        vm.startPrank(alice);
        uint256 aliceMax = vault.maxWithdraw(alice);
        vault.withdraw(aliceMax, alice, alice);
        vm.stopPrank();

        // Bob withdraws all
        vm.startPrank(bob);
        uint256 bobMax = vault.maxWithdraw(bob);
        vault.withdraw(bobMax, bob, bob);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0, "alice shares should be 0");
        assertEq(vault.balanceOf(bob), 0, "bob shares should be 0");
        assertLe(vault.totalAssets(), 2, "vault should be nearly empty (dust OK)");
    }

    // ---- Rounding edge cases ----

    function test_VerySmallDeposit() public {
        vm.startPrank(alice);
        doc.approve(address(vault), 1);
        uint256 shares = vault.deposit(1, alice); // 1 wei
        vm.stopPrank();

        // With _decimalsOffset() = 3, even 1 wei should produce shares
        assertGt(shares, 0, "should get shares even for 1 wei");
    }

    function test_LargeDeposit() public {
        doc.mint(alice, 1_000_000 ether);

        vm.startPrank(alice);
        doc.approve(address(vault), 1_000_000 ether);
        uint256 shares = vault.deposit(1_000_000 ether, alice);
        vm.stopPrank();

        assertGt(shares, 0, "should get shares for large deposit");
        assertApproxEqRel(vault.totalAssets(), 1_000_000 ether, 0.001e18, "totalAssets should match");
    }

    function test_SovrynCeilDivision_SmallAmount() public {
        // Test the ceiling division in Sovryn withdraw with a very small amount
        // burnAmount = (amount * 1e18 + price - 1) / price
        vm.startPrank(alice);
        doc.approve(address(vault), 10 ether);
        vault.deposit(10 ether, alice);
        vm.stopPrank();

        vault.initialDeposit();

        // If Tropykus is active, flip to Sovryn to test its withdraw
        if (address(vault.activeAdapter()) == address(tropykusAdapter)) {
            mockIDOC.setSupplyInterestRate(8e16);
            vm.warp(block.timestamp + COOLDOWN + 1);
            doc.mint(address(mockKDOC), 0.1 ether);
            mockKDOC.accrueInterest();
            vault.rebalance();
        }

        // Withdraw 1 wei from Sovryn adapter
        vm.startPrank(alice);
        vault.withdraw(1, alice, alice);
        vm.stopPrank();
    }

    // ---- Interest accrual / share value increase ----

    function test_InterestAccrual_ShareValueIncreases() public {
        vm.startPrank(alice);
        doc.approve(address(vault), 100 ether);
        vault.deposit(100 ether, alice);
        vm.stopPrank();

        vault.initialDeposit();

        uint256 totalBefore = vault.totalAssets();
        uint256 sharesBefore = vault.balanceOf(alice);

        // Simulate 5% yield by adding DOC to the mock kToken
        doc.mint(address(mockKDOC), 5 ether);
        mockKDOC.accrueInterest();

        uint256 totalAfter = vault.totalAssets();

        assertGt(totalAfter, totalBefore, "totalAssets should increase with yield");
        assertApproxEqRel(totalAfter, 105 ether, 0.01e18, "should be ~105 DOC after 5% yield");

        // Shares unchanged but worth more
        assertEq(vault.balanceOf(alice), sharesBefore, "shares should not change");

        // Alice can withdraw more than she deposited
        vm.startPrank(alice);
        uint256 maxWithdraw = vault.maxWithdraw(alice);
        vm.stopPrank();

        assertGt(maxWithdraw, 100 ether, "should be able to withdraw more than deposited");
    }

    function test_InterestAccrual_NewDepositorGetsFairShares() public {
        // Alice deposits first
        vm.startPrank(alice);
        doc.approve(address(vault), 100 ether);
        vault.deposit(100 ether, alice);
        vm.stopPrank();

        vault.initialDeposit();

        // Yield accrues: 10%
        doc.mint(address(mockKDOC), 10 ether);
        mockKDOC.accrueInterest();

        // Bob deposits after yield
        vm.startPrank(bob);
        doc.approve(address(vault), 100 ether);
        uint256 bobShares = vault.deposit(100 ether, bob);
        vm.stopPrank();

        uint256 aliceShares = vault.balanceOf(alice);

        // Alice has 100 DOC + 10 DOC yield = 110 DOC value
        // Bob has 100 DOC value
        // Alice should have more shares per DOC (she got them cheaper)
        assertGt(aliceShares, bobShares, "Alice should have more shares (deposited before yield)");

        // Both should be able to withdraw their fair share
        uint256 aliceMax = vault.maxWithdraw(alice);
        uint256 bobMax = vault.maxWithdraw(bob);

        assertApproxEqRel(aliceMax, 110 ether, 0.02e18, "Alice should withdraw ~110 DOC");
        assertApproxEqRel(bobMax, 100 ether, 0.02e18, "Bob should withdraw ~100 DOC");
    }

    // ---- Rebalance edge cases ----

    function test_Rebalance_RewardExceedsReceived_NoRewardPaid() public {
        vm.startPrank(alice);
        doc.approve(address(vault), 5 ether);
        vault.deposit(5 ether, alice);
        vm.stopPrank();
        vault.initialDeposit();

        // Simulate huge yield that inflates yieldAccrued
        // but actual adapter balance hasn't grown as much
        // This can happen if someone donates to vault directly
        mockIDOC.setSupplyInterestRate(8e16);
        vm.warp(block.timestamp + COOLDOWN + 1);

        // Small yield in adapter
        doc.mint(address(mockKDOC), 0.01 ether);
        mockKDOC.accrueInterest();

        address rebalancer = makeAddr("rebalancer");
        uint256 rebalancerBefore = doc.balanceOf(rebalancer);

        vm.prank(rebalancer);
        vault.rebalance();

        uint256 rebalancerAfter = doc.balanceOf(rebalancer);
        uint256 reward = rebalancerAfter - rebalancerBefore;

        // Reward should be small (1% of actual yield, not inflated)
        assertLe(reward, 0.001 ether, "reward should be bounded by actual yield");
    }

    function test_Rebalance_WithIdleFunds_OnlyRedeploysWithdrawn() public {
        vm.startPrank(alice);
        doc.approve(address(vault), 5 ether);
        vault.deposit(5 ether, alice);
        vm.stopPrank();
        vault.initialDeposit();

        // Bob deposits (idle funds sit in vault since auto-deploy sends to active adapter)
        vm.startPrank(bob);
        doc.approve(address(vault), 3 ether);
        vault.deposit(3 ether, bob);
        vm.stopPrank();

        uint256 totalBefore = vault.totalAssets();

        // Rebalance
        mockIDOC.setSupplyInterestRate(8e16);
        vm.warp(block.timestamp + COOLDOWN + 1);
        doc.mint(address(mockKDOC), 0.1 ether);
        mockKDOC.accrueInterest();

        vault.rebalance();

        uint256 totalAfter = vault.totalAssets();

        // Total assets should be approximately the same (minus small reward)
        assertApproxEqRel(totalAfter, totalBefore, 0.02e18, "total assets should be preserved after rebalance");
    }

    // ---- Adapter getBalance / getRate with interest ----

    function test_TropykusAdapter_GetBalance_AfterInterest() public {
        vm.startPrank(alice);
        doc.approve(address(vault), 10 ether);
        vault.deposit(10 ether, alice);
        vm.stopPrank();
        vault.initialDeposit();

        // Simulate 5% interest
        mockKDOC.setExchangeRateStored(1.05e18);
        uint256 balance = tropykusAdapter.getBalance();

        assertApproxEqRel(balance, 10.5 ether, 0.01e18, "balance should reflect 5% interest");
    }

    function test_SovrynAdapter_GetBalance_AfterInterest() public {
        // Need to switch to Sovryn first
        vm.startPrank(alice);
        doc.approve(address(vault), 10 ether);
        vault.deposit(10 ether, alice);
        vm.stopPrank();

        // Make Sovryn win to deploy there
        mockIDOC.setSupplyInterestRate(8e16);
        mockKDOC.setSupplyRatePerBlock(28538812785); // ~3%
        vault.initialDeposit();

        assertEq(address(vault.activeAdapter()), address(sovrynAdapter), "should be Sovryn");

        // Simulate 3% interest
        mockIDOC.setTokenPrice(1.03e18);
        uint256 balance = sovrynAdapter.getBalance();

        assertApproxEqRel(balance, 10.3 ether, 0.01e18, "balance should reflect 3% interest");
    }

    // ---- Constructor validation ----

    function test_RewardTooHigh_Reverts() public {
        IERC20LendingAdapter[] memory adapters = new IERC20LendingAdapter[](2);
        adapters[0] = IERC20LendingAdapter(address(new TropykusERC20Adapter(address(mockKDOC), address(doc))));
        adapters[1] = IERC20LendingAdapter(address(new SovrynERC20Adapter(address(mockIDOC), address(doc))));

        vm.expectRevert("reward too high");
        new ERC20YieldVault(address(doc), adapters, COOLDOWN, THRESHOLD, 501, "Test", "T");
    }

    // ---- Rebalance before initialDeposit ----

    function test_Rebalance_BeforeInit_Reverts() public {
        vm.expectRevert("no active adapter");
        vault.rebalance();
    }

    // ---- initialDeposit with no funds ----

    function test_InitialDeposit_NoFunds_Reverts() public {
        vm.expectRevert("no funds to deploy");
        vault.initialDeposit();
    }

    // ---- setVault zero address ----

    function test_SetVault_ZeroAddress_Reverts() public {
        TropykusERC20Adapter adapter = new TropykusERC20Adapter(address(mockKDOC), address(doc));

        vm.expectRevert("zero address");
        adapter.setVault(address(0));
    }
}
