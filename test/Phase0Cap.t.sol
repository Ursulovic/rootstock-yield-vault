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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockWRBTC} from "./mocks/MockWRBTC.sol";
import {MockLayerBankPool} from "./mocks/MockLayerBankPool.sol";
import {MockiToken} from "./mocks/MockiToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockLoanToken} from "./mocks/MockLoanToken.sol";

/// @notice Phase 0 immutable TVL cap: deposits cannot push totalAssets above
///         tvlCap, the cap is exposed through maxDeposit/maxMint, rebalancing
///         is unaffected, and type(uint256).max disables the cap.
contract Phase0CapTest is Test {
    MockWRBTC wrbtc;
    MockLayerBankPool lbPool;
    MockiToken mockIToken;
    LayerBankAdapter lbAdapter;
    SovrynAdapter sovrynAdapter;

    MockERC20 doc;
    MockLayerBankPool lbPoolErc;
    MockLoanToken mockIDOC;

    address alice = makeAddr("cap_alice");

    uint256 constant COOLDOWN = 3600;
    uint256 constant THRESHOLD = 5e14;
    uint256 constant REWARD_BPS = 100;
    uint256 constant MAX_RATE = 0.5e18;
    uint256 constant CAP_BPS = 6000;
    uint256 constant NATIVE_CAP = 1 ether;
    uint256 constant ERC20_CAP = 1000 ether;

    function setUp() public {
        wrbtc = new MockWRBTC();
        lbPool = new MockLayerBankPool();
        lbPool.initReserve(address(wrbtc));
        mockIToken = new MockiToken();

        doc = new MockERC20("Dollar on Chain", "DOC");
        lbPoolErc = new MockLayerBankPool();
        lbPoolErc.initReserve(address(doc));
        mockIDOC = new MockLoanToken(address(doc));

        lbPool.setSupplyRate1e18(address(wrbtc), 5e16); // LayerBank 5%
        mockIToken.setSupplyInterestRate(3e16 * 100); // Sovryn 3%, percent scale
        lbPoolErc.setSupplyRate1e18(address(doc), 5e16);
        mockIDOC.setSupplyInterestRate(3e16 * 100);
    }

    function _nativeVault(uint256 cap) internal returns (YieldVault v) {
        lbAdapter = new LayerBankAdapter(address(lbPool), address(wrbtc));
        sovrynAdapter = new SovrynAdapter(address(mockIToken));
        ILendingAdapter[] memory adapters = new ILendingAdapter[](2);
        adapters[0] = ILendingAdapter(address(lbAdapter));
        adapters[1] = ILendingAdapter(address(sovrynAdapter));
        v = new YieldVault(address(wrbtc), adapters, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_RATE, CAP_BPS, cap);
    }

    function _erc20Vault(uint256 cap) internal returns (ERC20YieldVault v) {
        LayerBankERC20Adapter lb = new LayerBankERC20Adapter(address(lbPoolErc), address(doc));
        SovrynERC20Adapter sov = new SovrynERC20Adapter(address(mockIDOC), address(doc));
        IERC20LendingAdapter[] memory adapters = new IERC20LendingAdapter[](2);
        adapters[0] = IERC20LendingAdapter(address(lb));
        adapters[1] = IERC20LendingAdapter(address(sov));
        v = new ERC20YieldVault(
            address(doc), adapters, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_RATE, CAP_BPS, cap, "Test", "T", address(this)
        );
    }

    function _depositNative(YieldVault v, address who, uint256 amount) internal {
        vm.deal(who, amount);
        vm.prank(who);
        v.depositNative{value: amount}(who);
    }

    // -- Native vault --

    function test_Constructor_RevertsOnZeroCap() public {
        lbAdapter = new LayerBankAdapter(address(lbPool), address(wrbtc));
        sovrynAdapter = new SovrynAdapter(address(mockIToken));
        ILendingAdapter[] memory adapters = new ILendingAdapter[](2);
        adapters[0] = ILendingAdapter(address(lbAdapter));
        adapters[1] = ILendingAdapter(address(sovrynAdapter));
        vm.expectRevert("tvlCap=0");
        new YieldVault(address(wrbtc), adapters, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_RATE, CAP_BPS, 0);
    }

    function test_MaxDeposit_TracksRemainingHeadroom() public {
        YieldVault v = _nativeVault(NATIVE_CAP);
        assertEq(v.maxDeposit(alice), NATIVE_CAP, "fresh vault: full cap available");

        _depositNative(v, alice, 0.4 ether);
        assertApproxEqAbs(v.maxDeposit(alice), 0.6 ether, 2, "headroom shrinks by deposit");
        assertApproxEqAbs(v.totalAssets(), 0.4 ether, 2, "totalAssets under cap");
    }

    function test_DepositNative_AtExactCapSucceeds() public {
        YieldVault v = _nativeVault(NATIVE_CAP);
        _depositNative(v, alice, NATIVE_CAP);
        assertApproxEqAbs(v.totalAssets(), NATIVE_CAP, 2, "filled exactly to cap");
        assertEq(v.maxDeposit(alice), 0, "no headroom left");
    }

    function test_DepositNative_OverCapReverts() public {
        YieldVault v = _nativeVault(NATIVE_CAP);
        _depositNative(v, alice, NATIVE_CAP);
        // one wei past the cap must revert
        vm.deal(alice, 1);
        vm.prank(alice);
        vm.expectRevert("deposit exceeds max");
        v.depositNative{value: 1}(alice);
    }

    function test_MaxMint_TracksCap() public {
        YieldVault v = _nativeVault(NATIVE_CAP);
        assertGt(v.maxMint(alice), 0, "mintable while under cap");
        _depositNative(v, alice, NATIVE_CAP);
        assertEq(v.maxMint(alice), 0, "nothing mintable at cap");
    }

    /// Rebalance moves funds between adapters without minting shares, it must
    /// never be blocked by the cap even when the vault sits exactly at it.
    function test_Rebalance_NotBlockedByCap() public {
        YieldVault v = _nativeVault(NATIVE_CAP);
        _depositNative(v, alice, NATIVE_CAP);
        v.initialDeposit();

        mockIToken.setSupplyInterestRate(8e16 * 100); // Sovryn now best
        vm.warp(block.timestamp + COOLDOWN + 1);
        v.rebalance(); // must not revert despite sitting at the cap

        assertApproxEqAbs(v.totalAssets(), NATIVE_CAP, 3, "rebalance preserves total under cap");
    }

    function test_Uncapped_MaxDepositIsSentinel() public {
        YieldVault v = _nativeVault(type(uint256).max);
        assertEq(v.maxDeposit(alice), type(uint256).max, "uncapped: maxDeposit sentinel");
        assertEq(v.maxMint(alice), type(uint256).max, "uncapped: maxMint sentinel");
        _depositNative(v, alice, 100 ether); // large deposit, no cap
        assertApproxEqAbs(v.totalAssets(), 100 ether, 2);
        assertEq(v.maxDeposit(alice), type(uint256).max, "still uncapped after deposit");
    }

    // -- ERC-20 vault --

    function test_ERC20_Constructor_RevertsOnZeroCap() public {
        LayerBankERC20Adapter lb = new LayerBankERC20Adapter(address(lbPoolErc), address(doc));
        SovrynERC20Adapter sov = new SovrynERC20Adapter(address(mockIDOC), address(doc));
        IERC20LendingAdapter[] memory adapters = new IERC20LendingAdapter[](2);
        adapters[0] = IERC20LendingAdapter(address(lb));
        adapters[1] = IERC20LendingAdapter(address(sov));
        vm.expectRevert("tvlCap=0");
        new ERC20YieldVault(
            address(doc), adapters, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_RATE, CAP_BPS, 0, "Test", "T", address(this)
        );
    }

    function test_ERC20_MaxDeposit_TracksCap() public {
        ERC20YieldVault v = _erc20Vault(ERC20_CAP);
        assertEq(v.maxDeposit(alice), ERC20_CAP, "fresh: full cap");

        doc.mint(alice, 400 ether);
        vm.startPrank(alice);
        doc.approve(address(v), 400 ether);
        v.deposit(400 ether, alice);
        vm.stopPrank();

        assertApproxEqAbs(v.maxDeposit(alice), 600 ether, 2, "headroom shrinks");
    }

    function test_ERC20_Deposit_OverCapReverts() public {
        ERC20YieldVault v = _erc20Vault(ERC20_CAP);
        doc.mint(alice, ERC20_CAP + 1);
        vm.startPrank(alice);
        doc.approve(address(v), ERC20_CAP + 1);
        v.deposit(ERC20_CAP, alice); // fills cap
        assertEq(v.maxDeposit(alice), 0, "at cap");
        vm.expectRevert(); // OZ ERC4626ExceededMaxDeposit
        v.deposit(1, alice);
        vm.stopPrank();
    }

    function test_ERC20_Uncapped_DefersToPauseLogic() public {
        ERC20YieldVault v = _erc20Vault(type(uint256).max);
        // uncapped: maxDeposit falls back to the OZ default (max) when unpaused
        assertEq(v.maxDeposit(alice), type(uint256).max, "uncapped + unpaused");
        v.pause();
        assertEq(v.maxDeposit(alice), 0, "paused overrides cap headroom");
        assertEq(v.maxMint(alice), 0, "paused: no mint");
    }

    function test_ERC20_Cap_AndPause_Combine() public {
        ERC20YieldVault v = _erc20Vault(ERC20_CAP);
        assertEq(v.maxDeposit(alice), ERC20_CAP, "capped + unpaused");
        v.pause();
        assertEq(v.maxDeposit(alice), 0, "paused beats cap headroom");
    }
}
