// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20LendingAdapter} from "../interfaces/IERC20LendingAdapter.sol";
import {IiERC20Token} from "../interfaces/IiERC20Token.sol";

contract SovrynERC20Adapter is IERC20LendingAdapter {
    using SafeERC20 for IERC20;

    IiERC20Token public immutable iToken;
    IERC20 public immutable underlying;
    address public vault;

    modifier onlyVault() {
        require(msg.sender == vault, "only vault");
        _;
    }

    constructor(address _iToken, address _underlying) {
        iToken = IiERC20Token(_iToken);
        underlying = IERC20(_underlying);
        // Infinite approval so mint() can pull tokens without per-tx approve
        underlying.forceApprove(_iToken, type(uint256).max);
    }

    function setVault(address _vault) external {
        require(vault == address(0), "vault already set");
        require(_vault != address(0), "zero address");
        vault = _vault;
    }

    function deposit(uint256 amount) external onlyVault {
        underlying.safeTransferFrom(vault, address(this), amount);
        iToken.mint(address(this), amount);
    }

    function withdraw(uint256 amount) external onlyVault returns (uint256) {
        uint256 price = iToken.tokenPrice();
        // Round up to ensure we withdraw at least `amount`
        uint256 burnAmount = (amount * 1e18 + price - 1) / price;

        // burn sends underlying directly to the receiver (vault)
        uint256 actualAmount = iToken.burn(vault, burnAmount);
        return actualAmount;
    }

    function getBalance() external view returns (uint256) {
        return iToken.assetBalanceOf(address(this));
    }

    function getRate() external view returns (uint256) {
        // Sovryn returns annualized rate already (1e18 = 100%)
        return iToken.supplyInterestRate();
    }

    function getProtocolName() external pure returns (string memory) {
        return "Sovryn";
    }
}
