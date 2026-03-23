// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {YieldVault} from "../src/YieldVault.sol";
import {TropykusAdapter} from "../src/adapters/TropykusAdapter.sol";
import {SovrynAdapter} from "../src/adapters/SovrynAdapter.sol";
import {ILendingAdapter} from "../src/interfaces/ILendingAdapter.sol";

contract Deploy is Script {
    // Rootstock Testnet addresses
    address constant WRBTC = 0x69FE5cEC81D5eF92600c1A0dB1F11986AB3758Ab;
    address constant KRBTC = 0x5B35072Cd6110606c8421e013304110FA04A32a3;
    address constant IRBTC = 0xe67Fe227e0504e8e96A34C3594795756dC26e14B;

    // Vault parameters
    uint256 constant COOLDOWN = 3600; // 1 hour
    uint256 constant THRESHOLD = 5e14; // 0.05% annual rate difference
    uint256 constant REWARD_BPS = 100; // 1% of yield

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy adapters
        TropykusAdapter tropykus = new TropykusAdapter(KRBTC);
        console.log("TropykusAdapter:", address(tropykus));

        SovrynAdapter sovryn = new SovrynAdapter(IRBTC);
        console.log("SovrynAdapter:", address(sovryn));

        // 2. Deploy vault (constructor calls setVault on each adapter)
        ILendingAdapter[] memory adapters = new ILendingAdapter[](2);
        adapters[0] = ILendingAdapter(address(tropykus));
        adapters[1] = ILendingAdapter(address(sovryn));

        YieldVault vault = new YieldVault(
            WRBTC,
            adapters,
            COOLDOWN,
            THRESHOLD,
            REWARD_BPS
        );
        console.log("YieldVault:", address(vault));

        vm.stopBroadcast();
    }
}
