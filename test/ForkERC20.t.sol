// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20YieldVault} from "../src/ERC20YieldVault.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {TropykusERC20Adapter} from "../src/adapters/TropykusERC20Adapter.sol";
import {SovrynERC20Adapter} from "../src/adapters/SovrynERC20Adapter.sol";
import {IERC20LendingAdapter} from "../src/interfaces/IERC20LendingAdapter.sol";
import {IkERC20Token} from "../src/interfaces/IkERC20Token.sol";
import {IiERC20Token} from "../src/interfaces/IiERC20Token.sol";

// ============================================================
//  Rootstock Mainnet Fork Tests — ERC-20 Vaults (DOC)
// ============================================================
//
//  HOW TO RUN:
//
//    forge test --match-contract ForkERC20 \
//        --fork-url https://public-node.rsk.co \
//        --fork-block-number 7_200_000 -vvv
//
//  These tests verify the ERC-20 adapters and vault against
//  real Tropykus kDOC and Sovryn iDOC contracts on Rootstock
//  mainnet. DOC is a BTC-collateralized USD stablecoin.
//
// ============================================================

contract ForkERC20Test is Test {
    // ---- Mainnet addresses (verified on Blockscout) ----
    address constant DOC  = 0xe700691dA7b9851F2F35f8b8182c69c53CcaD9Db;
    address constant KDOC = 0x544Eb90e766B405134b3B3F62b6b4C23Fcd5fDa2;
    address constant IDOC = 0xd8D25f03EBbA94E15Df2eD4d6D38276B595593c1; // iSUSD on-chain name

    uint256 constant COOLDOWN  = 3600;
    uint256 constant THRESHOLD = 5e14;
    uint256 constant REWARD_BPS = 100;
    uint256 constant BLOCK_TIME = 30;

    ERC20YieldVault public vault;
    TropykusERC20Adapter public tropykusAdapter;
    SovrynERC20Adapter public sovrynAdapter;

    address public alice = makeAddr("alice");
    address public bob   = makeAddr("bob");

    function setUp() public {
        tropykusAdapter = new TropykusERC20Adapter(KDOC, DOC);
        sovrynAdapter   = new SovrynERC20Adapter(IDOC, DOC);

        IERC20LendingAdapter[] memory adapters = new IERC20LendingAdapter[](2);
        adapters[0] = IERC20LendingAdapter(address(tropykusAdapter));
        adapters[1] = IERC20LendingAdapter(address(sovrynAdapter));

        vault = new ERC20YieldVault(
            DOC, adapters, COOLDOWN, THRESHOLD, REWARD_BPS,
            "DOC Yield Vault", "yvDOC"
        );

        // Fund test users with DOC (use deal to set ERC-20 balance)
        deal(DOC, alice, 1000 ether);
        deal(DOC, bob,   1000 ether);
    }

    // ---- Raw protocol queries ----

    function test_fork_kDOC_supplyRatePerBlock() public view {
        uint256 rate = IkERC20Token(KDOC).supplyRatePerBlock();
        console.log("kDOC supplyRatePerBlock:", rate);

        uint256 annualized = rate * 1_051_200;
        console.log("kDOC annualized rate:", annualized);
        console.log("kDOC APR %:", annualized * 100 / 1e18);

        assertGt(rate, 0, "kDOC rate should be > 0");
        assertLt(annualized, 50e16, "kDOC APR should be < 50%");
    }

    function test_fork_iDOC_supplyInterestRate() public view {
        uint256 rate = IiERC20Token(IDOC).supplyInterestRate();
        console.log("iDOC supplyInterestRate:", rate);
        console.log("iDOC APR %:", rate * 100 / 1e18);

        assertGt(rate, 0, "iDOC rate should be > 0");
        assertLt(rate, 50e16, "iDOC APR should be < 50%");
    }

    function test_fork_rate_comparison() public view {
        uint256 tropykusRate = IkERC20Token(KDOC).supplyRatePerBlock() * 1_051_200;
        uint256 sovrynRate   = IiERC20Token(IDOC).supplyInterestRate();

        console.log("Tropykus kDOC rate:", tropykusRate);
        console.log("Sovryn   iDOC rate:", sovrynRate);

        if (tropykusRate > sovrynRate) {
            console.log("Winner: Tropykus");
        } else {
            console.log("Winner: Sovryn");
        }
    }

    // ---- Adapter-level tests ----

    function test_fork_tropykusERC20Adapter_deposit_getBalance_getRate() public {
        uint256 depositAmount = 10 ether; // 10 DOC

        // Transfer DOC to vault so adapter can pull
        vm.prank(alice);
        IERC20(DOC).transfer(address(vault), depositAmount);

        // Deposit through adapter (must come from vault)
        vm.prank(address(vault));
        tropykusAdapter.deposit(depositAmount);

        uint256 balance = tropykusAdapter.getBalance();
        uint256 rate = tropykusAdapter.getRate();

        console.log("TropykusERC20Adapter balance after deposit:", balance);
        console.log("TropykusERC20Adapter rate:", rate);

        assertApproxEqRel(balance, depositAmount, 0.01e18, "balance should be ~10 DOC");
        assertGt(rate, 0, "rate should be > 0");
    }

    function test_fork_sovrynERC20Adapter_deposit_getBalance_getRate() public {
        uint256 depositAmount = 10 ether;

        vm.prank(alice);
        IERC20(DOC).transfer(address(vault), depositAmount);

        vm.prank(address(vault));
        sovrynAdapter.deposit(depositAmount);

        uint256 balance = sovrynAdapter.getBalance();
        uint256 rate = sovrynAdapter.getRate();

        console.log("SovrynERC20Adapter balance after deposit:", balance);
        console.log("SovrynERC20Adapter rate:", rate);

        assertApproxEqRel(balance, depositAmount, 0.01e18, "balance should be ~10 DOC");
        assertGt(rate, 0, "rate should be > 0");
    }

    function test_fork_tropykusERC20Adapter_withdraw() public {
        uint256 depositAmount = 10 ether;

        vm.prank(alice);
        IERC20(DOC).transfer(address(vault), depositAmount);

        vm.prank(address(vault));
        tropykusAdapter.deposit(depositAmount);

        // Withdraw half
        uint256 vaultBalBefore = IERC20(DOC).balanceOf(address(vault));
        vm.prank(address(vault));
        uint256 received = tropykusAdapter.withdraw(5 ether);

        uint256 vaultBalAfter = IERC20(DOC).balanceOf(address(vault));
        console.log("Withdrew from Tropykus:", received);

        assertApproxEqRel(received, 5 ether, 0.01e18, "should receive ~5 DOC");
        assertEq(vaultBalAfter - vaultBalBefore, received, "vault balance should increase by received");
    }

    function test_fork_sovrynERC20Adapter_withdraw() public {
        uint256 depositAmount = 10 ether;

        vm.prank(alice);
        IERC20(DOC).transfer(address(vault), depositAmount);

        vm.prank(address(vault));
        sovrynAdapter.deposit(depositAmount);

        // Withdraw half
        uint256 vaultBalBefore = IERC20(DOC).balanceOf(address(vault));
        vm.prank(address(vault));
        uint256 received = sovrynAdapter.withdraw(5 ether);

        uint256 vaultBalAfter = IERC20(DOC).balanceOf(address(vault));
        console.log("Withdrew from Sovryn:", received);

        assertApproxEqRel(received, 5 ether, 0.01e18, "should receive ~5 DOC");
        assertGe(vaultBalAfter - vaultBalBefore, 5 ether - 1, "vault should receive withdrawn DOC");
    }

    // ---- Full vault lifecycle ----

    function test_fork_vault_deposit_and_totalAssets() public {
        vm.startPrank(alice);
        IERC20(DOC).approve(address(vault), 100 ether);
        uint256 shares = vault.deposit(100 ether, alice);
        vm.stopPrank();

        assertGt(shares, 0, "should receive shares");
        assertApproxEqRel(vault.totalAssets(), 100 ether, 0.01e18, "totalAssets should be ~100 DOC");
    }

    function test_fork_vault_initialDeposit_selectsBest() public {
        vm.startPrank(alice);
        IERC20(DOC).approve(address(vault), 100 ether);
        vault.deposit(100 ether, alice);
        vm.stopPrank();

        vault.initialDeposit();

        address active = address(vault.activeAdapter());
        assertTrue(
            active == address(tropykusAdapter) || active == address(sovrynAdapter),
            "should pick one of the adapters"
        );

        assertApproxEqRel(vault.totalAssets(), 100 ether, 0.01e18, "totalAssets should be ~100 DOC");
        console.log("Selected adapter:", ERC20YieldVault(address(vault)).activeAdapter().getProtocolName());
    }

    function test_fork_vault_withdraw_after_deploy() public {
        vm.startPrank(alice);
        IERC20(DOC).approve(address(vault), 100 ether);
        vault.deposit(100 ether, alice);
        vm.stopPrank();

        vault.initialDeposit();

        // Withdraw half
        vm.startPrank(alice);
        uint256 docBefore = IERC20(DOC).balanceOf(alice);
        vault.withdraw(50 ether, alice, alice);
        uint256 docAfter = IERC20(DOC).balanceOf(alice);
        vm.stopPrank();

        assertApproxEqRel(docAfter - docBefore, 50 ether, 0.01e18, "should receive ~50 DOC");
    }

    function test_fork_vault_multiple_depositors() public {
        vm.startPrank(alice);
        IERC20(DOC).approve(address(vault), 100 ether);
        uint256 aliceShares = vault.deposit(100 ether, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC20(DOC).approve(address(vault), 200 ether);
        uint256 bobShares = vault.deposit(200 ether, bob);
        vm.stopPrank();

        assertApproxEqRel(bobShares, aliceShares * 2, 0.01e18, "Bob should have ~2x Alice's shares");
        assertApproxEqRel(vault.totalAssets(), 300 ether, 0.01e18, "totalAssets should be ~300 DOC");
    }

    function test_fork_vault_yield_accrual_over_time() public {
        vm.startPrank(alice);
        IERC20(DOC).approve(address(vault), 100 ether);
        vault.deposit(100 ether, alice);
        vm.stopPrank();

        vault.initialDeposit();

        uint256 totalBefore = vault.totalAssets();

        // Advance 1 day (2880 blocks at 30s each)
        uint256 blocksPerDay = 86400 / BLOCK_TIME;
        vm.warp(block.timestamp + 86400);
        vm.roll(block.number + blocksPerDay);

        // Poke the active adapter's protocol to accrue interest
        address active = address(vault.activeAdapter());
        if (active == address(tropykusAdapter)) {
            // Mint a tiny amount to trigger Tropykus interest accrual
            deal(DOC, address(this), 0.01 ether);
            IERC20(DOC).approve(KDOC, 0.01 ether);
            IkERC20Token(KDOC).mint(0.01 ether);
        }

        uint256 totalAfter = vault.totalAssets();
        console.log("Total before:", totalBefore);
        console.log("Total after 1 day:", totalAfter);

        assertGe(totalAfter, totalBefore, "assets should not decrease after time passes");
    }

    // ---- Rebalance on real rates ----

    function test_fork_vault_rebalance() public {
        vm.startPrank(alice);
        IERC20(DOC).approve(address(vault), 100 ether);
        vault.deposit(100 ether, alice);
        vm.stopPrank();

        vault.initialDeposit();

        // Wait for cooldown
        vm.warp(block.timestamp + COOLDOWN + 1);

        // Check if rebalance is possible (rates might not differ enough)
        uint256 activeRate = vault.activeAdapter().getRate();
        (string[] memory names, uint256[] memory rates) = vault.getAllRates();

        uint256 inactiveRate;
        for (uint256 i = 0; i < names.length; i++) {
            console.log(names[i], "rate:", rates[i]);
            if (rates[i] != activeRate) {
                inactiveRate = rates[i];
            }
        }

        if (inactiveRate > activeRate + THRESHOLD) {
            vault.rebalance();
            console.log("Rebalance executed. New adapter:", vault.activeAdapter().getProtocolName());
        } else {
            console.log("Skipping rebalance: rate difference below threshold");
        }
    }

    receive() external payable {}
}
