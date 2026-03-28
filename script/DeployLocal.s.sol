// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {YieldVault} from "../src/YieldVault.sol";
import {TropykusAdapter} from "../src/adapters/TropykusAdapter.sol";
import {SovrynAdapter} from "../src/adapters/SovrynAdapter.sol";
import {ILendingAdapter} from "../src/interfaces/ILendingAdapter.sol";
import {MockWRBTC} from "../test/mocks/MockWRBTC.sol";
import {MockkToken} from "../test/mocks/MockkToken.sol";
import {MockiToken} from "../test/mocks/MockiToken.sol";

contract DeployLocal is Script {
    uint256 constant COOLDOWN = 3600;
    uint256 constant THRESHOLD = 5e14;
    uint256 constant REWARD_BPS = 100;

    function run() external {
        uint256 deployerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy mock protocol contracts
        MockWRBTC wrbtc = new MockWRBTC();
        console.log("WRBTC:", address(wrbtc));

        MockkToken mockKToken = new MockkToken();
        console.log("MockkToken (Tropykus):", address(mockKToken));

        MockiToken mockIToken = new MockiToken();
        console.log("MockiToken (Sovryn):", address(mockIToken));

        // 2. Set realistic rates: Tropykus 5%, Sovryn 3%
        mockKToken.setSupplyRatePerBlock(47564687975);
        mockIToken.setSupplyInterestRate(3e16);

        // 3. Deploy adapters
        TropykusAdapter tropykus = new TropykusAdapter(address(mockKToken));
        console.log("TropykusAdapter:", address(tropykus));

        SovrynAdapter sovryn = new SovrynAdapter(address(mockIToken));
        console.log("SovrynAdapter:", address(sovryn));

        // 4. Deploy vault
        ILendingAdapter[] memory adapters = new ILendingAdapter[](2);
        adapters[0] = ILendingAdapter(address(tropykus));
        adapters[1] = ILendingAdapter(address(sovryn));

        YieldVault vault = new YieldVault(
            address(wrbtc),
            adapters,
            COOLDOWN,
            THRESHOLD,
            REWARD_BPS
        );
        console.log("YieldVault:", address(vault));

        vm.stopBroadcast();
    }
}
