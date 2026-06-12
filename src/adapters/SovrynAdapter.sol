// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ILendingAdapter} from "../interfaces/ILendingAdapter.sol";
import {IiToken} from "../interfaces/IiToken.sol";

contract SovrynAdapter is ILendingAdapter {
    IiToken public immutable iToken;
    address public vault;

    modifier onlyVault() {
        require(msg.sender == vault, "only vault");
        _;
    }

    constructor(address _iToken) {
        iToken = IiToken(_iToken);
    }

    function setVault(address _vault) external {
        require(vault == address(0), "vault already set");
        require(_vault != address(0), "zero address");
        vault = _vault;
    }

    function deposit() external payable onlyVault {
        iToken.mintWithBTC{value: msg.value}(address(this), false);
    }

    function withdraw(uint256 amount) external onlyVault returns (uint256) {
        uint256 price = iToken.tokenPrice();
        // Round up to ensure we withdraw at least `amount`
        uint256 burnAmount = (amount * 1e18 + price - 1) / price;

        // Burn to self, then forward — the vault only accepts rBTC from its adapters
        uint256 actualAmount = iToken.burnToBTC(address(this), burnAmount, false);
        require(actualAmount >= amount, "sovryn: insufficient withdrawal");

        (bool success,) = vault.call{value: actualAmount}("");
        require(success, "rBTC transfer failed");
        return actualAmount;
    }

    function getBalance() external view returns (uint256) {
        return iToken.assetBalanceOf(address(this));
    }

    function getRate() external view returns (uint256) {
        // Sovryn (bZx) reports the annual rate percent-scaled: 1e18 = 1%
        // (verified against real iRBTC tokenPrice growth on mainnet).
        // Normalize to the vault's 1e18 = 100% scale.
        return iToken.supplyInterestRate() / 100;
    }

    function getProtocolName() external pure returns (string memory) {
        return "Sovryn";
    }

    receive() external payable {}
}
