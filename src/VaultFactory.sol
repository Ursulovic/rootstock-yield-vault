// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20YieldVault} from "./ERC20YieldVault.sol";
import {IERC20LendingAdapter} from "./interfaces/IERC20LendingAdapter.sol";

/// @notice Deploys ERC-4626 yield vaults for ERC-20 assets and keeps a registry
///         of deployed vaults and the adapters they are allowed to use.
/// @dev Vault creation is permissionless but restricted to owner-approved
///      adapters, so a vault deployed through the factory can only route funds
///      into vetted lending markets. The factory owner becomes the guardian of
///      every vault it creates. The factory can be permanently shut down to
///      stop new deployments; existing vaults are unaffected.
/// @custom:security-contact ivanursulovic@protonmail.com
contract VaultFactory is Ownable {
    /// @notice True once the factory has been permanently shut down; blocks new vault creation.
    bool public shutdown;

    /// @notice True for every vault deployed by this factory and not since removed from the registry.
    mapping(address => bool) public isVault;

    /// @notice All vaults ever deployed by this factory, in creation order.
    address[] public allVaults;

    /// @notice Vaults deployed by this factory, grouped by underlying asset.
    mapping(address => address[]) public vaultsByAsset;

    /// @notice Adapters approved by the owner for use in newly created vaults.
    mapping(address => bool) public trustedAdapters;

    /// @notice Emitted when a new vault is deployed through the factory.
    /// @param vault Address of the newly deployed vault.
    /// @param asset Underlying ERC-20 asset of the vault.
    /// @param name ERC-20 name of the vault's share token.
    /// @param symbol ERC-20 symbol of the vault's share token.
    event VaultCreated(address indexed vault, address indexed asset, string name, string symbol);

    /// @notice Emitted when a vault is delisted from the registry.
    /// @param vault Address of the delisted vault.
    event VaultRemoved(address indexed vault);

    /// @notice Emitted when an adapter is approved for use in new vaults.
    /// @param adapter Address of the approved adapter.
    event AdapterTrusted(address indexed adapter);

    /// @notice Emitted when an adapter's approval is revoked.
    /// @param adapter Address of the revoked adapter.
    event AdapterDistrusted(address indexed adapter);

    /// @notice Emitted when the factory is permanently shut down.
    event FactoryShutdown();

    /// @notice Sets the deployer as the factory owner.
    constructor() Ownable(msg.sender) {}

    /// @notice Approves an adapter for use in newly created vaults.
    /// @dev Only affects future vault deployments; already-deployed vaults keep their adapter set.
    /// @param _adapter Address of the lending adapter to approve.
    function trustAdapter(address _adapter) external onlyOwner {
        require(_adapter != address(0), "zero address");
        trustedAdapters[_adapter] = true;
        emit AdapterTrusted(_adapter);
    }

    /// @notice Revokes an adapter's approval for use in newly created vaults.
    /// @dev Does not remove the adapter from vaults that already use it.
    /// @param _adapter Address of the lending adapter to revoke.
    function distrustAdapter(address _adapter) external onlyOwner {
        trustedAdapters[_adapter] = false;
        emit AdapterDistrusted(_adapter);
    }

    /// @notice Deploys a new ERC20YieldVault and registers it with the factory.
    /// @dev Permissionless, but every adapter passed in must be trusted by the
    ///      owner. The factory owner is set as the vault's guardian. Rate
    ///      parameters use the vault's 1e18 = 100% APR scale.
    /// @param _asset Underlying ERC-20 asset the vault accepts.
    /// @param _adapters Lending adapters the vault may allocate to; each must be trusted.
    /// @param _cooldownPeriod Minimum time in seconds between rebalances.
    /// @param _rateThreshold Minimum rate advantage (1e18 = 100% APR) required to trigger a rebalance.
    /// @param _callerRewardBps Share of accrued yield, in basis points, paid to the rebalance caller.
    /// @param _maxSaneRate Hard ceiling on any rate considered during adapter selection; rates above it indicate a manipulated or illiquid market and are ignored.
    /// @param _adapterCapBps Per-adapter concentration cap in basis points of total assets.
    /// @param _tvlCap Ceiling on totalAssets(); use type(uint256).max for an uncapped vault.
    /// @param _utilizationCeilingBps Per-venue utilization ceiling in basis points; markets at or above it receive no new allocation.
    /// @param _name ERC-20 name for the vault's share token.
    /// @param _symbol ERC-20 symbol for the vault's share token.
    /// @return Address of the newly deployed vault.
    function createVault(
        address _asset,
        IERC20LendingAdapter[] memory _adapters,
        uint256 _cooldownPeriod,
        uint256 _rateThreshold,
        uint256 _callerRewardBps,
        uint256 _maxSaneRate,
        uint256 _adapterCapBps,
        uint256 _tvlCap,
        uint256 _utilizationCeilingBps,
        string memory _name,
        string memory _symbol
    ) external returns (address) {
        require(!shutdown, "factory is shutdown");

        for (uint256 i = 0; i < _adapters.length; i++) {
            require(trustedAdapters[address(_adapters[i])], "adapter not trusted");
        }

        ERC20YieldVault vault = new ERC20YieldVault(
            _asset,
            _adapters,
            ERC20YieldVault.VaultConfig({
                cooldownPeriod: _cooldownPeriod,
                rateThreshold: _rateThreshold,
                callerRewardBps: _callerRewardBps,
                maxSaneRate: _maxSaneRate,
                adapterCapBps: _adapterCapBps,
                tvlCap: _tvlCap,
                utilizationCeilingBps: _utilizationCeilingBps
            }),
            _name,
            _symbol,
            owner()
        );

        isVault[address(vault)] = true;
        allVaults.push(address(vault));
        vaultsByAsset[_asset].push(address(vault));

        emit VaultCreated(address(vault), _asset, _name, _symbol);
        return address(vault);
    }

    /// @notice Delists a vault from the registry.
    /// @dev Only clears the `isVault` flag; the vault itself keeps operating
    ///      and remains in `allVaults` and `vaultsByAsset`.
    /// @param _vault Address of the vault to delist.
    function removeVault(address _vault) external onlyOwner {
        isVault[_vault] = false;
        emit VaultRemoved(_vault);
    }

    /// @notice Permanently shuts down the factory, blocking all future vault creation.
    /// @dev Irreversible. Existing vaults are unaffected.
    function shutdownFactory() external onlyOwner {
        shutdown = true;
        emit FactoryShutdown();
    }

    /// @notice Returns the total number of vaults ever deployed by this factory.
    /// @return Number of deployed vaults.
    function vaultCount() external view returns (uint256) {
        return allVaults.length;
    }

    /// @notice Returns all vaults deployed for a given underlying asset.
    /// @param _asset Underlying ERC-20 asset to query.
    /// @return Addresses of vaults deployed for the asset.
    function getVaultsForAsset(address _asset) external view returns (address[] memory) {
        return vaultsByAsset[_asset];
    }
}
