// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {YieldVault} from "../src/YieldVault.sol";
import {ERC20YieldVault} from "../src/ERC20YieldVault.sol";
import {LayerBankAdapter} from "../src/adapters/LayerBankAdapter.sol";
import {LayerBankERC20Adapter} from "../src/adapters/LayerBankERC20Adapter.sol";
import {SovrynAdapter} from "../src/adapters/SovrynAdapter.sol";
import {SovrynERC20Adapter} from "../src/adapters/SovrynERC20Adapter.sol";
import {ILendingAdapter} from "../src/interfaces/ILendingAdapter.sol";
import {IERC20LendingAdapter} from "../src/interfaces/IERC20LendingAdapter.sol";
import {MockWRBTC} from "./mocks/MockWRBTC.sol";
import {MockLayerBankPool} from "./mocks/MockLayerBankPool.sol";
import {MockiToken} from "./mocks/MockiToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockLoanToken} from "./mocks/MockLoanToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Native adapter that short-pays withdrawals 100:1 WITHOUT reverting,
///      the receipt position stays mostly stuck, like a market that only has
///      a sliver of exit liquidity. Used to force reward > received.
contract CPShortPayNativeAdapter is ILendingAdapter {
    uint256 public rate;

    constructor(uint256 _rate) {
        rate = _rate;
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function setVault(address) external {}

    function deposit() external payable {}

    function withdraw(uint256 amount) external returns (uint256) {
        uint256 pay = amount / 100;
        (bool ok,) = msg.sender.call{value: pay}("");
        require(ok, "send failed");
        return pay;
    }

    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function getRate() external view returns (uint256) {
        return rate;
    }

    function getUtilization() external pure returns (uint256) {
        return 0;
    }

    function getProtocolName() external pure returns (string memory) {
        return "ShortPay";
    }

    function transferPosition(address, uint256, uint256) external {}
}

/// @dev Honest constant-rate native adapter to pair with the short-payer.
contract CPFixedNativeAdapter is ILendingAdapter {
    uint256 public immutable rate;
    uint256 internal held;

    constructor(uint256 _rate) {
        rate = _rate;
    }

    function setVault(address) external {}

    function deposit() external payable {
        held += msg.value;
    }

    function withdraw(uint256 amount) external returns (uint256) {
        held -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "send failed");
        return amount;
    }

    function getBalance() external view returns (uint256) {
        return held;
    }

    function getRate() external view returns (uint256) {
        return rate;
    }

    function getUtilization() external pure returns (uint256) {
        return 0;
    }

    function getProtocolName() external pure returns (string memory) {
        return "Fixed";
    }

    function transferPosition(address, uint256, uint256) external {}
}

