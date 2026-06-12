// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {YieldVault} from "../src/YieldVault.sol";
import {LayerBankAdapter} from "../src/adapters/LayerBankAdapter.sol";
import {SovrynAdapter} from "../src/adapters/SovrynAdapter.sol";
import {ILendingAdapter} from "../src/interfaces/ILendingAdapter.sol";
import {ILayerBankPool} from "../src/interfaces/ILayerBankPool.sol";
import {IiToken} from "../src/interfaces/IiToken.sol";
import {IWRBTC} from "../src/interfaces/IWRBTC.sol";

// ============================================================
//  Rootstock Mainnet Fork Tests
// ============================================================
//
//  HOW TO RUN:
//
//    # Basic (uses latest block):
//    forge test --match-contract ForkRootstock \
//        --fork-url https://public-node.rsk.co -vvv
//
//    # Pinned to a specific block (reproducible, cached):
//    forge test --match-contract ForkRootstock \
//        --fork-url https://public-node.rsk.co \
//        --fork-block-number 8_935_125 -vvv
//
//  NOTES ON ROOTSTOCK FORKING:
//
//  - The public node (https://public-node.rsk.co) supports
//    eth_getStorageAt and eth_call at arbitrary blocks, which is
//    what Foundry needs for forking. It works, but it is rate-limited.
//    Pinning to --fork-block-number caches all storage reads in
//    ~/.foundry/cache so subsequent runs don't hit the RPC at all.
//
//  - Rootstock has 30-second blocks. When simulating time passing,
//    advance both block.timestamp (vm.warp) AND block.number
//    (vm.roll) proportionally.
//
//  - LayerBank on Rootstock is an Aave V3 fork (verified on-chain:
//    PoolInstance implementation behind an EIP-1967 proxy). Its
//    WRBTC market is ERC-20 based, so the adapter wraps/unwraps.
//
// ============================================================

