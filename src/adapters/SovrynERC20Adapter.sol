// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20LendingAdapter} from "../interfaces/IERC20LendingAdapter.sol";
import {IiERC20Token} from "../interfaces/IiERC20Token.sol";

/// @notice Lending adapter that routes an ERC-20 vault's funds into a Sovryn
///         (bZx-style) iToken market.
/// @dev Holds iTokens on behalf of the vault and exposes the unified
///      IERC20LendingAdapter interface. Only the vault set via setVault may
///      deposit or withdraw.
contract SovrynERC20Adapter is IERC20LendingAdapter {
    using SafeERC20 for IERC20;

    /// @notice Sovryn iToken market this adapter supplies into.
    IiERC20Token public immutable iToken;
    /// @notice Underlying ERC-20 asset accepted by the iToken market.
    IERC20 public immutable underlying;
    /// @notice Vault authorized to call deposit/withdraw; set once via setVault.
    address public vault;

    modifier onlyVault() {
        require(msg.sender == vault, "only vault");
        _;
    }

    /// @notice Deploys the adapter for a given Sovryn iToken market and its
    ///         underlying asset.
    /// @dev Grants the iToken infinite approval so mint() can pull tokens
    ///      without a per-tx approve.
    /// @param _iToken Address of the Sovryn iToken market.
    /// @param _underlying Address of the underlying ERC-20 asset.
    constructor(address _iToken, address _underlying) {
        iToken = IiERC20Token(_iToken);
        underlying = IERC20(_underlying);
        // Infinite approval so mint() can pull tokens without per-tx approve
        underlying.forceApprove(_iToken, type(uint256).max);
    }

    /// @notice Sets the vault address that is authorized to call deposit and
    ///         withdraw. Callable once; reverts if the vault is already set.
    /// @param _vault Address of the vault contract.
    function setVault(address _vault) external {
        require(vault == address(0), "vault already set");
        require(_vault != address(0), "zero address");
        vault = _vault;
    }

    /// @notice Deposits `amount` of the underlying asset into the Sovryn
    ///         market, minting iTokens to this adapter.
    /// @dev Pulls the underlying from the vault, which granted this adapter
    ///      approval in its constructor. Safe because `onlyVault` is the sole
    ///      caller and the vault only ever passes its own funds.
    /// @param amount Amount of underlying tokens to deposit.
    function deposit(uint256 amount) external onlyVault {
        // Pulls from the vault, which granted this adapter approval in its
        // constructor. Safe because `onlyVault` is the sole caller and the
        // vault only ever passes its own funds.
        underlying.safeTransferFrom(vault, address(this), amount);
        iToken.mint(address(this), amount);
    }

    /// @notice Withdraws at least `amount` of the underlying asset from the
    ///         Sovryn market directly to the vault.
    /// @dev Converts `amount` to an iToken burn amount at the current
    ///      tokenPrice, rounding up so the withdrawal covers at least
    ///      `amount`. burn() sends the underlying directly to the receiver
    ///      (the vault); reverts if less than `amount` is received.
    /// @param amount Minimum amount of underlying tokens to withdraw.
    /// @return The actual amount of underlying tokens sent to the vault.
    function withdraw(uint256 amount) external onlyVault returns (uint256) {
        uint256 price = iToken.tokenPrice();
        // Round up to ensure we withdraw at least `amount`
        uint256 burnAmount = (amount * 1e18 + price - 1) / price;

        // burn sends underlying directly to the receiver (vault)
        uint256 actualAmount = iToken.burn(vault, burnAmount);
        require(actualAmount >= amount, "sovryn: insufficient withdrawal");
        return actualAmount;
    }

    /// @notice Returns the adapter's current balance in the Sovryn market,
    ///         denominated in the underlying asset.
    /// @return The underlying value of the adapter's iToken holdings.
    function getBalance() external view returns (uint256) {
        return iToken.assetBalanceOf(address(this));
    }

    /// @notice Returns the market's current annual supply rate, normalized to
    ///         the vault's 1e18 = 100% APR scale.
    /// @dev Sovryn (bZx) reports the annual rate percent-scaled (1e18 = 1%),
    ///      verified against real iRBTC tokenPrice growth on mainnet, so the
    ///      reported value is divided by 100.
    /// @return The annual supply rate where 1e18 = 100% APR.
    function getRate() external view returns (uint256) {
        // Sovryn (bZx) reports the annual rate percent-scaled: 1e18 = 1%
        // (verified against real iRBTC tokenPrice growth on mainnet).
        // Normalize to the vault's 1e18 = 100% scale.
        return iToken.supplyInterestRate() / 100;
    }


    /// @notice Transfers a fraction of the iToken position directly to `to`.
    /// @dev Only the vault may call this (in-kind redemptions). iTokens are
    ///      standard ERC-20s, so this works even when the protocol's
    ///      mint/burn paths are paused.
    /// @param to Recipient of the iTokens.
    /// @param numerator Fraction numerator.
    /// @param denominator Fraction denominator (>= numerator, > 0).
    function transferPosition(address to, uint256 numerator, uint256 denominator) external onlyVault {
        uint256 amount = iToken.balanceOf(address(this)) * numerator / denominator;
        if (amount > 0) {
            require(iToken.transfer(to, amount), "iToken transfer failed");
        }
    }

    /// @notice Returns the human-readable name of the underlying protocol.
    /// @return The protocol name, "Sovryn".
    function getProtocolName() external pure returns (string memory) {
        return "Sovryn";
    }
}
