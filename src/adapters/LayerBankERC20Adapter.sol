// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20LendingAdapter} from "../interfaces/IERC20LendingAdapter.sol";
import {ILayerBankPool} from "../interfaces/ILayerBankPool.sol";

/// @title LayerBankERC20Adapter
/// @notice Routes an ERC-20 vault's funds into the matching LayerBank market
///         (Aave V3 fork: supply mints a rebasing 1:1 aToken).
/// @dev The adapter holds the aToken position itself; the position accrues
///      interest by rebasing, so `getBalance` is simply the aToken balance.
contract LayerBankERC20Adapter is IERC20LendingAdapter {
    using SafeERC20 for IERC20;

    /// @notice LayerBank pool (Aave V3 fork) this adapter supplies to.
    ILayerBankPool public immutable pool;

    /// @notice ERC-20 asset the adapter deposits and withdraws.
    IERC20 public immutable underlying;

    /// @notice Rebasing aToken received from the pool, 1:1 with the underlying.
    IERC20 public immutable aToken;

    /// @notice Variable-debt token of the reserve; its total supply is the
    ///         market's outstanding borrows.
    IERC20 public immutable debtToken;

    /// @notice Vault bound to this adapter; the only address allowed to move funds.
    address public vault;

    /// @dev Restricts a function to the bound vault.
    modifier onlyVault() {
        require(msg.sender == vault, "only vault");
        _;
    }

    /// @notice Deploys an adapter bound to one LayerBank pool and underlying asset.
    /// @dev Resolves the market's aToken from the pool's reserve data and reverts
    ///      if the market is not listed. Grants the pool infinite approval so
    ///      `supply()` can pull tokens without a per-transaction approve.
    /// @param _pool Address of the LayerBank pool.
    /// @param _underlying Address of the ERC-20 asset to supply.
    constructor(address _pool, address _underlying) {
        pool = ILayerBankPool(_pool);
        underlying = IERC20(_underlying);
        ILayerBankPool.ReserveDataLegacy memory reserve = ILayerBankPool(_pool).getReserveData(_underlying);
        aToken = IERC20(reserve.aTokenAddress);
        debtToken = IERC20(reserve.variableDebtTokenAddress);
        require(address(aToken) != address(0), "market not listed");
        require(address(debtToken) != address(0), "market not listed");
        underlying.forceApprove(_pool, type(uint256).max);
    }

    /// @notice Binds the adapter to its vault. Callable once.
    /// @dev Reverts if the vault is already set or `_vault` is the zero address.
    /// @param _vault Address of the vault allowed to call `deposit` and `withdraw`.
    function setVault(address _vault) external {
        require(vault == address(0), "vault already set");
        require(_vault != address(0), "zero address");
        vault = _vault;
    }

    /// @notice Pulls `amount` of underlying from the vault and supplies it to LayerBank.
    /// @dev Relies on the approval the vault granted this adapter in its constructor.
    ///      Safe because `onlyVault` is the sole caller and the vault only ever
    ///      passes its own funds.
    /// @param amount Amount of underlying to deposit.
    function deposit(uint256 amount) external onlyVault {
        underlying.safeTransferFrom(vault, address(this), amount);
        pool.supply(address(underlying), amount, address(this), 0);
    }

    /// @notice Withdraws `amount` of underlying from LayerBank directly to the vault.
    /// @dev The pool's `withdraw()` sends the underlying straight to the vault;
    ///      reverts if LayerBank returns less than the requested amount.
    /// @param amount Amount of underlying to withdraw.
    /// @return Amount of underlying actually received by the vault.
    function withdraw(uint256 amount) external onlyVault returns (uint256) {
        // Full exits use Aave's max sentinel: the pool burns the entire scaled
        // balance, avoiding the sub-index-wei rounding edge on exact-balance
        // withdrawals (see KNOWN_ISSUES.md)
        uint256 request = amount >= aToken.balanceOf(address(this)) ? type(uint256).max : amount;
        uint256 received = pool.withdraw(address(underlying), request, vault);
        require(received >= amount, "layerbank: insufficient withdrawal");
        return received;
    }

    /// @notice Returns the adapter's position in LayerBank, denominated in underlying.
    /// @dev The aToken rebases 1:1 with the underlying, so its balance equals the
    ///      withdrawable amount (principal plus accrued interest).
    /// @return Underlying balance held via the aToken.
    function getBalance() external view returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    /// @notice Returns LayerBank's current annualized supply rate, normalized to
    ///         the vault's 1e18 = 100% APR scale.
    /// @dev `currentLiquidityRate` is the annualized supply rate in ray (1e27);
    ///      dividing by 1e9 converts it to the 1e18 = 100% scale the vault uses
    ///      to compare adapters.
    /// @return Supply APR where 1e18 equals 100%.
    function getRate() external view returns (uint256) {
        return pool.getReserveData(address(underlying)).currentLiquidityRate / 1e9;
    }

    /// @notice Returns the market's current utilization.
    /// @dev Variable debt over aToken supply (the Aave identity: aToken total
    ///      supply is free cash plus borrows). Slightly overstates true
    ///      utilization by unminted treasury accrual, the conservative
    ///      direction for an entry gate. An empty market reads as zero.
    /// @return Utilization on a 1e18 = 100% scale; can marginally exceed 1e18
    ///         when the reserve is drained.
    function getUtilization() external view returns (uint256) {
        uint256 supplied = aToken.totalSupply();
        if (supplied == 0) return 0;
        return debtToken.totalSupply() * 1e18 / supplied;
    }

    /// @notice Transfers a fraction of the aToken position directly to `to`.
    /// @dev Only the vault may call this (in-kind redemptions). aToken
    ///      transfers clear while the reserve is active or merely frozen; a
    ///      full Aave-style pause blocks transfers too, in which case the
    ///      vault skips this slice.
    /// @param to Recipient of the aTokens.
    /// @param numerator Fraction numerator.
    /// @param denominator Fraction denominator (>= numerator, > 0).
    function transferPosition(address to, uint256 numerator, uint256 denominator) external onlyVault {
        uint256 amount = aToken.balanceOf(address(this)) * numerator / denominator;
        if (amount > 0) {
            SafeERC20.safeTransfer(aToken, to, amount);
        }
    }

    /// @notice Returns the name of the protocol this adapter integrates.
    /// @return The string "LayerBank".
    function getProtocolName() external pure returns (string memory) {
        return "LayerBank";
    }
}