contract ForkRootstockTest is Test {
    // ---- Mainnet addresses (verified on-chain) ----
    address constant WRBTC   = 0x542fDA317318eBF1d3DEAf76E0b632741A7e677d;
    address constant LB_POOL = 0x526D06c65777eA6D56d7a1Dd47cD79230dDf72E9; // LayerBank Pool proxy
    address constant IRBTC   = 0xa9DcDC63eaBb8a2b6f39D7fF9429d88340044a7A;

    uint256 constant BLOCK_TIME = 30; // Rootstock: 30s per block

    // ---- Protocol interfaces pointed at real contracts ----
    IWRBTC wrbtc = IWRBTC(WRBTC);
    ILayerBankPool lbPool = ILayerBankPool(LB_POOL);
    IiToken iRBTC = IiToken(IRBTC);

    // ---- Project contracts (deployed fresh on fork) ----
    LayerBankAdapter layerBankAdapter;
    SovrynAdapter sovrynAdapter;
    YieldVault vault;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant COOLDOWN = 3600; // 1 hour
    uint256 constant THRESHOLD = 5e14; // 0.05% annual rate
    uint256 constant REWARD_BPS = 100; // 1% of yield
    uint256 constant MAX_SANE_RATE = 0.5e18; // 50% APR — generous vs observed sub-1% rBTC rates

    function setUp() public {
        // Skip cleanly when not running against a Rootstock fork (plain `forge test`)
        vm.skip(WRBTC.code.length == 0);
        // Deploy adapters pointing at real LayerBank / Sovryn
        layerBankAdapter = new LayerBankAdapter(LB_POOL, WRBTC);
        sovrynAdapter = new SovrynAdapter(IRBTC);

        ILendingAdapter[] memory adapters = new ILendingAdapter[](2);
        adapters[0] = ILendingAdapter(address(layerBankAdapter));
        adapters[1] = ILendingAdapter(address(sovrynAdapter));

        vault = new YieldVault(
            WRBTC,
            adapters,
            COOLDOWN,
            THRESHOLD,
            REWARD_BPS,
            MAX_SANE_RATE
        );

        // Give test users some rBTC
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    // ================================================================
    //  1. LayerBank pool -- direct interaction with real contract
    // ================================================================

    function test_fork_layerbank_liquidityRate() public view {
        ILayerBankPool.ReserveDataLegacy memory data = lbPool.getReserveData(WRBTC);
        console.log("LayerBank WRBTC currentLiquidityRate (ray):", data.currentLiquidityRate);
        console.log("LayerBank WRBTC rate (1e18=100%):", uint256(data.currentLiquidityRate) / 1e9);
        console.log("LayerBank WRBTC aToken:", data.aTokenAddress);

        assertTrue(data.aTokenAddress != address(0), "WRBTC market should be listed");
        assertLt(uint256(data.currentLiquidityRate) / 1e9, MAX_SANE_RATE, "rate suspiciously high");
    }

    function test_fork_layerbank_supply_and_balance() public {
        // Wrap rBTC, supply directly to the real pool
        vm.deal(address(this), 1 ether);
        uint256 depositAmount = 0.01 ether;
        wrbtc.deposit{value: depositAmount}();
        IERC20(WRBTC).approve(LB_POOL, depositAmount);

        address aToken = lbPool.getReserveData(WRBTC).aTokenAddress;
        uint256 aBalBefore = IERC20(aToken).balanceOf(address(this));

        lbPool.supply(WRBTC, depositAmount, address(this), 0);

        uint256 aBalAfter = IERC20(aToken).balanceOf(address(this));
        console.log("aWRBTC received:", aBalAfter - aBalBefore);

        // aTokens are rebasing 1:1 with the underlying
        assertApproxEqRel(
            aBalAfter - aBalBefore,
            depositAmount,
            0.01e18,
            "aToken balance should match deposit"
        );
    }

    // ================================================================
    //  2. Sovryn iRBTC -- direct interaction with real contract
    // ================================================================

    function test_fork_sovryn_supplyInterestRate() public view {
        // Sovryn (bZx) reports the annual rate PERCENT-scaled: 1e18 = 1%
        // (raw ~0.9e18 in June 2026 = 0.9% APR, verified against real
        // tokenPrice growth). The adapter normalizes to 1e18 = 100%.
        uint256 raw = iRBTC.supplyInterestRate();
        uint256 rate = sovrynAdapter.getRate();
        console.log("Sovryn raw supplyInterestRate (1e18=1%):", raw);
        console.log("Sovryn normalized rate (1e18=100%):", rate);

        assertEq(rate, raw / 100, "adapter must normalize percent scale");
        assertGt(rate, 0, "rate should be > 0");
        assertLt(rate, MAX_SANE_RATE, "rate suspiciously high (>50%)");
    }

    function test_fork_sovryn_deposit_and_balance() public {
        vm.deal(address(this), 1 ether);

        uint256 depositAmount = 0.01 ether;
        uint256 iBalBefore = iRBTC.balanceOf(address(this));

        // mintWithBTC: deposit native rBTC, receive iTokens
        iRBTC.mintWithBTC{value: depositAmount}(address(this), false);

        uint256 iBalAfter = iRBTC.balanceOf(address(this));
        assertGt(iBalAfter, iBalBefore, "should receive iRBTC tokens");

        // Check underlying value via assetBalanceOf
        uint256 assetBal = iRBTC.assetBalanceOf(address(this));
        console.log("iRBTC tokens received:", iBalAfter);
        console.log("tokenPrice:", iRBTC.tokenPrice());
        console.log("assetBalanceOf:", assetBal);

        assertApproxEqRel(
            assetBal,
            depositAmount,
            0.01e18,
            "asset balance should match deposit"
        );
    }

    // ================================================================
    //  3. Adapter tests on real protocols
    // ================================================================

    function test_fork_layerBankAdapter_deposit_getBalance_getRate() public {
        // Fund the vault, then deposit through adapter
        vm.deal(address(vault), 0.01 ether);

        vm.prank(address(vault));
        layerBankAdapter.deposit{value: 0.01 ether}();

        uint256 balance = layerBankAdapter.getBalance();
        console.log("LayerBankAdapter.getBalance():", balance);
        assertApproxEqRel(balance, 0.01 ether, 0.01e18, "adapter balance");

        uint256 rate = layerBankAdapter.getRate();
        console.log("LayerBankAdapter.getRate():", rate);
        assertGt(rate, 0, "rate should be > 0");
    }

    function test_fork_layerBankAdapter_withdraw() public {
        vm.deal(address(vault), 0.01 ether);

        vm.prank(address(vault));
        layerBankAdapter.deposit{value: 0.01 ether}();

        uint256 vaultBalBefore = address(vault).balance;
        vm.prank(address(vault));
        layerBankAdapter.withdraw(0.005 ether);

        // Vault receives native rBTC through its receive() filter
        assertGe(address(vault).balance - vaultBalBefore, 0.005 ether, "vault should receive rBTC");
    }

    function test_fork_sovrynAdapter_deposit_getBalance_getRate() public {
        vm.deal(address(vault), 0.01 ether);

        vm.prank(address(vault));
        sovrynAdapter.deposit{value: 0.01 ether}();

        uint256 balance = sovrynAdapter.getBalance();
        console.log("SovrynAdapter.getBalance():", balance);
        assertApproxEqRel(balance, 0.01 ether, 0.01e18, "adapter balance");

        uint256 rate = sovrynAdapter.getRate();
        console.log("SovrynAdapter.getRate():", rate);
        assertGt(rate, 0, "rate should be > 0");
    }

    // ================================================================
    //  4. Full vault lifecycle on fork
    // ================================================================

    function test_fork_vault_depositNative_and_totalAssets() public {
        vm.prank(alice);
        uint256 shares = vault.depositNative{value: 1 ether}(alice);

        assertGt(shares, 0, "should receive shares");
        assertEq(vault.balanceOf(alice), shares);

        // Funds are idle (no active adapter yet)
        uint256 total = vault.totalAssets();
        console.log("totalAssets after deposit (idle):", total);
        assertApproxEqRel(total, 1 ether, 0.001e18, "total should be ~1 ether");
    }

    function test_fork_vault_initialDeposit_selectsBest() public {
        // Deposit some rBTC
        vm.prank(alice);
        vault.depositNative{value: 1 ether}(alice);

        // Log both rates so we know which wins
        (string[] memory names, uint256[] memory rates) = vault.getAllRates();
        for (uint256 i = 0; i < names.length; i++) {
            console.log(names[i], "rate:", rates[i]);
        }

        // Deploy to whichever protocol has the higher (sane) rate
        vault.initialDeposit();

        address active = address(vault.activeAdapter());
        assertTrue(
            active == address(layerBankAdapter) || active == address(sovrynAdapter),
            "active adapter should be one of the two"
        );
        console.log("Active adapter:", active);

        // totalAssets should still be ~1 ether (now deployed)
        uint256 total = vault.totalAssets();
        console.log("totalAssets after initialDeposit:", total);
        assertApproxEqRel(total, 1 ether, 0.02e18, "total ~1 ether after deploy");
    }

    function test_fork_vault_deposit_wrbtc() public {
        // Deposit using WRBTC (the ERC-4626 standard path)
        vm.startPrank(alice);
        wrbtc.deposit{value: 1 ether}(); // wrap rBTC -> WRBTC
        wrbtc.approve(address(vault), 1 ether); // approve vault
        uint256 shares = vault.deposit(1 ether, alice);
        vm.stopPrank();

        assertGt(shares, 0, "should receive shares");
        console.log("Shares from WRBTC deposit:", shares);
    }

    function test_fork_vault_withdraw_after_deploy() public {
        // Deposit and deploy
        vm.prank(alice);
        vault.depositNative{value: 1 ether}(alice);
        vault.initialDeposit();

        // Withdraw half -- should pull from whichever adapter is active
        uint256 balBefore = alice.balance;
        vm.prank(alice);
        vault.withdrawNative(0.5 ether, alice, alice);

        assertGt(alice.balance, balBefore, "should receive rBTC");
        console.log("rBTC received:", alice.balance - balBefore);
    }

    // ================================================================
    //  5. Simulating time passing on a fork (vm.warp + vm.roll)
    // ================================================================

    function test_fork_vault_yield_accrual_over_time() public {
        // Deposit and deploy
        vm.prank(alice);
        vault.depositNative{value: 1 ether}(alice);
        vault.initialDeposit();

        uint256 totalBefore = vault.totalAssets();
        console.log("totalAssets at T=0:", totalBefore);

        // Simulate 1 day passing.
        // Rootstock: 30s blocks => 2880 blocks/day
        uint256 blocksPerDay = 86400 / BLOCK_TIME; // 2880
        vm.warp(block.timestamp + 86400);
        vm.roll(block.number + blocksPerDay);

        // On a fork, rates/indexes are snapshots: nothing accrues until
        // someone transacts with the protocol. Poke the active protocol
        // with a dust interaction to trigger accrual.
        uint256 totalAfterWarp = vault.totalAssets();
        console.log("totalAssets after 1-day warp (stale):", totalAfterWarp);

        vm.deal(address(this), 0.002 ether);
        if (address(vault.activeAdapter()) == address(layerBankAdapter)) {
            // LayerBank (Aave-style): any supply triggers index update
            wrbtc.deposit{value: 0.001 ether}();
            IERC20(WRBTC).approve(LB_POOL, 0.001 ether);
            lbPool.supply(WRBTC, 0.001 ether, address(this), 0);
        } else {
            // Sovryn: minting pokes the interest settlement
            iRBTC.mintWithBTC{value: 0.001 ether}(address(this), false);
        }

        uint256 totalAfterPoke = vault.totalAssets();
        console.log("totalAssets after poke:", totalAfterPoke);

        // After poking, totalAssets should be >= what it was before.
        // The difference may be tiny for 1 day on 1 rBTC.
        assertGe(totalAfterPoke, totalBefore, "assets should not decrease");
    }

    // ================================================================
    //  6. Rebalance on fork
    // ================================================================

    function test_fork_vault_rebalance() public {
        // Deposit and deploy to whichever is currently best
        vm.prank(alice);
        vault.depositNative{value: 1 ether}(alice);
        vault.initialDeposit();

        address activeBefore = address(vault.activeAdapter());

        // Read rates
        uint256 lbRate = layerBankAdapter.getRate();
        uint256 sovRate = sovrynAdapter.getRate();
        console.log("LayerBank rate:", lbRate);
        console.log("Sovryn rate:", sovRate);

        // Advance past cooldown
        vm.warp(block.timestamp + COOLDOWN + 1);
        vm.roll(block.number + (COOLDOWN + 1) / BLOCK_TIME);

        // Determine which adapter is NOT active
        bool layerBankActive = activeBefore == address(layerBankAdapter);
        uint256 activeRate = layerBankActive ? lbRate : sovRate;
        uint256 inactiveRate = layerBankActive ? sovRate : lbRate;

        // Only attempt rebalance if the inactive rate actually beats threshold
        // (and is sane) — on a real fork rates are whatever the market says
        if (inactiveRate > activeRate + THRESHOLD && inactiveRate <= MAX_SANE_RATE) {
            address rebalancer = makeAddr("rebalancer");
            vm.prank(rebalancer);
            vault.rebalance();

            address activeAfter = address(vault.activeAdapter());
            assertTrue(activeAfter != activeBefore, "adapter should have changed");
            console.log("Rebalanced from", activeBefore, "to", activeAfter);
        } else {
            console.log("Skipping rebalance: no eligible rate improvement");
            console.log("Active rate:", activeRate);
            console.log("Inactive rate:", inactiveRate);
        }
    }

    // ================================================================
    //  7. Multiple depositors and share accounting on fork
    // ================================================================

    function test_fork_vault_multiple_depositors() public {
        vm.prank(alice);
        uint256 aliceShares = vault.depositNative{value: 1 ether}(alice);
        vault.initialDeposit();

        vm.prank(bob);
        uint256 bobShares = vault.depositNative{value: 2 ether}(bob);

        console.log("Alice shares:", aliceShares);
        console.log("Bob shares:", bobShares);

        // Bob deposited 2x, should have ~2x shares
        assertApproxEqRel(bobShares, aliceShares * 2, 0.02e18, "proportional shares");

        uint256 total = vault.totalAssets();
        console.log("totalAssets:", total);
        assertApproxEqRel(total, 3 ether, 0.02e18, "total ~3 ether");
    }

    // ================================================================
    //  8. Rate comparison snapshot (useful for debugging)
    // ================================================================

    function test_fork_rate_comparison() public view {
        uint256 lbAnnual = layerBankAdapter.getRate();
        uint256 sovAnnual = sovrynAdapter.getRate();

        console.log("--- Rate Comparison ---");
        console.log("LayerBank annual (1e18=100%):", lbAnnual);
        console.log("Sovryn annual (1e18=100%):", sovAnnual);

        if (lbAnnual > sovAnnual) {
            console.log("Winner: LayerBank by", lbAnnual - sovAnnual);
        } else {
            console.log("Winner: Sovryn by", sovAnnual - lbAnnual);
        }

        // Rates can legitimately be near zero with no borrowing activity;
        // just make sure the calls work against the real contracts
        assertLt(lbAnnual, MAX_SANE_RATE, "LayerBank rate within sanity bound");
    }

    // Needed so this test contract can receive rBTC when unwrapping WRBTC
    // (real WRBTC pays out via transfer() with the 2300-gas stipend)
    receive() external payable {}
}
