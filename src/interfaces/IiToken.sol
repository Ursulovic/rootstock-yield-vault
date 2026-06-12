// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Sovryn iRBTC interface (bZx LoanTokenLogicWrbtcLM pattern). The
///         native rBTC lending market: minting takes rBTC directly and burning
///         pays out rBTC.
/// @dev supplyInterestRate is percent-scaled (1e18 = 1% APR), so adapters
///      divide by 100 to normalize to the vault's 1e18 = 100% scale.
interface IiToken {
    /// @notice Deposits the native rBTC sent with the call and mints iRBTC to
    ///         the receiver.
    /// @param receiver Address that receives the minted iRBTC.
    /// @param useLM True to stake the minted tokens in Sovryn's liquidity
    ///        mining; false to receive them directly.
    /// @return The amount of iRBTC minted.
    function mintWithBTC(address receiver, bool useLM) external payable returns (uint256);

    /// @notice Burns iRBTC from the caller and sends the underlying rBTC to
    ///         the receiver.
    /// @param receiver Address that receives the underlying rBTC.
    /// @param burnAmount Amount of iRBTC to burn.
    /// @param useLM True to unstake from Sovryn's liquidity mining before
    ///        burning; false to burn the caller's directly held tokens.
    /// @return The amount of rBTC paid out.
    function burnToBTC(address receiver, uint256 burnAmount, bool useLM) external returns (uint256);

    /// @notice Returns the current annual supply interest rate, percent-scaled
    ///         (1e18 = 1% APR).
    /// @return The percent-scaled annual supply rate.
    function supplyInterestRate() external view returns (uint256);

    /// @notice Returns the current iRBTC-to-rBTC exchange rate, scaled by 1e18.
    ///         Grows over time as interest accrues.
    /// @return The exchange rate (underlying per iToken, 1e18-scaled).
    function tokenPrice() external view returns (uint256);

    /// @notice Returns the owner's balance expressed in underlying rBTC
    ///         (iToken balance times tokenPrice).
    /// @param owner Address whose balance is queried.
    /// @return The underlying rBTC balance in wei.
    function assetBalanceOf(address owner) external view returns (uint256);

    /// @notice Returns the owner's raw iRBTC token balance.
    /// @param owner Address whose balance is queried.
    /// @return The iRBTC balance.
    function balanceOf(address owner) external view returns (uint256);
}
