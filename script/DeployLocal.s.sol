// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {YieldVault} from "../src/YieldVault.sol";
import {ERC20YieldVault} from "../src/ERC20YieldVault.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {LayerBankAdapter} from "../src/adapters/LayerBankAdapter.sol";
import {SovrynAdapter} from "../src/adapters/SovrynAdapter.sol";
import {LayerBankERC20Adapter} from "../src/adapters/LayerBankERC20Adapter.sol";
import {SovrynERC20Adapter} from "../src/adapters/SovrynERC20Adapter.sol";
import {ILendingAdapter} from "../src/interfaces/ILendingAdapter.sol";
import {IERC20LendingAdapter} from "../src/interfaces/IERC20LendingAdapter.sol";
import {MockWRBTC} from "../test/mocks/MockWRBTC.sol";
import {MockLayerBankPool} from "../test/mocks/MockLayerBankPool.sol";
import {MockiToken} from "../test/mocks/MockiToken.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {MockLoanToken} from "../test/mocks/MockLoanToken.sol";

contract DeployLocal is Script {
    uint256 constant COOLDOWN = 3600;
    uint256 constant THRESHOLD = 5e14;
    uint256 constant REWARD_BPS = 100;
    uint256 constant MAX_SANE_RATE = 2e18; // 200% APR
    uint256 constant ADAPTER_CAP_BPS = 6000; // 60% per-adapter concentration cap
    uint256 constant TVL_CAP = type(uint256).max; // uncapped (local dev)

    function run() external {
        uint256 deployerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address deployer = vm.addr(deployerPrivateKey);
        vm.startBroadcast(deployerPrivateKey);

        _deployRbtcVault();
        VaultFactory factory = _deployERC20Vaults(deployer);

        console.log("VaultFactory:", address(factory));

        vm.stopBroadcast();
    }

    function _deployRbtcVault() internal {
        MockWRBTC wrbtc = new MockWRBTC();
        MockLayerBankPool lbPool = new MockLayerBankPool();
        lbPool.initReserve(address(wrbtc));
        MockiToken mockIToken = new MockiToken();

        lbPool.setSupplyRate1e18(address(wrbtc), 5e16); // 5%
        mockIToken.setSupplyInterestRate((3e16) * 100);         // 3%

        LayerBankAdapter layerBank = new LayerBankAdapter(address(lbPool), address(wrbtc));
        SovrynAdapter sovryn = new SovrynAdapter(address(mockIToken));

        ILendingAdapter[] memory adapters = new ILendingAdapter[](2);
        adapters[0] = ILendingAdapter(address(layerBank));
        adapters[1] = ILendingAdapter(address(sovryn));

        YieldVault vault = new YieldVault(
            address(wrbtc), adapters, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_SANE_RATE, ADAPTER_CAP_BPS, TVL_CAP
        );

        console.log("WRBTC:", address(wrbtc));
        console.log("MockLayerBankPool:", address(lbPool));
        console.log("MockiToken:", address(mockIToken));
        console.log("LayerBankAdapter:", address(layerBank));
        console.log("SovrynAdapter:", address(sovryn));
        console.log("YieldVault:", address(vault));
    }

    function _deployERC20Vaults(address deployer) internal returns (VaultFactory) {
        VaultFactory factory = new VaultFactory();

        _deployDocVault(factory, deployer);
        _deployUsdrifVault(factory, deployer);

        return factory;
    }

    function _deployDocVault(VaultFactory factory, address deployer) internal {
        MockERC20 doc = new MockERC20("Dollar on Chain", "DOC");
        MockLayerBankPool lbDOC = new MockLayerBankPool();
        lbDOC.initReserve(address(doc));
        MockLoanToken iDOC = new MockLoanToken(address(doc));

        lbDOC.setSupplyRate1e18(address(doc), 10e16); // 10%
        iDOC.setSupplyInterestRate((7e16) * 100);             // 7%

        LayerBankERC20Adapter layerBank = new LayerBankERC20Adapter(address(lbDOC), address(doc));
        SovrynERC20Adapter sovryn = new SovrynERC20Adapter(address(iDOC), address(doc));

        factory.trustAdapter(address(layerBank));
        factory.trustAdapter(address(sovryn));

        IERC20LendingAdapter[] memory adapters = new IERC20LendingAdapter[](2);
        adapters[0] = IERC20LendingAdapter(address(layerBank));
        adapters[1] = IERC20LendingAdapter(address(sovryn));

        address vault = factory.createVault(
            address(doc), adapters, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_SANE_RATE, ADAPTER_CAP_BPS, TVL_CAP,
            "Rootstock Yield DOC", "ryDOC"
        );

        // Fund user and lending pools
        doc.mint(deployer, 10_000 ether);
        doc.mint(address(lbDOC), 100_000 ether);
        doc.mint(address(iDOC), 100_000 ether);

        console.log("DOC:", address(doc));
        console.log("DOC LayerBankAdapter:", address(layerBank));
        console.log("DOC SovrynAdapter:", address(sovryn));
        console.log("DOC Vault:", vault);
    }

    function _deployUsdrifVault(VaultFactory factory, address deployer) internal {
        MockERC20 usdrif = new MockERC20("RIF US Dollar", "USDRIF");
        MockLayerBankPool lbUSDRIF = new MockLayerBankPool();
        lbUSDRIF.initReserve(address(usdrif));
        MockLoanToken iUSDRIF = new MockLoanToken(address(usdrif));

        lbUSDRIF.setSupplyRate1e18(address(usdrif), 7e16); // 7%
        iUSDRIF.setSupplyInterestRate((12e16) * 100);              // 12%

        LayerBankERC20Adapter layerBank = new LayerBankERC20Adapter(address(lbUSDRIF), address(usdrif));
        SovrynERC20Adapter sovryn = new SovrynERC20Adapter(address(iUSDRIF), address(usdrif));

        factory.trustAdapter(address(layerBank));
        factory.trustAdapter(address(sovryn));

        IERC20LendingAdapter[] memory adapters = new IERC20LendingAdapter[](2);
        adapters[0] = IERC20LendingAdapter(address(layerBank));
        adapters[1] = IERC20LendingAdapter(address(sovryn));

        address vault = factory.createVault(
            address(usdrif), adapters, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_SANE_RATE, ADAPTER_CAP_BPS, TVL_CAP,
            "Rootstock Yield USDRIF", "ryUSDRIF"
        );

        // Fund user and lending pools
        usdrif.mint(deployer, 10_000 ether);
        usdrif.mint(address(lbUSDRIF), 100_000 ether);
        usdrif.mint(address(iUSDRIF), 100_000 ether);

        console.log("USDRIF:", address(usdrif));
        console.log("USDRIF LayerBankAdapter:", address(layerBank));
        console.log("USDRIF SovrynAdapter:", address(sovryn));
        console.log("USDRIF Vault:", vault);
    }
}
