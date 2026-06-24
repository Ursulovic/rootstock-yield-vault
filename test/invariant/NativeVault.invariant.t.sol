// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {YieldVault} from "../../src/YieldVault.sol";
import {LayerBankAdapter} from "../../src/adapters/LayerBankAdapter.sol";
import {SovrynAdapter} from "../../src/adapters/SovrynAdapter.sol";
import {ILendingAdapter} from "../../src/interfaces/ILendingAdapter.sol";
import {MockWRBTC} from "../mocks/MockWRBTC.sol";
import {MockLayerBankPool} from "../mocks/MockLayerBankPool.sol";
import {MockiToken} from "../mocks/MockiToken.sol";
import {NativeVaultHandler} from "./NativeHandler.sol";

/// @notice Stateful invariant suite for the native rBTC vault, the trustless
///         flagship. Covers the native-only surface the ERC20 suite cannot:
///         wrap/unwrap on every hop, the gated receive(), native balance-delta
///         accounting in rebalance, and depositNative/withdrawNative.
contract NativeVaultInvariantTest is Test {
    YieldVault vault;
    MockWRBTC wrbtc;
    MockLayerBankPool lbPool;
    MockiToken iPool;
    LayerBankAdapter lbAdapter;
    SovrynAdapter sovrynAdapter;
    NativeVaultHandler handler;

    uint256 constant COOLDOWN = 3600;
    uint256 constant THRESHOLD = 5e14;
    uint256 constant REWARD_BPS = 100;
    uint256 constant MAX_RATE = 1e18; // 100% APR cap for the fuzz domain
    uint256 constant CAP_BPS = 6000; // 60% per-adapter cap
    // Finite cap so the handler TVL-cap assertion actually binds under fuzzing
    uint256 constant TVL_CAP = 1e25;

    function setUp() public {
        wrbtc = new MockWRBTC();
        lbPool = new MockLayerBankPool();
        lbPool.initReserve(address(wrbtc));
        iPool = new MockiToken();

        lbAdapter = new LayerBankAdapter(address(lbPool), address(wrbtc));
        sovrynAdapter = new SovrynAdapter(address(iPool));

        ILendingAdapter[] memory adapters = new ILendingAdapter[](2);
        adapters[0] = ILendingAdapter(address(lbAdapter));
        adapters[1] = ILendingAdapter(address(sovrynAdapter));

        vault = new YieldVault(address(wrbtc), adapters, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_RATE, CAP_BPS, TVL_CAP);

        lbPool.setSupplyRate1e18(address(wrbtc), 5e16);
        iPool.setSupplyInterestRate(3e16 * 100); // Sovryn mock is percent-scaled

        handler = new NativeVaultHandler(vault, wrbtc, lbPool, iPool, COOLDOWN);
        targetContract(address(handler));
    }

    // The priced totalAssets may never exceed what the vault actually holds
    // (idle plus deployed): the vesting buffer can only DISCOUNT the price.
    // Catches double counting, stranded funds, and vesting math errors.
    function invariant_pricedAssetsNeverExceedRaw() public view {
        uint256 idle = wrbtc.balanceOf(address(vault));
        uint256 deployed = lbAdapter.getBalance() + sovrynAdapter.getBalance();
        assertLe(vault.totalAssets(), idle + deployed, "priced assets exceed raw holdings");
    }


    // The vault must never sit on loose NATIVE rBTC: everything it holds is
    // either idle WRBTC or deployed. Native arrives only transiently inside
    // rebalance/withdraw flows and must be fully consumed within the call.
    function invariant_noLooseNativeInVault() public view {
        assertEq(address(vault).balance, 0, "vault holds loose native rBTC");
    }

    // Adapters are pass-through: no WRBTC and no native rBTC may stick to them.
    function invariant_noLooseFundsInAdapters() public view {
        assertEq(wrbtc.balanceOf(address(lbAdapter)), 0, "lb adapter holds loose WRBTC");
        assertEq(address(lbAdapter).balance, 0, "lb adapter holds loose rBTC");
        assertEq(wrbtc.balanceOf(address(sovrynAdapter)), 0, "sovryn adapter holds loose WRBTC");
        assertEq(address(sovrynAdapter).balance, 0, "sovryn adapter holds loose rBTC");
    }


    // Shares are always fully backed (rounding favors the vault).
    function invariant_sharesFullyBacked() public view {
        uint256 owed = vault.convertToAssets(vault.totalSupply());
        assertLe(owed, vault.totalAssets() + 1, "shares must stay fully backed");
    }

    // No shareholder can ever be entitled to more than the vault holds.
    function invariant_noUserExceedsTotal() public view {
        for (uint256 i = 0; i < 3; i++) {
            address actor = handler.actors(i);
            assertLe(vault.maxWithdraw(actor), vault.totalAssets(), "user maxWithdraw exceeds total");
        }
    }
}
