// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILendingAdapter} from "../interfaces/ILendingAdapter.sol";
import {ILayerBankPool} from "../interfaces/ILayerBankPool.sol";
import {IWRBTC} from "../interfaces/IWRBTC.sol";

/// @title LayerBankAdapter
/// @notice Routes the vault's native rBTC into LayerBank's WRBTC market.
///         LayerBank is an Aave V3 fork, so the market is WRBTC (ERC-20),
///         not native — the adapter wraps on deposit and unwraps on withdraw.
/// @dev Holds rebasing aTokens as its position; balance grows in place
///      without accrual calls. Only the vault may deposit or withdraw.
contract LayerBankAdapter is ILendingAdapter {
    using SafeERC20 for IERC20;

    /// @notice LayerBank pool (Aave V3 fork) this adapter supplies to.
    ILayerBankPool public immutable pool;

    /// @notice Wrapped rBTC token used as the underlying of the LayerBank market.
    IWRBTC public immutable wrbtc;

    /// @notice LayerBank receipt token for the WRBTC reserve — a rebasing
    ///         aToken, 1:1 with underlying.
    IERC20 public immutable aToken;

    /// @notice Vault allowed to call deposit/withdraw; set once via setVault.
    address public vault;

    modifier onlyVault() {
        require(msg.sender == vault, "only vault");
        _;
    }

    /// @notice Wires the adapter to a LayerBank pool and the WRBTC token,
    ///         resolves the reserve's aToken, and grants the pool an infinite
    ///         WRBTC allowance so supply() can pull without per-tx approvals.
    /// @dev Reverts if the WRBTC market is not listed on the pool.
    /// @param _pool LayerBank pool (Aave V3 fork) address.
    /// @param _wrbtc WRBTC token address.
    constructor(address _pool, address _wrbtc) {
        pool = ILayerBankPool(_pool);
        wrbtc = IWRBTC(_wrbtc);
        // aToken address is fixed per reserve in Aave-style pools
        aToken = IERC20(ILayerBankPool(_pool).getReserveData(_wrbtc).aTokenAddress);
        require(address(aToken) != address(0), "market not listed");
        // Infinite approval so supply() can pull WRBTC without per-tx approve
        IERC20(_wrbtc).forceApprove(_pool, type(uint256).max);
    }

    /// @notice Sets the vault address that is allowed to call deposit/withdraw.
    /// @dev One-shot: reverts if the vault is already set or `_vault` is zero.
    /// @param _vault Address of the vault.
    function setVault(address _vault) external {
        require(vault == address(0), "vault already set");
        require(_vault != address(0), "zero address");
        vault = _vault;
    }

    /// @notice Deposits native rBTC sent by the vault: wraps it into WRBTC
    ///         and supplies it to the LayerBank pool.
    function deposit() external payable onlyVault {
        wrbtc.deposit{value: msg.value}();
        pool.supply(address(wrbtc), msg.value, address(this), 0);
    }

    /// @notice Withdraws WRBTC from the LayerBank pool, unwraps it to native
    ///         rBTC, and forwards it to the vault.
    /// @dev Reverts if the pool returns less than requested or if the rBTC
    ///      transfer to the vault fails.
    /// @param amount Amount of underlying (WRBTC/rBTC, 18 decimals) to withdraw.
    /// @return Amount of rBTC actually forwarded to the vault.
    function withdraw(uint256 amount) external onlyVault returns (uint256) {
        uint256 received = pool.withdraw(address(wrbtc), amount, address(this));
        require(received >= amount, "layerbank: insufficient withdrawal");

        // Unwrap, then forward — the vault only accepts rBTC from its adapters
        wrbtc.withdraw(received);
        (bool success,) = vault.call{value: received}("");
        require(success, "rBTC transfer failed");
        return received;
    }

    /// @notice Returns the adapter's position in the LayerBank market.
    /// @dev aTokens rebase, so the aToken balance equals the underlying
    ///      (principal plus accrued interest), 1:1.
    /// @return Underlying rBTC value of the position, in wei.
    function getBalance() external view returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    /// @notice Returns the current annualized supply rate of the WRBTC market.
    /// @return Supply APR normalized to the vault's 1e18 = 100% scale.
    function getRate() external view returns (uint256) {
        // currentLiquidityRate is the annualized supply rate in ray (1e27);
        // the vault compares rates on a 1e18 = 100% APR scale
        return pool.getReserveData(address(wrbtc)).currentLiquidityRate / 1e9;
    }

    /// @notice Returns the human-readable name of the underlying protocol.
    /// @return Protocol name, "LayerBank".
    function getProtocolName() external pure returns (string memory) {
        return "LayerBank";
    }

    /// @notice Accepts native rBTC unwrapped from WRBTC.
    /// @dev Must stay empty — WRBTC pays out via transfer() with a 2300-gas
    ///      stipend, which leaves no gas for any logic here.
    receive() external payable {}
}
