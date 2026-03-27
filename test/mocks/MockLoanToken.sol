// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Mock Sovryn iToken for ERC-20 markets (bZx LoanTokenLogicLM pattern)
contract MockLoanToken {
    IERC20 public underlying;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    uint256 public tokenPrice;
    uint256 public supplyInterestRate;

    constructor(address _underlying) {
        underlying = IERC20(_underlying);
        tokenPrice = 1e18;
        supplyInterestRate = 0;
    }

    function mint(address receiver, uint256 depositAmount) external returns (uint256) {
        underlying.transferFrom(msg.sender, address(this), depositAmount);
        uint256 tokens = depositAmount * 1e18 / tokenPrice;
        balanceOf[receiver] += tokens;
        totalSupply += tokens;
        return tokens;
    }

    function burn(address receiver, uint256 burnAmount) external returns (uint256) {
        require(balanceOf[msg.sender] >= burnAmount, "insufficient balance");
        uint256 underlyingAmount = burnAmount * tokenPrice / 1e18;
        balanceOf[msg.sender] -= burnAmount;
        totalSupply -= burnAmount;
        underlying.transfer(receiver, underlyingAmount);
        return underlyingAmount;
    }

    function assetBalanceOf(address owner) external view returns (uint256) {
        return balanceOf[owner] * tokenPrice / 1e18;
    }

    // Test helpers
    function setTokenPrice(uint256 _price) external {
        tokenPrice = _price;
    }

    function setSupplyInterestRate(uint256 _rate) external {
        supplyInterestRate = _rate;
    }

    function accrueInterest() external {
        if (totalSupply > 0) {
            tokenPrice = underlying.balanceOf(address(this)) * 1e18 / totalSupply;
        }
    }
}
