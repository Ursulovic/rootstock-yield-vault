// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
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
    /// @notice Best-rate adapter at the last allocation; holds the largest share
    ///         of deployed funds (up to the cap); zero until initialDeposit.
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
    /// @notice Yield recognized since the last rebalance; basis for the caller reward.
    uint256 public rewardableYield;

    /// @notice Minimum time that must pass between rebalances.
    uint256 public immutable cooldownPeriod;
    /// @notice Minimum rate improvement (on the 1e18 = 100% APR scale) required to rebalance.
    uint256 public immutable rateThreshold;
    /// @notice Share of accrued yield paid to the rebalance caller, in basis points (max 500).
    uint256 public immutable callerRewardBps;
    /// @notice Address allowed to pause and unpause the vault.
    address public immutable guardian;

    /// @notice Per-adapter concentration cap in basis points of total assets.
    /// @dev No single adapter may exceed this cap; overflow spills to the next
    ///      adapter or stays idle. Trued up on the next deposit or rebalance.
    uint256 public immutable adapterCapBps;

    /// @notice Immutable ceiling on totalAssets(). Deposits that would push the
    ///         vault above it are rejected; type(uint256).max means uncapped.
    /// @dev Enforced via maxDeposit/maxMint; production deploys use type(uint256).max.
    uint256 public immutable tvlCap;

    /// @notice Hard ceiling on any rate considered when selecting an adapter.
    /// @dev Rates above this are treated as manipulated or illiquid and ignored.
    uint256 public immutable maxSaneRate;

    /// @notice Emitted when funds move from one adapter to another.
    /// @param fromAdapter Adapter that was the primary before the rebalance.
    /// @param toAdapter New primary: the largest holder after re-allocation.
    /// @param amount Total deployed balance at rebalance time.
    /// @param oldRate Rate of the previous primary at rebalance time (1e18 = 100% APR).
    /// @param newRate Rate of the new primary after re-allocation (1e18 = 100% APR).
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

    /// @notice Emitted on an in-kind redemption.
    /// @param caller Address that initiated the redemption.
    /// @param receiver Address that received the idle assets and receipt tokens.
    /// @param owner Owner whose shares were burned.
    /// @param shares Shares burned.
    /// @param value Underlying value delivered, on the share-price (vesting-discounted) basis.
    event RedeemedInKind(
        address indexed caller, address indexed receiver, address indexed owner, uint256 shares, uint256 value
    );

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
    /// @param _adapterCapBps Per-adapter concentration cap in basis points of total assets.
    /// @param _tvlCap Ceiling on totalAssets(); use type(uint256).max for an uncapped vault.
    /// @param _guardian Address allowed to pause and unpause the vault.
    constructor(
        address _asset,
        IERC20LendingAdapter[] memory _adapters,
        uint256 _cooldownPeriod,
        uint256 _rateThreshold,
        uint256 _callerRewardBps,
        uint256 _maxSaneRate,
        uint256 _adapterCapBps,
        uint256 _tvlCap,
        string memory _name,
        string memory _symbol,
        address _guardian
    ) ERC4626(IERC20(_asset)) ERC20(_name, _symbol) ERC20Permit(_name) {
        require(_adapters.length >= 2, "need at least 2 adapters");
        require(_callerRewardBps <= 500, "reward too high");
        require(_maxSaneRate > 0, "zero max rate");
        require(_adapterCapBps > 0 && _adapterCapBps <= 10_000, "bad adapter cap");
        require(_adapterCapBps * _adapters.length >= 10_000, "caps cannot cover deposits");
        require(_tvlCap > 0, "tvlCap=0");
        require(_guardian != address(0), "zero guardian");

        cooldownPeriod = _cooldownPeriod;
        rateThreshold = _rateThreshold;
        callerRewardBps = _callerRewardBps;
        maxSaneRate = _maxSaneRate;
        adapterCapBps = _adapterCapBps;
        tvlCap = _tvlCap;
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

    /// @dev Fail-open sum of adapter balances (a reverting view counts as 0).
    ///      Exit-side pricing only; entry/recognition must use _strictDeployed.
    function _deployedBalance() internal view returns (uint256 total) {
        (total,) = _strictDeployed();
    }

    /// @dev Fail-open sum plus a health flag, false if any view reverts. A dark
    ///      adapter makes the total unmeasurable, so minting and profit
    ///      recognition refuse to act on it (depressed-price entry / phantom yield).
    function _strictDeployed() internal view returns (uint256 total, bool healthy) {
        healthy = true;
        uint256 len = adapters.length;
        for (uint256 i = 0; i < len; ++i) {
            try adapters[i].getBalance() returns (uint256 b) {
                total += b;
            } catch {
                healthy = false;
            }
        }
    }

    /// @dev Recognizes adapter-balance deltas since the last checkpoint (gains
    ///      vest, losses hit the buffer; only adapter growth counts). On a dark
    ///      adapter view, recognizes nothing and returns the cached baseline.
    function _checkpointProfit() internal returns (uint256 current) {
        bool healthy;
        (current, healthy) = _strictDeployed();
        if (!healthy) return trackedDeployed;
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

    /// @notice Assets depositable now: zero while paused, otherwise the
    ///         remaining headroom under the immutable TVL cap.
    /// @return Maximum deposit amount.
    function maxDeposit(address) public view override returns (uint256) {
        if (paused()) return 0;
        if (tvlCap == type(uint256).max) return super.maxDeposit(address(0));
        uint256 ta = totalAssets();
        return ta >= tvlCap ? 0 : tvlCap - ta;
    }

    /// @notice Shares mintable now: zero while paused, otherwise the shares
    ///         corresponding to the remaining cap headroom.
    /// @return Maximum mint amount.
    function maxMint(address) public view override returns (uint256) {
        if (paused()) return 0;
        if (tvlCap == type(uint256).max) return super.maxMint(address(0));
        return convertToShares(maxDeposit(address(0)));
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override nonReentrant whenNotPaused {
        // Fail-closed on entry: a dark adapter under-counts totalAssets, so
        // minting would let a depositor enter at a depressed price. Exits stay
        // fail-open by design.
        (, bool healthy) = _strictDeployed();
        require(healthy, "adapter view down");
        _checkpointProfit();
        super._deposit(caller, receiver, assets, shares);
        if (address(activeAdapter) != address(0)) {
            // Waterfall full idle balance to sweep stranded remainders.
            uint256 deployed = _deployWaterfall(IERC20(asset()).balanceOf(address(this)));
            trackedDeployed += deployed;
        }
    }

    /// @dev Withdrawals are not gated by paused(). Pulls from the active adapter if idle is short.
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override nonReentrant {
        uint256 deployedNow = _checkpointProfit();
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 raw = idle + deployedNow;
        if (idle < assets && address(activeAdapter) != address(0)) {
            uint256 pulled = _pullWaterfall(assets - idle);
            trackedDeployed = trackedDeployed > pulled ? trackedDeployed - pulled : 0;
        }
        // Drop the exit's pro-rata share from the reward base (mulDiv: overflow-safe; clamp guards rounding).
        if (raw > 0) {
            uint256 s = Math.mulDiv(rewardableYield, assets, raw);
            rewardableYield = rewardableYield > s ? rewardableYield - s : 0;
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

        // Reverting rate query counts as zero so a sane alternative can replace it.
        uint256 currentRate;
        try activeAdapter.getRate() returns (uint256 r) {
            currentRate = r;
        } catch {}
        (IERC20LendingAdapter bestAdapter, uint256 bestRate) = _findBestRate();

        require(bestRate > currentRate + rateThreshold, "rate improvement too small");

        // Fail-closed: rebalancing under a dark adapter would resync from an
        // under-count and synthesize phantom yield on recovery. Escape a dark
        // adapter via redeemInKind; block rebalance until its view recovers.
        (, bool healthy) = _strictDeployed();
        require(healthy, "adapter view down");

        // Refresh the reward base before computing the caller share.
        uint256 deployedBalance = _checkpointProfit();
        uint256 yieldAccrued = rewardableYield;
        uint256 reward = yieldAccrued * callerRewardBps / 10_000;
        // Cap reward at the unvested buffer; vested yield belongs to share price.
        if (reward > lockedProfitStored) reward = lockedProfitStored;

        IERC20LendingAdapter previousAdapter = activeAdapter;

        // Withdraw all positions; skip empties (Aave reverts on zero-amount).
        uint256 balanceBefore = IERC20(asset()).balanceOf(address(this));
        uint256 len = adapters.length;
        for (uint256 i = 0; i < len; ++i) {
            uint256 held;
            // skip adapters whose balance view reverts
            try adapters[i].getBalance() returns (uint256 b) { held = b; } catch { continue; }
            if (held > 0) {
                // Allow only sub-dust to stay behind; abort on material pull failure.
                try adapters[i].withdraw(held) {}
                catch {
                    require(held <= deployedBalance / 1e6, "rebalance pull failed");
                }
            }
        }
        uint256 received = IERC20(asset()).balanceOf(address(this)) - balanceBefore;

        if (reward > received) reward = received;
        if (reward > 0) {
            // Paid from locked-profit buffer; safe before re-allocation since a
            // plain ERC-20 safeTransfer hands no control to the caller (unlike
            // the native vault's rBTC .call).
            lockedProfitStored -= reward;
            IERC20(asset()).safeTransfer(msg.sender, reward);
            emit RebalancerRewardPaid(msg.sender, reward, yieldAccrued);
        }
        rewardableYield = 0;

        // Re-allocate all idle assets across adapters.
        {
            uint256 idleNow = IERC20(asset()).balanceOf(address(this));
            if (idleNow > 0) {
                _deployWaterfall(idleNow);
            }
        }

        // Record the largest post-allocation holder as primary; on ties pick the
        // highest rate to avoid no-op rebalances (own liquidity moves the rates).
        {
            uint256 maxHeld;
            for (uint256 i = 0; i < len; ++i) {
                uint256 held;
                try adapters[i].getBalance() returns (uint256 b) { held = b; } catch {}
                if (held > maxHeld) maxHeld = held;
            }
            if (maxHeld > 0) {
                bool found;
                uint256 bestHeldRate;
                for (uint256 i = 0; i < len; ++i) {
                    uint256 held;
                    // skip adapters whose balance view reverts
                    try adapters[i].getBalance() returns (uint256 b) { held = b; } catch { continue; }
                    // 1% tie window for allocation rounding
                    if (held + maxHeld / 100 < maxHeld) continue;
                    uint256 r;
                    try adapters[i].getRate() returns (uint256 rr) {
                        r = rr;
                    } catch {}
                    if (!found || r > bestHeldRate) {
                        found = true;
                        bestHeldRate = r;
                        bestAdapter = adapters[i];
                        bestRate = r;
                    }
                }
            }
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

        _deployWaterfall(idle);

        trackedDeployed = _deployedBalance();
        lastProfitCheckpoint = block.timestamp;

        emit InitialDepositDeployed(address(bestAdapter), idle);
    }


    /// @notice Burns `shares` and delivers the equivalent value IN KIND: a
    ///         pro-rata slice of the idle asset plus a pro-rata slice of every
    ///         adapter's receipt-token position, transferred directly to
    ///         `receiver`. Needs no protocol interaction beyond ERC-20
    ///         transfers, so it remains available even when the underlying
    ///         lending protocols pause supply and withdrawals.
    /// @dev The delivered fraction is computed on the share-price basis
    ///      (vesting-discounted), so still-locked profit cannot be captured by
    ///      exiting in kind. The receiver takes over protocol risk and must
    ///      redeem the receipt tokens with the protocols themselves.
    /// @param shares Shares to burn.
    /// @param receiver Recipient of the assets and receipt tokens.
    /// @param owner Owner of the shares; msg.sender needs allowance if different.
    /// @return value Underlying value delivered, on the discounted basis.
    function redeemInKind(uint256 shares, address receiver, address owner)
        external
        nonReentrant
        returns (uint256 value)
    {
        require(shares > 0, "zero shares");
        uint256 deployedNow = _checkpointProfit();

        value = previewRedeem(shares);
        require(value > 0, "zero value");
        // raw uses the checkpoint baseline (frozen on a dark view). value/raw
        // stays <= shares/supply, so the delivery is CONSERVATIVE: during a rare
        // getBalance-revert window an in-kind redeemer under-claims (the unclaimed
        // slice stays for other holders, recoverable when the view heals) rather
        // than over-distributing. Documented in KNOWN_ISSUES.
        uint256 raw = IERC20(asset()).balanceOf(address(this)) + deployedNow;

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }
        _burn(owner, shares);

        // Deliver value/raw of everything the vault holds (mulDiv: overflow-safe)
        uint256 idleShare = Math.mulDiv(IERC20(asset()).balanceOf(address(this)), value, raw);
        if (idleShare > 0) {
            SafeERC20.safeTransfer(IERC20(asset()), receiver, idleShare);
        }
        uint256 len = adapters.length;
        for (uint256 i = 0; i < len; ++i) {
            // Skip broken adapters; the redeemer forgoes that slice.
            try adapters[i].transferPosition(receiver, value, raw) {} catch {}
        }

        // Shrink baseline and reward base pro-rata (mulDiv: overflow-safe).
        uint256 td = Math.mulDiv(trackedDeployed, value, raw);
        trackedDeployed = trackedDeployed > td ? trackedDeployed - td : 0;
        uint256 ry = Math.mulDiv(rewardableYield, value, raw);
        rewardableYield = rewardableYield > ry ? rewardableYield - ry : 0;

        emit RedeemedInKind(msg.sender, receiver, owner, shares, value);
    }

    // -- View helpers --

    /// @notice Number of registered adapters.
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
            // Placeholder on revert so a single bad adapter does not break the listing.
            try adapters[i].getProtocolName() returns (string memory n) { names[i] = n; } catch { names[i] = "?"; }
            try adapters[i].getRate() returns (uint256 r) { rates[i] = r; } catch { rates[i] = 0; }
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
            if (rate > maxSaneRate) continue; // manipulated or illiquid
            if (rate > bestRate) {
                bestRate = rate;
                bestAdapter = adapters[i];
            }
        }
    }

    /// @dev Rate-sorted usable adapters (insertion sort; small fixed set).
    function _sortedSaneAdapters() internal view returns (IERC20LendingAdapter[] memory sorted, uint256 count) {
        uint256 len = adapters.length;
        sorted = new IERC20LendingAdapter[](len);
        uint256[] memory rates = new uint256[](len);
        for (uint256 i = 0; i < len; ++i) {
            uint256 rate;
            try adapters[i].getRate() returns (uint256 r) {
                rate = r;
            } catch {
                continue;
            }
            if (rate > maxSaneRate) continue;
            uint256 j = count;
            while (j > 0 && rates[j - 1] < rate) {
                sorted[j] = sorted[j - 1];
                rates[j] = rates[j - 1];
                --j;
            }
            sorted[j] = adapters[i];
            rates[j] = rate;
            ++count;
        }
    }

    /// @dev Deploys `amount` of idle assets across sane adapters in rate order,
    ///      filling each up to its cap share of the post-deployment total.
    ///      Whatever cannot be placed stays idle. Returns the amount deployed.
    function _deployWaterfall(uint256 amount) internal returns (uint256 deployed) {
        (IERC20LendingAdapter[] memory sorted, uint256 count) = _sortedSaneAdapters();
        if (count == 0) return 0;

        uint256 capBase = IERC20(asset()).balanceOf(address(this)) + _deployedBalance();
        uint256 cap = capBase * adapterCapBps / 10_000;

        for (uint256 i = 0; i < count && amount > 0; ++i) {
            uint256 held;
            try sorted[i].getBalance() returns (uint256 b) { held = b; } catch { continue; }
            if (held >= cap) continue;
            uint256 room = cap - held;
            uint256 place = amount < room ? amount : room;
            if (place == 0) continue;
            // Sub-dust slices may revert (e.g. Aave); leave idle on failure.
            try sorted[i].deposit(place) {
                amount -= place;
                deployed += place;
            } catch {}
        }
    }

    /// @dev Pulls `amount` from adapters starting with the WORST rate so the
    ///      best-yielding allocations are drained last. Returns the amount pulled.
    function _pullWaterfall(uint256 amount) internal returns (uint256 pulled) {
        (IERC20LendingAdapter[] memory sorted, uint256 count) = _sortedSaneAdapters();
        for (uint256 i = count; i > 0 && pulled < amount; --i) {
            IERC20LendingAdapter a = sorted[i - 1];
            uint256 held;
            try a.getBalance() returns (uint256 b) { held = b; } catch { continue; }
            if (held == 0) continue;
            uint256 want = amount - pulled;
            uint256 take = want < held ? want : held;
            // Skip on revert; remainder covered by next adapter or fallback.
            try a.withdraw(take) returns (uint256 got) {
                pulled += got;
            } catch {}
        }
        // Fallback: unsorted pass for adapters with failing rate queries.
        if (pulled < amount) {
            uint256 len = adapters.length;
            for (uint256 i = 0; i < len && pulled < amount; ++i) {
                uint256 held;
                try adapters[i].getBalance() returns (uint256 h) {
                    held = h;
                } catch {
                    continue;
                }
                if (held == 0) continue;
                uint256 want = amount - pulled;
                uint256 take = want < held ? want : held;
                try adapters[i].withdraw(take) returns (uint256 got) {
                    pulled += got;
                } catch {}
            }
        }
    }
}
