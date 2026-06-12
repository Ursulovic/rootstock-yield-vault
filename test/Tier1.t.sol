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
import {MockBrokenAdapter} from "./mocks/MockBrokenAdapter.sol";

/// @notice Tests for the Tier 1 feature set: EIP-2612 permit, adapter health
///         checks with failure isolation, and the LayerBank full-withdraw
///         sentinel.
contract Tier1Test is Test {
    YieldVault vault;
    MockWRBTC wrbtc;
    MockLayerBankPool lbPool;
    MockiToken mockIToken;
    LayerBankAdapter lbAdapter;
    SovrynAdapter sovrynAdapter;

    address alice;
    uint256 alicePk;
    address bob = makeAddr("t1_bob");
    address rebalancer = makeAddr("t1_rebalancer");

    uint256 constant COOLDOWN = 3600;
    uint256 constant THRESHOLD = 5e14;
    uint256 constant REWARD_BPS = 100;
    uint256 constant MAX_RATE = 0.5e18;

    function setUp() public {
        (alice, alicePk) = makeAddrAndKey("t1_alice");

        wrbtc = new MockWRBTC();
        lbPool = new MockLayerBankPool();
        lbPool.initReserve(address(wrbtc));
        mockIToken = new MockiToken();

        lbAdapter = new LayerBankAdapter(address(lbPool), address(wrbtc));
        sovrynAdapter = new SovrynAdapter(address(mockIToken));

        ILendingAdapter[] memory adapters = new ILendingAdapter[](2);
        adapters[0] = ILendingAdapter(address(lbAdapter));
        adapters[1] = ILendingAdapter(address(sovrynAdapter));
        vault = new YieldVault(address(wrbtc), adapters, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_RATE);

        lbPool.setSupplyRate1e18(address(wrbtc), 5e16);
        mockIToken.setSupplyInterestRate(3e16 * 100); // percent scale

        vm.deal(alice, 10 ether);
    }

    // ------------------------------------------------------------------
    // EIP-2612 permit
    // ------------------------------------------------------------------

    function test_Permit_SetsAllowanceFromSignature() public {
        vm.prank(alice);
        uint256 shares = vault.depositNative{value: 1 ether}(alice);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                alice,
                bob,
                shares,
                vault.nonces(alice),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

        // Gasless approval: bob submits alice's signature, then spends
        vm.prank(bob);
        vault.permit(alice, bob, shares, deadline, v, r, s);
        assertEq(vault.allowance(alice, bob), shares, "permit should set allowance");

        vm.prank(bob);
        vault.withdrawNative(1 ether, bob, alice);
        assertEq(bob.balance, 1 ether, "spender should withdraw via permit allowance");
    }

    function test_Permit_RejectsWrongSigner() public {
        (, uint256 evePk) = makeAddrAndKey("t1_eve");
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                alice,
                bob,
                1 ether,
                vault.nonces(alice),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(evePk, digest);

        vm.expectRevert();
        vault.permit(alice, bob, 1 ether, deadline, v, r, s);
    }

    // ------------------------------------------------------------------
    // Adapter health + failure isolation
    // ------------------------------------------------------------------

    function _vaultWithBrokenAdapter()
        internal
        returns (YieldVault v, MockBrokenAdapter broken, LayerBankAdapter healthy)
    {
        broken = new MockBrokenAdapter();
        healthy = new LayerBankAdapter(address(lbPool), address(wrbtc));

        ILendingAdapter[] memory adapters = new ILendingAdapter[](2);
        adapters[0] = ILendingAdapter(address(broken));
        adapters[1] = ILendingAdapter(address(healthy));
        v = new YieldVault(address(wrbtc), adapters, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_RATE);
    }

    function test_AdapterHealth_ReportsBrokenAdapter() public {
        (YieldVault v, MockBrokenAdapter broken,) = _vaultWithBrokenAdapter();

        bool[] memory health = v.getAdapterHealth();
        assertFalse(health[0], "broken adapter must report unhealthy");
        assertTrue(health[1], "healthy adapter must report healthy");

        broken.setBroken(false, false);
        assertTrue(v.isAdapterHealthy(0), "recovered adapter reports healthy again");
    }

    function test_Selection_SkipsAdapterWithRevertingRate() public {
        (YieldVault v, MockBrokenAdapter broken, LayerBankAdapter healthy) = _vaultWithBrokenAdapter();
        // Rate query bricked, balance still readable — the realistic partial
        // failure. (A reverting getBalance fails the whole vault closed by
        // design: share pricing must never silently undercount.)
        broken.setBroken(true, false);

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        v.depositNative{value: 1 ether}(alice);
        v.initialDeposit();

        assertEq(address(v.activeAdapter()), address(healthy), "selection must skip the broken adapter");
    }

    function test_TotalAssets_FailsClosedOnBrokenBalance() public {
        (YieldVault v, MockBrokenAdapter broken,) = _vaultWithBrokenAdapter();
        broken.setBroken(false, true);

        // Fail-closed: a balance query that reverts must brick pricing rather
        // than silently undercount and let exits drain at a wrong share price
        vm.expectRevert("protocol down");
        v.totalAssets();
    }

    // ------------------------------------------------------------------
    // LayerBank full-withdraw sentinel (dust-free exits)
    // ------------------------------------------------------------------

    function test_Sentinel_RebalanceLeavesNoScaledDust() public {
        vm.prank(alice);
        vault.depositNative{value: 1 ether}(alice);
        vault.initialDeposit(); // LayerBank

        // Skew the index to a value where an exact-amount withdrawal would
        // round below the full scaled balance
        vm.deal(address(this), 0.123456789 ether);
        wrbtc.deposit{value: 0.123456789 ether}();
        wrbtc.transfer(address(lbPool), 0.123456789 ether);
        lbPool.accrueInterest(address(wrbtc));

        // Rebalance away: withdraw(getBalance()) hits the max sentinel and
        // must burn the ENTIRE scaled position
        mockIToken.setSupplyInterestRate(8e16 * 100);
        vm.warp(block.timestamp + COOLDOWN + 1);
        vm.prank(rebalancer);
        vault.rebalance();

        address aTokenAddr = address(lbPool.aTokens(address(wrbtc)));
        (bool ok, bytes memory data) =
            aTokenAddr.staticcall(abi.encodeWithSignature("scaledBalanceOf(address)", address(lbAdapter)));
        assertTrue(ok);
        assertEq(abi.decode(data, (uint256)), 0, "no scaled dust may remain after a full rebalance pull");
        assertEq(address(vault.activeAdapter()), address(sovrynAdapter), "rebalance completed");
    }
}
