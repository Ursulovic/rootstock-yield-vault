// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ILendingAdapter} from "../../src/interfaces/ILendingAdapter.sol";
import {IERC20LendingAdapter} from "../../src/interfaces/IERC20LendingAdapter.sol";

/// @notice Test double simulating a bricked protocol: every query reverts
///         (toggleable), deposits/withdrawals revert. Implements both adapter
///         interfaces so either vault can register it.
contract MockBrokenAdapter {
    address public vault;
    bool public rateBroken = true;
    bool public balanceBroken = true;

    function setBroken(bool _rate, bool _balance) external {
        rateBroken = _rate;
        balanceBroken = _balance;
    }

    function setVault(address _vault) external {
        require(vault == address(0), "vault already set");
        require(_vault != address(0), "zero address");
        vault = _vault;
    }

    function deposit() external payable {
        revert("protocol down");
    }

    function deposit(uint256) external pure {
        revert("protocol down");
    }

    function withdraw(uint256) external pure returns (uint256) {
        revert("protocol down");
    }

    function getBalance() external view returns (uint256) {
        if (balanceBroken) revert("protocol down");
        return 0;
    }

    function getRate() external view returns (uint256) {
        if (rateBroken) revert("protocol down");
        return 0;
    }

    function transferPosition(address, uint256, uint256) external pure {
        revert("protocol down");
    }

    function getProtocolName() external pure returns (string memory) {
        return "Broken";
    }
}
