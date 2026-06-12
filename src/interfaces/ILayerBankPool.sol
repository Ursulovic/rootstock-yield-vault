// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal interface for LayerBank's pool on Rootstock. LayerBank V2
///         is an Aave V3 fork (verified on-chain: PoolInstance implementation
///         behind an EIP-1967 proxy at 0x526D06c65777eA6D56d7a1Dd47cD79230dDf72E9,
///         getReserveData returns Aave's 15-field ReserveDataLegacy).
interface ILayerBankPool {
    struct ReserveConfigurationMap {
        uint256 data;
    }

    /// @dev Aave V3 DataTypes.ReserveDataLegacy — exact on-chain layout
    struct ReserveDataLegacy {
        ReserveConfigurationMap configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate; // supply APR in ray (1e27 = 100%)
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40 lastUpdateTimestamp;
        uint16 id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint128 accruedToTreasury;
        uint128 unbacked;
        uint128 isolationModeTotalDebt;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    /// @return The underlying amount actually withdrawn
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    function getReserveData(address asset) external view returns (ReserveDataLegacy memory);
}
