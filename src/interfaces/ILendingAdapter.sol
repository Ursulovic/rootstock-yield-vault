// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ILendingAdapter {
    function deposit() external payable;
    function withdraw(uint256 amount) external returns (uint256);
    function getBalance() external view returns (uint256);
    function getRate() external view returns (uint256);
    function getProtocolName() external pure returns (string memory);
    function setVault(address vault) external;
}