/// @dev ERC-20 twin of the short-paying adapter.
contract CPShortPayERC20Adapter is IERC20LendingAdapter {
    IERC20 public immutable token;
    uint256 public rate;

    constructor(address _token, uint256 _rate) {
        token = IERC20(_token);
        rate = _rate;
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function setVault(address) external {}

    function deposit(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
    }

    function withdraw(uint256 amount) external returns (uint256) {
        uint256 pay = amount / 100;
        token.transfer(msg.sender, pay);
        return pay;
    }

    function getBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function getRate() external view returns (uint256) {
        return rate;
    }

    function getUtilization() external pure returns (uint256) {
        return 0;
    }

    function getProtocolName() external pure returns (string memory) {
        return "ShortPayERC20";
    }

    function transferPosition(address, uint256, uint256) external {}
}

/// @dev Honest constant-rate ERC-20 adapter to pair with the short-payer.
contract CPFixedERC20Adapter is IERC20LendingAdapter {
    IERC20 public immutable token;
    uint256 public immutable rate;

    constructor(address _token, uint256 _rate) {
        token = IERC20(_token);
        rate = _rate;
    }

    function setVault(address) external {}

    function deposit(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
    }

    function withdraw(uint256 amount) external returns (uint256) {
        token.transfer(msg.sender, amount);
        return amount;
    }

    function getBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function getRate() external view returns (uint256) {
        return rate;
    }

    function getUtilization() external pure returns (uint256) {
        return 0;
    }

    function getProtocolName() external pure returns (string memory) {
        return "FixedERC20";
    }

    function transferPosition(address, uint256, uint256) external {}
}

/// @notice Pins the checkpoint/reward state machine in BOTH vaults:
///         (1) rewardableYield accumulates across gain checkpoints (+=) and is
///             reset to zero at rebalance AFTER the reward is computed, so a
///             second rebalance never re-pays historic yield;
///         (2) the reward-vs-received clamp actually binds when adapters
///             short-pay, and the ERC20 unvested-buffer clamp binds too;
///         (3) a loss CHECKPOINT consumes the locked buffer first, shrinks the
///             reward base, re-syncs trackedDeployed, and emits
///             YieldRecognized(0, loss, ...).
contract CheckpointPinsTest is Test {
    MockWRBTC wrbtc;
    MockLayerBankPool lbPool;
    MockiToken mockIToken;
    LayerBankAdapter lbAdapter;
    SovrynAdapter sovrynAdapter;

    MockERC20 doc;
    MockLayerBankPool lbPoolErc;
    MockLoanToken mockIDOC;
    LayerBankERC20Adapter lbErcAdapter;
    SovrynERC20Adapter sovErcAdapter;

    address alice = makeAddr("cp_alice");
    address bob = makeAddr("cp_bob");
    address carol = makeAddr("cp_carol");
    address rebalancer = makeAddr("cp_rebalancer");

    uint256 constant COOLDOWN = 3600;
    uint256 constant THRESHOLD = 5e14;
    uint256 constant MAX_RATE = 0.5e18;
    uint256 constant REWARD_BPS = 500; // 5%
    uint256 constant TVL_CAP = type(uint256).max;

    function setUp() public {
        wrbtc = new MockWRBTC();
        lbPool = new MockLayerBankPool();
        lbPool.initReserve(address(wrbtc));
        mockIToken = new MockiToken();

        doc = new MockERC20("Dollar on Chain", "DOC");
        lbPoolErc = new MockLayerBankPool();
        lbPoolErc.initReserve(address(doc));
        mockIDOC = new MockLoanToken(address(doc));

        lbPool.setSupplyRate1e18(address(wrbtc), 5e16);
        mockIToken.setSupplyInterestRate(3e16 * 100); // percent scale
        lbPoolErc.setSupplyRate1e18(address(doc), 5e16);
        mockIDOC.setSupplyInterestRate(3e16 * 100);
    }

    // -- Builders / helpers --

    /// 100% cap: everything lands in the best market, so checkpoint math has
    /// a single moving balance and the assertions stay wei-exact.
    function _nativeVault() internal returns (YieldVault v) {
        lbAdapter = new LayerBankAdapter(address(lbPool), address(wrbtc));
        sovrynAdapter = new SovrynAdapter(address(mockIToken));
        ILendingAdapter[] memory adapters = new ILendingAdapter[](2);
        adapters[0] = ILendingAdapter(address(lbAdapter));
        adapters[1] = ILendingAdapter(address(sovrynAdapter));
        v = new YieldVault(address(wrbtc), adapters, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_RATE, 10_000, TVL_CAP);
    }

    function _erc20Vault() internal returns (ERC20YieldVault v) {
        lbErcAdapter = new LayerBankERC20Adapter(address(lbPoolErc), address(doc));
        sovErcAdapter = new SovrynERC20Adapter(address(mockIDOC), address(doc));
        IERC20LendingAdapter[] memory adapters = new IERC20LendingAdapter[](2);
        adapters[0] = IERC20LendingAdapter(address(lbErcAdapter));
        adapters[1] = IERC20LendingAdapter(address(sovErcAdapter));
        v = new ERC20YieldVault(
            address(doc),
            adapters,
            COOLDOWN,
            THRESHOLD,
            REWARD_BPS,
            MAX_RATE,
            10_000,
            TVL_CAP,
            "Test",
            "T",
            address(this)
        );
    }

    function _accrueLbNative(uint256 gain) internal {
        vm.deal(address(this), gain);
        wrbtc.deposit{value: gain}();
        wrbtc.transfer(address(lbPool), gain);
        lbPool.accrueInterest(address(wrbtc));
    }

    function _accrueLbErc(uint256 gain) internal {
        doc.mint(address(lbPoolErc), gain);
        lbPoolErc.accrueInterest(address(doc));
    }

    function _accrueSovNative(uint256 gain) internal {
        vm.deal(address(mockIToken), address(mockIToken).balance + gain);
        mockIToken.accrueInterest();
    }

    function _accrueSovErc(uint256 gain) internal {
        doc.mint(address(mockIDOC), gain);
        mockIDOC.accrueInterest();
    }

    /// Burn `loss` out of the LayerBank pool and recompute the index.
    function _inflictLbNativeLoss(uint256 loss) internal {
        vm.prank(address(lbPool));
        wrbtc.transfer(address(0xdead), loss);
        lbPool.accrueInterest(address(wrbtc));
    }

    function _inflictLbErcLoss(uint256 loss) internal {
        vm.prank(address(lbPoolErc));
        doc.transfer(address(0xdead), loss);
        lbPoolErc.accrueInterest(address(doc));
    }

    function _depositNative(YieldVault v, address who, uint256 amount) internal {
        vm.deal(who, amount);
        vm.prank(who);
        v.depositNative{value: amount}(who);
    }

    function _depositErc(ERC20YieldVault v, address who, uint256 amount) internal {
        doc.mint(who, amount);
        vm.startPrank(who);
        doc.approve(address(v), amount);
        v.deposit(amount, who);
        vm.stopPrank();
    }

    // -- rewardableYield accumulates across checkpoints (+= gain, not = gain) --

    function test_RewardableYieldAccumulatesAcrossCheckpoints() public {
        YieldVault vault = _nativeVault();
        _depositNative(vault, alice, 10 ether);
        vault.initialDeposit(); // all in LayerBank at 5%

        _accrueLbNative(0.4 ether);
        _depositNative(vault, bob, 1); // checkpoint #1
        assertApproxEqAbs(vault.rewardableYield(), 0.4 ether, 2, "first gain enters the reward base");

        _accrueLbNative(0.6 ether);
        _depositNative(vault, carol, 1); // checkpoint #2
        assertApproxEqAbs(vault.rewardableYield(), 1 ether, 4, "gains must ACCUMULATE across checkpoints");

        // ...and the rebalance reward covers the SUM of both gains
        mockIToken.setSupplyInterestRate(8e16 * 100);
        vm.warp(block.timestamp + COOLDOWN + 1);
        vm.prank(rebalancer);
        vault.rebalance();
        assertApproxEqAbs(rebalancer.balance, 0.05 ether, 4, "reward = 5% of BOTH checkpointed gains");
    }

    function test_ERC20_RewardableYieldAccumulatesAcrossCheckpoints() public {
        ERC20YieldVault vault = _erc20Vault();
        _depositErc(vault, alice, 10 ether);
        vault.initialDeposit();

        _accrueLbErc(0.4 ether);
        _depositErc(vault, bob, 1);
        assertApproxEqAbs(vault.rewardableYield(), 0.4 ether, 2, "first gain enters the reward base");

        _accrueLbErc(0.6 ether);
        _depositErc(vault, carol, 1);
        assertApproxEqAbs(vault.rewardableYield(), 1 ether, 4, "gains must ACCUMULATE across checkpoints");

        mockIDOC.setSupplyInterestRate(8e16 * 100);
        vm.warp(block.timestamp + COOLDOWN + 1);
        vm.prank(rebalancer);
        vault.rebalance();
        assertApproxEqAbs(doc.balanceOf(rebalancer), 0.05 ether, 4, "reward = 5% of BOTH checkpointed gains");
    }

    // rewardableYield resets at rebalance (after reward computation):
    // the second rebalance must pay for NEW yield only, never re-pay

    function test_SecondRebalanceRewardCountsOnlyNewYield() public {
        YieldVault vault = _nativeVault();
        _depositNative(vault, alice, 100 ether);
        vault.initialDeposit(); // all in LayerBank at 5%

        _accrueLbNative(2 ether);
        mockIToken.setSupplyInterestRate(8e16 * 100);
        vm.warp(block.timestamp + COOLDOWN + 1);
        vm.prank(rebalancer);
        vault.rebalance(); // moves everything to Sovryn

        uint256 reward1 = rebalancer.balance;
        assertApproxEqAbs(reward1, 0.1 ether, 2, "first reward = 5% of the first gain");
        assertEq(vault.rewardableYield(), 0, "reward base must reset at rebalance");

        // 1 ether of NEW yield on the new primary, then rebalance back
        _accrueSovNative(1 ether);
        lbPool.setSupplyRate1e18(address(wrbtc), 12e16);
        vm.warp(block.timestamp + COOLDOWN + 1);
        vm.prank(rebalancer);
        vault.rebalance();

        uint256 reward2 = rebalancer.balance - reward1;
        // Sovryn tokenPrice floors can shave ~100 wei off the recognized gain
        assertApproxEqAbs(reward2, 0.05 ether, 200, "second reward must count ONLY post-reset yield");
        assertEq(vault.rewardableYield(), 0, "reward base resets again");
    }

    function test_ERC20_SecondRebalanceRewardCountsOnlyNewYield() public {
        ERC20YieldVault vault = _erc20Vault();
        _depositErc(vault, alice, 100 ether);
        vault.initialDeposit();

        _accrueLbErc(2 ether);
        mockIDOC.setSupplyInterestRate(8e16 * 100);
        vm.warp(block.timestamp + COOLDOWN + 1);
        vm.prank(rebalancer);
        vault.rebalance();

        uint256 reward1 = doc.balanceOf(rebalancer);
        assertApproxEqAbs(reward1, 0.1 ether, 2, "first reward = 5% of the first gain");
        assertEq(vault.rewardableYield(), 0, "reward base must reset at rebalance");

        _accrueSovErc(1 ether);
        lbPoolErc.setSupplyRate1e18(address(doc), 12e16);
        vm.warp(block.timestamp + COOLDOWN + 1);
        vm.prank(rebalancer);
        vault.rebalance();

        uint256 reward2 = doc.balanceOf(rebalancer) - reward1;
        assertApproxEqAbs(reward2, 0.05 ether, 200, "second reward must count ONLY post-reset yield");
        assertEq(vault.rewardableYield(), 0, "reward base resets again");
    }

    // -- Reward clamped to what the rebalance actually withdrew --

    /// All funds sit in an adapter whose exit liquidity is 1% of the position:
    /// the 5% reward formula (0.5 ether) exceeds the 0.11 ether the rebalance
    /// actually received, so the payout must clamp to `received`.
    function test_RewardClampedToReceived_ShortPayingAdapter() public {
        CPShortPayNativeAdapter shortPay = new CPShortPayNativeAdapter(5e16);
        CPFixedNativeAdapter fixedAdapter = new CPFixedNativeAdapter(3e16);
        ILendingAdapter[] memory adapters = new ILendingAdapter[](2);
        adapters[0] = ILendingAdapter(address(shortPay));
        adapters[1] = ILendingAdapter(address(fixedAdapter));
        YieldVault vault =
            new YieldVault(address(wrbtc), adapters, COOLDOWN, THRESHOLD, REWARD_BPS, MAX_RATE, 10_000, TVL_CAP);

        _depositNative(vault, alice, 1 ether);
        vault.initialDeposit(); // all 1 ether into ShortPay (5% > 3%)

        vm.deal(address(shortPay), 11 ether); // 10 ether of unrecognized gain
        shortPay.setRate(1e16); // gate: fixed 3% beats 1% + threshold
        vm.warp(block.timestamp + COOLDOWN + 1);

        vm.prank(rebalancer);
        vault.rebalance();

        // formula: 5% of the 10 ether gain = 0.5; received: 11/100 = 0.11
        assertEq(rebalancer.balance, 0.11 ether, "reward must clamp to what was actually withdrawn");
        assertLt(rebalancer.balance, 0.5 ether, "the raw formula amount must NOT be paid");
        assertEq(vault.rewardableYield(), 0, "reward base reset");
        assertEq(vault.lockedProfitStored(), 10 ether - 0.11 ether, "buffer shrinks by the clamped reward only");
    }

    function test_ERC20_RewardClampedToReceived_ShortPayingAdapter() public {
        CPShortPayERC20Adapter shortPay = new CPShortPayERC20Adapter(address(doc), 5e16);
        CPFixedERC20Adapter fixedAdapter = new CPFixedERC20Adapter(address(doc), 3e16);
        IERC20LendingAdapter[] memory adapters = new IERC20LendingAdapter[](2);
        adapters[0] = IERC20LendingAdapter(address(shortPay));
        adapters[1] = IERC20LendingAdapter(address(fixedAdapter));
        ERC20YieldVault vault = new ERC20YieldVault(
            address(doc),
            adapters,
            COOLDOWN,
            THRESHOLD,
            REWARD_BPS,
            MAX_RATE,
            10_000,
            TVL_CAP,
            "Test",
            "T",
            address(this)
        );

        _depositErc(vault, alice, 1 ether);
        vault.initialDeposit();

        doc.mint(address(shortPay), 10 ether); // unrecognized gain
        shortPay.setRate(1e16);
        vm.warp(block.timestamp + COOLDOWN + 1);

        vm.prank(rebalancer);
        vault.rebalance();

        assertEq(doc.balanceOf(rebalancer), 0.11 ether, "reward must clamp to what was actually withdrawn");
        assertEq(vault.rewardableYield(), 0, "reward base reset");
        assertEq(vault.lockedProfitStored(), 10 ether - 0.11 ether, "buffer shrinks by the clamped reward only");
    }

    /// ERC20 twin of Tier1Fixes.test_RewardClampedToUnvestedBuffer: the raw
    /// formula claims 5% of 10.1 ether but only the fresh 0.1 is still locked.
    function test_ERC20_RewardClampedToUnvestedBuffer() public {
        ERC20YieldVault vault = _erc20Vault();
        _depositErc(vault, alice, 100 ether);
        vault.initialDeposit();

        _accrueLbErc(10 ether);
        _depositErc(vault, carol, 1);
        vm.warp(block.timestamp + 3 days + 1);
        _accrueLbErc(0.1 ether);

        mockIDOC.setSupplyInterestRate(8e16 * 100);
        uint256 priceBefore = vault.previewRedeem(1e21);
        vm.prank(rebalancer);
        vault.rebalance();

        assertApproxEqAbs(doc.balanceOf(rebalancer), 0.1 ether, 1e6, "reward should clamp to the locked buffer");
        assertApproxEqAbs(vault.previewRedeem(1e21), priceBefore, 2, "paying the reward must not move the price");
    }

    // Loss checkpoints: buffer-first consumption, reward-base shrink,
    // trackedDeployed resync, YieldRecognized(0, loss, ...) event

    function test_LossCheckpoint_ConsumesBufferAndRewardBase() public {
        YieldVault vault = _nativeVault();
        _depositNative(vault, alice, 5 ether);
        vault.initialDeposit(); // all in LayerBank

        _accrueLbNative(0.3 ether);
        _depositNative(vault, bob, 1); // checkpoint the gain
        uint256 storedBefore = vault.lockedProfitStored();
        uint256 ryBefore = vault.rewardableYield();
        assertApproxEqAbs(storedBefore, 0.3 ether, 2, "gain locked");

        _inflictLbNativeLoss(0.2 ether);

        // Expected writes, computed from live state (no time has passed since
        // the gain checkpoint, so remaining == storedBefore exactly)
        uint256 live = lbAdapter.getBalance() + sovrynAdapter.getBalance();
        uint256 lossExp = vault.trackedDeployed() - live;
        assertGt(lossExp, 0, "sanity: a loss exists");
        assertLt(lossExp, storedBefore, "sanity: loss smaller than the buffer");

        vm.deal(carol, 1);
        vm.expectEmit(false, false, false, true);
        emit YieldVault.YieldRecognized(0, lossExp, storedBefore - lossExp);
        vm.prank(carol);
        vault.depositNative{value: 1}(carol); // checkpoint the loss

        assertEq(vault.lockedProfitStored(), storedBefore - lossExp, "loss must consume the locked buffer first");
        assertEq(vault.rewardableYield(), ryBefore - lossExp, "loss must shrink the reward base");
        assertEq(
            vault.trackedDeployed(),
            lbAdapter.getBalance() + sovrynAdapter.getBalance(),
            "baseline must resync to the live deployed balance"
        );
        // buffer absorbed everything: principal intact
        assertGe(vault.totalAssets(), 5 ether + 1, "principal stays whole while the buffer absorbs the loss");
    }

    function test_ERC20_LossCheckpoint_ConsumesBufferAndRewardBase() public {
        ERC20YieldVault vault = _erc20Vault();
        _depositErc(vault, alice, 5 ether);
        vault.initialDeposit();

        _accrueLbErc(0.3 ether);
        _depositErc(vault, bob, 1);
        uint256 storedBefore = vault.lockedProfitStored();
        uint256 ryBefore = vault.rewardableYield();
        assertApproxEqAbs(storedBefore, 0.3 ether, 2, "gain locked");

        _inflictLbErcLoss(0.2 ether);

        uint256 live = lbErcAdapter.getBalance() + sovErcAdapter.getBalance();
        uint256 lossExp = vault.trackedDeployed() - live;
        assertGt(lossExp, 0, "sanity: a loss exists");
        assertLt(lossExp, storedBefore, "sanity: loss smaller than the buffer");

        doc.mint(carol, 1);
        vm.prank(carol);
        doc.approve(address(vault), 1);
        vm.expectEmit(false, false, false, true);
        emit ERC20YieldVault.YieldRecognized(0, lossExp, storedBefore - lossExp);
        vm.prank(carol);
        vault.deposit(1, carol);

        assertEq(vault.lockedProfitStored(), storedBefore - lossExp, "loss must consume the locked buffer first");
        assertEq(vault.rewardableYield(), ryBefore - lossExp, "loss must shrink the reward base");
        assertEq(
            vault.trackedDeployed(),
            lbErcAdapter.getBalance() + sovErcAdapter.getBalance(),
            "baseline must resync to the live deployed balance"
        );
        assertGe(vault.totalAssets(), 5 ether + 1, "principal stays whole while the buffer absorbs the loss");
    }
}
