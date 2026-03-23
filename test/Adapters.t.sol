// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TropykusAdapter} from "../src/adapters/TropykusAdapter.sol";
import {SovrynAdapter} from "../src/adapters/SovrynAdapter.sol";
import {MockkToken} from "./mocks/MockkToken.sol";
import {MockiToken} from "./mocks/MockiToken.sol";

contract AdaptersTest is Test {
    TropykusAdapter public tropykusAdapter;
    SovrynAdapter public sovrynAdapter;
    MockkToken public mockKToken;
    MockiToken public mockIToken;

    address public vaultAddr = makeAddr("vault");

    function setUp() public {
        mockKToken = new MockkToken();
        mockIToken = new MockiToken();

        tropykusAdapter = new TropykusAdapter(address(mockKToken));
        sovrynAdapter = new SovrynAdapter(address(mockIToken));

        tropykusAdapter.setVault(vaultAddr);
        sovrynAdapter.setVault(vaultAddr);

        // vaultAddr needs to receive rBTC from adapters
        vm.deal(vaultAddr, 0);
    }

    // -- Tropykus Adapter --

    function test_Tropykus_Deposit() public {
        vm.deal(vaultAddr, 1 ether);
        vm.prank(vaultAddr);
        tropykusAdapter.deposit{value: 1 ether}();

        assertGt(tropykusAdapter.getBalance(), 0, "should have balance");
    }

    function test_Tropykus_Withdraw() public {
        vm.deal(vaultAddr, 1 ether);
        vm.prank(vaultAddr);
        tropykusAdapter.deposit{value: 1 ether}();

        uint256 vaultBalBefore = vaultAddr.balance;
        vm.prank(vaultAddr);
        tropykusAdapter.withdraw(0.5 ether);

        assertGt(vaultAddr.balance, vaultBalBefore, "vault should receive rBTC");
    }

    function test_Tropykus_GetRate() public {
        mockKToken.setSupplyRatePerBlock(47564687975); // ~5% annual
        uint256 rate = tropykusAdapter.getRate();
        // 47564687975 * 1,051,200 ≈ 5e16
        assertApproxEqRel(rate, 5e16, 0.01e18, "rate should be ~5%");
    }

    function test_Tropykus_GetBalance_WithInterest() public {
        vm.deal(vaultAddr, 1 ether);
        vm.prank(vaultAddr);
        tropykusAdapter.deposit{value: 1 ether}();

        // Simulate interest: exchange rate goes from 1e18 to 1.05e18
        mockKToken.setExchangeRateStored(1.05e18);

        uint256 balance = tropykusAdapter.getBalance();
        assertApproxEqRel(balance, 1.05 ether, 0.01e18, "balance should reflect interest");
    }

    function test_Tropykus_OnlyVault() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert("only vault");
        tropykusAdapter.deposit{value: 1 ether}();
    }

    function test_Tropykus_ProtocolName() public view {
        assertEq(tropykusAdapter.getProtocolName(), "Tropykus");
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

        assertGt(vaultAddr.balance, vaultBalBefore, "vault should receive rBTC");
    }

    function test_Sovryn_GetRate() public {
        mockIToken.setSupplyInterestRate(3e16); // 3% annual
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
        TropykusAdapter adapter = new TropykusAdapter(address(mockKToken));
        adapter.setVault(vaultAddr);

        vm.expectRevert("vault already set");
        adapter.setVault(address(0x123));
    }

    function test_SetVault_RejectsZeroAddress() public {
        TropykusAdapter adapter = new TropykusAdapter(address(mockKToken));

        vm.expectRevert("zero address");
        adapter.setVault(address(0));
    }
}
