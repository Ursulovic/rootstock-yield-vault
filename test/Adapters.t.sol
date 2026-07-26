// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LayerBankAdapter} from "../src/adapters/LayerBankAdapter.sol";
import {SovrynAdapter} from "../src/adapters/SovrynAdapter.sol";
import {ILayerBankPool} from "../src/interfaces/ILayerBankPool.sol";
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

        // Protocol pays out less than requested, adapter must refuse
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

    function test_LayerBank_GetUtilization() public {
        // empty market reads zero, not a division-by-zero revert
        assertEq(layerBankAdapter.getUtilization(), 0, "empty market must read 0%");

        vm.deal(vaultAddr, 10 ether);
        vm.prank(vaultAddr);
        layerBankAdapter.deposit{value: 10 ether}();

        lbPool.setTotalDebt(address(wrbtc), 4 ether);
        assertEq(layerBankAdapter.getUtilization(), 0.4e18, "4/10 borrowed = 40%");

        // a drained reserve can read above 100%; the vault's >= gate still holds
        lbPool.setTotalDebt(address(wrbtc), 12 ether);
        assertEq(layerBankAdapter.getUtilization(), 1.2e18, "debt above supply reads above 100%");
    }

    function test_LayerBank_ResolvesDebtToken() public view {
        assertEq(
            address(layerBankAdapter.debtToken()),
            address(lbPool.debtTokens(address(wrbtc))),
            "debt token must come from the reserve data"
        );
    }

    function test_LayerBank_RevertsWhenDebtTokenMissing() public {
        // a reserve with an aToken but no variable-debt token must be rejected
        // at deploy time, not fail-closed forever at allocation time
        ILayerBankPool.ReserveDataLegacy memory data;
        data.aTokenAddress = address(lbPool.aTokens(address(wrbtc)));
        vm.mockCall(
            address(lbPool),
            abi.encodeWithSelector(ILayerBankPool.getReserveData.selector, address(wrbtc)),
            abi.encode(data)
        );
        vm.expectRevert("market not listed");
        new LayerBankAdapter(address(lbPool), address(wrbtc));
        vm.clearMockedCalls();
    }

    function test_Sovryn_GetUtilization() public {
        assertEq(sovrynAdapter.getUtilization(), 0, "empty market must read 0%");

        vm.deal(vaultAddr, 10 ether);
        vm.prank(vaultAddr);
        sovrynAdapter.deposit{value: 10 ether}();

        mockIToken.setTotalAssetBorrow(8.71 ether);
        assertEq(sovrynAdapter.getUtilization(), 0.871e18, "8.71/10 borrowed = 87.1%");
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

        // Protocol skims 1% on burn, adapter must refuse the short withdrawal
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
