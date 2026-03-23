// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Tropykus kRBTC interface (Compound V2 cETH pattern)
interface IkToken {
    function mint() external payable;
    function redeem(uint256 redeemTokens) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function supplyRatePerBlock() external view returns (uint256);
}
