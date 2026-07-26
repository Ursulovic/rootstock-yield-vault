// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {YieldVault} from "../src/YieldVault.sol";
import {ERC20YieldVault} from "../src/ERC20YieldVault.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
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

/// @notice Pins the per-venue utilization ceiling in BOTH vaults:
///         (1) entry gate only: a venue at or above the ceiling receives no
///             new allocation (deposits spill to the next venue or stay idle)
///             and rebalance never targets it;
///         (2) exits never consult utilization: withdrawals and in-kind
///             redemptions work at 100% utilization and with a reverting
///             utilization view;
///         (3) a reverting getUtilization() counts as at ceiling (fail-closed
///             entry), and the bps boundary is exact.
contract UtilizationCeilingTest is Test {
    MockWRBTC wrbtc;
    MockLayerBankPool lbPool;
    MockiToken mockIToken;
    LayerBankAdapter lbAdapter;
    SovrynAdapter sovrynAdapter;
    YieldVault vault;

    MockERC20 doc;
    MockLayerBankPool lbPoolErc;
    MockLoanToken mockIDOC;
    LayerBankERC20Adapter lbErcAdapter;
    SovrynERC20Adapter sovErcAdapter;
    ERC20YieldVault evault;

    address alice = makeAddr("uc_alice");
    address whale = makeAddr("uc_whale");

    uint256 constant COOLDOWN = 3600;
    uint256 constant THRESHOLD = 5e14;
    uint256 constant REWARD_BPS = 100;
    uint256 constant MAX_RATE = 0.5e18;
    uint256 constant CAP_BPS = 6000;
    uint256 constant TVL_CAP = type(uint256).max;
    uint256 constant UTIL_CEILING_BPS = 9000; // 90%, the Phase 0 value
    uint256 constant GATE = UTIL_CEILING_BPS * 1e14; // 1e18 scale

    function setUp() public {
        wrbtc = new MockWRBTC();
        lbPool = new MockLayerBankPool();
        lbPool.initReserve(address(wrbtc));
        mockIToken = new MockiToken();

        doc = new MockERC20("Dollar on Chain", "DOC");
        lbPoolErc = new MockLayerBankPool();
        lbPoolErc.initReserve(address(doc));
        mockIDOC = new MockLoanToken(address(doc));

        // LayerBank is the better rate in both stacks, so the gate is
        // exercised on the venue selection WOULD otherwise pick
        lbPool.setSupplyRate1e18(address(wrbtc), 5e16);
        mockIToken.setSupplyInterestRate(3e16 * 100); // percent scale
        lbPoolErc.setSupplyRate1e18(address(doc), 5e16);
        mockIDOC.setSupplyInterestRate(3e16 * 100);

        vault = _nativeVault();
        evault = _erc20Vault();
    }

    // -- Builders / helpers --

    function _nativeVault() internal returns (YieldVault v) {
        lbAdapter = new LayerBankAdapter(address(lbPool), address(wrbtc));
        sovrynAdapter = new SovrynAdapter(address(mockIToken));
        ILendingAdapter[] memory adapters = new ILendingAdapter[](2);
        adapters[0] = ILendingAdapter(address(lbAdapter));
        adapters[1] = ILendingAdapter(address(sovrynAdapter));
        v = new YieldVault(
            address(wrbtc), adapters, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_RATE, CAP_BPS, TVL_CAP, UTIL_CEILING_BPS
        );
    }

    function _erc20Vault() internal returns (ERC20YieldVault v) {
        lbErcAdapter = new LayerBankERC20Adapter(address(lbPoolErc), address(doc));
        sovErcAdapter = new SovrynERC20Adapter(address(mockIDOC), address(doc));
        IERC20LendingAdapter[] memory adapters = new IERC20LendingAdapter[](2);
        adapters[0] = IERC20LendingAdapter(address(lbErcAdapter));
        adapters[1] = IERC20LendingAdapter(address(sovErcAdapter));
        v = new ERC20YieldVault(
            address(doc),
            adapters,
            ERC20YieldVault.VaultConfig({
                cooldownPeriod: COOLDOWN,
                rateThreshold: THRESHOLD,
                callerRewardBps: REWARD_BPS,
                maxSaneRate: MAX_RATE,
                adapterCapBps: CAP_BPS,
                tvlCap: TVL_CAP,
                utilizationCeilingBps: UTIL_CEILING_BPS
            }),
            "Test",
            "T",
            address(this)
        );
    }

    /// Third-party supply so the LayerBank market has utilization to speak of
    /// before the vault ever touches it.
    function _seedLbNative(uint256 amount) internal {
        vm.deal(whale, amount);
        vm.startPrank(whale);
        wrbtc.deposit{value: amount}();
        wrbtc.approve(address(lbPool), amount);
        lbPool.supply(address(wrbtc), amount, whale, 0);
        vm.stopPrank();
    }

    function _seedSovNative(uint256 amount) internal {
        vm.deal(whale, amount);
        vm.prank(whale);
        mockIToken.mintWithBTC{value: amount}(whale, false);
    }

    function _seedLbErc(uint256 amount) internal {
        doc.mint(whale, amount);
        vm.startPrank(whale);
        doc.approve(address(lbPoolErc), amount);
        lbPoolErc.supply(address(doc), amount, whale, 0);
        vm.stopPrank();
    }

    function _seedSovErc(uint256 amount) internal {
        doc.mint(whale, amount);
        vm.startPrank(whale);
        doc.approve(address(mockIDOC), amount);
        mockIDOC.mint(whale, amount);
        vm.stopPrank();
    }

    /// Set utilization relative to the market's CURRENT supply, in bps.
    function _setLbNativeUtil(uint256 bps) internal {
        uint256 supply = lbPool.aTokens(address(wrbtc)).totalSupply();
        lbPool.setTotalDebt(address(wrbtc), supply * bps / 10_000);
    }

    function _setSovNativeUtil(uint256 bps) internal {
        mockIToken.setTotalAssetBorrow(mockIToken.totalAssetSupply() * bps / 10_000);
    }

    function _setLbErcUtil(uint256 bps) internal {
        uint256 supply = lbPoolErc.aTokens(address(doc)).totalSupply();
        lbPoolErc.setTotalDebt(address(doc), supply * bps / 10_000);
    }

    function _setSovErcUtil(uint256 bps) internal {
        mockIDOC.setTotalAssetBorrow(mockIDOC.totalAssetSupply() * bps / 10_000);
    }

    function _depositNative(YieldVault v, uint256 amount) internal {
        vm.deal(alice, amount);
        vm.prank(alice);
        v.depositNative{value: amount}(alice);
    }

    function _depositErc(ERC20YieldVault v, uint256 amount) internal {
        doc.mint(alice, amount);
        vm.startPrank(alice);
        doc.approve(address(v), amount);
        v.deposit(amount, alice);
        vm.stopPrank();
    }

    // -- Entry gate: initial deployment --

    function test_InitialDeposit_SkipsBestRateVenueAtCeiling() public {
        // LayerBank has the better rate but sits at 95% utilization
        _seedLbNative(100 ether);
        _seedSovNative(100 ether);
        _setLbNativeUtil(9500);

        _depositNative(vault, 1 ether);
        vault.initialDeposit();

        assertEq(lbAdapter.getBalance(), 0, "venue at ceiling must receive nothing");
        assertGt(sovrynAdapter.getBalance(), 0, "funds must spill to the venue below ceiling");
        assertEq(address(vault.activeAdapter()), address(sovrynAdapter), "primary must be the eligible venue");
    }

    function test_InitialDeposit_AllVenuesAtCeiling_Reverts() public {
        _seedLbNative(100 ether);
        _seedSovNative(100 ether);
        _setLbNativeUtil(9500);
        _setSovNativeUtil(9500);

        _depositNative(vault, 1 ether);
        vm.expectRevert("no adapter within sane rate");
        vault.initialDeposit();
    }

    // -- Entry gate: subsequent deposits --

    function test_Deposit_SpillsToOtherVenue_WhenBestAtCeiling() public {
        _depositNative(vault, 1 ether);
        vault.initialDeposit();
        uint256 lbBefore = lbAdapter.getBalance();
        assertGt(lbBefore, 0, "sanity: layerbank funded while below ceiling");

        _setLbNativeUtil(9500);
        uint256 sovBefore = sovrynAdapter.getBalance();
        _depositNative(vault, 1 ether);

        assertEq(lbAdapter.getBalance(), lbBefore, "venue at ceiling must receive no new funds");
        assertGt(sovrynAdapter.getBalance(), sovBefore, "new funds must spill to the eligible venue");
    }

    function test_Deposit_BothAtCeiling_StaysIdle() public {
        _depositNative(vault, 1 ether);
        vault.initialDeposit();
        _setLbNativeUtil(9500);
        _setSovNativeUtil(9500);

        uint256 lbBefore = lbAdapter.getBalance();
        uint256 sovBefore = sovrynAdapter.getBalance();
        uint256 idleBefore = wrbtc.balanceOf(address(vault));

        _depositNative(vault, 1 ether); // must SUCCEED, not revert

        assertEq(lbAdapter.getBalance(), lbBefore, "layerbank must receive nothing");
        assertEq(sovrynAdapter.getBalance(), sovBefore, "sovryn must receive nothing");
        assertEq(wrbtc.balanceOf(address(vault)), idleBefore + 1 ether, "deposit must stay idle in the vault");
    }

    function test_ERC20_Deposit_SpillsToOtherVenue_WhenBestAtCeiling() public {
        _depositErc(evault, 100 ether);
        evault.initialDeposit();
        uint256 lbBefore = lbErcAdapter.getBalance();
        assertGt(lbBefore, 0, "sanity: layerbank funded while below ceiling");

        _setLbErcUtil(9500);
        uint256 sovBefore = sovErcAdapter.getBalance();
        _depositErc(evault, 100 ether);

        assertEq(lbErcAdapter.getBalance(), lbBefore, "venue at ceiling must receive no new funds");
        assertGt(sovErcAdapter.getBalance(), sovBefore, "new funds must spill to the eligible venue");
    }

    function test_ERC20_Deposit_BothAtCeiling_StaysIdle() public {
        _depositErc(evault, 100 ether);
        evault.initialDeposit();
        _setLbErcUtil(9500);
        _setSovErcUtil(9500);

        uint256 lbBefore = lbErcAdapter.getBalance();
        uint256 sovBefore = sovErcAdapter.getBalance();
        uint256 idleBefore = doc.balanceOf(address(evault));

        _depositErc(evault, 100 ether);

        assertEq(lbErcAdapter.getBalance(), lbBefore, "layerbank must receive nothing");
        assertEq(sovErcAdapter.getBalance(), sovBefore, "sovryn must receive nothing");
        assertEq(doc.balanceOf(address(evault)), idleBefore + 100 ether, "deposit must stay idle in the vault");
    }

    // -- Exact boundary --

    function test_Boundary_ExactCeilingSkipped_JustBelowAllowed() public {
        _depositNative(vault, 1 ether);
        vault.initialDeposit();
        uint256 supply = lbPool.aTokens(address(wrbtc)).totalSupply();

        // smallest debt with utilization >= 90.00%: exactly at ceiling skips
        uint256 debtAtCeiling = (supply * UTIL_CEILING_BPS + 9999) / 10_000;
        lbPool.setTotalDebt(address(wrbtc), debtAtCeiling);
        assertGe(lbAdapter.getUtilization(), GATE, "sanity: at or above the gate");
        uint256 lbBefore = lbAdapter.getBalance();
        _depositNative(vault, 1 ether);
        assertEq(lbAdapter.getBalance(), lbBefore, "utilization == ceiling must be skipped");

        // one wei less debt puts utilization strictly below the gate: allowed
        lbPool.setTotalDebt(address(wrbtc), debtAtCeiling - 1);
        assertLt(lbAdapter.getUtilization(), GATE, "sanity: strictly below the gate");
        _depositNative(vault, 1 ether);
        assertGt(lbAdapter.getBalance(), lbBefore, "just below the ceiling must be allowed");
    }

    function test_ERC20_Boundary_ExactCeilingSkipped_JustBelowAllowed() public {
        _depositErc(evault, 100 ether);
        evault.initialDeposit();
        uint256 supply = lbPoolErc.aTokens(address(doc)).totalSupply();

        uint256 debtAtCeiling = (supply * UTIL_CEILING_BPS + 9999) / 10_000;
        lbPoolErc.setTotalDebt(address(doc), debtAtCeiling);
        assertGe(lbErcAdapter.getUtilization(), GATE, "sanity: at or above the gate");
        uint256 lbBefore = lbErcAdapter.getBalance();
        _depositErc(evault, 100 ether);
        assertEq(lbErcAdapter.getBalance(), lbBefore, "utilization == ceiling must be skipped");

        lbPoolErc.setTotalDebt(address(doc), debtAtCeiling - 1);
        assertLt(lbErcAdapter.getUtilization(), GATE, "sanity: strictly below the gate");
        _depositErc(evault, 100 ether);
        assertGt(lbErcAdapter.getBalance(), lbBefore, "just below the ceiling must be allowed");
    }

    // -- Fail-closed entry on a reverting utilization view --

    function test_RevertingUtilizationView_SkipsVenueForEntry() public {
        _depositNative(vault, 1 ether);
        vault.initialDeposit();
        uint256 lbBefore = lbAdapter.getBalance();
        uint256 sovBefore = sovrynAdapter.getBalance();

        vm.mockCallRevert(address(lbAdapter), abi.encodeWithSelector(ILendingAdapter.getUtilization.selector), "dark");
        _depositNative(vault, 1 ether);
        vm.clearMockedCalls();

        assertEq(lbAdapter.getBalance(), lbBefore, "dark utilization view must be treated as at ceiling");
        assertGt(sovrynAdapter.getBalance(), sovBefore, "eligible venue must still receive funds");
    }

    function test_ERC20_RevertingUtilizationView_SkipsVenueForEntry() public {
        _depositErc(evault, 100 ether);
        evault.initialDeposit();
        uint256 lbBefore = lbErcAdapter.getBalance();
        uint256 sovBefore = sovErcAdapter.getBalance();

        vm.mockCallRevert(
            address(lbErcAdapter), abi.encodeWithSelector(IERC20LendingAdapter.getUtilization.selector), "dark"
        );
        _depositErc(evault, 100 ether);
        vm.clearMockedCalls();

        assertEq(lbErcAdapter.getBalance(), lbBefore, "dark utilization view must be treated as at ceiling");
        assertGt(sovErcAdapter.getBalance(), sovBefore, "eligible venue must still receive funds");
    }

    // -- Exits are never gated --

    function test_Exits_UnaffectedAt100PercentUtilization() public {
        _depositNative(vault, 2 ether);
        vault.initialDeposit();
        _setLbNativeUtil(10_000);
        _setSovNativeUtil(10_000);

        // ERC-4626 withdraw pulls from adapters despite full utilization
        vm.prank(alice);
        vault.withdraw(0.5 ether, alice, alice);
        assertEq(wrbtc.balanceOf(alice), 0.5 ether, "withdraw must work at 100% utilization");

        // native withdraw path
        uint256 balBefore = alice.balance;
        vm.prank(alice);
        vault.withdrawNative(0.5 ether, alice, alice);
        assertEq(alice.balance - balBefore, 0.5 ether, "withdrawNative must work at 100% utilization");

        // in-kind redemption needs only receipt-token transfers
        uint256 shares = vault.balanceOf(alice) / 2;
        vm.prank(alice);
        vault.redeemInKind(shares, alice, alice);
        assertGt(
            lbPool.aTokens(address(wrbtc)).balanceOf(alice) + mockIToken.balanceOf(alice),
            0,
            "redeemInKind must deliver receipt tokens at 100% utilization"
        );
    }

    function test_Exits_WorkWhenUtilizationViewsRevert() public {
        _depositNative(vault, 2 ether);
        vault.initialDeposit();

        vm.mockCallRevert(address(lbAdapter), abi.encodeWithSelector(ILendingAdapter.getUtilization.selector), "dark");
        vm.mockCallRevert(
            address(sovrynAdapter), abi.encodeWithSelector(ILendingAdapter.getUtilization.selector), "dark"
        );

        vm.prank(alice);
        vault.withdraw(0.5 ether, alice, alice);
        assertEq(wrbtc.balanceOf(alice), 0.5 ether, "withdraw must ignore utilization views");

        uint256 shares = vault.balanceOf(alice) / 2;
        vm.prank(alice);
        vault.redeemInKind(shares, alice, alice);

        // and a deposit still SUCCEEDS, it just stays idle (fail-closed entry)
        uint256 idleBefore = wrbtc.balanceOf(address(vault));
        _depositNative(vault, 1 ether);
        assertEq(wrbtc.balanceOf(address(vault)), idleBefore + 1 ether, "deposit must land idle, not revert");
        vm.clearMockedCalls();
    }

    function test_ERC20_Exits_UnaffectedAt100PercentUtilization() public {
        _depositErc(evault, 200 ether);
        evault.initialDeposit();
        _setLbErcUtil(10_000);
        _setSovErcUtil(10_000);

        vm.prank(alice);
        evault.withdraw(50 ether, alice, alice);
        assertEq(doc.balanceOf(alice), 50 ether, "withdraw must work at 100% utilization");

        uint256 shares = evault.balanceOf(alice) / 2;
        vm.prank(alice);
        evault.redeemInKind(shares, alice, alice);
        assertGt(
            lbPoolErc.aTokens(address(doc)).balanceOf(alice) + mockIDOC.balanceOf(alice),
            0,
            "redeemInKind must deliver receipt tokens at 100% utilization"
        );
    }

    // -- Post-allocation drift --

    function test_DriftAboveCeiling_NeverForcesExit() public {
        _depositNative(vault, 1 ether);
        vault.initialDeposit();
        uint256 lbBefore = lbAdapter.getBalance();
        assertGt(lbBefore, 0, "sanity: layerbank funded");

        // utilization drifts above the ceiling AFTER allocation
        _setLbNativeUtil(9900);

        assertEq(lbAdapter.getBalance(), lbBefore, "drift must not move deployed funds");
        vm.prank(alice);
        vault.withdraw(0.3 ether, alice, alice);
        assertEq(wrbtc.balanceOf(alice), 0.3 ether, "withdraw must still pull from the drifted venue");
    }

    // -- Rebalance target selection --

    function test_Rebalance_NeverTargetsVenueAtCeiling() public {
        _depositNative(vault, 1 ether);
        vault.initialDeposit();
        assertEq(address(vault.activeAdapter()), address(lbAdapter), "sanity: layerbank primary");

        // Sovryn's rate becomes far better, but the market is nearly drained
        mockIToken.setSupplyInterestRate(20e16 * 100); // 20%
        _setSovNativeUtil(9500);
        vm.warp(block.timestamp + COOLDOWN + 1);

        vm.expectRevert("rate improvement too small");
        vault.rebalance();

        // once utilization falls below the ceiling the same rebalance goes through
        _setSovNativeUtil(5000);
        vault.rebalance();
        assertEq(address(vault.activeAdapter()), address(sovrynAdapter), "eligible venue becomes primary");
    }

    function test_ERC20_Rebalance_NeverTargetsVenueAtCeiling() public {
        _depositErc(evault, 100 ether);
        evault.initialDeposit();
        assertEq(address(evault.activeAdapter()), address(lbErcAdapter), "sanity: layerbank primary");

        mockIDOC.setSupplyInterestRate(20e16 * 100); // 20%
        _setSovErcUtil(9500);
        vm.warp(block.timestamp + COOLDOWN + 1);

        vm.expectRevert("rate improvement too small");
        evault.rebalance();

        _setSovErcUtil(5000);
        evault.rebalance();
        assertEq(address(evault.activeAdapter()), address(sovErcAdapter), "eligible venue becomes primary");
    }

    // -- Constructor bounds and factory pass-through --

    function test_Constructor_CeilingBounds() public {
        ILendingAdapter[] memory adapters = new ILendingAdapter[](2);
        adapters[0] = ILendingAdapter(address(new LayerBankAdapter(address(lbPool), address(wrbtc))));
        adapters[1] = ILendingAdapter(address(new SovrynAdapter(address(mockIToken))));

        vm.expectRevert("bad utilization ceiling");
        new YieldVault(address(wrbtc), adapters, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_RATE, CAP_BPS, TVL_CAP, 0);

        vm.expectRevert("bad utilization ceiling");
        new YieldVault(address(wrbtc), adapters, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_RATE, CAP_BPS, TVL_CAP, 10_001);

        // 10_000 is legal: the gate binds only on fully utilized markets
        YieldVault v = new YieldVault(
            address(wrbtc), adapters, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_RATE, CAP_BPS, TVL_CAP, 10_000
        );
        assertEq(v.utilizationCeilingBps(), 10_000);
        assertEq(vault.utilizationCeilingBps(), UTIL_CEILING_BPS, "main vault carries the Phase 0 value");
    }

    function test_ERC20_Constructor_CeilingBounds() public {
        IERC20LendingAdapter[] memory adapters = new IERC20LendingAdapter[](2);
        adapters[0] = IERC20LendingAdapter(address(new LayerBankERC20Adapter(address(lbPoolErc), address(doc))));
        adapters[1] = IERC20LendingAdapter(address(new SovrynERC20Adapter(address(mockIDOC), address(doc))));

        vm.expectRevert("bad utilization ceiling");
        new ERC20YieldVault(
            address(doc),
            adapters,
            ERC20YieldVault.VaultConfig({
                cooldownPeriod: COOLDOWN,
                rateThreshold: THRESHOLD,
                callerRewardBps: REWARD_BPS,
                maxSaneRate: MAX_RATE,
                adapterCapBps: CAP_BPS,
                tvlCap: TVL_CAP,
                utilizationCeilingBps: 0
            }),
            "Test",
            "T",
            address(this)
        );

        vm.expectRevert("bad utilization ceiling");
        new ERC20YieldVault(
            address(doc),
            adapters,
            ERC20YieldVault.VaultConfig({
                cooldownPeriod: COOLDOWN,
                rateThreshold: THRESHOLD,
                callerRewardBps: REWARD_BPS,
                maxSaneRate: MAX_RATE,
                adapterCapBps: CAP_BPS,
                tvlCap: TVL_CAP,
                utilizationCeilingBps: 10_001
            }),
            "Test",
            "T",
            address(this)
        );

        assertEq(evault.utilizationCeilingBps(), UTIL_CEILING_BPS, "main vault carries the Phase 0 value");
    }

    function test_Factory_PassesCeilingThrough() public {
        VaultFactory factory = new VaultFactory();
        LayerBankERC20Adapter lb = new LayerBankERC20Adapter(address(lbPoolErc), address(doc));
        SovrynERC20Adapter sov = new SovrynERC20Adapter(address(mockIDOC), address(doc));
        factory.trustAdapter(address(lb));
        factory.trustAdapter(address(sov));

        IERC20LendingAdapter[] memory adapters = new IERC20LendingAdapter[](2);
        adapters[0] = IERC20LendingAdapter(address(lb));
        adapters[1] = IERC20LendingAdapter(address(sov));

        address v = factory.createVault(
            address(doc), adapters, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_RATE, CAP_BPS, TVL_CAP, 8500, "F", "F"
        );
        assertEq(ERC20YieldVault(v).utilizationCeilingBps(), 8500, "factory must thread the ceiling through");
    }

    function test_Factory_RejectsBadCeiling() public {
        VaultFactory factory = new VaultFactory();
        LayerBankERC20Adapter lb = new LayerBankERC20Adapter(address(lbPoolErc), address(doc));
        SovrynERC20Adapter sov = new SovrynERC20Adapter(address(mockIDOC), address(doc));
        factory.trustAdapter(address(lb));
        factory.trustAdapter(address(sov));

        IERC20LendingAdapter[] memory adapters = new IERC20LendingAdapter[](2);
        adapters[0] = IERC20LendingAdapter(address(lb));
        adapters[1] = IERC20LendingAdapter(address(sov));

        vm.expectRevert("bad utilization ceiling");
        factory.createVault(
            address(doc), adapters, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_RATE, CAP_BPS, TVL_CAP, 0, "F", "F"
        );
    }

    // -- Vesting discount vs gated re-allocation --

    /// Accrue yield onto the LayerBank position, recomputing the index.
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

    /// A rebalance whose redeploy is fully gated leaves everything idle and
    /// resyncs trackedDeployed to zero while the vesting buffer stays. The
    /// still-vesting profit must NOT unlock early into the share price then,
    /// and the price must not collapse when the funds are later redeployed.
    /// Pins the total-basis vesting discount in totalAssets().
    function test_GatedRebalance_KeepsVestingDiscount_NoPriceCollapse() public {
        _seedLbNative(1 ether); // external supply the vault cannot pull:
        _seedSovNative(1 ether); // gated markets stay non-empty through the pull
        _depositNative(vault, 10 ether);
        vault.initialDeposit();

        // recognize 1 ether of profit; it starts vesting over 3 days
        _accrueLbNative(1 ether);
        _depositNative(vault, 0.01 ether);
        assertGt(vault.lockedProfitStored(), 0.8 ether, "sanity: gain recognized and locked");
        uint256 taBefore = vault.totalAssets();

        // LayerBank gated outright; Sovryn passes selection at 88% but its
        // market is mostly the vault's own supply, so the rebalance pull
        // pushes it over the ceiling and the redeploy places nothing
        _setLbNativeUtil(9500);
        _setSovNativeUtil(8800);
        mockIToken.setSupplyInterestRate(20e16 * 100); // 20%
        vm.warp(block.timestamp + COOLDOWN + 1);
        vault.rebalance();

        assertEq(lbAdapter.getBalance() + sovrynAdapter.getBalance(), 0, "sanity: redeploy fully gated");
        assertGt(wrbtc.balanceOf(address(vault)), 0, "sanity: funds idle");

        // (1) going idle must not unlock the vesting buffer early
        assertLe(vault.totalAssets(), taBefore + 0.05 ether, "idle funds unlocked still-vesting profit");

        // a large in-kind exit prices at the discounted basis, then fresh
        // funds redeploy everything below a cleared ceiling
        uint256 shares = vault.balanceOf(alice) * 95 / 100;
        vm.prank(alice);
        vault.redeemInKind(shares, alice, alice);
        lbPool.setTotalDebt(address(wrbtc), 0);
        mockIToken.setTotalAssetBorrow(0);
        _depositNative(vault, 0.5 ether);

        // (2) the stale buffer must not over-discount the redeployed funds
        assertGe(vault.totalAssets(), 0.5 ether, "vesting buffer over-discounted redeployed funds");
    }

    function test_ERC20_GatedRebalance_KeepsVestingDiscount_NoPriceCollapse() public {
        _seedLbErc(100 ether); // external supply the vault cannot pull
        _seedSovErc(100 ether);
        _depositErc(evault, 1000 ether);
        evault.initialDeposit();

        _accrueLbErc(100 ether);
        _depositErc(evault, 1 ether);
        assertGt(evault.lockedProfitStored(), 80 ether, "sanity: gain recognized and locked");
        uint256 taBefore = evault.totalAssets();

        _setLbErcUtil(9500);
        _setSovErcUtil(8800);
        mockIDOC.setSupplyInterestRate(20e16 * 100); // 20%
        vm.warp(block.timestamp + COOLDOWN + 1);
        evault.rebalance();

        assertEq(lbErcAdapter.getBalance() + sovErcAdapter.getBalance(), 0, "sanity: redeploy fully gated");
        assertGt(doc.balanceOf(address(evault)), 0, "sanity: funds idle");

        assertLe(evault.totalAssets(), taBefore + 5 ether, "idle funds unlocked still-vesting profit");

        uint256 shares = evault.balanceOf(alice) * 95 / 100;
        vm.prank(alice);
        evault.redeemInKind(shares, alice, alice);
        lbPoolErc.setTotalDebt(address(doc), 0);
        mockIDOC.setTotalAssetBorrow(0);
        _depositErc(evault, 50 ether);

        assertGe(evault.totalAssets(), 50 ether, "vesting buffer over-discounted redeployed funds");
    }

    /// Native rebalance pays the caller reward in rBTC.
    receive() external payable {}

    // -- Fuzz: the boundary is exactly ceiling * 1e14 on the 1e18 scale --

    function testFuzz_CeilingBoundary_Native(uint256 debtSeed) public {
        _depositNative(vault, 1 ether);
        vault.initialDeposit();

        uint256 supply = lbPool.aTokens(address(wrbtc)).totalSupply();
        lbPool.setTotalDebt(address(wrbtc), bound(debtSeed, 0, supply * 12_000 / 10_000));

        uint256 util = lbAdapter.getUtilization();
        uint256 lbBefore = lbAdapter.getBalance();
        _depositNative(vault, 1 ether);

        if (util >= GATE) {
            assertEq(lbAdapter.getBalance(), lbBefore, "venue at or above ceiling received new funds");
        } else {
            assertGt(lbAdapter.getBalance(), lbBefore, "venue below ceiling was wrongly skipped");
        }
    }

    function testFuzz_CeilingBoundary_ERC20(uint256 debtSeed) public {
        _depositErc(evault, 100 ether);
        evault.initialDeposit();

        uint256 supply = lbPoolErc.aTokens(address(doc)).totalSupply();
        lbPoolErc.setTotalDebt(address(doc), bound(debtSeed, 0, supply * 12_000 / 10_000));

        uint256 util = lbErcAdapter.getUtilization();
        uint256 lbBefore = lbErcAdapter.getBalance();
        _depositErc(evault, 100 ether);

        if (util >= GATE) {
            assertEq(lbErcAdapter.getBalance(), lbBefore, "venue at or above ceiling received new funds");
        } else {
            assertGt(lbErcAdapter.getBalance(), lbBefore, "venue below ceiling was wrongly skipped");
        }
    }
}
