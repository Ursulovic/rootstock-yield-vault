// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {YieldVault} from "../src/YieldVault.sol";
import {ERC20YieldVault} from "../src/ERC20YieldVault.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {TropykusAdapter} from "../src/adapters/TropykusAdapter.sol";
import {SovrynAdapter} from "../src/adapters/SovrynAdapter.sol";
import {TropykusERC20Adapter} from "../src/adapters/TropykusERC20Adapter.sol";
import {SovrynERC20Adapter} from "../src/adapters/SovrynERC20Adapter.sol";
import {ILendingAdapter} from "../src/interfaces/ILendingAdapter.sol";
import {IERC20LendingAdapter} from "../src/interfaces/IERC20LendingAdapter.sol";
import {MockWRBTC} from "../test/mocks/MockWRBTC.sol";
import {MockkToken} from "../test/mocks/MockkToken.sol";
import {MockiToken} from "../test/mocks/MockiToken.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {MockCErc20} from "../test/mocks/MockCErc20.sol";
import {MockLoanToken} from "../test/mocks/MockLoanToken.sol";

contract DeployLocal is Script {
    uint256 constant COOLDOWN = 3600;
    uint256 constant THRESHOLD = 5e14;
    uint256 constant REWARD_BPS = 100;

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
        MockkToken mockKToken = new MockkToken();
        MockiToken mockIToken = new MockiToken();

        mockKToken.setSupplyRatePerBlock(47564687975); // ~5%
        mockIToken.setSupplyInterestRate(3e16);         // 3%

        TropykusAdapter tropykus = new TropykusAdapter(address(mockKToken));
        SovrynAdapter sovryn = new SovrynAdapter(address(mockIToken));

        ILendingAdapter[] memory adapters = new ILendingAdapter[](2);
        adapters[0] = ILendingAdapter(address(tropykus));
        adapters[1] = ILendingAdapter(address(sovryn));

        YieldVault vault = new YieldVault(
            address(wrbtc), adapters, COOLDOWN, THRESHOLD, REWARD_BPS
        );

        console.log("WRBTC:", address(wrbtc));
        console.log("MockkToken:", address(mockKToken));
        console.log("MockiToken:", address(mockIToken));
        console.log("TropykusAdapter:", address(tropykus));
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
        MockCErc20 kDOC = new MockCErc20(address(doc));
        MockLoanToken iDOC = new MockLoanToken(address(doc));

        kDOC.setSupplyRatePerBlock(95129375951); // ~10%
        iDOC.setSupplyInterestRate(7e16);         // 7%

        TropykusERC20Adapter tropykus = new TropykusERC20Adapter(address(kDOC), address(doc));
        SovrynERC20Adapter sovryn = new SovrynERC20Adapter(address(iDOC), address(doc));

        factory.trustAdapter(address(tropykus));
        factory.trustAdapter(address(sovryn));

        IERC20LendingAdapter[] memory adapters = new IERC20LendingAdapter[](2);
        adapters[0] = IERC20LendingAdapter(address(tropykus));
        adapters[1] = IERC20LendingAdapter(address(sovryn));

        address vault = factory.createVault(
            address(doc), adapters, COOLDOWN, THRESHOLD, REWARD_BPS,
            "Rootstock Yield DOC", "ryDOC"
        );

        // Fund user and lending pools
        doc.mint(deployer, 10_000 ether);
        doc.mint(address(kDOC), 100_000 ether);
        doc.mint(address(iDOC), 100_000 ether);

        console.log("DOC:", address(doc));
        console.log("DOC TropykusAdapter:", address(tropykus));
        console.log("DOC SovrynAdapter:", address(sovryn));
        console.log("DOC Vault:", vault);
    }

    function _deployUsdrifVault(VaultFactory factory, address deployer) internal {
        MockERC20 usdrif = new MockERC20("RIF US Dollar", "USDRIF");
        MockCErc20 kUSDRIF = new MockCErc20(address(usdrif));
        MockLoanToken iUSDRIF = new MockLoanToken(address(usdrif));

        kUSDRIF.setSupplyRatePerBlock(66590563166); // ~7%
        iUSDRIF.setSupplyInterestRate(12e16);        // 12%

        TropykusERC20Adapter tropykus = new TropykusERC20Adapter(address(kUSDRIF), address(usdrif));
        SovrynERC20Adapter sovryn = new SovrynERC20Adapter(address(iUSDRIF), address(usdrif));

        factory.trustAdapter(address(tropykus));
        factory.trustAdapter(address(sovryn));

        IERC20LendingAdapter[] memory adapters = new IERC20LendingAdapter[](2);
        adapters[0] = IERC20LendingAdapter(address(tropykus));
        adapters[1] = IERC20LendingAdapter(address(sovryn));

        address vault = factory.createVault(
            address(usdrif), adapters, COOLDOWN, THRESHOLD, REWARD_BPS,
            "Rootstock Yield USDRIF", "ryUSDRIF"
        );

        // Fund user and lending pools
        usdrif.mint(deployer, 10_000 ether);
        usdrif.mint(address(kUSDRIF), 100_000 ether);
        usdrif.mint(address(iUSDRIF), 100_000 ether);

        console.log("USDRIF:", address(usdrif));
        console.log("USDRIF TropykusAdapter:", address(tropykus));
        console.log("USDRIF SovrynAdapter:", address(sovryn));
        console.log("USDRIF Vault:", vault);
    }
}
