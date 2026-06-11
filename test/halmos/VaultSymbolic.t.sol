// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {YieldVault} from "../../src/YieldVault.sol";
import {ERC20YieldVault} from "../../src/ERC20YieldVault.sol";
import {TropykusAdapter} from "../../src/adapters/TropykusAdapter.sol";
import {SovrynAdapter} from "../../src/adapters/SovrynAdapter.sol";
import {TropykusERC20Adapter} from "../../src/adapters/TropykusERC20Adapter.sol";
import {SovrynERC20Adapter} from "../../src/adapters/SovrynERC20Adapter.sol";
import {ILendingAdapter} from "../../src/interfaces/ILendingAdapter.sol";
import {IERC20LendingAdapter} from "../../src/interfaces/IERC20LendingAdapter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockCErc20} from "../mocks/MockCErc20.sol";
import {MockLoanToken} from "../mocks/MockLoanToken.sol";
import {MockWRBTC} from "../mocks/MockWRBTC.sol";
import {MockkToken} from "../mocks/MockkToken.sol";
import {MockiToken} from "../mocks/MockiToken.sol";

/// @dev Exposes the internal adapter-selection logic for symbolic verification
contract ERC20VaultHarness is ERC20YieldVault {
    constructor(
        address _asset,
        IERC20LendingAdapter[] memory _adapters,
        uint256 _cooldownPeriod,
        uint256 _rateThreshold,
        uint256 _callerRewardBps,
        uint256 _maxSaneRate,
        address _guardian
    ) ERC20YieldVault(_asset, _adapters, _cooldownPeriod, _rateThreshold, _callerRewardBps, _maxSaneRate, "H", "H", _guardian) {}

    function exposed_findBestRate() external view returns (IERC20LendingAdapter, uint256) {
        return _findBestRate();
    }
}

