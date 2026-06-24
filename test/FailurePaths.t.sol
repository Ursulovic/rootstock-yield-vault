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
import {MockLayerBankPool, MockAToken} from "./mocks/MockLayerBankPool.sol";
import {MockiToken} from "./mocks/MockiToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockLoanToken} from "./mocks/MockLoanToken.sol";

/// @notice Failure-path coverage for both vault flavors: the LayerBank
///         full-exit sentinel on the actual rounding edge, the rebalance
///         abort-vs-dust-tolerance distinction on pull failures, the
///         _pullWaterfall fallback pass for rate-broken adapters, and the
///         code-existence branch of isAdapterHealthy.
contract FailurePathsTest is Test {
    uint256 constant RAY = 1e27;
    uint256 constant DUST = 1e12; // well below deployedBalance / 1e6 in these tests

    YieldVault vault;
    MockWRBTC wrbtc;
    MockLayerBankPool lbPool;
    MockiToken mockIToken;
    LayerBankAdapter lbAdapter;
    SovrynAdapter sovrynAdapter;

    ERC20YieldVault evault;
    MockERC20 doc;
    MockLayerBankPool lbPoolDoc;
    MockLoanToken mockIDOC;
    LayerBankERC20Adapter lbErc20Adapter;
    SovrynERC20Adapter sovErc20Adapter;

    address alice = makeAddr("fp_alice");
    address rebalancer = makeAddr("fp_rebalancer");

    uint256 constant COOLDOWN = 3600;
    uint256 constant THRESHOLD = 5e14;
    uint256 constant REWARD_BPS = 100;
    uint256 constant MAX_RATE = 0.5e18;
    uint256 constant CAP_BPS = 6000; // 60% per-adapter cap
    uint256 constant TVL_CAP = type(uint256).max;

    function setUp() public {
        wrbtc = new MockWRBTC();
        lbPool = new MockLayerBankPool();
        lbPool.initReserve(address(wrbtc));
        mockIToken = new MockiToken();
        lbAdapter = new LayerBankAdapter(address(lbPool), address(wrbtc));
        sovrynAdapter = new SovrynAdapter(address(mockIToken));

        ILendingAdapter[] memory nAdapters = new ILendingAdapter[](2);
        nAdapters[0] = ILendingAdapter(address(lbAdapter));
        nAdapters[1] = ILendingAdapter(address(sovrynAdapter));
        vault = new YieldVault(address(wrbtc), nAdapters, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_RATE, CAP_BPS, TVL_CAP);

        lbPool.setSupplyRate1e18(address(wrbtc), 5e16);
        mockIToken.setSupplyInterestRate(3e16 * 100); // percent scale

        doc = new MockERC20("Dollar on Chain", "DOC");
        lbPoolDoc = new MockLayerBankPool();
        lbPoolDoc.initReserve(address(doc));
        mockIDOC = new MockLoanToken(address(doc));
        lbErc20Adapter = new LayerBankERC20Adapter(address(lbPoolDoc), address(doc));
        sovErc20Adapter = new SovrynERC20Adapter(address(mockIDOC), address(doc));

        IERC20LendingAdapter[] memory eAdapters = new IERC20LendingAdapter[](2);
        eAdapters[0] = IERC20LendingAdapter(address(lbErc20Adapter));
        eAdapters[1] = IERC20LendingAdapter(address(sovErc20Adapter));
        evault = new ERC20YieldVault(
            address(doc),
            eAdapters,
            COOLDOWN,
            THRESHOLD,
            REWARD_BPS,
            MAX_RATE,
            CAP_BPS,
            TVL_CAP,
            "DOC Yield Vault",
            "yvDOC",
            address(this)
        );

        lbPoolDoc.setSupplyRate1e18(address(doc), 5e16);
        mockIDOC.setSupplyInterestRate(3e16 * 100);

        vm.deal(alice, 100 ether);
        doc.mint(alice, 100 ether);
    }

    /// @dev Sentinel tests bind standalone adapters to this contract as their vault.
    receive() external payable {}

    function _depositNativeAndInit(uint256 amount) internal {
        vm.prank(alice);
        vault.depositNative{value: amount}(alice);
        vault.initialDeposit();
    }

    function _depositErc20AndInit(uint256 amount) internal {
        vm.startPrank(alice);
        doc.approve(address(evault), amount);
        evault.deposit(amount, alice);
        vm.stopPrank();
        evault.initialDeposit();
    }

    // LayerBank full-exit sentinel, hit on the real rounding edge:
    // the adapter must enter AFTER the index has moved so its scaled
    // balance carries a fractional remainder. (Depositing at idx == RAY
    // first makes scaled * idx % RAY == 0 and the assertion vacuous.)

    function test_Native_Sentinel_FullPullOnRoundingEdge_LeavesNoScaledDust() public {
        MockLayerBankPool pool = new MockLayerBankPool();
        pool.initReserve(address(wrbtc));
        LayerBankAdapter adapter = new LayerBankAdapter(address(pool), address(wrbtc));
        adapter.setVault(address(this));

        vm.deal(address(this), 13 ether);
        wrbtc.deposit{value: 11.5 ether}();
        wrbtc.approve(address(pool), 10 ether);
        pool.supply(address(wrbtc), 10 ether, address(this), 0);

        wrbtc.transfer(address(pool), 1 ether);
        pool.accrueInterest(address(wrbtc)); // idx 1.1 RAY before the adapter enters
        adapter.deposit{value: 1 ether}(); // scaled = 10/11 * 1e18, truncated
        wrbtc.transfer(address(pool), 0.5 ether);
        pool.accrueInterest(address(wrbtc));

        MockAToken aToken = pool.aTokens(address(wrbtc));
        uint256 idx = pool.liquidityIndex(address(wrbtc));
        uint256 scaled = aToken.scaledBalanceOf(address(adapter));
        // Self-check: an exact-amount withdrawal would half-up-round the burn
        // to scaled - 1 here, which is exactly the edge the sentinel closes
        assertGt(scaled * idx % RAY, idx / 2, "setup must land on the rounding edge");

        uint256 held = adapter.getBalance();
        uint256 received = adapter.withdraw(held);
        assertGe(received, held, "full pull delivers the full balance");
        assertEq(aToken.scaledBalanceOf(address(adapter)), 0, "no scaled dust after a full exit");
    }

    function test_ERC20_Sentinel_FullPullOnRoundingEdge_LeavesNoScaledDust() public {
        MockLayerBankPool pool = new MockLayerBankPool();
        pool.initReserve(address(doc));
        LayerBankERC20Adapter adapter = new LayerBankERC20Adapter(address(pool), address(doc));
        adapter.setVault(address(this));

        doc.mint(address(this), 12.5 ether);
        doc.approve(address(pool), 10 ether);
        pool.supply(address(doc), 10 ether, address(this), 0);

        doc.transfer(address(pool), 1 ether);
        pool.accrueInterest(address(doc));
        doc.approve(address(adapter), 1 ether);
        adapter.deposit(1 ether);
        doc.transfer(address(pool), 0.5 ether);
        pool.accrueInterest(address(doc));

        MockAToken aToken = pool.aTokens(address(doc));
        uint256 idx = pool.liquidityIndex(address(doc));
        uint256 scaled = aToken.scaledBalanceOf(address(adapter));
        assertGt(scaled * idx % RAY, idx / 2, "setup must land on the rounding edge");

        uint256 held = adapter.getBalance();
        uint256 received = adapter.withdraw(held);
        assertGe(received, held, "full pull delivers the full balance");
        assertEq(aToken.scaledBalanceOf(address(adapter)), 0, "no scaled dust after a full exit");
    }

    // Rebalance pull failures: a MATERIAL stuck position must abort, a
    // sub-dust one (<= deployedBalance / 1e6) must be tolerated.

    function test_Native_Rebalance_AbortsOnMaterialPullFailure() public {
        _depositNativeAndInit(10 ether); // LB 6 / Sovryn 4, active LB at 5%

        mockIToken.setSupplyInterestRate(8e16 * 100); // Sovryn becomes best
        lbPool.setPaused(true); // LB withdraw reverts while holding 6 ether
        vm.warp(block.timestamp + COOLDOWN + 1);

        vm.prank(rebalancer);
        vm.expectRevert("rebalance pull failed");
        vault.rebalance();
    }

    function test_Native_Rebalance_ToleratesDustOnlyStuckPosition() public {
        lbPool.setSupplyRate1e18(address(wrbtc), 3e16); // LB worst -> drained first on exits
        mockIToken.setSupplyInterestRate(5e16 * 100);
        _depositNativeAndInit(10 ether); // Sovryn 6 / LB 4

        vm.prank(alice);
        vault.withdrawNative(4 ether - DUST, alice, alice);
        assertEq(lbAdapter.getBalance(), DUST, "setup: dust-only position left in LB");

        lbPool.setPaused(true); // the dust pull will revert
        lbPool.setSupplyRate1e18(address(wrbtc), 8e16); // LB best again, triggers rebalance
        vm.warp(block.timestamp + COOLDOWN + 1);

        vm.prank(rebalancer);
        vault.rebalance();

        assertEq(vault.lastRebalanceTime(), block.timestamp, "dust-only stuck position must not abort");
        assertEq(lbAdapter.getBalance(), DUST, "dust stays behind");
    }

    function test_ERC20_Rebalance_AbortsOnMaterialPullFailure() public {
        _depositErc20AndInit(10 ether); // LB 6 / Sovryn 4, active LB at 5%

        mockIDOC.setSupplyInterestRate(8e16 * 100);
        lbPoolDoc.setPaused(true);
        vm.warp(block.timestamp + COOLDOWN + 1);

        vm.prank(rebalancer);
        vm.expectRevert("rebalance pull failed");
        evault.rebalance();
    }

    function test_ERC20_Rebalance_ToleratesDustOnlyStuckPosition() public {
        lbPoolDoc.setSupplyRate1e18(address(doc), 3e16);
        mockIDOC.setSupplyInterestRate(5e16 * 100);
        _depositErc20AndInit(10 ether); // Sovryn 6 / LB 4

        vm.prank(alice);
        evault.withdraw(4 ether - DUST, alice, alice);
        assertEq(lbErc20Adapter.getBalance(), DUST, "setup: dust-only position left in LB");

        lbPoolDoc.setPaused(true);
        lbPoolDoc.setSupplyRate1e18(address(doc), 8e16);
        vm.warp(block.timestamp + COOLDOWN + 1);

        vm.prank(rebalancer);
        evault.rebalance();

        assertEq(evault.lastRebalanceTime(), block.timestamp, "dust-only stuck position must not abort");
        assertEq(lbErc20Adapter.getBalance(), DUST, "dust stays behind");
    }

    // _pullWaterfall fallback pass: an adapter excluded from the sorted
    // list (getRate reverts) but still holding withdrawable funds must be
    // drained when a withdrawal needs more than the healthy adapters hold.

    function test_Native_Withdraw_FallbackDrainsRateBrokenAdapter() public {
        _depositNativeAndInit(10 ether); // LB 6 / Sovryn 4

        vm.mockCallRevert(
            address(sovrynAdapter), abi.encodeWithSelector(SovrynAdapter.getRate.selector), "rate oracle down"
        );

        uint256 before = alice.balance;
        vm.prank(alice);
        vault.withdrawNative(9 ether, alice, alice); // LB alone holds only 6

        assertEq(alice.balance - before, 9 ether, "withdrawal must reach funds in the rate-broken adapter");
        assertEq(lbAdapter.getBalance(), 0, "sorted pass drained the healthy adapter");
        assertApproxEqAbs(sovrynAdapter.getBalance(), 1 ether, 2, "fallback pass pulled the shortfall");
    }

    function test_ERC20_Withdraw_FallbackDrainsRateBrokenAdapter() public {
        _depositErc20AndInit(10 ether); // LB 6 / Sovryn 4

        vm.mockCallRevert(
            address(sovErc20Adapter), abi.encodeWithSelector(SovrynERC20Adapter.getRate.selector), "rate oracle down"
        );

        uint256 before = doc.balanceOf(alice);
        vm.prank(alice);
        evault.withdraw(9 ether, alice, alice);

        assertEq(doc.balanceOf(alice) - before, 9 ether, "withdrawal must reach funds in the rate-broken adapter");
        assertEq(lbErc20Adapter.getBalance(), 0, "sorted pass drained the healthy adapter");
        assertApproxEqAbs(sovErc20Adapter.getBalance(), 1 ether, 2, "fallback pass pulled the shortfall");
    }

    // isAdapterHealthy code-existence branch: an adapter address with no
    // code must report unhealthy (and not brick getAdapterHealth).

    function test_Native_AdapterHealth_FalseForCodelessAdapter() public {
        assertTrue(vault.isAdapterHealthy(1), "sanity: adapter healthy before code removal");

        vm.etch(address(sovrynAdapter), "");
        assertFalse(vault.isAdapterHealthy(1), "code-less adapter must report unhealthy");

        bool[] memory health = vault.getAdapterHealth();
        assertTrue(health[0], "other adapter unaffected");
        assertFalse(health[1], "health array reflects the code-less adapter");
    }

    function test_ERC20_AdapterHealth_FalseForCodelessAdapter() public {
        assertTrue(evault.isAdapterHealthy(1), "sanity: adapter healthy before code removal");

        vm.etch(address(sovErc20Adapter), "");
        assertFalse(evault.isAdapterHealthy(1), "code-less adapter must report unhealthy");

        bool[] memory health = evault.getAdapterHealth();
        assertTrue(health[0], "other adapter unaffected");
        assertFalse(health[1], "health array reflects the code-less adapter");
    }
}
