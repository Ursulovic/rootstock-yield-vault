// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20LendingAdapter} from "../interfaces/IERC20LendingAdapter.sol";
import {ILayerBankPool} from "../interfaces/ILayerBankPool.sol";

/// @notice Routes an ERC-20 vault's funds into the matching LayerBank market
///         (Aave V3 fork: supply mints a rebasing 1:1 aToken).
contract LayerBankERC20Adapter is IERC20LendingAdapter {
    using SafeERC20 for IERC20;

    ILayerBankPool public immutable pool;
    IERC20 public immutable underlying;
    IERC20 public immutable aToken;
    address public vault;

    modifier onlyVault() {
        require(msg.sender == vault, "only vault");
        _;
    }

    constructor(address _pool, address _underlying) {
        pool = ILayerBankPool(_pool);
        underlying = IERC20(_underlying);
        aToken = IERC20(ILayerBankPool(_pool).getReserveData(_underlying).aTokenAddress);
        require(address(aToken) != address(0), "market not listed");
        // Infinite approval so supply() can pull tokens without per-tx approve
        underlying.forceApprove(_pool, type(uint256).max);
    }

    function setVault(address _vault) external {
        require(vault == address(0), "vault already set");
        require(_vault != address(0), "zero address");
        vault = _vault;
    }

    function deposit(uint256 amount) external onlyVault {
        // Pulls from the vault, which granted this adapter approval in its
        // constructor. Safe because `onlyVault` is the sole caller and the
        // vault only ever passes its own funds.
        underlying.safeTransferFrom(vault, address(this), amount);
        pool.supply(address(underlying), amount, address(this), 0);
    }

    function withdraw(uint256 amount) external onlyVault returns (uint256) {
        // withdraw() sends the underlying directly to the vault
        uint256 received = pool.withdraw(address(underlying), amount, vault);
        require(received >= amount, "layerbank: insufficient withdrawal");
        return received;
    }

    function getBalance() external view returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    function getRate() external view returns (uint256) {
        // currentLiquidityRate is the annualized supply rate in ray (1e27);
        // the vault compares rates on a 1e18 = 100% APR scale
        return pool.getReserveData(address(underlying)).currentLiquidityRate / 1e9;
    }

    function getProtocolName() external pure returns (string memory) {
        return "LayerBank";
    }
}
