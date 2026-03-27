// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {YieldVault} from "../src/YieldVault.sol";
import {TropykusAdapter} from "../src/adapters/TropykusAdapter.sol";
import {SovrynAdapter} from "../src/adapters/SovrynAdapter.sol";
import {ILendingAdapter} from "../src/interfaces/ILendingAdapter.sol";
import {IkToken} from "../src/interfaces/IkToken.sol";
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
//    # Pinned to a specific block (reproducible):
//    forge test --match-contract ForkRootstock \
//        --fork-url https://public-node.rsk.co \
//        --fork-block-number 7_200_000 -vvv
//
//    # Using the foundry.toml alias:
//    ROOTSTOCK_MAINNET_RPC=https://public-node.rsk.co \
//    forge test --match-contract ForkRootstock \
//        --fork-url rootstock_mainnet -vvv
//
//  NOTES ON ROOTSTOCK FORKING:
//
//  - The public node (https://public-node.rsk.co) supports
//    eth_getStorageAt and eth_call at arbitrary blocks, which is
//    what Foundry needs for forking. It works, but it is rate-limited.
//
//  - If you hit 429 errors, add --retries 5 --delay 3 or use
//    a paid RPC like Ankr (https://rpc.ankr.com/rootstock) or
//    GetBlock.
//
//  - Pinning to --fork-block-number is strongly recommended:
//    (a) tests become deterministic (rates, balances don't shift),
//    (b) Foundry caches all storage reads to ~/.foundry/cache so
//        subsequent runs don't hit the RPC at all.
//
//  - Rootstock has 30-second blocks. When simulating time passing,
//    you must advance both block.timestamp (vm.warp) AND
//    block.number (vm.roll) proportionally. The formulas below
//    use BLOCK_TIME = 30 to keep them in sync. Tropykus computes
//    interest per-block, so advancing block.number matters.
//
// ============================================================

