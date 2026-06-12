// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {YieldVault} from "../src/YieldVault.sol";
import {LayerBankAdapter} from "../src/adapters/LayerBankAdapter.sol";
import {SovrynAdapter} from "../src/adapters/SovrynAdapter.sol";
import {ILendingAdapter} from "../src/interfaces/ILendingAdapter.sol";

contract Deploy is Script {
    // Rootstock Testnet addresses
    address constant WRBTC = 0x69FE5cEC81D5eF92600c1A0dB1F11986AB3758Ab;
    // LayerBank Pool proxy (Aave V3 fork; WRBTC market verified live)
    address constant LB_POOL = 0xF972ADe3d7dD21af206Da81595e2fA4Ae28af536;
    address constant IRBTC = 0xe67Fe227e0504e8e96A34C3594795756dC26e14B;

    // Mainnet equivalents, for reference:
    //   WRBTC   0x542fDA317318eBF1d3DEAf76E0b632741A7e677d
    //   LB_POOL 0x526D06c65777eA6D56d7a1Dd47cD79230dDf72E9
    //   IRBTC   0xa9DcDC63eaBb8a2b6f39D7fF9429d88340044a7A

    // Vault parameters
    uint256 constant COOLDOWN = 3600; // 1 hour
    uint256 constant THRESHOLD = 5e14; // 0.05% annual rate difference
    uint256 constant REWARD_BPS = 100; // 1% of yield
    // Real Rootstock lending rates sit well under 10% APR even in stressed
    // markets (June 2026: Sovryn rBTC ~0.9%, iDOC ~9.35%, LayerBank <0.01%).
    // 50% is generous headroom; the cap only needs to catch flash-loan spikes
    // and absurdly illiquid markets.
    uint256 constant MAX_SANE_RATE = 0.5e18; // 50% APR
    uint256 constant ADAPTER_CAP_BPS = 6000; // 60% per-adapter concentration cap

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy adapters
        LayerBankAdapter layerBank = new LayerBankAdapter(LB_POOL, WRBTC);
        console.log("LayerBankAdapter:", address(layerBank));

        SovrynAdapter sovryn = new SovrynAdapter(IRBTC);
        console.log("SovrynAdapter:", address(sovryn));

        // 2. Deploy vault (constructor calls setVault on each adapter)
        ILendingAdapter[] memory adapters = new ILendingAdapter[](2);
        adapters[0] = ILendingAdapter(address(layerBank));
        adapters[1] = ILendingAdapter(address(sovryn));

        YieldVault vault = new YieldVault(
            WRBTC,
            adapters,
            COOLDOWN,
            THRESHOLD,
            REWARD_BPS,
            MAX_SANE_RATE, ADAPTER_CAP_BPS
        );
        console.log("YieldVault:", address(vault));

        vm.stopBroadcast();
    }
}
