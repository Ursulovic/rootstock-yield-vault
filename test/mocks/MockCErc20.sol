// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Mock Tropykus kToken for ERC-20 markets (Compound V2 CErc20 pattern)
contract MockCErc20 {
    IERC20 public underlying;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    uint256 public exchangeRateStored;
    uint256 public supplyRatePerBlock;

    constructor(address _underlying) {
        underlying = IERC20(_underlying);
        exchangeRateStored = 1e18;
        supplyRatePerBlock = 0;
    }

    function mint(uint256 mintAmount) external returns (uint256) {
        underlying.transferFrom(msg.sender, address(this), mintAmount);
        uint256 tokens = mintAmount * 1e18 / exchangeRateStored;
        balanceOf[msg.sender] += tokens;
        totalSupply += tokens;
        return 0; // 0 = success
    }

    function redeem(uint256 redeemTokens) external returns (uint256) {
        require(balanceOf[msg.sender] >= redeemTokens, "insufficient balance");
        uint256 underlyingAmount = redeemTokens * exchangeRateStored / 1e18;
        balanceOf[msg.sender] -= redeemTokens;
        totalSupply -= redeemTokens;
        underlying.transfer(msg.sender, underlyingAmount);
        return 0;
    }

    function redeemUnderlying(uint256 redeemAmount) external returns (uint256) {
        uint256 tokensNeeded = (redeemAmount * 1e18 + exchangeRateStored - 1) / exchangeRateStored;
        require(balanceOf[msg.sender] >= tokensNeeded, "insufficient balance");
        balanceOf[msg.sender] -= tokensNeeded;
        totalSupply -= tokensNeeded;
        underlying.transfer(msg.sender, redeemAmount);
        return 0;
    }

    // Test helpers
    function setExchangeRateStored(uint256 _rate) external {
        exchangeRateStored = _rate;
    }

    function setSupplyRatePerBlock(uint256 _rate) external {
        supplyRatePerBlock = _rate;
    }

    function accrueInterest() external {
        if (totalSupply > 0) {
            exchangeRateStored = underlying.balanceOf(address(this)) * 1e18 / totalSupply;
        }
    }
}
