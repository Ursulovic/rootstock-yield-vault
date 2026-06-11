// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20YieldVault} from "../../src/ERC20YieldVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockCErc20} from "../mocks/MockCErc20.sol";
import {MockLoanToken} from "../mocks/MockLoanToken.sol";

/// @notice Drives the vault through random deposit/withdraw/rebalance/donate/accrue
///         sequences for invariant testing. Reverts inside actions are swallowed
///         so a single illegal call doesn't abort the whole run; the invariants
///         (asserted in the test contract) are what must always hold.
contract VaultHandler is Test {
    ERC20YieldVault public immutable vault;
    MockERC20 public immutable asset;
    MockCErc20 public immutable kPool; // Tropykus-style pool
    MockLoanToken public immutable iPool; // Sovryn-style pool
    uint256 public immutable cooldown;

    address[] public actors;
    uint256 public ghost_donated; // total adversarial donations (never counted as principal)

    constructor(
        ERC20YieldVault _vault,
        MockERC20 _asset,
        MockCErc20 _kPool,
        MockLoanToken _iPool,
        uint256 _cooldown
    ) {
        vault = _vault;
        asset = _asset;
        kPool = _kPool;
        iPool = _iPool;
        cooldown = _cooldown;
        actors.push(makeAddr("inv_alice"));
        actors.push(makeAddr("inv_bob"));
        actors.push(makeAddr("inv_carol"));
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, 1, 1e24);
        asset.mint(actor, amount);

        vm.startPrank(actor);
        asset.approve(address(vault), amount);
        try vault.deposit(amount, actor) {} catch {}
        vm.stopPrank();

        // Bootstrap the active adapter once funds are idle
        if (address(vault.activeAdapter()) == address(0) && asset.balanceOf(address(vault)) > 0) {
            try vault.initialDeposit() {} catch {}
        }
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        uint256 max = vault.maxWithdraw(actor);
        if (max == 0) return;
        amount = bound(amount, 1, max);

        vm.prank(actor);
        try vault.withdraw(amount, actor, actor) {} catch {}
    }

    function rebalance(uint256 rateSeed, uint256 timeJump) external {
        // Keep both rates strictly under the vault's sane cap so the fuzzer
        // actually exercises rebalances rather than always hitting the filter
        uint256 cap = vault.maxSaneRate();
        uint256 rateA = bound(rateSeed, 1e15, cap - 1);
        uint256 rateB = bound(uint256(keccak256(abi.encode(rateSeed))), 1e15, cap - 1);
        // kPool rate is per-block * 1,051,200; invert to set supplyRatePerBlock
        kPool.setSupplyRatePerBlock(rateA / 1_051_200);
        iPool.setSupplyInterestRate(rateB);

        vm.warp(block.timestamp + cooldown + bound(timeJump, 1, 30 days));
        try vault.rebalance() {} catch {}
    }

    // Solvency/liveness: a depositor pulling their entire balance must always
    // succeed. No try/catch — if the vault can't honor a full exit, the
    // withdraw reverts and the whole invariant run fails.
    function fullExit(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        uint256 max = vault.maxWithdraw(actor);
        if (max == 0) return;
        vm.prank(actor);
        vault.withdraw(max, actor, actor);
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 1, 1e24);
        asset.mint(address(vault), amount);
        ghost_donated += amount;
    }

    function accrue(uint256 amount) external {
        amount = bound(amount, 0, 1e22);
        // Add real yield to whichever pool currently holds funds
        asset.mint(address(kPool), amount);
        kPool.accrueInterest();
        asset.mint(address(iPool), amount);
        iPool.accrueInterest();
    }
}
