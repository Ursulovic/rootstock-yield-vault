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
    bool public transferBroken = true;
    uint256 public reportedBalance;

    /// @notice Backward-compatible 2-arg toggle: leaves transferPosition broken.
    function setBroken(bool _rate, bool _balance) external {
        rateBroken = _rate;
        balanceBroken = _balance;
    }

    /// @notice Full 3-arg toggle so a view-bricked-but-transferable adapter can
    ///         be simulated for the in-kind escape-hatch tests.
    function setBroken(bool _rate, bool _balance, bool _transfer) external {
        rateBroken = _rate;
        balanceBroken = _balance;
        transferBroken = _transfer;
    }

    function setBalance(uint256 b) external {
        reportedBalance = b;
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
        return reportedBalance;
    }

    function getRate() external view returns (uint256) {
        if (rateBroken) revert("protocol down");
        return 0;
    }

    function transferPosition(address, uint256, uint256) external view {
        if (transferBroken) revert("protocol down");
    }

    function getProtocolName() external pure returns (string memory) {
        return "Broken";
    }
}