contract ForkRootstockTest is Test {
    // ---- Mainnet addresses (verified on-chain) ----
    address constant WRBTC    = 0x542fDA317318eBF1d3DEAf76E0b632741A7e677d;
    address constant KRBTC    = 0x0AEAdb9d4C6A80462A47e87E76E487Fa8B9a37d7;
    address constant IRBTC    = 0xa9DcDC63eaBb8a2b6f39D7fF9429d88340044a7A;

    uint256 constant BLOCK_TIME = 30; // Rootstock: 30s per block

    // ---- Protocol interfaces pointed at real contracts ----
    IWRBTC  wrbtc  = IWRBTC(WRBTC);
    IkToken kRBTC  = IkToken(KRBTC);
    IiToken iRBTC  = IiToken(IRBTC);

    // ---- Project contracts (deployed fresh on fork) ----
    TropykusAdapter tropykusAdapter;
    SovrynAdapter   sovrynAdapter;
    YieldVault      vault;

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");

    uint256 constant COOLDOWN     = 3600;  // 1 hour
    uint256 constant THRESHOLD    = 5e14;  // 0.05% annual rate
    uint256 constant REWARD_BPS   = 100;   // 1% of yield

    // ================================================================
    //  setUp -- deploys our contracts on top of the forked state
    // ================================================================

    function setUp() public {
        // Deploy adapters pointing at real Tropykus / Sovryn
        tropykusAdapter = new TropykusAdapter(KRBTC);
        sovrynAdapter   = new SovrynAdapter(IRBTC);

        ILendingAdapter[] memory adapters = new ILendingAdapter[](2);
        adapters[0] = ILendingAdapter(address(tropykusAdapter));
        adapters[1] = ILendingAdapter(address(sovrynAdapter));

        vault = new YieldVault(
            WRBTC,
            adapters,
            COOLDOWN,
            THRESHOLD,
            REWARD_BPS
        );

        // Give test users some rBTC
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    // ================================================================
    //  1. Tropykus kRBTC -- direct interaction with real contract
    // ================================================================

    function test_fork_tropykus_supplyRatePerBlock() public view {
        // supplyRatePerBlock() should return a non-zero per-block rate
        uint256 ratePerBlock = kRBTC.supplyRatePerBlock();
        console.log("Tropykus supplyRatePerBlock:", ratePerBlock);

        // Annualize: rate * blocks_per_year (1,051,200 for 30s blocks)
        uint256 annualRate = ratePerBlock * 1_051_200;
        console.log("Tropykus annualized rate (1e18=100%):", annualRate);

        // Sanity: rate should be between 0% and 50% APR
        assertLt(annualRate, 5e17, "rate suspiciously high (>50%)");
    }

    function test_fork_tropykus_deposit_and_balance() public {
        // Give this test contract rBTC to deposit directly
        vm.deal(address(this), 1 ether);

        // Deposit 0.01 rBTC into kRBTC via mint() payable
        uint256 depositAmount = 0.01 ether;
        uint256 kBalBefore = kRBTC.balanceOf(address(this));

        kRBTC.mint{value: depositAmount}();

        uint256 kBalAfter = kRBTC.balanceOf(address(this));
        assertGt(kBalAfter, kBalBefore, "should receive kRBTC tokens");

        // Check underlying value via exchangeRateStored
        uint256 exchangeRate = kRBTC.exchangeRateStored();
        uint256 underlyingValue = kBalAfter * exchangeRate / 1e18;
        console.log("kRBTC tokens received:", kBalAfter);
        console.log("exchangeRateStored:", exchangeRate);
        console.log("underlying value:", underlyingValue);

        // Underlying value should be close to what we deposited
        assertApproxEqRel(
            underlyingValue,
            depositAmount,
            0.01e18, // 1% tolerance for rounding
            "underlying value should match deposit"
        );
    }

    // ================================================================
    //  2. Sovryn iRBTC -- direct interaction with real contract
    // ================================================================

    function test_fork_sovryn_supplyInterestRate() public view {
        // supplyInterestRate() returns annualized rate (1e18 = 100%)
        uint256 rate = iRBTC.supplyInterestRate();
        console.log("Sovryn supplyInterestRate (1e18=100%):", rate);

        // Sanity: between 0% and 50%
        assertLt(rate, 5e17, "rate suspiciously high (>50%)");
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

    function test_fork_tropykusAdapter_deposit_getBalance_getRate() public {
        // Fund the vault, then deposit through adapter
        vm.deal(address(vault), 0.01 ether);

        vm.prank(address(vault));
        tropykusAdapter.deposit{value: 0.01 ether}();

        uint256 balance = tropykusAdapter.getBalance();
        console.log("TropykusAdapter.getBalance():", balance);
        assertApproxEqRel(balance, 0.01 ether, 0.01e18, "adapter balance");

        uint256 rate = tropykusAdapter.getRate();
        console.log("TropykusAdapter.getRate():", rate);
        assertGt(rate, 0, "rate should be > 0");
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

        // Deploy to whichever protocol has the higher rate
        vault.initialDeposit();

        address active = address(vault.activeAdapter());
        assertTrue(
            active == address(tropykusAdapter) || active == address(sovrynAdapter),
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
        wrbtc.deposit{value: 1 ether}();           // wrap rBTC -> WRBTC
        wrbtc.approve(address(vault), 1 ether);     // approve vault
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

        // After warping, the on-chain rate queries still return the
        // same snapshot (no real transactions accrue interest on a
        // fork). The exchangeRateStored / tokenPrice won't change
        // unless someone calls accrueInterest() on the real contract.
        //
        // For Tropykus (Compound-style), we can poke the contract
        // to force accrual:
        //   - Calling any state-changing function triggers accrueInterest()
        //   - Or we can call it directly if exposed.
        //
        // For demonstration, let's read the stale and note it:
        uint256 totalAfterWarp = vault.totalAssets();
        console.log("totalAssets after 1-day warp (stale):", totalAfterWarp);

        // The values should be the same (stale exchange rate):
        // This is expected behavior on a fork. Real yield accrual
        // requires either (a) someone to transact with the pool, or
        // (b) using vm.store to manually bump the exchange rate.
        //
        // To see yield, deposit a tiny amount to trigger accrual:
        vm.deal(address(this), 0.001 ether);
        kRBTC.mint{value: 0.001 ether}();  // pokes Tropykus accrueInterest

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
        uint256 tropRate = tropykusAdapter.getRate();
        uint256 sovRate  = sovrynAdapter.getRate();
        console.log("Tropykus rate:", tropRate);
        console.log("Sovryn rate:", sovRate);

        // For rebalance to succeed, the non-active adapter must beat
        // the active one by more than THRESHOLD. On a real fork, the
        // rates might be close. If so, this test will revert with
        // "rate improvement too small" -- which is correct behavior.
        //
        // To force a rebalance in testing, we can skip this test when
        // rates are too close, or we can accept the revert.

        // Advance past cooldown
        vm.warp(block.timestamp + COOLDOWN + 1);
        vm.roll(block.number + (COOLDOWN + 1) / BLOCK_TIME);

        // Determine which adapter is NOT active
        bool tropykusActive = activeBefore == address(tropykusAdapter);
        uint256 activeRate   = tropykusActive ? tropRate : sovRate;
        uint256 inactiveRate = tropykusActive ? sovRate  : tropRate;

        // Only attempt rebalance if the inactive rate actually beats threshold
        if (inactiveRate > activeRate + THRESHOLD) {
            address rebalancer = makeAddr("rebalancer");
            vm.prank(rebalancer);
            vault.rebalance();

            address activeAfter = address(vault.activeAdapter());
            assertTrue(activeAfter != activeBefore, "adapter should have changed");
            console.log("Rebalanced from", activeBefore, "to", activeAfter);
        } else {
            console.log("Skipping rebalance: rate difference below threshold");
            console.log("Active rate:", activeRate, "Inactive rate:", inactiveRate);
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
        uint256 tropPerBlock = kRBTC.supplyRatePerBlock();
        uint256 tropAnnual   = tropPerBlock * 1_051_200;
        uint256 sovAnnual    = iRBTC.supplyInterestRate();

        console.log("--- Rate Comparison ---");
        console.log("Tropykus per-block:", tropPerBlock);
        console.log("Tropykus annual (1e18=100%):", tropAnnual);
        console.log("Sovryn annual (1e18=100%):", sovAnnual);

        if (tropAnnual > sovAnnual) {
            console.log("Winner: Tropykus by", tropAnnual - sovAnnual);
        } else {
            console.log("Winner: Sovryn by", sovAnnual - tropAnnual);
        }

        // Both should return something reasonable
        assertGt(tropPerBlock, 0, "Tropykus rate should be > 0");
        // Sovryn rate can legitimately be 0 if no borrowing activity
    }

    // Need receive() so this contract can accept rBTC from kRBTC.redeem()
    // (Tropykus uses .transfer() with 2300 gas limit)
    receive() external payable {}
}
