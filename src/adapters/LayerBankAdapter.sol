// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILendingAdapter} from "../interfaces/ILendingAdapter.sol";
import {ILayerBankPool} from "../interfaces/ILayerBankPool.sol";
import {IWRBTC} from "../interfaces/IWRBTC.sol";

/// @notice Routes the vault's native rBTC into LayerBank's WRBTC market.
///         LayerBank is an Aave V3 fork, so the market is WRBTC (ERC-20),
///         not native — the adapter wraps on deposit and unwraps on withdraw.
contract LayerBankAdapter is ILendingAdapter {
    using SafeERC20 for IERC20;

    ILayerBankPool public immutable pool;
    IWRBTC public immutable wrbtc;
    IERC20 public immutable aToken; // rebasing receipt token, 1:1 with underlying
    address public vault;

    modifier onlyVault() {
        require(msg.sender == vault, "only vault");
        _;
    }

    constructor(address _pool, address _wrbtc) {
        pool = ILayerBankPool(_pool);
        wrbtc = IWRBTC(_wrbtc);
        // aToken address is fixed per reserve in Aave-style pools
        aToken = IERC20(ILayerBankPool(_pool).getReserveData(_wrbtc).aTokenAddress);
        require(address(aToken) != address(0), "market not listed");
        // Infinite approval so supply() can pull WRBTC without per-tx approve
        IERC20(_wrbtc).forceApprove(_pool, type(uint256).max);
    }

    function setVault(address _vault) external {
        require(vault == address(0), "vault already set");
        require(_vault != address(0), "zero address");
        vault = _vault;
    }

    function deposit() external payable onlyVault {
        wrbtc.deposit{value: msg.value}();
        pool.supply(address(wrbtc), msg.value, address(this), 0);
    }

    function withdraw(uint256 amount) external onlyVault returns (uint256) {
        uint256 received = pool.withdraw(address(wrbtc), amount, address(this));
        require(received >= amount, "layerbank: insufficient withdrawal");

        // Unwrap, then forward — the vault only accepts rBTC from its adapters
        wrbtc.withdraw(received);
        (bool success,) = vault.call{value: received}("");
        require(success, "rBTC transfer failed");
        return received;
    }

    function getBalance() external view returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    function getRate() external view returns (uint256) {
        // currentLiquidityRate is the annualized supply rate in ray (1e27);
        // the vault compares rates on a 1e18 = 100% APR scale
        return pool.getReserveData(address(wrbtc)).currentLiquidityRate / 1e9;
    }

    function getProtocolName() external pure returns (string memory) {
        return "LayerBank";
    }

    // Must stay empty — WRBTC pays out via transfer() with a 2300-gas stipend
    receive() external payable {}
}
