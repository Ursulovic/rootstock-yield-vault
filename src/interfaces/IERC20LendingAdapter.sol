// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Adapter interface for routing an ERC-20 vault's funds into a
///         lending protocol. Each adapter wraps one market and is bound to a
///         single vault via a one-time setVault call.
/// @dev Unlike ILendingAdapter (native rBTC), deposit pulls tokens from the
///      vault via transferFrom, so the vault must approve the adapter first.
interface IERC20LendingAdapter {
    /// @notice Pulls `amount` of the underlying token from the vault and
    ///         deposits it into the underlying lending protocol. Only callable
    ///         by the bound vault.
    /// @param amount Amount of underlying tokens to deposit.
    function deposit(uint256 amount) external;

    /// @notice Withdraws at least `amount` of the underlying token from the
    ///         protocol and transfers it to the vault.
    /// @param amount Minimum amount of underlying tokens to withdraw.
    /// @return The amount of underlying tokens actually withdrawn and
    ///         transferred to the vault.
    function withdraw(uint256 amount) external returns (uint256);

    /// @notice Returns the adapter's balance of the underlying token held in
    ///         the lending protocol, including accrued interest.
    /// @return The underlying token balance.
    function getBalance() external view returns (uint256);

    /// @notice Returns the protocol's current annualized supply rate,
    ///         normalized to the vault's comparison scale of 1e18 = 100% APR.
    /// @return The normalized supply rate.
    function getRate() external view returns (uint256);

    /// @notice Returns a human-readable name of the underlying protocol.
    /// @return The protocol name.
    function getProtocolName() external pure returns (string memory);

    /// @notice Binds the adapter to its vault. Can only be set once.
    /// @param vault Address of the vault authorized to call deposit and withdraw.
    function setVault(address vault) external;
}
