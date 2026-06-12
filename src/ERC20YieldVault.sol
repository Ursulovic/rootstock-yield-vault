// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20LendingAdapter} from "./interfaces/IERC20LendingAdapter.sol";

/// @title ERC20YieldVault
/// @notice ERC-4626 vault that deploys an ERC-20 asset into the highest-yielding
///         of a fixed set of lending adapters and rebalances between them when
///         a sufficiently better rate appears. Anyone can trigger a rebalance
///         and earns a reward taken from accrued yield.
/// @dev Adapters report supply rates normalized to a common scale where
///      1e18 = 100% APR. A guardian can pause deposits/mints and rebalancing;
///      withdrawals and redemptions always remain open.
contract ERC20YieldVault is ERC4626, ERC20Permit, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /// @notice Registered lending adapters the vault can allocate to.
    IERC20LendingAdapter[] public adapters;
    /// @notice Adapter currently holding the vault's deployed funds; zero address until `initialDeposit`.
    IERC20LendingAdapter public activeAdapter;

    /// @notice Timestamp of the last rebalance (or initial deployment), used for the cooldown check.
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

    /// @notice Minimum time that must pass between rebalances.
    uint256 public immutable cooldownPeriod;
    /// @notice Minimum rate improvement (on the 1e18 = 100% APR scale) required to rebalance.
    uint256 public immutable rateThreshold;
    /// @notice Share of accrued yield paid to the rebalance caller, in basis points (max 500).
    uint256 public immutable callerRewardBps;
    /// @notice Address allowed to pause and unpause the vault.
    address public immutable guardian;

    /// @notice Hard ceiling on any rate considered when selecting an adapter.
    /// @dev A rate above this means the market is either being manipulated
    ///      (flash-loan utilization spike) or too illiquid to safely enter —
    ///      never chase it.
    uint256 public immutable maxSaneRate;

    /// @notice Emitted when funds move from one adapter to another.
    /// @param fromAdapter Adapter funds were withdrawn from.
    /// @param toAdapter Adapter funds were deposited into.
    /// @param amount Balance held by the previous adapter before withdrawal.
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

    /// @notice Emitted when idle funds are first deployed to an adapter.
    /// @param adapter Adapter that received the funds.
    /// @param amount Amount of the asset deployed.
    event InitialDepositDeployed(address indexed adapter, uint256 amount);

    /// @notice Emitted whenever a profit checkpoint recognizes a change in deployed value.
    /// @param gain Newly recognized profit (zero on loss checkpoints).
    /// @param loss Newly recognized loss (zero on gain checkpoints).
    /// @param lockedProfitAfter Locked, still-vesting profit after this checkpoint.
    event YieldRecognized(uint256 gain, uint256 loss, uint256 lockedProfitAfter);

    /// @notice Emitted when a rebalance caller is paid their reward.
    /// @param rebalancer Address that received the reward.
    /// @param reward Amount of the asset paid out (clamped to what the rebalance actually withdrew).
    /// @param yieldAccrued Recognized yield since the last rebalance that the reward was computed from.
    event RebalancerRewardPaid(address indexed rebalancer, uint256 reward, uint256 yieldAccrued);

    modifier onlyGuardian() {
        require(msg.sender == guardian, "only guardian");
        _;
    }

    /// @notice Deploys the vault, registers the adapters, and grants each one
    ///         an unlimited asset allowance.
    /// @dev Each adapter is bound to this vault via `setVault`. The adapter set
    ///      is fixed for the lifetime of the contract.
    /// @param _asset Underlying ERC-20 asset of the vault.
    /// @param _adapters Lending adapters to register (at least 2).
    /// @param _cooldownPeriod Minimum seconds between rebalances.
    /// @param _rateThreshold Minimum rate improvement required to rebalance (1e18 = 100% APR scale).
    /// @param _callerRewardBps Rebalance caller reward in basis points (max 500).
    /// @param _maxSaneRate Ceiling above which a rate is treated as manipulated/illiquid and ignored.
    /// @param _name ERC-20 name of the vault share token.
    /// @param _symbol ERC-20 symbol of the vault share token.
    /// @param _guardian Address allowed to pause and unpause the vault.
    constructor(
        address _asset,
        IERC20LendingAdapter[] memory _adapters,
        uint256 _cooldownPeriod,
        uint256 _rateThreshold,
        uint256 _callerRewardBps,
        uint256 _maxSaneRate,
        string memory _name,
        string memory _symbol,
        address _guardian
    ) ERC4626(IERC20(_asset)) ERC20(_name, _symbol) ERC20Permit(_name) {
        require(_adapters.length >= 2, "need at least 2 adapters");
        require(_callerRewardBps <= 500, "reward too high");
        require(_maxSaneRate > 0, "zero max rate");
        require(_guardian != address(0), "zero guardian");

        cooldownPeriod = _cooldownPeriod;
        rateThreshold = _rateThreshold;
        callerRewardBps = _callerRewardBps;
        maxSaneRate = _maxSaneRate;
        guardian = _guardian;
        lastProfitCheckpoint = block.timestamp;

        for (uint256 i = 0; i < _adapters.length; i++) {
            adapters.push(_adapters[i]);
            _adapters[i].setVault(address(this));
            IERC20(_asset).forceApprove(address(_adapters[i]), type(uint256).max);
        }
    }

    // -- Guardian functions --

    /// @notice Pauses deposits, mints, and rebalancing. Withdrawals stay open.
    function pause() external onlyGuardian {
        _pause();
    }

    /// @notice Resumes deposits, mints, and rebalancing.
    function unpause() external onlyGuardian {
        _unpause();
    }

    // -- ERC-4626 overrides --

    /// @notice Total assets backing the share price: idle balance plus deployed
    ///         balances, minus profit that is still vesting.
    /// @dev Deployed gains enter the price only after being checkpointed and
    ///      then linearly over PROFIT_UNLOCK_PERIOD, so a sudden balance jump
    ///      (lazy index update, airdrop) cannot be sniped by depositing right
    ///      before it and exiting right after. Losses are reflected immediately,
    ///      absorbed by the locked buffer first.
    /// @return Priced total assets, denominated in the underlying asset.
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

    /// @dev Shares carry 3 extra decimals over the asset to blunt inflation/donation attacks.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 3;
    }

    /// @dev Resolves the ERC4626/ERC20Permit diamond: share decimals come from
    ///      ERC4626 (underlying decimals plus the virtual offset).
    function decimals() public view override(ERC4626, ERC20) returns (uint8) {
        return super.decimals();
    }

    /// @notice Maximum assets that can be deposited; zero while the vault is paused.
    /// @return Maximum deposit amount.
    function maxDeposit(address) public view override returns (uint256) {
        return paused() ? 0 : super.maxDeposit(address(0));
    }

    /// @notice Maximum shares that can be minted; zero while the vault is paused.
    /// @return Maximum mint amount.
    function maxMint(address) public view override returns (uint256) {
        return paused() ? 0 : super.maxMint(address(0));
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override nonReentrant whenNotPaused {
        _checkpointProfit();
        super._deposit(caller, receiver, assets, shares);
        if (address(activeAdapter) != address(0)) {
            _deployToActiveAdapter(assets);
            trackedDeployed += assets;
        }
    }

    /// @dev Withdrawals always work, even when paused — users must be able to exit.
    ///      Pulls the shortfall from the active adapter when idle balance is insufficient.
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

    // -- Rebalance --

    /// @notice Moves all deployed funds to the adapter with the best rate and
    ///         pays the caller a share of the yield accrued since the last
    ///         rebalance. Callable by anyone once the cooldown has elapsed and
    ///         the best rate beats the current one by at least `rateThreshold`.
    /// @dev Adapters quoting above `maxSaneRate` are excluded from selection.
    ///      The caller reward is clamped to what the rebalance actually
    ///      withdrew from the previous adapter.
    function rebalance() external nonReentrant whenNotPaused {
        require(address(activeAdapter) != address(0), "no active adapter");
        require(block.timestamp >= lastRebalanceTime + cooldownPeriod, "cooldown active");

        // A broken active adapter must not block escaping it: treat a
        // reverting rate query as zero so any sane alternative can win
        uint256 currentRate;
        try activeAdapter.getRate() returns (uint256 r) {
            currentRate = r;
        } catch {}
        (IERC20LendingAdapter bestAdapter, uint256 bestRate) = _findBestRate();

        require(bestRate > currentRate + rateThreshold, "rate improvement too small");

        // Recognize all deployed growth so the reward base is current.
        // Donation-proof: rewardableYield only ever reflects adapter growth
        _checkpointProfit();
        uint256 yieldAccrued = rewardableYield;
        uint256 reward = yieldAccrued * callerRewardBps / 10_000;

        uint256 deployedBalance = activeAdapter.getBalance();
        IERC20LendingAdapter previousAdapter = activeAdapter;

        // Skip when empty: Aave-style pools revert on zero-amount withdrawals
        uint256 balanceBefore = IERC20(asset()).balanceOf(address(this));
        if (deployedBalance > 0) {
            activeAdapter.withdraw(deployedBalance);
        }
        uint256 received = IERC20(asset()).balanceOf(address(this)) - balanceBefore;

        if (reward > received) reward = received;
        if (reward > 0) {
            IERC20(asset()).safeTransfer(msg.sender, reward);
            received -= reward;
            // The reward is paid out of recognized profit — shrink the vesting
            // buffer with it so the price never dips below principal
            uint256 remaining = lockedProfit();
            lockedProfitStored = remaining > reward ? remaining - reward : 0;
            emit RebalancerRewardPaid(msg.sender, reward, yieldAccrued);
        }
        rewardableYield = 0;

        if (received > 0) {
            bestAdapter.deposit(received);
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

    /// @notice One-time bootstrap: deploys all idle funds to the adapter with
    ///         the best rate. Callable by anyone, only before an active adapter
    ///         has been selected.
    function initialDeposit() external nonReentrant whenNotPaused {
        require(address(activeAdapter) == address(0), "already initialized");
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        require(idle > 0, "no funds to deploy");

        (IERC20LendingAdapter bestAdapter,) = _findBestRate();
        require(address(bestAdapter) != address(0), "no adapter within sane rate");

        // Set selection state before the external call (checks-effects-interactions)
        activeAdapter = bestAdapter;
        lastRebalanceTime = block.timestamp;

        bestAdapter.deposit(idle);

        trackedDeployed = _deployedBalance();
        lastProfitCheckpoint = block.timestamp;

        emit InitialDepositDeployed(address(bestAdapter), idle);
    }

    // -- View helpers --

    /// @notice Number of registered adapters.
    /// @return Adapter count.
    function getAdapterCount() external view returns (uint256) {
        return adapters.length;
    }

    /// @notice Current rate of every registered adapter, paired with its protocol name.
    /// @return names Protocol name reported by each adapter.
    /// @return rates Current supply rate of each adapter (1e18 = 100% APR).
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
        IERC20LendingAdapter a = adapters[index];
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

    function _findBestRate() internal view returns (IERC20LendingAdapter bestAdapter, uint256 bestRate) {
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
        activeAdapter.deposit(amount);
    }

    function _pullFromAdapter(uint256 amount) internal returns (uint256 pulled) {
        pulled = activeAdapter.withdraw(amount);
    }
}
