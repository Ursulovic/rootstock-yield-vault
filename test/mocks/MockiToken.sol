// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Mock Sovryn iRBTC for testing (bZx LoanTokenLogicWrbtcLM pattern)
contract MockiToken {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    uint256 public tokenPrice;
    uint256 public supplyInterestRate;

    constructor() {
        tokenPrice = 1e18; // 1:1 initially
        supplyInterestRate = 0;
    }

    function mintWithBTC(address receiver, bool /* useLM */) external payable returns (uint256) {
        require(msg.value > 0, "zero mint");
        uint256 tokens = msg.value * 1e18 / tokenPrice;
        balanceOf[receiver] += tokens;
        totalSupply += tokens;
        return tokens;
    }

    function burnToBTC(address receiver, uint256 burnAmount, bool /* useLM */) external returns (uint256) {
        require(balanceOf[msg.sender] >= burnAmount, "insufficient balance");
        uint256 underlyingAmount = burnAmount * tokenPrice / 1e18;
        balanceOf[msg.sender] -= burnAmount;
        totalSupply -= burnAmount;
        (bool success,) = receiver.call{value: underlyingAmount}("");
        require(success, "transfer failed");
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

    /// @notice Simulate interest accrual by recalculating token price from balance
    function accrueInterest() external {
        if (totalSupply > 0) {
            tokenPrice = address(this).balance * 1e18 / totalSupply;
        }
    }

    receive() external payable {}
}
