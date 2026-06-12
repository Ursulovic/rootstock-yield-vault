// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {YieldVault} from "../../src/YieldVault.sol";
import {MockWRBTC} from "../mocks/MockWRBTC.sol";
import {MockLayerBankPool} from "../mocks/MockLayerBankPool.sol";
import {MockiToken} from "../mocks/MockiToken.sol";

/// @notice Drives the native rBTC vault through random sequences for invariant
///         testing: native and ERC-4626 deposits/withdrawals, rebalances, WRBTC
///         donations and yield accrual on both protocols. Mirrors Handler.sol
///         but exercises the native-only paths (wrap/unwrap, receive() filter,
///         native balance-delta accounting in rebalance).
contract NativeVaultHandler is Test {
    uint256 internal constant RAY = 1e27;

    YieldVault public immutable vault;
    MockWRBTC public immutable wrbtc;
    MockLayerBankPool public immutable lbPool;
    MockiToken public immutable iPool;
    uint256 public immutable cooldown;

    address[] public actors;
    uint256 public ghost_donated;

    constructor(
        YieldVault _vault,
        MockWRBTC _wrbtc,
        MockLayerBankPool _lbPool,
        MockiToken _iPool,
        uint256 _cooldown
    ) {
        vault = _vault;
        wrbtc = _wrbtc;
        lbPool = _lbPool;
        iPool = _iPool;
        cooldown = _cooldown;
        actors.push(makeAddr("ninv_alice"));
        actors.push(makeAddr("ninv_bob"));
        actors.push(makeAddr("ninv_carol"));
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// Tolerated failure band for LayerBank pulls: amounts whose scaled value
    /// rounds to zero revert "invalid burn amount" on real Aave too.
    function _dustLimit() internal view returns (uint256) {
        uint256 idx = lbPool.liquidityIndex(address(wrbtc));
        return idx / 1e27 * 2 + idx / (2 * 1e27) + 2;
    }

    function depositNative(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, 1, 1e24);
        vm.deal(actor, amount);

        vm.prank(actor);
        try vault.depositNative{value: amount}(actor) {}
        catch {
            // Only the sub-index-wei supply edge may fail (real Aave parity)
            require(amount <= _dustLimit(), "depositNative failed beyond dust edge");
        }

        if (address(vault.activeAdapter()) == address(0) && wrbtc.balanceOf(address(vault)) > 0) {
            try vault.initialDeposit() {} catch {}
        }
    }

    function depositWrapped(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, 1, 1e24);
        vm.deal(actor, amount);

        vm.startPrank(actor);
        wrbtc.deposit{value: amount}();
        wrbtc.approve(address(vault), amount);
        try vault.deposit(amount, actor) {}
        catch {
            require(amount <= _dustLimit(), "deposit failed beyond dust edge");
        }
        vm.stopPrank();
    }

    function withdrawNative(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        uint256 max = vault.maxWithdraw(actor);
        if (max == 0) return;
        amount = bound(amount, 1, max);
        uint256 idle = wrbtc.balanceOf(address(vault));

        vm.prank(actor);
        try vault.withdrawNative(amount, actor, actor) {}
        catch {
            uint256 pullNeeded = amount > idle ? amount - idle : 0;
            require(pullNeeded > 0 && pullNeeded <= _dustLimit(), "withdrawNative failed beyond dust edge");
        }
    }

    function rebalance(uint256 rateSeed, uint256 timeJump) external {
        uint256 cap = vault.maxSaneRate();
        uint256 rateA = bound(rateSeed, 1e15, cap - 1);
        uint256 rateB = bound(uint256(keccak256(abi.encode(rateSeed))), 1e15, cap - 1);
        lbPool.setSupplyRate1e18(address(wrbtc), rateA);
        iPool.setSupplyInterestRate(rateB * 100); // Sovryn mock is percent-scaled

        vm.warp(block.timestamp + cooldown + bound(timeJump, 1, 30 days));
        try vault.rebalance() {} catch {}
    }

    // Solvency/liveness with the same precisely-scoped dust exception as the
    // ERC20 handler: anything beyond the sub-index-wei band must succeed.
    function fullExit(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        uint256 max = vault.maxWithdraw(actor);
        if (max == 0) return;
        uint256 idle = wrbtc.balanceOf(address(vault));

        vm.prank(actor);
        try vault.withdrawNative(max, actor, actor) {}
        catch {
            uint256 pullNeeded = max > idle ? max - idle : 0;
            require(pullNeeded > 0 && pullNeeded <= _dustLimit(), "fullExit failed beyond known dust edge");
        }
    }

    /// WRBTC ERC-20 donation — the channel the receive() filter cannot block
    function donateWrbtc(uint256 amount) external {
        amount = bound(amount, 1, 1e24);
        vm.deal(address(this), amount);
        wrbtc.deposit{value: amount}();
        wrbtc.transfer(address(vault), amount);
        ghost_donated += amount;
    }

    /// Direct native send must ALWAYS revert — the donation filter at work
    function donateNativeMustRevert(uint256 amount) external {
        amount = bound(amount, 1, 1e24);
        address rando = makeAddr("ninv_rando");
        vm.deal(rando, amount);
        vm.prank(rando);
        (bool ok,) = address(vault).call{value: amount}("");
        require(!ok, "vault accepted rBTC from an arbitrary sender");
    }

    function accrue(uint256 amount) external {
        amount = bound(amount, 0, 1e22);
        // LayerBank yield: WRBTC lands in the pool, index recomputed
        if (amount > 0) {
            vm.deal(address(this), amount);
            wrbtc.deposit{value: amount}();
            wrbtc.transfer(address(lbPool), amount);
        }
        lbPool.accrueInterest(address(wrbtc));
        // Sovryn yield: native rBTC lands in the iToken, price recomputed
        vm.deal(address(iPool), address(iPool).balance + amount);
        iPool.accrueInterest();
    }

    receive() external payable {}
}
