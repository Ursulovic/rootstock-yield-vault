// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Tropykus kToken interface for ERC-20 markets (Compound V2 CErc20 pattern)
interface IkERC20Token {
    function mint(uint256 mintAmount) external returns (uint256);
    function redeem(uint256 redeemTokens) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function supplyRatePerBlock() external view returns (uint256);
}
