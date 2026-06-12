// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILayerBankPool} from "../../src/interfaces/ILayerBankPool.sol";

/// @notice Mock aToken: rebasing receipt, balanceOf = scaled * liquidityIndex / RAY
contract MockAToken {
    uint256 internal constant RAY = 1e27;

    MockLayerBankPool public immutable pool;
    address public immutable asset;
    mapping(address => uint256) public scaledBalanceOf;
    uint256 public scaledTotalSupply;

    modifier onlyPool() {
        require(msg.sender == address(pool), "only pool");
        _;
    }

    constructor(address _asset) {
        pool = MockLayerBankPool(msg.sender);
        asset = _asset;
    }

    function balanceOf(address user) external view returns (uint256) {
        // Floor rayMul. Real Aave rounds half-up, which can overstate the
        // closed-system pool by 1 wei (covered by other suppliers on mainnet);
        // flooring keeps this single-supplier mock solvent and errs against
        // the depositor, so it can never hide vault insolvency.
        return scaledBalanceOf[user] * pool.liquidityIndex(asset) / RAY;
    }

    function totalSupply() external view returns (uint256) {
        return scaledTotalSupply * pool.liquidityIndex(asset) / RAY;
    }

    function mintScaled(address to, uint256 scaled) external onlyPool {
        scaledBalanceOf[to] += scaled;
        scaledTotalSupply += scaled;
    }

    function burnScaled(address from, uint256 scaled) external onlyPool {
        require(scaledBalanceOf[from] >= scaled, "insufficient balance");
        scaledBalanceOf[from] -= scaled;
        scaledTotalSupply -= scaled;
    }
}

/// @notice Mock LayerBank pool (Aave V3 fork pattern): multi-asset, rebasing
///         aTokens via a per-asset liquidity index, rates in ray.
contract MockLayerBankPool is ILayerBankPool {
    uint256 internal constant RAY = 1e27;

    mapping(address => MockAToken) public aTokens;
    mapping(address => uint256) public liquidityIndex; // ray
    mapping(address => uint256) public liquidityRate; // ray
    // Simulates a broken/malicious fork that short-pays withdrawals. Real Aave
    // either transfers exactly `amount` or reverts (validation, pause, or
    // illiquidity) — it never partially pays. The knob exists only to pin the
    // adapters' defensive require(received >= amount) check.
    uint256 public withdrawFeeBps;

    /// @notice List a market for `asset` (test setup)
    function initReserve(address asset) external returns (address) {
        require(address(aTokens[asset]) == address(0), "already listed");
        aTokens[asset] = new MockAToken(asset);
        liquidityIndex[asset] = RAY;
        return address(aTokens[asset]);
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        require(amount > 0, "26"); // real Aave rejects zero amounts (error code 26)
        MockAToken aToken = aTokens[asset];
        require(address(aToken) != address(0), "market not listed");
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        // Floor rayDiv + nonzero-scaled check (real Aave rounds half-up; floor
        // keeps the closed-system mock solvent — see MockAToken.balanceOf)
        uint256 idx = liquidityIndex[asset];
        uint256 scaled = amount * RAY / idx;
        require(scaled != 0, "invalid mint amount");
        aToken.mintScaled(onBehalfOf, scaled);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        require(amount > 0, "26"); // real Aave rejects zero amounts (error code 26)
        MockAToken aToken = aTokens[asset];
        require(address(aToken) != address(0), "market not listed");
        uint256 idx = liquidityIndex[asset];
        uint256 scaled;
        if (amount == type(uint256).max) {
            // Aave full-withdraw sentinel: burn the caller's entire scaled balance
            scaled = aToken.scaledBalanceOf(msg.sender);
            require(scaled != 0, "invalid burn amount");
            amount = scaled * idx / RAY; // floor rayMul, matching balanceOf
        } else {
            // Half-up rayDiv + nonzero-scaled check, like real Aave _burnScaled
            scaled = (amount * RAY + idx / 2) / idx;
            require(scaled != 0, "invalid burn amount");
        }
        aToken.burnScaled(msg.sender, scaled);
        uint256 paid = amount - amount * withdrawFeeBps / 10_000;
        IERC20(asset).transfer(to, paid);
        return paid;
    }

    function getReserveData(address asset) external view returns (ReserveDataLegacy memory data) {
        data.liquidityIndex = uint128(liquidityIndex[asset]);
        data.currentLiquidityRate = uint128(liquidityRate[asset]);
        data.aTokenAddress = address(aTokens[asset]);
    }

    // -- Test helpers --

    /// @param rate1e18 annual supply rate on the vault's 1e18 = 100% scale
    function setSupplyRate1e18(address asset, uint256 rate1e18) external {
        liquidityRate[asset] = rate1e18 * 1e9; // 1e18 -> ray
    }

    function setWithdrawFeeBps(uint256 _bps) external {
        withdrawFeeBps = _bps;
    }

    /// @notice Simulate interest accrual by recomputing the index from the
    ///         pool's actual underlying balance (mint/transfer yield in first).
    ///         FIDELITY CAVEAT: real Aave's index is a monotone function of
    ///         time x rate and is donation-immune; this helper is neither and
    ///         is only sound for single-supplier test pools. It also never
    ///         models illiquidity — real withdrawals can revert when utilization
    ///         is high, which the vault cannot hedge (no partial withdraws).
    function accrueInterest(address asset) external {
        MockAToken aToken = aTokens[asset];
        uint256 scaled = aToken.scaledTotalSupply();
        if (scaled > 0) {
            liquidityIndex[asset] = IERC20(asset).balanceOf(address(this)) * RAY / scaled;
        }
    }
}
