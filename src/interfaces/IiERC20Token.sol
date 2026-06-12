// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Sovryn iToken interface for ERC-20 markets (bZx LoanTokenLogicLM
///         pattern). Minting pulls the underlying ERC-20 via transferFrom, so
///         the caller must approve the iToken first.
/// @dev supplyInterestRate is percent-scaled (1e18 = 1% APR), so adapters
///      divide by 100 to normalize to the vault's 1e18 = 100% scale.
interface IiERC20Token {
    /// @notice Pulls `depositAmount` of the underlying token from the caller
    ///         and mints iTokens to the receiver.
    /// @param receiver Address that receives the minted iTokens.
    /// @param depositAmount Amount of underlying tokens to deposit.
    /// @return The amount of iTokens minted.
    function mint(address receiver, uint256 depositAmount) external returns (uint256);

    /// @notice Burns iTokens from the caller and sends the underlying tokens
    ///         to the receiver.
    /// @param receiver Address that receives the underlying tokens.
    /// @param burnAmount Amount of iTokens to burn.
    /// @return The amount of underlying tokens paid out.
    function burn(address receiver, uint256 burnAmount) external returns (uint256);

    /// @notice Returns the current annual supply interest rate, percent-scaled
    ///         (1e18 = 1% APR).
    /// @return The percent-scaled annual supply rate.
    function supplyInterestRate() external view returns (uint256);

    /// @notice Returns the current iToken-to-underlying exchange rate, scaled
    ///         by 1e18. Grows over time as interest accrues.
    /// @return The exchange rate (underlying per iToken, 1e18-scaled).
    function tokenPrice() external view returns (uint256);

    /// @notice Returns the owner's balance expressed in underlying tokens
    ///         (iToken balance times tokenPrice).
    /// @param owner Address whose balance is queried.
    /// @return The underlying token balance.
    function assetBalanceOf(address owner) external view returns (uint256);

    /// @notice Returns the owner's raw iToken balance.
    /// @param owner Address whose balance is queried.
    /// @return The iToken balance.
    function balanceOf(address owner) external view returns (uint256);

    /// @notice Standard ERC-20 transfer of iTokens (loan tokens are ERC-20s).
    /// @param to Recipient address.
    /// @param amount iToken amount to transfer.
    /// @return True on success.
    function transfer(address to, uint256 amount) external returns (bool);
}
