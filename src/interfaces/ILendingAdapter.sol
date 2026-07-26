// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Adapter interface for routing the native rBTC vault's funds into a
///         lending protocol. Each adapter wraps one market and is bound to a
///         single vault via a one-time setVault call.
interface ILendingAdapter {
    /// @notice Deposits the native rBTC sent with the call into the underlying
    ///         lending protocol. Only callable by the bound vault.
    function deposit() external payable;

    /// @notice Withdraws at least `amount` of rBTC from the underlying protocol
    ///         and forwards it to the vault.
    /// @param amount Minimum amount of rBTC (wei) to withdraw.
    /// @return The amount of rBTC actually withdrawn and forwarded to the vault.
    function withdraw(uint256 amount) external returns (uint256);

    /// @notice Returns the adapter's balance of underlying rBTC held in the
    ///         lending protocol, including accrued interest.
    /// @return The underlying balance in wei.
    function getBalance() external view returns (uint256);

    /// @notice Returns the protocol's current annualized supply rate,
    ///         normalized to the vault's comparison scale of 1e18 = 100% APR.
    /// @return The normalized supply rate.
    function getRate() external view returns (uint256);

    /// @notice Returns the underlying market's current utilization (borrows
    ///         over total supplied liquidity) on a 1e18 = 100% scale.
    /// @dev Consulted by the vault only to gate new allocation; exit paths
    ///      never depend on it.
    /// @return The market utilization (1e18 = 100%).
    function getUtilization() external view returns (uint256);

    /// @notice Returns a human-readable name of the underlying protocol.
    /// @return The protocol name.
    function getProtocolName() external pure returns (string memory);

    /// @notice Transfers `numerator/denominator` of this adapter's receipt-token
    ///         position directly to `to`. Used by the vault's in-kind redemption:
    ///         the receiver takes over the protocol position itself, with no
    ///         protocol interaction required.
    /// @param to Recipient of the receipt tokens.
    /// @param numerator Fraction numerator.
    /// @param denominator Fraction denominator (>= numerator, > 0).
    function transferPosition(address to, uint256 numerator, uint256 denominator) external;

    /// @notice Binds the adapter to its vault. Can only be set once.
    /// @param vault Address of the vault authorized to call deposit and withdraw.
    function setVault(address vault) external;
}
