// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ERC20YieldVault} from "../src/ERC20YieldVault.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {LayerBankERC20Adapter} from "../src/adapters/LayerBankERC20Adapter.sol";
import {SovrynERC20Adapter} from "../src/adapters/SovrynERC20Adapter.sol";
import {IERC20LendingAdapter} from "../src/interfaces/IERC20LendingAdapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockLayerBankPool} from "./mocks/MockLayerBankPool.sol";
import {MockLoanToken} from "./mocks/MockLoanToken.sol";

contract ERC20YieldVaultTest is Test {
    ERC20YieldVault public vault;
    VaultFactory public factory;
    MockERC20 public doc;
    MockLayerBankPool public lbPool;
    MockLoanToken public mockIDOC;
    LayerBankERC20Adapter public layerBankAdapter;
    SovrynERC20Adapter public sovrynAdapter;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public rebalancer = makeAddr("rebalancer");

    uint256 constant COOLDOWN = 3600;
    uint256 constant THRESHOLD = 5e14;
    uint256 constant REWARD_BPS = 100;
    uint256 constant MAX_RATE = 0.5e18; // 50% APR sanity cap

    function setUp() public {
        // Deploy mock DOC token and lending protocol mocks
        doc = new MockERC20("Dollar on Chain", "DOC");
        lbPool = new MockLayerBankPool();
        lbPool.initReserve(address(doc));
        mockIDOC = new MockLoanToken(address(doc));

        // Deploy adapters
        layerBankAdapter = new LayerBankERC20Adapter(address(lbPool), address(doc));
        sovrynAdapter = new SovrynERC20Adapter(address(mockIDOC), address(doc));

        // Deploy via factory
        factory = new VaultFactory();

        // Trust adapters before creating vault
        factory.trustAdapter(address(layerBankAdapter));
        factory.trustAdapter(address(sovrynAdapter));

        IERC20LendingAdapter[] memory adapters = new IERC20LendingAdapter[](2);
        adapters[0] = IERC20LendingAdapter(address(layerBankAdapter));
        adapters[1] = IERC20LendingAdapter(address(sovrynAdapter));

        address vaultAddr = factory.createVault(
            address(doc),
            adapters,
            COOLDOWN,
            THRESHOLD,
            REWARD_BPS,
            MAX_RATE,
            "DOC Yield Vault",
            "yvDOC"
        );
        vault = ERC20YieldVault(vaultAddr);

        // Set rates: LayerBank 5%, Sovryn 3%
        lbPool.setSupplyRate1e18(address(doc), 5e16);
        mockIDOC.setSupplyInterestRate((3e16) * 100);

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
        MockLayerBankPool lbPool2 = new MockLayerBankPool();
        lbPool2.initReserve(address(doc));
        MockLoanToken mockIDOC2 = new MockLoanToken(address(doc));
        LayerBankERC20Adapter t2 = new LayerBankERC20Adapter(address(lbPool2), address(doc));
        SovrynERC20Adapter s2 = new SovrynERC20Adapter(address(mockIDOC2), address(doc));

        factory.trustAdapter(address(t2));
        factory.trustAdapter(address(s2));

        IERC20LendingAdapter[] memory adapters2 = new IERC20LendingAdapter[](2);
        adapters2[0] = IERC20LendingAdapter(address(t2));
        adapters2[1] = IERC20LendingAdapter(address(s2));

        factory.createVault(address(doc), adapters2, 7200, 1e15, 200, MAX_RATE, "DOC Vault 2", "yvDOC2");

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
        one[0] = IERC20LendingAdapter(address(layerBankAdapter));

        vm.expectRevert("need at least 2 adapters");
        new ERC20YieldVault(address(doc), one, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_RATE, "Test", "T", address(this));
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

        assertEq(address(vault.activeAdapter()), address(layerBankAdapter), "should pick LayerBank (5% > 3%)");
        assertGt(layerBankAdapter.getBalance(), 0, "adapter should have balance");
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

        // LayerBank has 5%, Sovryn has 3%
        assertEq(address(vault.activeAdapter()), address(layerBankAdapter), "should pick LayerBank");
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
        assertEq(names[0], "LayerBank");
        assertEq(names[1], "Sovryn");
        assertGt(rates[0], 0, "LayerBank rate should be > 0");
        assertGt(rates[1], 0, "Sovryn rate should be > 0");
    }

    // -- Rebalance tests --

    function test_Rebalance_MovesFundsToHigherRate() public {
        // Setup: deposit + initialize to LayerBank
        vm.startPrank(alice);
        doc.approve(address(vault), 5 ether);
        vault.deposit(5 ether, alice);
        vm.stopPrank();
        vault.initialDeposit();

        // Flip rates: Sovryn now 8%
        mockIDOC.setSupplyInterestRate((8e16) * 100);
        vm.warp(block.timestamp + COOLDOWN + 1);

        // Simulate yield: add DOC to mock kDOC
        doc.mint(address(lbPool), 0.1 ether);
        lbPool.accrueInterest(address(doc));

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

        mockIDOC.setSupplyInterestRate((8e16) * 100);

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

        // Sovryn barely above LayerBank — below threshold
        mockIDOC.setSupplyInterestRate((5e16 + THRESHOLD / 2) * 100);
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

        mockIDOC.setSupplyInterestRate((8e16) * 100);
        vm.warp(block.timestamp + COOLDOWN + 1);

        // Simulate yield
        doc.mint(address(lbPool), 0.1 ether);
        lbPool.accrueInterest(address(doc));

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

        mockIDOC.setSupplyInterestRate((8e16) * 100);
        vm.warp(block.timestamp + COOLDOWN + 1);

        uint256 rebalancerBefore = doc.balanceOf(rebalancer);
        vm.prank(rebalancer);
        vault.rebalance();

        assertEq(doc.balanceOf(rebalancer), rebalancerBefore, "no yield means no reward");
    }

    function test_Rebalance_IgnoresRateAboveSanityCap() public {
        vm.startPrank(alice);
        doc.approve(address(vault), 5 ether);
        vault.deposit(5 ether, alice);
        vm.stopPrank();
        vault.initialDeposit();

        // Sovryn rate manipulated way above any real lending rate —
        // it stops being a candidate, leaving no improvement over LayerBank
        mockIDOC.setSupplyInterestRate((0.6e18) * 100); // 60% APR
        vm.warp(block.timestamp + COOLDOWN + 1);

        vm.prank(rebalancer);
        vm.expectRevert("rate improvement too small");
        vault.rebalance();
    }

    function test_Rebalance_AllowsRateAtSanityCap() public {
        vm.startPrank(alice);
        doc.approve(address(vault), 5 ether);
        vault.deposit(5 ether, alice);
        vm.stopPrank();
        vault.initialDeposit();

        mockIDOC.setSupplyInterestRate((MAX_RATE) * 100); // exactly the cap
        vm.warp(block.timestamp + COOLDOWN + 1);

        vm.prank(rebalancer);
        vault.rebalance();

        assertEq(address(vault.activeAdapter()), address(sovrynAdapter), "should move at exactly the cap");
    }

    function test_Rebalance_ActiveAdapterAboveCap_StaysPut() public {
        vm.startPrank(alice);
        doc.approve(address(vault), 5 ether);
        vault.deposit(5 ether, alice);
        vm.stopPrank();
        vault.initialDeposit();

        // Active LayerBank rate spikes above the cap: the filtered bestRate can
        // never beat the raw current rate, so the vault deliberately stays put
        // (fail closed) until the market normalizes
        lbPool.setSupplyRate1e18(address(doc), 0.6e18); // 60% APR
        mockIDOC.setSupplyInterestRate((0.4e18) * 100); // sane and attractive
        vm.warp(block.timestamp + COOLDOWN + 1);

        vm.prank(rebalancer);
        vm.expectRevert("rate improvement too small");
        vault.rebalance();
    }

    function test_Rebalance_RewardClampedToReceived() public {
        vm.startPrank(alice);
        doc.approve(address(vault), 5 ether);
        vault.deposit(5 ether, alice);
        vm.stopPrank();
        vault.initialDeposit();

        mockIDOC.setSupplyInterestRate((8e16) * 100);
        vm.warp(block.timestamp + COOLDOWN + 1);

        // Fake "yield" via direct DOC transfer: the naive 1% reward (6 ether)
        // exceeds the 5 ether actually pulled from the adapter
        doc.mint(address(vault), 600 ether);

        uint256 rebalancerBefore = doc.balanceOf(rebalancer);
        vm.prank(rebalancer);
        vault.rebalance();

        // Reward clamped to what came back from the adapter; no revert on zero redeploy
        assertEq(doc.balanceOf(rebalancer) - rebalancerBefore, 5 ether, "reward should be clamped to received");
        assertEq(address(vault.activeAdapter()), address(sovrynAdapter), "rebalance should still complete");
    }

    function test_Rebalance_EmptyActiveAdapter_SwitchesCleanly() public {
        vm.startPrank(alice);
        doc.approve(address(vault), 5 ether);
        vault.deposit(5 ether, alice);
        vm.stopPrank();
        vault.initialDeposit(); // LayerBank active

        // Everyone exits — active adapter balance drops to exactly 0
        vm.startPrank(alice);
        vault.withdraw(vault.maxWithdraw(alice), alice, alice);
        vm.stopPrank();
        assertEq(layerBankAdapter.getBalance(), 0, "adapter should be empty");

        // Sovryn becomes better; rebalance must not call withdraw(0) — Aave
        // pools revert on zero-amount withdrawals (error 26)
        mockIDOC.setSupplyInterestRate((8e16) * 100);
        vm.warp(block.timestamp + COOLDOWN + 1);
        vm.prank(rebalancer);
        vault.rebalance();

        assertEq(address(vault.activeAdapter()), address(sovrynAdapter), "pointer should move");
    }

    function test_InitialDeposit_PrefersSaneRate() public {
        // Sovryn manipulated above the cap — must pick lower-rate LayerBank instead
        mockIDOC.setSupplyInterestRate((0.6e18) * 100);

        vm.startPrank(alice);
        doc.approve(address(vault), 5 ether);
        vault.deposit(5 ether, alice);
        vm.stopPrank();
        vault.initialDeposit();

        assertEq(address(vault.activeAdapter()), address(layerBankAdapter), "should skip insane Sovryn rate");
    }

    function test_InitialDeposit_RevertsWhenNoSaneRate() public {
        // Both rates above the cap — nothing sane to deploy into, so revert
        // with a clear reason instead of the opaque empty revert a call to
        // the zero address would produce
        lbPool.setSupplyRate1e18(address(doc), 0.6e18); // 60% APR
        mockIDOC.setSupplyInterestRate((0.6e18) * 100);

        vm.startPrank(alice);
        doc.approve(address(vault), 5 ether);
        vault.deposit(5 ether, alice);
        vm.stopPrank();

        vm.expectRevert("no adapter within sane rate");
        vault.initialDeposit();
    }

    function test_Rebalance_EmitsRewardPaidEvent() public {
        vm.startPrank(alice);
        doc.approve(address(vault), 5 ether);
        vault.deposit(5 ether, alice);
        vm.stopPrank();
        vault.initialDeposit();

        mockIDOC.setSupplyInterestRate((8e16) * 100);
        vm.warp(block.timestamp + COOLDOWN + 1);

        doc.mint(address(lbPool), 0.1 ether);
        lbPool.accrueInterest(address(doc));

        // Yield is exactly 0.1 ether, reward is 1% of it
        vm.prank(rebalancer);
        vm.expectEmit(true, false, false, true);
        emit ERC20YieldVault.RebalancerRewardPaid(rebalancer, 0.001 ether, 0.1 ether);
        vault.rebalance();
    }

    function test_SovrynAdapter_Withdraw_RevertsOnShortfall() public {
        MockLoanToken iDoc2 = new MockLoanToken(address(doc));
        SovrynERC20Adapter s2 = new SovrynERC20Adapter(address(iDoc2), address(doc));
        address fakeVault = makeAddr("fakeVault");
        s2.setVault(fakeVault);

        doc.mint(fakeVault, 1 ether);
        vm.startPrank(fakeVault);
        doc.approve(address(s2), 1 ether);
        s2.deposit(1 ether);

        // Protocol skims 1% on burn — adapter must refuse the short withdrawal
        iDoc2.setBurnFeeBps(100);
        vm.expectRevert("sovryn: insufficient withdrawal");
        s2.withdraw(0.5 ether);
        vm.stopPrank();
    }

    function test_Rebalance_EmitsEvent() public {
        vm.startPrank(alice);
        doc.approve(address(vault), 5 ether);
        vault.deposit(5 ether, alice);
        vm.stopPrank();
        vault.initialDeposit();

        mockIDOC.setSupplyInterestRate((8e16) * 100);
        vm.warp(block.timestamp + COOLDOWN + 1);

        doc.mint(address(lbPool), 0.1 ether);
        lbPool.accrueInterest(address(doc));

        vm.prank(rebalancer);
        vm.expectEmit(true, true, true, false);
        emit ERC20YieldVault.Rebalanced(
            address(layerBankAdapter),
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

        // First rebalance: LayerBank -> Sovryn
        mockIDOC.setSupplyInterestRate((8e16) * 100);
        vm.warp(block.timestamp + COOLDOWN + 1);
        doc.mint(address(lbPool), 0.1 ether);
        lbPool.accrueInterest(address(doc));
        vm.prank(rebalancer);
        vault.rebalance();
        assertEq(address(vault.activeAdapter()), address(sovrynAdapter));

        // Second rebalance: Sovryn -> LayerBank
        lbPool.setSupplyRate1e18(address(doc), 10e16); // 10%
        mockIDOC.setSupplyInterestRate((3e16) * 100);
        vm.warp(block.timestamp + COOLDOWN + 1);
        doc.mint(address(mockIDOC), 0.1 ether);
        mockIDOC.accrueInterest();
        vm.prank(rebalancer);
        vault.rebalance();
        assertEq(address(vault.activeAdapter()), address(layerBankAdapter));
    }

    // -- Adapter access control --

    function test_Adapter_OnlyVault() public {
        vm.expectRevert("only vault");
        layerBankAdapter.deposit(1 ether);

        vm.expectRevert("only vault");
        layerBankAdapter.withdraw(1 ether);

        vm.expectRevert("only vault");
        sovrynAdapter.deposit(1 ether);

        vm.expectRevert("only vault");
        sovrynAdapter.withdraw(1 ether);
    }

    function test_Adapter_SetVaultOnlyOnce() public {
        // Adapters already have vault set from factory deployment
        vm.expectRevert("vault already set");
        layerBankAdapter.setVault(alice);
    }

    // -- Zero deposit --

    function test_ZeroDeposit_MintsZeroShares() public {
        vm.startPrank(alice);
        doc.approve(address(vault), 0);
        uint256 shares = vault.deposit(0, alice);
        vm.stopPrank();

        assertEq(shares, 0, "zero deposit should mint zero shares");
    }

    // -- Pause tests --

    function test_Pause_BlocksDeposits() public {
        // Factory owner is guardian (address(this))
        vault.pause();

        vm.startPrank(alice);
        doc.approve(address(vault), 5 ether);
        vm.expectRevert(); // ERC4626ExceededMaxDeposit (maxDeposit returns 0 when paused)
        vault.deposit(5 ether, alice);
        vm.stopPrank();
    }

    function test_Pause_AllowsWithdrawals() public {
        // Deposit first
        vm.startPrank(alice);
        doc.approve(address(vault), 5 ether);
        vault.deposit(5 ether, alice);
        vm.stopPrank();

        // Pause
        vault.pause();

        // Withdraw should still work
        vm.startPrank(alice);
        uint256 docBefore = doc.balanceOf(alice);
        vault.withdraw(3 ether, alice, alice);
        vm.stopPrank();

        assertEq(doc.balanceOf(alice) - docBefore, 3 ether, "withdrawal should work when paused");
    }

    function test_Pause_BlocksRebalance() public {
        vm.startPrank(alice);
        doc.approve(address(vault), 5 ether);
        vault.deposit(5 ether, alice);
        vm.stopPrank();
        vault.initialDeposit();

        vault.pause();

        mockIDOC.setSupplyInterestRate((8e16) * 100);
        vm.warp(block.timestamp + COOLDOWN + 1);

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.rebalance();
    }

    function test_Pause_BlocksInitialDeposit() public {
        vm.startPrank(alice);
        doc.approve(address(vault), 5 ether);
        vault.deposit(5 ether, alice);
        vm.stopPrank();

        // Pause before initialDeposit — wait, deposit itself would be blocked
        // So we need to deposit first, then pause, then try initialDeposit
        // But deposit already happened above. Let's create a fresh vault.
        MockLayerBankPool mk = new MockLayerBankPool();
        mk.initReserve(address(doc));
        MockLoanToken mi = new MockLoanToken(address(doc));
        LayerBankERC20Adapter ta = new LayerBankERC20Adapter(address(mk), address(doc));
        SovrynERC20Adapter sa = new SovrynERC20Adapter(address(mi), address(doc));
        factory.trustAdapter(address(ta));
        factory.trustAdapter(address(sa));

        IERC20LendingAdapter[] memory a = new IERC20LendingAdapter[](2);
        a[0] = IERC20LendingAdapter(address(ta));
        a[1] = IERC20LendingAdapter(address(sa));
        ERC20YieldVault v2 = ERC20YieldVault(factory.createVault(
            address(doc), a, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_RATE, "V2", "V2"
        ));

        mk.setSupplyRate1e18(address(doc), 5e16);
        mi.setSupplyInterestRate((3e16) * 100);

        // Deposit to v2
        vm.startPrank(alice);
        doc.approve(address(v2), 5 ether);
        v2.deposit(5 ether, alice);
        vm.stopPrank();

        // Pause, then try initialDeposit
        v2.pause();
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        v2.initialDeposit();
    }

    function test_Pause_OnlyGuardian() public {
        vm.prank(alice);
        vm.expectRevert("only guardian");
        vault.pause();
    }

    function test_Unpause() public {
        vault.pause();
        assertTrue(vault.paused());

        vault.unpause();
        assertFalse(vault.paused());

        // Deposits should work again
        vm.startPrank(alice);
        doc.approve(address(vault), 5 ether);
        uint256 shares = vault.deposit(5 ether, alice);
        vm.stopPrank();
        assertGt(shares, 0);
    }

    // -- Factory security tests --

    function test_Factory_UntrustedAdapter_Reverts() public {
        LayerBankERC20Adapter untrusted = new LayerBankERC20Adapter(address(lbPool), address(doc));

        IERC20LendingAdapter[] memory adapters2 = new IERC20LendingAdapter[](2);
        adapters2[0] = IERC20LendingAdapter(address(untrusted));
        adapters2[1] = IERC20LendingAdapter(address(sovrynAdapter));

        vm.expectRevert("adapter not trusted");
        factory.createVault(address(doc), adapters2, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_RATE, "Bad", "BAD");
    }

    function test_Factory_Shutdown_BlocksNewVaults() public {
        factory.shutdownFactory();
        assertTrue(factory.shutdown());

        IERC20LendingAdapter[] memory adapters2 = new IERC20LendingAdapter[](2);
        adapters2[0] = IERC20LendingAdapter(address(layerBankAdapter));
        adapters2[1] = IERC20LendingAdapter(address(sovrynAdapter));

        vm.expectRevert("factory is shutdown");
        factory.createVault(address(doc), adapters2, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_RATE, "X", "X");
    }

    function test_Factory_RemoveVault() public {
        assertTrue(factory.isVault(address(vault)));

        factory.removeVault(address(vault));

        assertFalse(factory.isVault(address(vault)), "vault should be removed");
    }

    function test_Factory_OnlyOwner() public {
        vm.startPrank(alice);

        vm.expectRevert();
        factory.trustAdapter(address(0x1));

        vm.expectRevert();
        factory.distrustAdapter(address(layerBankAdapter));

        vm.expectRevert();
        factory.shutdownFactory();

        vm.expectRevert();
        factory.removeVault(address(vault));

        vm.stopPrank();
    }

    function test_Unpause_OnlyGuardian() public {
        vault.pause();

        vm.prank(alice);
        vm.expectRevert("only guardian");
        vault.unpause();
    }

    function test_Pause_DoublePause_Reverts() public {
        vault.pause();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.pause();
    }

    function test_Factory_DistrustAdapter() public {
        assertTrue(factory.trustedAdapters(address(layerBankAdapter)));

        factory.distrustAdapter(address(layerBankAdapter));

        assertFalse(factory.trustedAdapters(address(layerBankAdapter)));
    }

    function test_Factory_DistrustAdapter_ExistingVaultStillWorks() public {
        // Distrust an adapter after vault is already deployed
        factory.distrustAdapter(address(layerBankAdapter));

        // Vault should still work — deposits, withdrawals, etc.
        vm.startPrank(alice);
        doc.approve(address(vault), 5 ether);
        uint256 shares = vault.deposit(5 ether, alice);
        vm.stopPrank();

        assertGt(shares, 0, "vault should still accept deposits after adapter distrusted");
    }

    function test_Factory_TrustAdapter_ZeroAddress_Reverts() public {
        vm.expectRevert("zero address");
        factory.trustAdapter(address(0));
    }

    function test_MaxDeposit_ReturnsZeroWhenPaused() public {
        assertGt(vault.maxDeposit(alice), 0, "maxDeposit should be > 0 when not paused");
        assertGt(vault.maxMint(alice), 0, "maxMint should be > 0 when not paused");

        vault.pause();

        assertEq(vault.maxDeposit(alice), 0, "maxDeposit should be 0 when paused");
        assertEq(vault.maxMint(alice), 0, "maxMint should be 0 when paused");
    }

    function test_ZeroGuardian_Reverts() public {
        IERC20LendingAdapter[] memory a = new IERC20LendingAdapter[](2);
        a[0] = IERC20LendingAdapter(address(new LayerBankERC20Adapter(address(lbPool), address(doc))));
        a[1] = IERC20LendingAdapter(address(new SovrynERC20Adapter(address(mockIDOC), address(doc))));

        vm.expectRevert("zero guardian");
        new ERC20YieldVault(address(doc), a, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_RATE, "T", "T", address(0));
    }

    function test_ConstructorRejectsZeroMaxRate() public {
        IERC20LendingAdapter[] memory a = new IERC20LendingAdapter[](2);
        a[0] = IERC20LendingAdapter(address(new LayerBankERC20Adapter(address(lbPool), address(doc))));
        a[1] = IERC20LendingAdapter(address(new SovrynERC20Adapter(address(mockIDOC), address(doc))));

        vm.expectRevert("zero max rate");
        new ERC20YieldVault(address(doc), a, COOLDOWN, THRESHOLD, REWARD_BPS, 0, "T", "T", address(this));
    }

    function test_Factory_OnlyOwner_AdminFunctions() public {
        vm.startPrank(alice);

        vm.expectRevert();
        factory.trustAdapter(address(0xBEEF));

        vm.expectRevert();
        factory.distrustAdapter(address(layerBankAdapter));

        vm.expectRevert();
        factory.removeVault(address(vault));

        vm.expectRevert();
        factory.shutdownFactory();

        vm.stopPrank();
    }

    // createVault is deliberately permissionless — anyone may deploy a vault
    // from owner-trusted adapters; the factory owner becomes its guardian
    function test_Factory_CreateVault_IsPermissionless() public {
        MockLayerBankPool lb2 = new MockLayerBankPool();
        lb2.initReserve(address(doc));
        MockLoanToken mi2 = new MockLoanToken(address(doc));
        LayerBankERC20Adapter a1 = new LayerBankERC20Adapter(address(lb2), address(doc));
        SovrynERC20Adapter a2 = new SovrynERC20Adapter(address(mi2), address(doc));
        factory.trustAdapter(address(a1));
        factory.trustAdapter(address(a2));

        IERC20LendingAdapter[] memory adapters2 = new IERC20LendingAdapter[](2);
        adapters2[0] = IERC20LendingAdapter(address(a1));
        adapters2[1] = IERC20LendingAdapter(address(a2));

        vm.prank(alice); // not the owner
        address v = factory.createVault(
            address(doc), adapters2, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_RATE, "Anyone", "ANY"
        );
        assertTrue(factory.isVault(v), "vault should register");
        assertEq(ERC20YieldVault(v).guardian(), address(this), "guardian is the factory owner, not the creator");
    }

    // Adapters bind to exactly one vault: reusing them in a second createVault
    // must revert with the adapter's one-shot setVault guard
    function test_Factory_ReusedAdapter_Reverts() public {
        IERC20LendingAdapter[] memory adapters2 = new IERC20LendingAdapter[](2);
        adapters2[0] = IERC20LendingAdapter(address(layerBankAdapter)); // already bound in setUp
        adapters2[1] = IERC20LendingAdapter(address(sovrynAdapter));

        vm.expectRevert("vault already set");
        factory.createVault(address(doc), adapters2, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_RATE, "Dup", "DUP");
    }

    function test_Factory_RejectsZeroMaxRate() public {
        IERC20LendingAdapter[] memory a = new IERC20LendingAdapter[](2);
        a[0] = IERC20LendingAdapter(address(layerBankAdapter));
        a[1] = IERC20LendingAdapter(address(sovrynAdapter));

        vm.expectRevert("zero max rate");
        factory.createVault(address(doc), a, COOLDOWN, THRESHOLD, REWARD_BPS, 0, "X", "X");
    }
}
