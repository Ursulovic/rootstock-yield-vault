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

contract YieldVaultTest is Test {
    YieldVault public vault;
    MockWRBTC public wrbtc;
    MockkToken public mockKToken;
    MockiToken public mockIToken;
    TropykusAdapter public tropykusAdapter;
    SovrynAdapter public sovrynAdapter;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 constant COOLDOWN = 3600; // 1 hour
    uint256 constant THRESHOLD = 5e14; // 0.05% annual rate difference
    uint256 constant REWARD_BPS = 100; // 1% of yield

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

        // Set initial rates: Tropykus 5%, Sovryn 3%
        // Tropykus: per-block rate * 1,051,200 = annual rate
        // 5% annual = 5e16 => per-block = 5e16 / 1,051,200 ≈ 47564687975
        mockKToken.setSupplyRatePerBlock(47564687975);
        // Sovryn: already annualized, 3% = 3e16
        mockIToken.setSupplyInterestRate(3e16);

        // Fund test users
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    function test_DepositNative() public {
        vm.prank(alice);
        uint256 shares = vault.depositNative{value: 1 ether}(alice);

        assertGt(shares, 0, "should receive shares");
        assertEq(vault.balanceOf(alice), shares, "shares mismatch");
    }

    function test_DepositNative_DeploysToAdapter() public {
        // First, do an initial deposit to set up the active adapter
        vm.prank(alice);
        vault.depositNative{value: 1 ether}(alice);

        // No active adapter yet, funds sit idle
        assertEq(address(vault.activeAdapter()), address(0), "no active adapter yet");

        // Trigger initial deploy
        vault.initialDeposit();

        // Now the active adapter should have funds
        assertGt(tropykusAdapter.getBalance(), 0, "adapter should have funds");
    }

    function test_DepositNative_AfterActiveAdapter() public {
        // Set up active adapter first
        vm.prank(alice);
        vault.depositNative{value: 1 ether}(alice);
        vault.initialDeposit();

        // Second deposit should auto-deploy
        vm.prank(bob);
        vault.depositNative{value: 2 ether}(bob);

        // Active adapter balance should reflect both deposits
        assertGt(vault.totalAssets(), 2.9 ether, "total assets too low");
    }

    function test_WithdrawNative() public {
        vm.startPrank(alice);
        vault.depositNative{value: 1 ether}(alice);
        vm.stopPrank();

        // Funds are idle (no active adapter), so withdraw should work
        uint256 balanceBefore = alice.balance;

        vm.prank(alice);
        vault.withdrawNative(1 ether, alice, alice);

        assertGt(alice.balance, balanceBefore, "should receive rBTC");
    }

    function test_WithdrawNative_FromAdapter() public {
        vm.prank(alice);
        vault.depositNative{value: 1 ether}(alice);
        vault.initialDeposit();

        // Now withdraw — should pull from adapter
        uint256 balanceBefore = alice.balance;
        uint256 shares = vault.balanceOf(alice);

        vm.prank(alice);
        vault.withdrawNative(0.5 ether, alice, alice);

        assertGt(alice.balance, balanceBefore, "should receive rBTC");
        assertLt(vault.balanceOf(alice), shares, "shares should decrease");
    }

    function test_DepositWithWRBTC() public {
        // Wrap rBTC manually
        vm.startPrank(alice);
        wrbtc.deposit{value: 1 ether}();
        wrbtc.approve(address(vault), 1 ether);
        uint256 shares = vault.deposit(1 ether, alice);
        vm.stopPrank();

        assertGt(shares, 0, "should receive shares");
    }

    function test_TotalAssets_IncludesDeployedFunds() public {
        vm.prank(alice);
        vault.depositNative{value: 5 ether}(alice);
        vault.initialDeposit();

        uint256 total = vault.totalAssets();
        // Should be approximately 5 ether (minus any rounding)
        assertGt(total, 4.9 ether, "total assets too low");
        assertLe(total, 5.1 ether, "total assets too high");
    }

    function test_MultipleDepositors_ProportionalShares() public {
        vm.prank(alice);
        uint256 aliceShares = vault.depositNative{value: 1 ether}(alice);

        vm.prank(bob);
        uint256 bobShares = vault.depositNative{value: 2 ether}(bob);

        // Bob deposited 2x, should have ~2x shares
        assertApproxEqRel(bobShares, aliceShares * 2, 0.01e18, "proportional shares");
    }

    function test_InitialDeposit_SelectsBestRate() public {
        // Tropykus: 5%, Sovryn: 3% — should pick Tropykus
        vm.prank(alice);
        vault.depositNative{value: 1 ether}(alice);
        vault.initialDeposit();

        assertEq(address(vault.activeAdapter()), address(tropykusAdapter), "should pick Tropykus");
    }

    function test_InitialDeposit_RevertsWhenAlreadyInitialized() public {
        vm.prank(alice);
        vault.depositNative{value: 1 ether}(alice);
        vault.initialDeposit();

        vm.expectRevert("already initialized");
        vault.initialDeposit();
    }

    function test_GetAllRates() public view {
        (string[] memory names, uint256[] memory rates) = vault.getAllRates();

        assertEq(names.length, 2);
        assertEq(names[0], "Tropykus");
        assertEq(names[1], "Sovryn");
        assertGt(rates[0], 0);
        assertGt(rates[1], 0);
    }

    function test_ZeroDeposit_Reverts() public {
        vm.prank(alice);
        vm.expectRevert("zero deposit");
        vault.depositNative{value: 0}(alice);
    }

    function test_ConstructorRequiresMinAdapters() public {
        ILendingAdapter[] memory one = new ILendingAdapter[](1);
        MockkToken mk = new MockkToken();
        TropykusAdapter ta = new TropykusAdapter(address(mk));
        one[0] = ILendingAdapter(address(ta));

        vm.expectRevert("need at least 2 adapters");
        new YieldVault(address(wrbtc), one, COOLDOWN, THRESHOLD, REWARD_BPS);
    }
}
