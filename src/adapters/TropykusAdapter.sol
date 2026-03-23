// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ILendingAdapter} from "../interfaces/ILendingAdapter.sol";
import {IkToken} from "../interfaces/IkToken.sol";

contract TropykusAdapter is ILendingAdapter {
    uint256 private constant BLOCKS_PER_YEAR = 1_051_200; // 30s blocks on Rootstock

    IkToken public immutable kToken;
    address public vault;

    modifier onlyVault() {
        require(msg.sender == vault, "only vault");
        _;
    }

    constructor(address _kToken) {
        kToken = IkToken(_kToken);
    }

    function setVault(address _vault) external {
        require(vault == address(0), "vault already set");
        require(_vault != address(0), "zero address");
        vault = _vault;
    }

    function deposit() external payable onlyVault {
        kToken.mint{value: msg.value}();
    }

    function withdraw(uint256 amount) external onlyVault returns (uint256) {
        uint256 balanceBefore = address(this).balance;
        uint256 err = kToken.redeemUnderlying(amount);
        require(err == 0, "redeem failed");
        uint256 received = address(this).balance - balanceBefore;
        (bool success,) = vault.call{value: received}("");
        require(success, "rBTC transfer failed");
        return received;
    }

    function getBalance() external view returns (uint256) {
        uint256 kTokenBal = kToken.balanceOf(address(this));
        if (kTokenBal == 0) return 0;
        return kTokenBal * kToken.exchangeRateStored() / 1e18;
    }

    function getRate() external view returns (uint256) {
        return kToken.supplyRatePerBlock() * BLOCKS_PER_YEAR;
    }

    function getProtocolName() external pure returns (string memory) {
        return "Tropykus";
    }

    // Must be empty — kToken uses .transfer() with 2300 gas limit
    receive() external payable {}
}
