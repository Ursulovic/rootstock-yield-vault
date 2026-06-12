// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20YieldVault} from "../../src/ERC20YieldVault.sol";
import {LayerBankERC20Adapter} from "../../src/adapters/LayerBankERC20Adapter.sol";
import {SovrynERC20Adapter} from "../../src/adapters/SovrynERC20Adapter.sol";
import {IERC20LendingAdapter} from "../../src/interfaces/IERC20LendingAdapter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockLayerBankPool} from "../mocks/MockLayerBankPool.sol";
import {MockLoanToken} from "../mocks/MockLoanToken.sol";
import {VaultHandler} from "./Handler.sol";

/// @notice Stateful invariant suite. The fuzzer drives the handler through
///         thousands of random deposit/withdraw/rebalance/donate/accrue
///         sequences; these properties must hold after every single call.
contract VaultInvariantTest is Test {
    ERC20YieldVault vault;
    MockERC20 asset;
    MockLayerBankPool lbPool;
    MockLoanToken iPool;
    LayerBankERC20Adapter kAdapter;
    SovrynERC20Adapter iAdapter;
    VaultHandler handler;

    uint256 constant COOLDOWN = 3600;
    uint256 constant THRESHOLD = 5e14;
    uint256 constant REWARD_BPS = 100;
    uint256 constant MAX_RATE = 1e18; // 100% APR cap for the fuzz domain

    function setUp() public {
        asset = new MockERC20("Dollar on Chain", "DOC");
        lbPool = new MockLayerBankPool();
        lbPool.initReserve(address(asset));
        iPool = new MockLoanToken(address(asset));

        kAdapter = new LayerBankERC20Adapter(address(lbPool), address(asset));
        iAdapter = new SovrynERC20Adapter(address(iPool), address(asset));

        IERC20LendingAdapter[] memory adapters = new IERC20LendingAdapter[](2);
        adapters[0] = IERC20LendingAdapter(address(kAdapter));
        adapters[1] = IERC20LendingAdapter(address(iAdapter));

        vault = new ERC20YieldVault(
            address(asset), adapters, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_RATE,
            "DOC Yield Vault", "yvDOC", address(this)
        );

        // Seed initial sane rates: LayerBank 5%, Sovryn 3%
        lbPool.setSupplyRate1e18(address(asset), 5e16);
        iPool.setSupplyInterestRate(3e16);

        handler = new VaultHandler(vault, asset, lbPool, iPool, COOLDOWN);

        targetContract(address(handler));
    }

    // The priced totalAssets may never exceed what the vault actually holds
    // (idle plus deployed): the vesting buffer can only DISCOUNT the price.
    // Catches double counting, stranded funds, and vesting math errors.
    function invariant_pricedAssetsNeverExceedRaw() public view {
        uint256 idle = asset.balanceOf(address(vault));
        uint256 deployed = kAdapter.getBalance() + iAdapter.getBalance();
        assertLe(vault.totalAssets(), idle + deployed, "priced assets exceed raw holdings");
    }


    // 100%-deployed model: funds live in at most one adapter at a time. If a
    // rebalance ever left funds in both, this trips.
    function invariant_singleActiveAdapter() public view {
        uint256 k = kAdapter.getBalance();
        uint256 i = iAdapter.getBalance();
        assertTrue(k == 0 || i == 0, "funds must not be split across adapters");
    }

    // Adapter contracts are pass-through: they never hold loose underlying,
    // everything is either in the lending pool or forwarded to the vault.
    function invariant_noLooseTokensInAdapters() public view {
        assertEq(asset.balanceOf(address(kAdapter)), 0, "k adapter holds loose tokens");
        assertEq(asset.balanceOf(address(iAdapter)), 0, "i adapter holds loose tokens");
    }

    // Shares are always fully backed: the assets owed to all shareholders never
    // exceed what the vault holds (rounding favors the vault).
    function invariant_sharesFullyBacked() public view {
        uint256 owed = vault.convertToAssets(vault.totalSupply());
        assertLe(owed, vault.totalAssets() + 1, "shares must stay fully backed");
    }

    // No shareholder can ever be entitled to withdraw more than the vault holds.
    function invariant_noUserExceedsTotal() public view {
        for (uint256 i = 0; i < 3; i++) {
            address actor = handler.actors(i);
            assertLe(vault.maxWithdraw(actor), vault.totalAssets(), "user maxWithdraw exceeds total");
        }
    }
}
