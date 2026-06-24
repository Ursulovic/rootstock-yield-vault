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

contract YieldVaultTest is Test {
    YieldVault public vault;
    MockWRBTC public wrbtc;
    MockLayerBankPool public lbPool;
    MockiToken public mockIToken;
    LayerBankAdapter public layerBankAdapter;
    SovrynAdapter public sovrynAdapter;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 constant COOLDOWN = 3600; // 1 hour
    uint256 constant THRESHOLD = 5e14; // 0.05% annual rate difference
    uint256 constant REWARD_BPS = 100; // 1% of yield
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

        // Set initial rates: LayerBank 5%, Sovryn 3% (both 1e18 = 100% annual)
        lbPool.setSupplyRate1e18(address(wrbtc), 5e16);
        mockIToken.setSupplyInterestRate((3e16) * 100);

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
        assertGt(layerBankAdapter.getBalance(), 0, "adapter should have funds");
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

        // Now withdraw, should pull from adapter
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

    // Standard ERC-4626 deposit() (not depositNative) must also deploy to the
    // active adapter, covers the _deposit override's deploy branch
    function test_StandardDeposit_DeploysToActiveAdapter() public {
        vm.prank(alice);
        vault.depositNative{value: 1 ether}(alice);
        vault.initialDeposit();

        vm.startPrank(bob);
        wrbtc.deposit{value: 2 ether}();
        wrbtc.approve(address(vault), 2 ether);
        vault.deposit(2 ether, bob);
        vm.stopPrank();

        // 60/40 cap split over the 3 ether total: primary holds 1.8
        assertApproxEqRel(layerBankAdapter.getBalance(), 1.8 ether, 0.01e18, "deposit() should waterfall to the primary up to its cap");
        assertApproxEqRel(
            layerBankAdapter.getBalance() + sovrynAdapter.getBalance(), 3 ether, 0.01e18, "everything should be deployed"
        );
    }

    // Standard ERC-4626 withdraw() (not withdrawNative) must pull from the
    // adapter when idle is short, covers the _withdraw override
    function test_StandardWithdraw_PullsFromAdapter() public {
        vm.prank(alice);
        vault.depositNative{value: 2 ether}(alice);
        vault.initialDeposit();

        uint256 wrbtcBefore = wrbtc.balanceOf(alice);

        vm.prank(alice);
        vault.withdraw(1 ether, alice, alice);

        assertEq(wrbtc.balanceOf(alice) - wrbtcBefore, 1 ether, "should receive WRBTC pulled from adapter");
    }

    function test_StandardRedeem_PullsFromAdapter() public {
        vm.prank(alice);
        uint256 shares = vault.depositNative{value: 2 ether}(alice);
        vault.initialDeposit();

        uint256 wrbtcBefore = wrbtc.balanceOf(alice);

        vm.prank(alice);
        uint256 assets = vault.redeem(shares / 2, alice, alice);

        assertEq(wrbtc.balanceOf(alice) - wrbtcBefore, assets, "redeem should return assets");
        assertGt(assets, 0, "should redeem some assets");
    }

    // Third party withdraws on the owner's behalf, exercises the allowance
    // branch in withdrawNative (msg.sender != owner -> _spendAllowance)
    function test_WithdrawNative_WithAllowance() public {
        vm.prank(alice);
        uint256 shares = vault.depositNative{value: 1 ether}(alice);

        vm.prank(alice);
        vault.approve(bob, shares);

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        vault.withdrawNative(1 ether, bob, alice);

        assertEq(bob.balance - bobBefore, 1 ether, "bob should receive alice's rBTC");
        assertEq(vault.balanceOf(alice), 0, "alice's shares burned");
        assertEq(vault.allowance(alice, bob), 0, "allowance fully spent");
    }

    function test_WithdrawNative_WithoutAllowance_Reverts() public {
        vm.prank(alice);
        vault.depositNative{value: 1 ether}(alice);

        vm.prank(bob);
        vm.expectRevert();
        vault.withdrawNative(1 ether, bob, alice);
    }

    function test_GetAdapterCount() public view {
        assertEq(vault.getAdapterCount(), 2, "should report two adapters");
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
        // LayerBank: 5%, Sovryn: 3%, should pick LayerBank
        vm.prank(alice);
        vault.depositNative{value: 1 ether}(alice);
        vault.initialDeposit();

        assertEq(address(vault.activeAdapter()), address(layerBankAdapter), "should pick LayerBank");
    }

    function test_InitialDeposit_PrefersSaneRate() public {
        // Sovryn manipulated above the cap, must pick lower-rate LayerBank instead
        mockIToken.setSupplyInterestRate((0.6e18) * 100);

        vm.prank(alice);
        vault.depositNative{value: 1 ether}(alice);
        vault.initialDeposit();

        assertEq(address(vault.activeAdapter()), address(layerBankAdapter), "should skip insane Sovryn rate");
    }

    function test_InitialDeposit_RevertsWhenNoSaneRate() public {
        // Both rates above the cap, nothing sane to deploy into, so revert
        // with a clear reason instead of the opaque empty revert a call to
        // the zero address would produce
        lbPool.setSupplyRate1e18(address(wrbtc), 0.6e18); // 60% APR
        mockIToken.setSupplyInterestRate((0.6e18) * 100);

        vm.prank(alice);
        vault.depositNative{value: 1 ether}(alice);

        vm.expectRevert("no adapter within sane rate");
        vault.initialDeposit();
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
        assertEq(names[0], "LayerBank");
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
        SovrynAdapter sa = new SovrynAdapter(address(new MockiToken()));
        one[0] = ILendingAdapter(address(sa));

        vm.expectRevert("need at least 2 adapters");
        new YieldVault(address(wrbtc), one, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_RATE, CAP_BPS, TVL_CAP);
    }

    function test_ConstructorRejectsHighReward() public {
        ILendingAdapter[] memory adapters = new ILendingAdapter[](2);
        adapters[0] = ILendingAdapter(address(new LayerBankAdapter(address(lbPool), address(wrbtc))));
        adapters[1] = ILendingAdapter(address(new SovrynAdapter(address(mockIToken))));

        vm.expectRevert("reward too high");
        new YieldVault(address(wrbtc), adapters, COOLDOWN, THRESHOLD, 501, MAX_RATE, CAP_BPS, TVL_CAP);
    }

    function test_WithdrawNative_ExceedsMax_Reverts() public {
        vm.prank(alice);
        vault.depositNative{value: 1 ether}(alice);

        vm.prank(alice);
        vm.expectRevert("withdraw exceeds max");
        vault.withdrawNative(2 ether, alice, alice);
    }

    function test_Rebalance_BeforeInit_Reverts() public {
        vm.prank(alice);
        vault.depositNative{value: 1 ether}(alice);

        vm.expectRevert("no active adapter");
        vault.rebalance();
    }

    function test_InitialDeposit_NoFunds_Reverts() public {
        vm.expectRevert("no funds to deploy");
        vault.initialDeposit();
    }

    // If the rBTC recipient rejects the transfer, withdrawNative must revert
    // cleanly (shares are not burned) rather than silently swallow the failure
    function test_WithdrawNative_RecipientRejects_Reverts() public {
        vm.prank(alice);
        vault.depositNative{value: 1 ether}(alice);

        RejectsETH rejecter = new RejectsETH();

        vm.prank(alice);
        vm.expectRevert("rBTC transfer failed");
        vault.withdrawNative(1 ether, address(rejecter), alice);

        assertGt(vault.balanceOf(alice), 0, "shares must not be burned on failed transfer");
    }

    function test_ConstructorRejectsZeroMaxRate() public {
        ILendingAdapter[] memory adapters = new ILendingAdapter[](2);
        adapters[0] = ILendingAdapter(address(new LayerBankAdapter(address(lbPool), address(wrbtc))));
        adapters[1] = ILendingAdapter(address(new SovrynAdapter(address(mockIToken))));

        vm.expectRevert("zero max rate");
        new YieldVault(address(wrbtc), adapters, COOLDOWN, THRESHOLD, REWARD_BPS, 0, CAP_BPS, TVL_CAP);
    }

    function test_Receive_RejectsDirectTransfer() public {
        vm.prank(alice);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertFalse(ok, "direct rBTC transfer should revert");
    }

    function test_Receive_AcceptsWRBTCAndAdapters() public {
        vm.deal(address(wrbtc), 1 ether);
        vm.prank(address(wrbtc));
        (bool okWrbtc,) = address(vault).call{value: 1 ether}("");
        assertTrue(okWrbtc, "WRBTC should be able to send rBTC");

        vm.deal(address(sovrynAdapter), 1 ether);
        vm.prank(address(sovrynAdapter));
        (bool okAdapter,) = address(vault).call{value: 1 ether}("");
        assertTrue(okAdapter, "adapter should be able to send rBTC");
    }
}

/// @notice Helper recipient with no payable fallback, any rBTC send to it reverts
contract RejectsETH {}
