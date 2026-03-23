// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Sovryn iRBTC interface (bZx LoanTokenLogicWrbtcLM pattern)
interface IiToken {
    function mintWithBTC(address receiver, bool useLM) external payable returns (uint256);
    function burnToBTC(address receiver, uint256 burnAmount, bool useLM) external returns (uint256);
    function supplyInterestRate() external view returns (uint256);
    function tokenPrice() external view returns (uint256);
    function assetBalanceOf(address owner) external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
}