/// @notice Halmos symbolic checks: each `check_` function is proven for ALL
///         inputs in its domain (or a counterexample is produced).
///         Run: halmos --contract VaultSymbolicTest
contract VaultSymbolicTest is Test {
    // ERC20 side
    ERC20VaultHarness vault;
    MockERC20 asset;
    MockCErc20 kPool;
    MockLoanToken iPool;
    TropykusERC20Adapter kAdapter;
    SovrynERC20Adapter iAdapter;

    // Native side (for the receive() filter proof)
    YieldVault nVault;
    MockWRBTC wrbtc;
    MockkToken kRbtc;
    MockiToken iRbtc;
    TropykusAdapter nkAdapter;
    SovrynAdapter niAdapter;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address rebalancer = address(0x4EBA);

    uint256 constant COOLDOWN = 3600;
    uint256 constant THRESHOLD = 5e14;
    uint256 constant REWARD_BPS = 100;
    uint256 constant MAX_RATE = 1e18; // 100% APR cap for the proof domain
    uint256 constant BLOCKS_PER_YEAR = 1_051_200;

    function setUp() public {
        // ERC20 vault + harness
        asset = new MockERC20("Dollar on Chain", "DOC");
        kPool = new MockCErc20(address(asset));
        iPool = new MockLoanToken(address(asset));
        kAdapter = new TropykusERC20Adapter(address(kPool), address(asset));
        iAdapter = new SovrynERC20Adapter(address(iPool), address(asset));

        IERC20LendingAdapter[] memory adapters = new IERC20LendingAdapter[](2);
        adapters[0] = IERC20LendingAdapter(address(kAdapter));
        adapters[1] = IERC20LendingAdapter(address(iAdapter));

        vault = new ERC20VaultHarness(
            address(asset), adapters, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_RATE, address(this)
        );

        // Native vault
        wrbtc = new MockWRBTC();
        kRbtc = new MockkToken();
        iRbtc = new MockiToken();
        nkAdapter = new TropykusAdapter(address(kRbtc));
        niAdapter = new SovrynAdapter(address(iRbtc));

        ILendingAdapter[] memory nAdapters = new ILendingAdapter[](2);
        nAdapters[0] = ILendingAdapter(address(nkAdapter));
        nAdapters[1] = ILendingAdapter(address(niAdapter));

        nVault = new YieldVault(address(wrbtc), nAdapters, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_RATE);
    }

    // ------------------------------------------------------------------
    // 1. Adapter selection filter — full functional correctness
    // ------------------------------------------------------------------

    /// For ALL rate pairs: the selected rate never exceeds the cap, an
    /// adapter is selected iff at least one rate is sane, and the selected
    /// rate is exactly the maximum of the sane rates.
    function check_findBestRate_filterCorrect(uint128 perBlockA, uint128 rateB) external {
        kPool.setSupplyRatePerBlock(perBlockA);
        iPool.setSupplyInterestRate(rateB);

        uint256 rateA = uint256(perBlockA) * BLOCKS_PER_YEAR; // kAdapter.getRate()

        (IERC20LendingAdapter best, uint256 bestRate) = vault.exposed_findBestRate();

        // Never exceeds the cap
        assert(bestRate <= MAX_RATE);

        bool aSane = rateA <= MAX_RATE;
        bool bSane = rateB <= MAX_RATE;

        if (!aSane && !bSane) {
            // Nothing selectable
            assert(address(best) == address(0));
            assert(bestRate == 0);
        } else {
            // bestRate is exactly the max of the sane rates
            uint256 expected = 0;
            if (aSane && rateA > expected) expected = rateA;
            if (bSane && rateB > expected) expected = rateB;
            assert(bestRate == expected);
            // and an insane adapter is never the selection
            if (!aSane) assert(address(best) != address(kAdapter));
            if (!bSane) assert(address(best) != address(iAdapter));
        }
    }

    // ------------------------------------------------------------------
    // 2. ERC-4626 rounding safety under arbitrary state (incl. donations)
    // ------------------------------------------------------------------

    /// Sets up an adversarial concrete prior state (dust deposit + huge
    /// donation = maximally skewed share price). Both symbolic-state AND
    /// symbolic-probe at once is intractable for SMT (symbolic division by a
    /// symbolic divisor), so the state is concrete and the probe is symbolic:
    /// the property is proven for ALL probe amounts under each state.
    function _skewedState(uint256 dep, uint256 donation) internal {
        asset.mint(alice, dep);
        vm.startPrank(alice);
        asset.approve(address(vault), dep);
        vault.deposit(dep, alice);
        vm.stopPrank();
        asset.mint(address(vault), donation);
    }

    /// NOT PROVEN — solver-intractable, kept for future attempts (e.g. with
    /// bitwuzla). The `noproof_` prefix excludes these from halmos runs.
    ///
    /// These three properties route through OpenZeppelin's Math.mulDiv, whose
    /// 512-bit mulmod machinery makes the SMT queries undecidable for yices
    /// within a 10-minute budget (timeouts, NO counterexamples found). The
    /// properties are battle-tested upstream (OZ ERC-4626) and covered here by
    /// the stateful invariant suite (sharesFullyBacked, 128k random calls).

    /// For ALL probe amounts under a maximally donation-skewed state:
    /// converting assets to shares and back never returns more than the input.
    function noproof_convertRoundTrip_skewedState(uint96 probe) external {
        _skewedState(1, 1_000_000 ether); // 1 wei deposit, 1M donation
        uint256 shares = vault.convertToShares(probe);
        assert(vault.convertToAssets(shares) <= probe);
    }

    /// Same property under a large-supply, small-donation state.
    function noproof_convertRoundTrip_largeSupply(uint96 probe) external {
        _skewedState(1_000_000 ether, 1);
        uint256 shares = vault.convertToShares(probe);
        assert(vault.convertToAssets(shares) <= probe);
    }

    /// For ALL deposit amounts under a donation-skewed state: deposit
    /// immediately followed by redeeming every received share never returns
    /// more than was put in.
    function noproof_depositRedeem_neverProfits(uint96 amount) external {
        vm.assume(amount > 0);
        _skewedState(1, 1_000_000 ether);

        asset.mint(bob, amount);
        vm.startPrank(bob);
        asset.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, bob);
        uint256 out = vault.redeem(shares, bob, bob);
        vm.stopPrank();

        assert(out <= amount);
    }

    // ------------------------------------------------------------------
    // 3. Reward clamp — rebalancer can never extract more than withdrawn
    // ------------------------------------------------------------------

    /// For ALL deposit sizes and donation sizes: the caller reward paid by
    /// rebalance() never exceeds what was actually pulled from the adapter.
    function check_rebalance_rewardBoundedByWithdrawn(uint96 dep, uint96 donation) external {
        vm.assume(dep > 0);

        // Tropykus 5%, Sovryn 3% -> initial deploy to Tropykus
        kPool.setSupplyRatePerBlock(47564687975);
        iPool.setSupplyInterestRate(3e16);

        asset.mint(alice, dep);
        vm.startPrank(alice);
        asset.approve(address(vault), dep);
        vault.deposit(dep, alice);
        vm.stopPrank();
        vault.initialDeposit();

        // Arbitrary donation inflates yieldAccrued
        asset.mint(address(vault), donation);

        // Make Sovryn the better market and pass the cooldown
        iPool.setSupplyInterestRate(8e16);
        vm.warp(block.timestamp + COOLDOWN + 1);

        uint256 before = asset.balanceOf(rebalancer);
        vm.prank(rebalancer);
        vault.rebalance();

        // Deployed balance was exactly `dep` (no accrual) — reward can never exceed it
        assert(asset.balanceOf(rebalancer) - before <= dep);
    }

    // ------------------------------------------------------------------
    // 4. Native vault donation filter — proven for ALL senders
    // ------------------------------------------------------------------

    /// For ALL senders that are not WRBTC or a registered adapter, and ALL
    /// nonzero amounts: a direct rBTC transfer to the vault reverts.
    function check_receive_rejectsAllArbitrarySenders(address sender, uint96 amount) external {
        vm.assume(amount > 0);
        vm.assume(sender != address(wrbtc));
        vm.assume(sender != address(nkAdapter));
        vm.assume(sender != address(niAdapter));
        vm.assume(sender != address(nVault)); // self-send is not the property under test

        vm.deal(sender, amount);
        vm.prank(sender);
        (bool ok,) = address(nVault).call{value: amount}("");
        assert(!ok);
    }

    /// Complement: WRBTC and registered adapters can ALWAYS send any amount.
    function check_receive_acceptsAllowedSenders(uint96 amount) external {
        vm.assume(amount > 0);

        vm.deal(address(wrbtc), amount);
        vm.prank(address(wrbtc));
        (bool okW,) = address(nVault).call{value: amount}("");
        assert(okW);

        vm.deal(address(niAdapter), amount);
        vm.prank(address(niAdapter));
        (bool okA,) = address(nVault).call{value: amount}("");
        assert(okA);
    }
}
