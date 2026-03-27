// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20LendingAdapter} from "../interfaces/IERC20LendingAdapter.sol";
import {IkERC20Token} from "../interfaces/IkERC20Token.sol";

contract TropykusERC20Adapter is IERC20LendingAdapter {
    using SafeERC20 for IERC20;

    uint256 private constant BLOCKS_PER_YEAR = 1_051_200; // 30s blocks on Rootstock

    IkERC20Token public immutable kToken;
    IERC20 public immutable underlying;
    address public vault;

    modifier onlyVault() {
        require(msg.sender == vault, "only vault");
        _;
    }

    constructor(address _kToken, address _underlying) {
        kToken = IkERC20Token(_kToken);
        underlying = IERC20(_underlying);
        // Infinite approval so mint() can pull tokens without per-tx approve
        underlying.forceApprove(_kToken, type(uint256).max);
    }

    function setVault(address _vault) external {
        require(vault == address(0), "vault already set");
        require(_vault != address(0), "zero address");
        vault = _vault;
    }

    function deposit(uint256 amount) external onlyVault {
        underlying.safeTransferFrom(vault, address(this), amount);
        uint256 err = kToken.mint(amount);
        require(err == 0, "mint failed");
    }

    function withdraw(uint256 amount) external onlyVault returns (uint256) {
        uint256 balanceBefore = underlying.balanceOf(address(this));
        uint256 err = kToken.redeemUnderlying(amount);
        require(err == 0, "redeem failed");
        uint256 received = underlying.balanceOf(address(this)) - balanceBefore;
        underlying.safeTransfer(vault, received);
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
}
