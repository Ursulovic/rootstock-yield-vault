// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ILendingAdapter} from "./interfaces/ILendingAdapter.sol";
import {IWRBTC} from "./interfaces/IWRBTC.sol";

/// @title YieldVault
/// @notice ERC-4626 vault for rBTC. Accepts WRBTC (or native rBTC via the
///         convenience functions) and deploys the full balance into whichever
///         registered lending adapter offers the best supply rate. Anyone can
///         trigger a rebalance once the cooldown has elapsed and the rate
///         improvement exceeds the threshold; the caller earns a share of the
///         accrued yield as a reward.
/// @dev Trustless by construction: no admin, no pause, no upgrade path. The
///      adapter set is fixed at deployment. Adapter rates are compared on a
///      normalized 1e18 = 100% APR scale.
contract YieldVault is ERC4626, ERC20Permit, ReentrancyGuard {
    /// @notice Registered lending adapters, fixed at deployment.
    ILendingAdapter[] public adapters;
    /// @notice Adapter currently holding the vault's deployed funds; zero until initialDeposit() runs.
    ILendingAdapter public activeAdapter;

    /// @notice Timestamp of the last rebalance or initial deployment; used to enforce the cooldown.
    uint256 public lastRebalanceTime;

    /// @notice Period over which newly recognized profit linearly unlocks into the share price.
    uint256 public constant PROFIT_UNLOCK_PERIOD = 3 days;
    /// @notice The vault's own record of assets deployed into adapters (principal plus
    ///         recognized profit). Compared against live adapter balances to measure yield;
    ///         immune to direct token donations.
    uint256 public trackedDeployed;
    /// @notice Profit recognized at the last checkpoint that is still vesting.
    uint256 public lockedProfitStored;
    /// @notice Timestamp of the last profit checkpoint.
    uint256 public lastProfitCheckpoint;
    /// @notice Yield recognized since the last rebalance — the caller-reward base.
    uint256 public rewardableYield;

    /// @notice Minimum time between rebalances, in seconds.
    uint256 public immutable cooldownPeriod;
    /// @notice Minimum rate improvement (1e18 = 100% APR scale) required for a rebalance.
    uint256 public immutable rateThreshold;
    /// @notice Rebalance caller reward, in basis points of yield accrued since the last rebalance.
    uint256 public immutable callerRewardBps;

    /// @notice Hard ceiling on any rate considered when selecting an adapter
    ///         (1e18 = 100% APR scale).
    /// @dev A rate above this means the market is either being manipulated
    ///      (flash-loan utilization spike) or too illiquid to safely enter —
    ///      never chase it.
    uint256 public immutable maxSaneRate;

    /// @notice True for registered adapter addresses; only these (and WRBTC) may send native rBTC to the vault.
    mapping(address => bool) public isAdapter;

    /// @notice Emitted when deployed funds move from one adapter to another.
    /// @param fromAdapter Adapter the funds were withdrawn from.
    /// @param toAdapter Adapter the funds were deposited into.
    /// @param amount Balance withdrawn from the previous adapter.
    /// @param oldRate Rate of the previous adapter at rebalance time (1e18 = 100% APR).
    /// @param newRate Rate of the new adapter at rebalance time (1e18 = 100% APR).
    /// @param caller Address that triggered the rebalance.
    event Rebalanced(
        address indexed fromAdapter,
        address indexed toAdapter,
        uint256 amount,
        uint256 oldRate,
        uint256 newRate,
        address indexed caller
    );

    /// @notice Emitted when idle funds are deployed to an adapter for the first time.
    /// @param adapter Adapter selected for the initial deployment.
    /// @param amount Amount of assets deployed.
    event InitialDepositDeployed(address indexed adapter, uint256 amount);

    /// @notice Emitted whenever a profit checkpoint recognizes a change in deployed value.
    /// @param gain Newly recognized profit (zero on loss checkpoints).
    /// @param loss Newly recognized loss (zero on gain checkpoints).
    /// @param lockedProfitAfter Locked, still-vesting profit after this checkpoint.
    event YieldRecognized(uint256 gain, uint256 loss, uint256 lockedProfitAfter);

    /// @notice Emitted when a rebalance caller is paid their reward.
    /// @param rebalancer Caller that received the reward.
    /// @param reward Native rBTC amount paid out.
    /// @param yieldAccrued Yield accrued since the last rebalance, from which the reward was computed.
    event RebalancerRewardPaid(address indexed rebalancer, uint256 reward, uint256 yieldAccrued);

    /// @notice Deploys the vault with a fixed adapter set and immutable rebalance parameters.
    /// @dev Registers each adapter and binds it to this vault via setVault().
    ///      The caller reward is capped at 500 bps (5%).
    /// @param _wrbtc WRBTC token address; the ERC-4626 underlying asset.
    /// @param _adapters Lending adapters to register (at least 2 required).
    /// @param _cooldownPeriod Minimum seconds between rebalances.
    /// @param _rateThreshold Minimum rate improvement (1e18 = 100% APR) required to rebalance.
    /// @param _callerRewardBps Rebalance caller reward in basis points of accrued yield (max 500).
    /// @param _maxSaneRate Hard ceiling on rates considered during adapter selection (1e18 = 100% APR).
    constructor(
        address _wrbtc,
        ILendingAdapter[] memory _adapters,
        uint256 _cooldownPeriod,
        uint256 _rateThreshold,
        uint256 _callerRewardBps,
        uint256 _maxSaneRate
    ) ERC4626(IERC20(_wrbtc)) ERC20("Rootstock Yield Vault", "ryRBTC") ERC20Permit("Rootstock Yield Vault") {
        require(_adapters.length >= 2, "need at least 2 adapters");
        require(_callerRewardBps <= 500, "reward too high"); // max 5%
        require(_maxSaneRate > 0, "zero max rate");

        cooldownPeriod = _cooldownPeriod;
        rateThreshold = _rateThreshold;
        callerRewardBps = _callerRewardBps;
        maxSaneRate = _maxSaneRate;
        lastProfitCheckpoint = block.timestamp;

        for (uint256 i = 0; i < _adapters.length; i++) {
            adapters.push(_adapters[i]);
            isAdapter[address(_adapters[i])] = true;
            _adapters[i].setVault(address(this));
        }
    }

    // -- ERC-4626 overrides --

    /// @notice Total assets backing the share price: idle WRBTC plus deployed
    ///         balances, minus profit that is still vesting.
    /// @dev Deployed gains enter the price only after being checkpointed and
    ///      then linearly over PROFIT_UNLOCK_PERIOD, so a sudden balance jump
    ///      (lazy index update, airdrop) cannot be sniped by depositing right
    ///      before it and exiting right after. Losses are reflected immediately,
    ///      absorbed by the locked buffer first.
    /// @return Priced total assets, denominated in the underlying WRBTC.
    function totalAssets() public view override returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 raw = _deployedBalance();
        uint256 locked = lockedProfit();
        if (raw >= trackedDeployed) {
            // unrecognized gains stay out of the price until checkpointed
            uint256 base = trackedDeployed > locked ? trackedDeployed - locked : 0;
            return idle + base;
        }
        // unrecognized loss: consumed from the locked buffer first
        uint256 loss = trackedDeployed - raw;
        uint256 lockedAfterLoss = locked > loss ? locked - loss : 0;
        uint256 baseLoss = raw > lockedAfterLoss ? raw - lockedAfterLoss : 0;
        return idle + baseLoss;
    }

    /// @notice Profit recognized but not yet unlocked into the share price.
    /// @return Remaining locked profit; decays linearly to zero over
    ///         PROFIT_UNLOCK_PERIOD from the last checkpoint.
    function lockedProfit() public view returns (uint256) {
        uint256 elapsed = block.timestamp - lastProfitCheckpoint;
        if (elapsed >= PROFIT_UNLOCK_PERIOD) return 0;
        return lockedProfitStored * (PROFIT_UNLOCK_PERIOD - elapsed) / PROFIT_UNLOCK_PERIOD;
    }

    /// @dev Live sum of all adapter balances (undiscounted).
    function _deployedBalance() internal view returns (uint256 total) {
        uint256 len = adapters.length;
        for (uint256 i = 0; i < len; ++i) {
            total += adapters[i].getBalance();
        }
    }

    /// @dev Recognizes deployed-balance changes since the last checkpoint:
    ///      gains start vesting (and accrue to the reward base), losses are
    ///      absorbed by the locked buffer and shrink the reward base. Donation
    ///      -proof: only adapter balance growth counts, never idle transfers.
    function _checkpointProfit() internal {
        uint256 current = _deployedBalance();
        uint256 remaining = lockedProfit();
        if (current >= trackedDeployed) {
            uint256 gain = current - trackedDeployed;
            lockedProfitStored = remaining + gain;
            rewardableYield += gain;
            if (gain > 0) emit YieldRecognized(gain, 0, lockedProfitStored);
        } else {
            uint256 loss = trackedDeployed - current;
            lockedProfitStored = remaining > loss ? remaining - loss : 0;
            rewardableYield = rewardableYield > loss ? rewardableYield - loss : 0;
            emit YieldRecognized(0, loss, lockedProfitStored);
        }
        trackedDeployed = current;
        lastProfitCheckpoint = block.timestamp;
    }

    /// @dev Adds 3 decimals of virtual share precision to blunt inflation/donation attacks.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 3;
    }

    /// @dev Resolves the ERC4626/ERC20Permit diamond: share decimals come from
    ///      ERC4626 (underlying decimals plus the virtual offset).
    function decimals() public view override(ERC4626, ERC20) returns (uint8) {
        return super.decimals();
    }

    /// @dev Checkpoints profit, then deploys deposited assets to the active
    ///      adapter (if one is set). Deployed principal is added to the tracked
    ///      baseline so it never counts as yield.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override nonReentrant {
        _checkpointProfit();
        super._deposit(caller, receiver, assets, shares);
        if (address(activeAdapter) != address(0)) {
            _deployToActiveAdapter(assets);
            trackedDeployed += assets;
        }
    }

    /// @dev Checkpoints profit, then pulls from the active adapter when idle
    ///      WRBTC is insufficient. The tracked baseline drops by what was
    ///      actually pulled.
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override nonReentrant {
        _checkpointProfit();
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle < assets && address(activeAdapter) != address(0)) {
            uint256 pulled = _pullFromAdapter(assets - idle);
            trackedDeployed = trackedDeployed > pulled ? trackedDeployed - pulled : 0;
        }
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    // -- Native rBTC convenience functions --

    /// @notice Deposits native rBTC, wraps it into WRBTC, and mints vault shares to `receiver`.
    /// @dev Shares are computed before wrapping so totalAssets() is not inflated by the
    ///      incoming value. Assets are deployed to the active adapter immediately when one is set.
    /// @param receiver Address that receives the minted shares.
    /// @return shares Amount of vault shares minted.
    function depositNative(address receiver) external payable nonReentrant returns (uint256 shares) {
        uint256 assets = msg.value;
        require(assets > 0, "zero deposit");
        require(assets <= maxDeposit(receiver), "deposit exceeds max");

        _checkpointProfit();

        // Calculate shares BEFORE wrapping so totalAssets() isn't inflated
        shares = previewDeposit(assets);

        IWRBTC(asset()).deposit{value: assets}();
        _mint(receiver, shares);

        if (address(activeAdapter) != address(0)) {
            _deployToActiveAdapter(assets);
            trackedDeployed += assets;
        }

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Burns shares from `owner` and sends `assets` to `receiver` as native rBTC.
    /// @dev Pulls from the active adapter when idle WRBTC is insufficient, unwraps,
    ///      and sends via low-level call (not transfer) so contract receivers are not
    ///      limited to the 2300-gas stipend.
    /// @param assets Amount of underlying assets to withdraw.
    /// @param receiver Address that receives the native rBTC.
    /// @param owner Owner of the shares being burned; msg.sender must have allowance if different.
    /// @return shares Amount of vault shares burned.
    function withdrawNative(
        uint256 assets,
        address receiver,
        address owner
    ) external nonReentrant returns (uint256 shares) {
        _checkpointProfit();

        require(assets <= maxWithdraw(owner), "withdraw exceeds max");
        shares = previewWithdraw(assets);

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle < assets && address(activeAdapter) != address(0)) {
            uint256 pulled = _pullFromAdapter(assets - idle);
            trackedDeployed = trackedDeployed > pulled ? trackedDeployed - pulled : 0;
        }

        _burn(owner, shares);

        IWRBTC(asset()).withdraw(assets);
        (bool success,) = receiver.call{value: assets}("");
        require(success, "rBTC transfer failed");

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    // -- Rebalance --

    /// @notice Moves all deployed funds to the adapter with the best rate. Callable by
    ///         anyone once the cooldown has elapsed, provided the best rate beats the
    ///         current adapter's rate by more than rateThreshold. The caller is paid
    ///         callerRewardBps of the yield accrued since the last rebalance.
    /// @dev Adapters with rates above maxSaneRate are excluded from selection. The
    ///      withdrawal arrives as native rBTC; the caller reward is clamped to what the
    ///      rebalance actually withdrew, paid out, and the remainder is deposited into
    ///      the new adapter.
    function rebalance() external nonReentrant {
        require(address(activeAdapter) != address(0), "no active adapter");
        require(block.timestamp >= lastRebalanceTime + cooldownPeriod, "cooldown active");

        // A broken active adapter must not block escaping it: treat a
        // reverting rate query as zero so any sane alternative can win
        uint256 currentRate;
        try activeAdapter.getRate() returns (uint256 r) {
            currentRate = r;
        } catch {}
        (ILendingAdapter bestAdapter, uint256 bestRate) = _findBestRate();

        require(bestRate > currentRate + rateThreshold, "rate improvement too small");

        // Recognize all deployed growth so the reward base is current.
        // Donation-proof: rewardableYield only ever reflects adapter growth
        _checkpointProfit();
        uint256 yieldAccrued = rewardableYield;
        uint256 reward = yieldAccrued * callerRewardBps / 10_000;

        uint256 deployedBalance = activeAdapter.getBalance();
        ILendingAdapter previousAdapter = activeAdapter;

        // Withdraw everything from current adapter (native rBTC arrives here).
        // Skip when empty: Aave-style pools revert on zero-amount withdrawals
        uint256 balanceBefore = address(this).balance;
        if (deployedBalance > 0) {
            activeAdapter.withdraw(deployedBalance);
        }
        uint256 received = address(this).balance - balanceBefore;

        // Pay caller reward from native rBTC
        if (reward > received) reward = received;
        if (reward > 0) {
            (bool success,) = msg.sender.call{value: reward}("");
            require(success, "reward transfer failed");
            received -= reward;
            // The reward is paid out of recognized profit — shrink the vesting
            // buffer with it so the price never dips below principal
            uint256 remaining = lockedProfit();
            lockedProfitStored = remaining > reward ? remaining - reward : 0;
            emit RebalancerRewardPaid(msg.sender, reward, yieldAccrued);
        }
        rewardableYield = 0;

        // Deposit remainder into best adapter
        if (received > 0) {
            bestAdapter.deposit{value: received}();
        }

        activeAdapter = bestAdapter;
        lastRebalanceTime = block.timestamp;
        // Re-sync the baseline to the post-move reality (reward already out)
        trackedDeployed = _deployedBalance();

        emit Rebalanced(
            address(previousAdapter),
            address(bestAdapter),
            deployedBalance,
            currentRate,
            bestRate,
            msg.sender
        );
    }

    /// @notice Deploys the vault's idle WRBTC into the best-rate adapter for the first
    ///         time. Callable by anyone, but only while no adapter is active.
    /// @dev Selection state is written before the external calls
    ///      (checks-effects-interactions). Reverts if every adapter's rate exceeds
    ///      maxSaneRate.
    function initialDeposit() external nonReentrant {
        require(address(activeAdapter) == address(0), "already initialized");
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        require(idle > 0, "no funds to deploy");

        (ILendingAdapter bestAdapter,) = _findBestRate();
        require(address(bestAdapter) != address(0), "no adapter within sane rate");

        // Set selection state before the external calls (checks-effects-interactions)
        activeAdapter = bestAdapter;
        lastRebalanceTime = block.timestamp;

        IWRBTC(asset()).withdraw(idle);
        bestAdapter.deposit{value: idle}();

        trackedDeployed = _deployedBalance();
        lastProfitCheckpoint = block.timestamp;

        emit InitialDepositDeployed(address(bestAdapter), idle);
    }

    // -- View helpers --

    /// @notice Returns the number of registered adapters.
    /// @return Number of adapters.
    function getAdapterCount() external view returns (uint256) {
        return adapters.length;
    }

    /// @notice Returns the protocol name and current supply rate of every adapter.
    /// @return names Protocol name per adapter.
    /// @return rates Current supply rate per adapter (1e18 = 100% APR scale).
    function getAllRates() external view returns (string[] memory names, uint256[] memory rates) {
        uint256 len = adapters.length;
        names = new string[](len);
        rates = new uint256[](len);
        for (uint256 i = 0; i < len; ++i) {
            names[i] = adapters[i].getProtocolName();
            rates[i] = adapters[i].getRate();
        }
    }

    /// @notice Reports whether an adapter is currently usable: its contract
    ///         exists and both its rate and balance queries succeed.
    /// @param index Position of the adapter in the `adapters` array.
    /// @return True if the adapter responds to rate and balance queries.
    function isAdapterHealthy(uint256 index) public view returns (bool) {
        ILendingAdapter a = adapters[index];
        if (address(a).code.length == 0) return false;
        try a.getRate() {} catch {
            return false;
        }
        try a.getBalance() {} catch {
            return false;
        }
        return true;
    }

    /// @notice Health status of every registered adapter, for rebalancers and UIs.
    /// @return healthy Per-adapter health flags, indexed like `adapters`.
    function getAdapterHealth() external view returns (bool[] memory healthy) {
        uint256 len = adapters.length;
        healthy = new bool[](len);
        for (uint256 i = 0; i < len; ++i) {
            healthy[i] = isAdapterHealthy(i);
        }
    }

    // -- Internal helpers --

    /// @dev Scans all adapters and returns the one with the highest rate at or below
    ///      maxSaneRate. Returns the zero address (and zero rate) when none qualifies.
    function _findBestRate() internal view returns (ILendingAdapter bestAdapter, uint256 bestRate) {
        uint256 len = adapters.length;
        for (uint256 i = 0; i < len; ++i) {
            uint256 rate;
            // One broken adapter must not brick selection for the whole vault
            try adapters[i].getRate() returns (uint256 r) {
                rate = r;
            } catch {
                continue;
            }
            if (rate > maxSaneRate) continue; // manipulated or illiquid — never a candidate
            if (rate > bestRate) {
                bestRate = rate;
                bestAdapter = adapters[i];
            }
        }
    }

    function _deployToActiveAdapter(uint256 amount) internal {
        IWRBTC(asset()).withdraw(amount);
        activeAdapter.deposit{value: amount}();
    }

    function _pullFromAdapter(uint256 amount) internal returns (uint256 pulled) {
        pulled = activeAdapter.withdraw(amount);
        // Adapters can deliver slightly more than requested (round-up burns on
        // Sovryn) — wrap the entire balance so no native dust strands unaccounted
        IWRBTC(asset()).deposit{value: address(this).balance}();
    }

    /// @notice Accepts native rBTC only from WRBTC (unwrapping) and registered adapters
    ///         (withdrawals); any other direct transfer reverts.
    /// @dev WRBTC takes the cheap early-return path because its withdraw() pays out via
    ///      transfer() with a 2300-gas stipend.
    receive() external payable {
        // WRBTC checked first: its withdraw() pays out via transfer() with a
        // 2300-gas stipend, which leaves no room for the isAdapter storage read
        if (msg.sender == asset()) return;
        require(isAdapter[msg.sender], "direct rBTC transfers not allowed");
    }
}
