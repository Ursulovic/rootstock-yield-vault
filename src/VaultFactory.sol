// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20YieldVault} from "./ERC20YieldVault.sol";
import {IERC20LendingAdapter} from "./interfaces/IERC20LendingAdapter.sol";

contract VaultFactory is Ownable {
    bool public shutdown;

    mapping(address => bool) public isVault;
    address[] public allVaults;
    mapping(address => address[]) public vaultsByAsset;
    mapping(address => bool) public trustedAdapters;

    event VaultCreated(address indexed vault, address indexed asset, string name, string symbol);
    event VaultRemoved(address indexed vault);
    event AdapterTrusted(address indexed adapter);
    event AdapterDistrusted(address indexed adapter);
    event FactoryShutdown();

    constructor() Ownable(msg.sender) {}

    function trustAdapter(address _adapter) external onlyOwner {
        require(_adapter != address(0), "zero address");
        trustedAdapters[_adapter] = true;
        emit AdapterTrusted(_adapter);
    }

    function distrustAdapter(address _adapter) external onlyOwner {
        trustedAdapters[_adapter] = false;
        emit AdapterDistrusted(_adapter);
    }

    function createVault(
        address _asset,
        IERC20LendingAdapter[] memory _adapters,
        uint256 _cooldownPeriod,
        uint256 _rateThreshold,
        uint256 _callerRewardBps,
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
            _cooldownPeriod,
            _rateThreshold,
            _callerRewardBps,
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

    function removeVault(address _vault) external onlyOwner {
        isVault[_vault] = false;
        emit VaultRemoved(_vault);
    }

    function shutdownFactory() external onlyOwner {
        shutdown = true;
        emit FactoryShutdown();
    }

    function vaultCount() external view returns (uint256) {
        return allVaults.length;
    }

    function getVaultsForAsset(address _asset) external view returns (address[] memory) {
        return vaultsByAsset[_asset];
    }
}
