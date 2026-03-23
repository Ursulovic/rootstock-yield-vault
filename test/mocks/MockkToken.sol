// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Mock Tropykus kRBTC for testing (Compound V2 cETH pattern)
contract MockkToken {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    uint256 public exchangeRateStored;
    uint256 public supplyRatePerBlock;

    constructor() {
        exchangeRateStored = 1e18; // 1:1 initially
        supplyRatePerBlock = 0;
    }

    function mint() external payable {
        require(msg.value > 0, "zero mint");
        uint256 tokens = msg.value * 1e18 / exchangeRateStored;
        balanceOf[msg.sender] += tokens;
        totalSupply += tokens;
    }

    function redeem(uint256 redeemTokens) external returns (uint256) {
        require(balanceOf[msg.sender] >= redeemTokens, "insufficient balance");
        uint256 underlyingAmount = redeemTokens * exchangeRateStored / 1e18;
        balanceOf[msg.sender] -= redeemTokens;
        totalSupply -= redeemTokens;
        // Uses .transfer() like real Compound cETH (2300 gas stipend)
        payable(msg.sender).transfer(underlyingAmount);
        return 0;
    }

    function redeemUnderlying(uint256 redeemAmount) external returns (uint256) {
        uint256 tokensNeeded = (redeemAmount * 1e18 + exchangeRateStored - 1) / exchangeRateStored;
        require(balanceOf[msg.sender] >= tokensNeeded, "insufficient balance");
        balanceOf[msg.sender] -= tokensNeeded;
        totalSupply -= tokensNeeded;
        payable(msg.sender).transfer(redeemAmount);
        return 0;
    }

    // Test helpers
    function setExchangeRateStored(uint256 _rate) external {
        exchangeRateStored = _rate;
    }

    function setSupplyRatePerBlock(uint256 _rate) external {
        supplyRatePerBlock = _rate;
    }

    /// @notice Simulate interest accrual by recalculating exchange rate from balance
    function accrueInterest() external {
        if (totalSupply > 0) {
            exchangeRateStored = address(this).balance * 1e18 / totalSupply;
        }
    }

    receive() external payable {}
}
