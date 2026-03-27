// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Sovryn iToken interface for ERC-20 markets (bZx LoanTokenLogicLM pattern)
interface IiERC20Token {
    function mint(address receiver, uint256 depositAmount) external returns (uint256);
    function burn(address receiver, uint256 burnAmount) external returns (uint256);
    function supplyInterestRate() external view returns (uint256);
    function tokenPrice() external view returns (uint256);
    function assetBalanceOf(address owner) external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
}
