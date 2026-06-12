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
import {MockLayerBankPool} from "./mocks/MockLayerBankPool.sol";
import {MockiToken} from "./mocks/MockiToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockLoanToken} from "./mocks/MockLoanToken.sol";

/// @notice Function-level fuzz tests: single-call properties over wide input
///         domains. Complements the unit suite (concrete values), the
///         invariant suite (sequences) and the halmos proofs (full domains
///         on selected lemmas).
contract FuzzTest is Test {
    // Native vault
    YieldVault vault;
    MockWRBTC wrbtc;
    MockLayerBankPool lbPool;
    MockiToken mockIToken;
    LayerBankAdapter lbAdapter;
    SovrynAdapter sovrynAdapter;

    // ERC20 vault
    ERC20YieldVault evault;
    MockERC20 doc;
    MockLayerBankPool lbPoolDoc;
    MockLoanToken mockIDOC;

    address alice = makeAddr("fuzz_alice");
    address rebalancer = makeAddr("fuzz_rebalancer");

    uint256 constant COOLDOWN = 3600;
    uint256 constant THRESHOLD = 5e14;
    uint256 constant REWARD_BPS = 100;
    uint256 constant MAX_RATE = 0.5e18;
    uint256 constant CAP_BPS = 6000; // 60% per-adapter cap

    function setUp() public {
        // Native
        wrbtc = new MockWRBTC();
        lbPool = new MockLayerBankPool();
        lbPool.initReserve(address(wrbtc));
        mockIToken = new MockiToken();
        lbAdapter = new LayerBankAdapter(address(lbPool), address(wrbtc));
        sovrynAdapter = new SovrynAdapter(address(mockIToken));

        ILendingAdapter[] memory a = new ILendingAdapter[](2);
        a[0] = ILendingAdapter(address(lbAdapter));
        a[1] = ILendingAdapter(address(sovrynAdapter));
        vault = new YieldVault(address(wrbtc), a, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_RATE, CAP_BPS);

        lbPool.setSupplyRate1e18(address(wrbtc), 5e16);
        mockIToken.setSupplyInterestRate(3e16 * 100); // percent scale

        // ERC20
        doc = new MockERC20("Dollar on Chain", "DOC");
        lbPoolDoc = new MockLayerBankPool();
        lbPoolDoc.initReserve(address(doc));
        mockIDOC = new MockLoanToken(address(doc));
        IERC20LendingAdapter[] memory ea = new IERC20LendingAdapter[](2);
        ea[0] = IERC20LendingAdapter(address(new LayerBankERC20Adapter(address(lbPoolDoc), address(doc))));
        ea[1] = IERC20LendingAdapter(address(new SovrynERC20Adapter(address(mockIDOC), address(doc))));
        evault = new ERC20YieldVault(
            address(doc), ea, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_RATE, CAP_BPS, "DOC Vault", "yvDOC", address(this)
        );
        lbPoolDoc.setSupplyRate1e18(address(doc), 5e16);
        mockIDOC.setSupplyInterestRate(3e16 * 100);
    }

    /// Deposit then immediately redeem all shares never returns more than was
    /// put in — for ANY amount, idle or deployed.
    function testFuzz_Native_DepositRedeem_NeverProfits(uint96 amount, bool deployed) public {
        amount = uint96(bound(amount, 1, 1e24));
        vm.deal(alice, amount);

        if (deployed) {
            vm.deal(address(this), 1 ether);
            vault.depositNative{value: 1 ether}(address(this));
            vault.initialDeposit();
        }

        vm.prank(alice);
        uint256 shares = vault.depositNative{value: amount}(alice);
        vm.prank(alice);
        uint256 outAssets = vault.redeem(shares, alice, alice);

        assertLe(outAssets, amount, "round-trip must not profit");
    }

    function testFuzz_ERC20_DepositRedeem_NeverProfits(uint96 amount, bool deployed) public {
        amount = uint96(bound(amount, 1, 1e24));

        if (deployed) {
            doc.mint(address(this), 1 ether);
            doc.approve(address(evault), 1 ether);
            evault.deposit(1 ether, address(this));
            evault.initialDeposit();
        }

        doc.mint(alice, amount);
        vm.startPrank(alice);
        doc.approve(address(evault), amount);
        uint256 shares = evault.deposit(amount, alice);
        uint256 outAssets = evault.redeem(shares, alice, alice);
        vm.stopPrank();

        assertLe(outAssets, amount, "round-trip must not profit");
    }

    /// previewDeposit must never promise more shares than deposit() mints.
    function testFuzz_PreviewDeposit_NeverOverpromises(uint96 amount) public {
        amount = uint96(bound(amount, 1, 1e24));
        uint256 promised = evault.previewDeposit(amount);

        doc.mint(alice, amount);
        vm.startPrank(alice);
        doc.approve(address(evault), amount);
        uint256 minted = evault.deposit(amount, alice);
        vm.stopPrank();

        assertGe(minted, promised, "deposit must mint at least previewDeposit");
    }

    /// The reward paid by rebalance is exactly yieldAccrued * bps / 10_000,
    /// clamped to what was withdrawn — for ANY yield size.
    function testFuzz_RebalanceReward_MatchesFormula(uint96 yieldAmount) public {
        yieldAmount = uint96(bound(yieldAmount, 0, 1e22));

        vm.deal(alice, 5 ether);
        vm.prank(alice);
        vault.depositNative{value: 5 ether}(alice);
        vault.initialDeposit(); // LayerBank (5% > 3%)

        // Real yield lands in the LayerBank pool
        if (yieldAmount > 0) {
            vm.deal(address(this), yieldAmount);
            wrbtc.deposit{value: yieldAmount}();
            wrbtc.transfer(address(lbPool), yieldAmount);
            lbPool.accrueInterest(address(wrbtc));
        }

        mockIToken.setSupplyInterestRate(8e16 * 100); // make Sovryn better
        vm.warp(block.timestamp + COOLDOWN + 1);

        // Reward base is the recognized adapter growth, never donations
        uint256 rawDeployed = lbAdapter.getBalance() + sovrynAdapter.getBalance();
        uint256 expectedYield = rawDeployed > 5 ether ? rawDeployed - 5 ether : 0;
        uint256 expectedReward = expectedYield * REWARD_BPS / 10_000;

        uint256 before = rebalancer.balance;
        vm.prank(rebalancer);
        vault.rebalance();
        uint256 paid = rebalancer.balance - before;

        assertLe(paid, rawDeployed, "reward cannot exceed what the rebalance could withdraw");
        // Allow 2 wei of index-rounding slack between preview and execution
        assertApproxEqAbs(paid, expectedReward > rawDeployed ? rawDeployed : expectedReward, 2, "reward formula");
    }

    /// The threshold boundary is exact: one wei below fails, at/above passes.
    function testFuzz_RebalanceThreshold_Boundary(uint96 delta) public {
        delta = uint96(bound(delta, 0, 1e17));

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vault.depositNative{value: 1 ether}(alice);
        vault.initialDeposit(); // LayerBank at 5e16

        uint256 newRate = 5e16 + THRESHOLD + delta;
        vm.assume(newRate <= MAX_RATE);
        // Sovryn mock takes percent scale; getRate truncates /100, so set an
        // exact multiple to avoid rounding skew at the boundary
        mockIToken.setSupplyInterestRate(newRate * 100);
        vm.warp(block.timestamp + COOLDOWN + 1);

        if (delta == 0) {
            // exactly current + THRESHOLD: strict > comparison must reject
            vm.prank(rebalancer);
            vm.expectRevert("rate improvement too small");
            vault.rebalance();
        } else {
            vm.prank(rebalancer);
            vault.rebalance();
            assertEq(address(vault.activeAdapter()), address(sovrynAdapter));
        }
    }

    /// Sovryn percent-scale normalization is exact for any protocol rate.
    function testFuzz_SovrynRateNormalization(uint128 raw) public {
        mockIToken.setSupplyInterestRate(raw);
        assertEq(sovrynAdapter.getRate(), uint256(raw) / 100, "must divide by exactly 100");
    }

    /// LayerBank ray->1e18 conversion is exact for any pool rate.
    function testFuzz_LayerBankRateNormalization(uint96 rate1e18) public {
        lbPool.setSupplyRate1e18(address(wrbtc), rate1e18);
        assertEq(lbAdapter.getRate(), uint256(rate1e18), "ray/1e9 must round-trip");
    }
}
