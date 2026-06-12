// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20YieldVault} from "../../src/ERC20YieldVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockLayerBankPool} from "../mocks/MockLayerBankPool.sol";
import {MockLoanToken} from "../mocks/MockLoanToken.sol";

/// @notice Drives the vault through random deposit/withdraw/rebalance/donate/accrue
///         sequences for invariant testing. Reverts inside actions are swallowed
///         so a single illegal call doesn't abort the whole run; the invariants
///         (asserted in the test contract) are what must always hold.
contract VaultHandler is Test {
    ERC20YieldVault public immutable vault;
    MockERC20 public immutable asset;
    MockLayerBankPool public immutable lbPool; // LayerBank (Aave-style) pool
    MockLoanToken public immutable iPool; // Sovryn-style pool
    uint256 public immutable cooldown;

    address[] public actors;
    uint256 public ghost_donated; // total adversarial donations (never counted as principal)

    constructor(
        ERC20YieldVault _vault,
        MockERC20 _asset,
        MockLayerBankPool _lbPool,
        MockLoanToken _iPool,
        uint256 _cooldown
    ) {
        vault = _vault;
        asset = _asset;
        lbPool = _lbPool;
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
        lbPool.setSupplyRate1e18(address(asset), rateA);
        iPool.setSupplyInterestRate((rateB) * 100);

        vm.warp(block.timestamp + cooldown + bound(timeJump, 1, 30 days));
        try vault.rebalance() {} catch {}
    }

    // Solvency/liveness: a depositor pulling their entire balance must always
    // succeed, with ONE precisely-scoped exception that mirrors real Aave:
    // when the required pull from the pool is below one "index-wei"
    // (amount * RAY / index rounds to 0 scaled), the pool reverts
    // "invalid burn amount" — real Aave's INVALID_BURN_AMOUNT. Anything
    // beyond that dust band must succeed or the invariant run fails.
    // (Tier 1 backlog: use Aave's type(uint256).max full-withdraw sentinel
    // in the adapters to close even the dust band.)
    function fullExit(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        uint256 max = vault.maxWithdraw(actor);
        if (max == 0) return;
        uint256 idle = asset.balanceOf(address(vault));

        vm.prank(actor);
        try vault.withdraw(max, actor, actor) {}
        catch {
            uint256 pullNeeded = max > idle ? max - idle : 0;
            // Rounding can shift the burn by ~1 scaled unit on top of the
            // sub-index-wei band, so allow the band plus 2 index-wei.
            uint256 idx = lbPool.liquidityIndex(address(asset));
            uint256 dustLimit = idx / 1e27 * 2 + idx / (2 * 1e27) + 2;
            require(pullNeeded > 0 && pullNeeded <= dustLimit, "fullExit failed beyond known dust edge");
        }
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 1, 1e24);
        asset.mint(address(vault), amount);
        ghost_donated += amount;
    }

    function accrue(uint256 amount) external {
        amount = bound(amount, 0, 1e22);
        // Add real yield to whichever pool currently holds funds
        asset.mint(address(lbPool), amount);
        lbPool.accrueInterest(address(asset));
        asset.mint(address(iPool), amount);
        iPool.accrueInterest();
    }
}
