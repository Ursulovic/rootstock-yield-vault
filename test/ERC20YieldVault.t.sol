// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ERC20YieldVault} from "../src/ERC20YieldVault.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {TropykusERC20Adapter} from "../src/adapters/TropykusERC20Adapter.sol";
import {SovrynERC20Adapter} from "../src/adapters/SovrynERC20Adapter.sol";
import {IERC20LendingAdapter} from "../src/interfaces/IERC20LendingAdapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockCErc20} from "./mocks/MockCErc20.sol";
import {MockLoanToken} from "./mocks/MockLoanToken.sol";

contract ERC20YieldVaultTest is Test {
    ERC20YieldVault public vault;
    VaultFactory public factory;
    MockERC20 public doc;
    MockCErc20 public mockKDOC;
    MockLoanToken public mockIDOC;
    TropykusERC20Adapter public tropykusAdapter;
    SovrynERC20Adapter public sovrynAdapter;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public rebalancer = makeAddr("rebalancer");

    uint256 constant COOLDOWN = 3600;
    uint256 constant THRESHOLD = 5e14;
    uint256 constant REWARD_BPS = 100;

    function setUp() public {
        // Deploy mock DOC token and lending protocol mocks
        doc = new MockERC20("Dollar on Chain", "DOC");
        mockKDOC = new MockCErc20(address(doc));
        mockIDOC = new MockLoanToken(address(doc));

        // Deploy adapters
        tropykusAdapter = new TropykusERC20Adapter(address(mockKDOC), address(doc));
        sovrynAdapter = new SovrynERC20Adapter(address(mockIDOC), address(doc));

        // Deploy via factory
        factory = new VaultFactory();

        IERC20LendingAdapter[] memory adapters = new IERC20LendingAdapter[](2);
        adapters[0] = IERC20LendingAdapter(address(tropykusAdapter));
        adapters[1] = IERC20LendingAdapter(address(sovrynAdapter));

        address vaultAddr = factory.createVault(
            address(doc),
            adapters,
            COOLDOWN,
            THRESHOLD,
            REWARD_BPS,
            "DOC Yield Vault",
            "yvDOC"
        );
        vault = ERC20YieldVault(vaultAddr);

        // Set rates: Tropykus 5%, Sovryn 3%
        mockKDOC.setSupplyRatePerBlock(47564687975);
        mockIDOC.setSupplyInterestRate(3e16);

        // Fund users with DOC
        doc.mint(alice, 100 ether);
        doc.mint(bob, 100 ether);
    }

    // -- Factory tests --

    function test_Factory_RegistersVault() public view {
        assertTrue(factory.isVault(address(vault)), "vault should be registered");
        assertEq(factory.vaultCount(), 1, "should have 1 vault");
    }

    function test_Factory_TracksVaultsByAsset() public view {
        address[] memory vaults = factory.getVaultsForAsset(address(doc));
        assertEq(vaults.length, 1, "should have 1 vault for DOC");
        assertEq(vaults[0], address(vault), "vault address mismatch");
    }

    function test_Factory_DeploysMultipleVaults() public {
        // Deploy second DOC vault with different params
        MockCErc20 mockKDOC2 = new MockCErc20(address(doc));
        MockLoanToken mockIDOC2 = new MockLoanToken(address(doc));
        TropykusERC20Adapter t2 = new TropykusERC20Adapter(address(mockKDOC2), address(doc));
        SovrynERC20Adapter s2 = new SovrynERC20Adapter(address(mockIDOC2), address(doc));

        IERC20LendingAdapter[] memory adapters2 = new IERC20LendingAdapter[](2);
        adapters2[0] = IERC20LendingAdapter(address(t2));
        adapters2[1] = IERC20LendingAdapter(address(s2));

        factory.createVault(address(doc), adapters2, 7200, 1e15, 200, "DOC Vault 2", "yvDOC2");

        assertEq(factory.vaultCount(), 2, "should have 2 vaults");
        address[] memory vaults = factory.getVaultsForAsset(address(doc));
        assertEq(vaults.length, 2, "should have 2 DOC vaults");
    }

    // -- Vault config tests --

    function test_VaultConfig() public view {
        assertEq(vault.asset(), address(doc), "asset should be DOC");
        assertEq(vault.name(), "DOC Yield Vault");
        assertEq(vault.symbol(), "yvDOC");
        assertEq(vault.getAdapterCount(), 2);
    }

    function test_ConstructorRequiresMinAdapters() public {
        IERC20LendingAdapter[] memory one = new IERC20LendingAdapter[](1);
        one[0] = IERC20LendingAdapter(address(tropykusAdapter));

        vm.expectRevert("need at least 2 adapters");
        new ERC20YieldVault(address(doc), one, COOLDOWN, THRESHOLD, REWARD_BPS, "Test", "T");
    }

    // -- Deposit tests --

    function test_Deposit() public {
        vm.startPrank(alice);
        doc.approve(address(vault), 10 ether);
        uint256 shares = vault.deposit(10 ether, alice);
        vm.stopPrank();

        assertGt(shares, 0, "should receive shares");
        assertEq(vault.balanceOf(alice), shares, "balance should match shares");
    }

    function test_Deposit_DeploysToAdapter() public {
        // First deposit (no active adapter yet)
        vm.startPrank(alice);
        doc.approve(address(vault), 5 ether);
        vault.deposit(5 ether, alice);
        vm.stopPrank();

        // Initialize to deploy funds
        vault.initialDeposit();

        assertEq(address(vault.activeAdapter()), address(tropykusAdapter), "should pick Tropykus (5% > 3%)");
        assertGt(tropykusAdapter.getBalance(), 0, "adapter should have balance");
    }

    function test_Deposit_AfterActiveAdapter() public {
        // Setup: deposit + initialize
        vm.startPrank(alice);
        doc.approve(address(vault), 10 ether);
        vault.deposit(5 ether, alice);
        vm.stopPrank();
        vault.initialDeposit();

        // Second deposit should auto-deploy
        vm.startPrank(alice);
        vault.deposit(3 ether, alice);
        vm.stopPrank();

        assertApproxEqRel(vault.totalAssets(), 8 ether, 0.01e18, "totalAssets should be ~8 ether");
    }

    // -- Withdraw tests --

    function test_Withdraw_IdleFunds() public {
        // Deposit but don't initialize (funds stay idle)
        vm.startPrank(alice);
        doc.approve(address(vault), 5 ether);
        uint256 shares = vault.deposit(5 ether, alice);

        uint256 docBefore = doc.balanceOf(alice);
        vault.withdraw(3 ether, alice, alice);
        vm.stopPrank();

        assertEq(doc.balanceOf(alice) - docBefore, 3 ether, "should receive 3 DOC");
        assertLt(vault.balanceOf(alice), shares, "shares should decrease");
    }

    function test_Withdraw_FromAdapter() public {
        // Deposit + initialize
        vm.startPrank(alice);
        doc.approve(address(vault), 5 ether);
        vault.deposit(5 ether, alice);
        vm.stopPrank();
        vault.initialDeposit();

        // Withdraw pulls from adapter
        vm.startPrank(alice);
        uint256 docBefore = doc.balanceOf(alice);
        vault.withdraw(3 ether, alice, alice);
        vm.stopPrank();

        assertEq(doc.balanceOf(alice) - docBefore, 3 ether, "should receive 3 DOC from adapter");
    }

    // -- totalAssets tests --

    function test_TotalAssets_IncludesDeployedFunds() public {
        vm.startPrank(alice);
        doc.approve(address(vault), 5 ether);
        vault.deposit(5 ether, alice);
        vm.stopPrank();
        vault.initialDeposit();

        assertApproxEqRel(vault.totalAssets(), 5 ether, 0.01e18, "totalAssets should be ~5 ether");
    }

    // -- initialDeposit tests --

    function test_InitialDeposit_SelectsBestRate() public {
        vm.startPrank(alice);
        doc.approve(address(vault), 5 ether);
        vault.deposit(5 ether, alice);
        vm.stopPrank();

        vault.initialDeposit();

        // Tropykus has 5%, Sovryn has 3%
        assertEq(address(vault.activeAdapter()), address(tropykusAdapter), "should pick Tropykus");
    }

    function test_InitialDeposit_RevertsWhenAlreadyInitialized() public {
        vm.startPrank(alice);
        doc.approve(address(vault), 5 ether);
        vault.deposit(5 ether, alice);
        vm.stopPrank();

        vault.initialDeposit();

        vm.expectRevert("already initialized");
        vault.initialDeposit();
    }

    // -- Multi-user tests --

    function test_MultipleDepositors_ProportionalShares() public {
        vm.startPrank(alice);
        doc.approve(address(vault), 1 ether);
        uint256 aliceShares = vault.deposit(1 ether, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        doc.approve(address(vault), 2 ether);
        uint256 bobShares = vault.deposit(2 ether, bob);
        vm.stopPrank();

        assertApproxEqRel(bobShares, aliceShares * 2, 0.01e18, "Bob should have ~2x Alice's shares");
    }

    // -- Rate view tests --

    function test_GetAllRates() public view {
        (string[] memory names, uint256[] memory rates) = vault.getAllRates();
        assertEq(names.length, 2);
        assertEq(names[0], "Tropykus");
        assertEq(names[1], "Sovryn");
        assertGt(rates[0], 0, "Tropykus rate should be > 0");
        assertGt(rates[1], 0, "Sovryn rate should be > 0");
    }

    // -- Rebalance tests --

    function test_Rebalance_MovesFundsToHigherRate() public {
        // Setup: deposit + initialize to Tropykus
        vm.startPrank(alice);
        doc.approve(address(vault), 5 ether);
        vault.deposit(5 ether, alice);
        vm.stopPrank();
        vault.initialDeposit();

        // Flip rates: Sovryn now 8%
        mockIDOC.setSupplyInterestRate(8e16);
        vm.warp(block.timestamp + COOLDOWN + 1);

        // Simulate yield: add DOC to mock kDOC
        doc.mint(address(mockKDOC), 0.1 ether);
        mockKDOC.accrueInterest();

        vm.prank(rebalancer);
        vault.rebalance();

        assertEq(address(vault.activeAdapter()), address(sovrynAdapter), "should move to Sovryn");
    }

    function test_Rebalance_CooldownEnforced() public {
        vm.startPrank(alice);
        doc.approve(address(vault), 5 ether);
        vault.deposit(5 ether, alice);
        vm.stopPrank();
        vault.initialDeposit();

        mockIDOC.setSupplyInterestRate(8e16);

        vm.prank(rebalancer);
        vm.expectRevert("cooldown active");
        vault.rebalance();
    }

    function test_Rebalance_ThresholdEnforced() public {
        vm.startPrank(alice);
        doc.approve(address(vault), 5 ether);
        vault.deposit(5 ether, alice);
        vm.stopPrank();
        vault.initialDeposit();

        // Sovryn barely above Tropykus — below threshold
        mockIDOC.setSupplyInterestRate(5e16 + THRESHOLD / 2);
        vm.warp(block.timestamp + COOLDOWN + 1);

        vm.prank(rebalancer);
        vm.expectRevert("rate improvement too small");
        vault.rebalance();
    }

    function test_Rebalance_CallerGetsReward() public {
        vm.startPrank(alice);
        doc.approve(address(vault), 5 ether);
        vault.deposit(5 ether, alice);
        vm.stopPrank();
        vault.initialDeposit();

        mockIDOC.setSupplyInterestRate(8e16);
        vm.warp(block.timestamp + COOLDOWN + 1);

        // Simulate yield
        doc.mint(address(mockKDOC), 0.1 ether);
        mockKDOC.accrueInterest();

        uint256 rebalancerBefore = doc.balanceOf(rebalancer);
        vm.prank(rebalancer);
        vault.rebalance();

        assertGt(doc.balanceOf(rebalancer), rebalancerBefore, "rebalancer should get DOC reward");
    }

    function test_Rebalance_NoYield_ZeroReward() public {
        vm.startPrank(alice);
        doc.approve(address(vault), 5 ether);
        vault.deposit(5 ether, alice);
        vm.stopPrank();
        vault.initialDeposit();

        mockIDOC.setSupplyInterestRate(8e16);
        vm.warp(block.timestamp + COOLDOWN + 1);

        uint256 rebalancerBefore = doc.balanceOf(rebalancer);
        vm.prank(rebalancer);
        vault.rebalance();

        assertEq(doc.balanceOf(rebalancer), rebalancerBefore, "no yield means no reward");
    }

    function test_Rebalance_EmitsEvent() public {
        vm.startPrank(alice);
        doc.approve(address(vault), 5 ether);
        vault.deposit(5 ether, alice);
        vm.stopPrank();
        vault.initialDeposit();

        mockIDOC.setSupplyInterestRate(8e16);
        vm.warp(block.timestamp + COOLDOWN + 1);

        doc.mint(address(mockKDOC), 0.1 ether);
        mockKDOC.accrueInterest();

        vm.prank(rebalancer);
        vm.expectEmit(true, true, true, false);
        emit ERC20YieldVault.Rebalanced(
            address(tropykusAdapter),
            address(sovrynAdapter),
            0, 0, 0,
            rebalancer
        );
        vault.rebalance();
    }

    function test_Rebalance_DoubleRebalance() public {
        vm.startPrank(alice);
        doc.approve(address(vault), 5 ether);
        vault.deposit(5 ether, alice);
        vm.stopPrank();
        vault.initialDeposit();

        // First rebalance: Tropykus -> Sovryn
        mockIDOC.setSupplyInterestRate(8e16);
        vm.warp(block.timestamp + COOLDOWN + 1);
        doc.mint(address(mockKDOC), 0.1 ether);
        mockKDOC.accrueInterest();
        vm.prank(rebalancer);
        vault.rebalance();
        assertEq(address(vault.activeAdapter()), address(sovrynAdapter));

        // Second rebalance: Sovryn -> Tropykus
        mockKDOC.setSupplyRatePerBlock(95129375950); // ~10%
        mockIDOC.setSupplyInterestRate(3e16);
        vm.warp(block.timestamp + COOLDOWN + 1);
        doc.mint(address(mockIDOC), 0.1 ether);
        mockIDOC.accrueInterest();
        vm.prank(rebalancer);
        vault.rebalance();
        assertEq(address(vault.activeAdapter()), address(tropykusAdapter));
    }

    // -- Adapter access control --

    function test_Adapter_OnlyVault() public {
        vm.expectRevert("only vault");
        tropykusAdapter.deposit(1 ether);

        vm.expectRevert("only vault");
        tropykusAdapter.withdraw(1 ether);

        vm.expectRevert("only vault");
        sovrynAdapter.deposit(1 ether);

        vm.expectRevert("only vault");
        sovrynAdapter.withdraw(1 ether);
    }

    function test_Adapter_SetVaultOnlyOnce() public {
        // Adapters already have vault set from factory deployment
        vm.expectRevert("vault already set");
        tropykusAdapter.setVault(alice);
    }

    // -- Zero deposit --

    function test_ZeroDeposit_MintsZeroShares() public {
        vm.startPrank(alice);
        doc.approve(address(vault), 0);
        uint256 shares = vault.deposit(0, alice);
        vm.stopPrank();

        assertEq(shares, 0, "zero deposit should mint zero shares");
    }
}
