// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20YieldVault} from "./ERC20YieldVault.sol";
import {IERC20LendingAdapter} from "./interfaces/IERC20LendingAdapter.sol";

contract VaultFactory {
    mapping(address => bool) public isVault;
    address[] public allVaults;
    mapping(address => address[]) public vaultsByAsset;

    event VaultCreated(
        address indexed vault,
        address indexed asset,
        string name,
        string symbol
    );

    function createVault(
        address _asset,
        IERC20LendingAdapter[] memory _adapters,
        uint256 _cooldownPeriod,
        uint256 _rateThreshold,
        uint256 _callerRewardBps,
        string memory _name,
        string memory _symbol
    ) external returns (address) {
        ERC20YieldVault vault = new ERC20YieldVault(
            _asset,
            _adapters,
            _cooldownPeriod,
            _rateThreshold,
            _callerRewardBps,
            _name,
            _symbol
        );

        isVault[address(vault)] = true;
        allVaults.push(address(vault));
        vaultsByAsset[_asset].push(address(vault));

        emit VaultCreated(address(vault), _asset, _name, _symbol);
        return address(vault);
    }

    function vaultCount() external view returns (uint256) {
        return allVaults.length;
    }

    function getVaultsForAsset(address _asset) external view returns (address[] memory) {
        return vaultsByAsset[_asset];
    }
}
