// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ILendingAdapter} from "../interfaces/ILendingAdapter.sol";
import {IiToken} from "../interfaces/IiToken.sol";

/// @notice Lending adapter that routes vault rBTC into a Sovryn (bZx-style) iToken market.
/// @dev Holds iTokens on behalf of the vault; only the vault may deposit or withdraw.
///      Normalizes Sovryn's percent-scaled supply rate to the vault's 1e18 = 100% APR scale.
contract SovrynAdapter is ILendingAdapter {
    /// @notice Sovryn iToken market this adapter deposits into (e.g. iRBTC).
    IiToken public immutable iToken;

    /// @notice Vault authorized to call deposit/withdraw. Set once via setVault.
    address public vault;

    modifier onlyVault() {
        require(msg.sender == vault, "only vault");
        _;
    }

    /// @notice Deploys the adapter bound to a Sovryn iToken market.
    /// @param _iToken Address of the Sovryn iToken contract.
    constructor(address _iToken) {
        iToken = IiToken(_iToken);
    }

    /// @notice Sets the vault address. Callable exactly once; immutable thereafter.
    /// @param _vault Address of the vault allowed to use this adapter.
    function setVault(address _vault) external {
        require(vault == address(0), "vault already set");
        require(_vault != address(0), "zero address");
        vault = _vault;
    }

    /// @notice Deposits the attached rBTC into the Sovryn market, minting iTokens to this adapter.
    /// @dev Only callable by the vault.
    function deposit() external payable onlyVault {
        iToken.mintWithBTC{value: msg.value}(address(this), false);
    }

    /// @notice Withdraws at least `amount` of rBTC from Sovryn and forwards it to the vault.
    /// @dev Only callable by the vault. The iToken burn amount is rounded up so the
    ///      redeemed rBTC is never less than `amount`; rBTC is burned to this adapter
    ///      first and then forwarded, since the vault only accepts rBTC from its adapters.
    /// @param amount Minimum amount of rBTC (in wei) to withdraw.
    /// @return The actual amount of rBTC forwarded to the vault (>= `amount`).
    function withdraw(uint256 amount) external onlyVault returns (uint256) {
        uint256 price = iToken.tokenPrice();
        uint256 burnAmount = (amount * 1e18 + price - 1) / price;

        uint256 actualAmount = iToken.burnToBTC(address(this), burnAmount, false);
        require(actualAmount >= amount, "sovryn: insufficient withdrawal");

        (bool success,) = vault.call{value: actualAmount}("");
        require(success, "rBTC transfer failed");
        return actualAmount;
    }

    /// @notice Returns the adapter's underlying rBTC balance held in the Sovryn market.
    /// @return The rBTC value (in wei) of this adapter's iToken position.
    function getBalance() external view returns (uint256) {
        return iToken.assetBalanceOf(address(this));
    }

    /// @notice Returns the current supply APR normalized to the vault's scale.
    /// @dev Sovryn (bZx) reports the annual rate percent-scaled (1e18 = 1%), verified
    ///      against real iRBTC tokenPrice growth on mainnet, so the adapter divides
    ///      by 100 to normalize to the vault's 1e18 = 100% scale.
    /// @return The supply APR where 1e18 = 100%.
    function getRate() external view returns (uint256) {
        return iToken.supplyInterestRate() / 100;
    }

    /// @notice Returns the iToken market's current utilization.
    /// @dev totalAssetBorrow over totalAssetSupply, both denominated in
    ///      underlying rBTC. An empty market reads as zero.
    /// @return Utilization on a 1e18 = 100% scale.
    function getUtilization() external view returns (uint256) {
        uint256 supplied = iToken.totalAssetSupply();
        if (supplied == 0) return 0;
        return iToken.totalAssetBorrow() * 1e18 / supplied;
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

    /// @notice Accepts rBTC sent by the iToken when burning during withdrawals.
    receive() external payable {}
}
