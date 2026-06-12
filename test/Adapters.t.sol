// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LayerBankAdapter} from "../src/adapters/LayerBankAdapter.sol";
import {SovrynAdapter} from "../src/adapters/SovrynAdapter.sol";
import {MockWRBTC} from "./mocks/MockWRBTC.sol";
import {MockLayerBankPool} from "./mocks/MockLayerBankPool.sol";
import {MockiToken} from "./mocks/MockiToken.sol";

contract AdaptersTest is Test {
    LayerBankAdapter public layerBankAdapter;
    SovrynAdapter public sovrynAdapter;
    MockWRBTC public wrbtc;
    MockLayerBankPool public lbPool;
    MockiToken public mockIToken;

    address public vaultAddr = makeAddr("vault");

    function setUp() public {
        wrbtc = new MockWRBTC();
        lbPool = new MockLayerBankPool();
        lbPool.initReserve(address(wrbtc));
        mockIToken = new MockiToken();

        layerBankAdapter = new LayerBankAdapter(address(lbPool), address(wrbtc));
        sovrynAdapter = new SovrynAdapter(address(mockIToken));

        layerBankAdapter.setVault(vaultAddr);
        sovrynAdapter.setVault(vaultAddr);

        // vaultAddr needs to receive rBTC from adapters
        vm.deal(vaultAddr, 0);
    }

    /// Simulate LayerBank yield: add WRBTC to the pool, recompute the index
    function _accrueLayerBankYield(uint256 amount) internal {
        vm.deal(address(this), amount);
        wrbtc.deposit{value: amount}();
        wrbtc.transfer(address(lbPool), amount);
        lbPool.accrueInterest(address(wrbtc));
    }

    // -- LayerBank Adapter --

    function test_LayerBank_Deposit() public {
        vm.deal(vaultAddr, 1 ether);
        vm.prank(vaultAddr);
        layerBankAdapter.deposit{value: 1 ether}();

        assertEq(layerBankAdapter.getBalance(), 1 ether, "should have balance");
    }

    function test_LayerBank_Withdraw() public {
        vm.deal(vaultAddr, 1 ether);
        vm.prank(vaultAddr);
        layerBankAdapter.deposit{value: 1 ether}();

        uint256 vaultBalBefore = vaultAddr.balance;
        vm.prank(vaultAddr);
        layerBankAdapter.withdraw(0.5 ether);

        assertEq(vaultAddr.balance - vaultBalBefore, 0.5 ether, "vault should receive the full amount");
        assertEq(address(layerBankAdapter).balance, 0, "no rBTC should be stranded in the adapter");
    }

    function test_LayerBank_Withdraw_RevertsOnShortfall() public {
        vm.deal(vaultAddr, 1 ether);
        vm.prank(vaultAddr);
        layerBankAdapter.deposit{value: 1 ether}();

        // Protocol pays out less than requested — adapter must refuse
        lbPool.setWithdrawFeeBps(100);
        vm.prank(vaultAddr);
        vm.expectRevert("layerbank: insufficient withdrawal");
        layerBankAdapter.withdraw(0.5 ether);
    }

    function test_LayerBank_GetRate() public {
        lbPool.setSupplyRate1e18(address(wrbtc), 5e16); // 5% annual
        assertEq(layerBankAdapter.getRate(), 5e16, "rate should be 5%");
    }

    function test_LayerBank_GetBalance_WithInterest() public {
        vm.deal(vaultAddr, 1 ether);
        vm.prank(vaultAddr);
        layerBankAdapter.deposit{value: 1 ether}();

        // 5% yield lands in the pool, index recomputed
        _accrueLayerBankYield(0.05 ether);

        assertEq(layerBankAdapter.getBalance(), 1.05 ether, "balance should reflect interest");
    }

    function test_LayerBank_OnlyVault() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert("only vault");
        layerBankAdapter.deposit{value: 1 ether}();
    }

    function test_LayerBank_ProtocolName() public view {
        assertEq(layerBankAdapter.getProtocolName(), "LayerBank");
    }

    function test_LayerBank_RevertsOnUnlistedMarket() public {
        MockWRBTC other = new MockWRBTC();
        vm.expectRevert("market not listed");
        new LayerBankAdapter(address(lbPool), address(other));
    }

    // -- Sovryn Adapter --

    function test_Sovryn_Deposit() public {
        vm.deal(vaultAddr, 1 ether);
        vm.prank(vaultAddr);
        sovrynAdapter.deposit{value: 1 ether}();

        assertGt(sovrynAdapter.getBalance(), 0, "should have balance");
    }

    function test_Sovryn_Withdraw() public {
        vm.deal(vaultAddr, 1 ether);
        vm.prank(vaultAddr);
        sovrynAdapter.deposit{value: 1 ether}();

        uint256 vaultBalBefore = vaultAddr.balance;
        vm.prank(vaultAddr);
        sovrynAdapter.withdraw(0.5 ether);

        assertEq(vaultAddr.balance - vaultBalBefore, 0.5 ether, "vault should receive the full amount");
        assertEq(address(sovrynAdapter).balance, 0, "no rBTC should be stranded in the adapter");
    }

    function test_Sovryn_Withdraw_RevertsOnShortfall() public {
        vm.deal(vaultAddr, 1 ether);
        vm.prank(vaultAddr);
        sovrynAdapter.deposit{value: 1 ether}();

        // Protocol skims 1% on burn — adapter must refuse the short withdrawal
        mockIToken.setBurnFeeBps(100);
        vm.prank(vaultAddr);
        vm.expectRevert("sovryn: insufficient withdrawal");
        sovrynAdapter.withdraw(0.5 ether);
    }

    function test_Sovryn_GetRate() public {
        mockIToken.setSupplyInterestRate((3e16) * 100); // 3% annual
        uint256 rate = sovrynAdapter.getRate();
        assertEq(rate, 3e16, "rate should be 3%");
    }

    function test_Sovryn_GetBalance_WithInterest() public {
        vm.deal(vaultAddr, 1 ether);
        vm.prank(vaultAddr);
        sovrynAdapter.deposit{value: 1 ether}();

        // Simulate interest: token price goes from 1e18 to 1.03e18
        mockIToken.setTokenPrice(1.03e18);

        uint256 balance = sovrynAdapter.getBalance();
        assertApproxEqRel(balance, 1.03 ether, 0.01e18, "balance should reflect interest");
    }

    function test_Sovryn_OnlyVault() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert("only vault");
        sovrynAdapter.deposit{value: 1 ether}();
    }

    function test_Sovryn_ProtocolName() public view {
        assertEq(sovrynAdapter.getProtocolName(), "Sovryn");
    }

    // -- SetVault one-shot --

    function test_SetVault_CanOnlyBeCalledOnce() public {
        LayerBankAdapter adapter = new LayerBankAdapter(address(lbPool), address(wrbtc));
        adapter.setVault(vaultAddr);

        vm.expectRevert("vault already set");
        adapter.setVault(address(0x123));
    }

    function test_SetVault_RejectsZeroAddress() public {
        LayerBankAdapter adapter = new LayerBankAdapter(address(lbPool), address(wrbtc));

        vm.expectRevert("zero address");
        adapter.setVault(address(0));
    }
}
