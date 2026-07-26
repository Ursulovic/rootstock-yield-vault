// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
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
    /// @notice Best-rate adapter at the last allocation; holds the largest share
    ///         of deployed funds (up to the cap); zero until initialDeposit() runs.
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
    /// @notice Yield recognized since the last rebalance; basis for the caller reward.
    uint256 public rewardableYield;

    /// @notice Minimum time between rebalances, in seconds.
    uint256 public immutable cooldownPeriod;
    /// @notice Minimum rate improvement (1e18 = 100% APR scale) required for a rebalance.
    uint256 public immutable rateThreshold;
    /// @notice Rebalance caller reward, in basis points of yield accrued since the last rebalance.
    uint256 public immutable callerRewardBps;

    /// @notice Hard ceiling on any rate considered when selecting an adapter
    ///         (1e18 = 100% APR scale).
    /// @dev Rates above this are treated as manipulated or illiquid and ignored.
    uint256 public immutable maxSaneRate;

    /// @notice Per-adapter concentration cap in basis points of total assets.
    /// @dev No single adapter may exceed this cap; overflow spills to the next
    ///      adapter or stays idle. Trued up on the next deposit or rebalance.
    uint256 public immutable adapterCapBps;

    /// @notice Immutable ceiling on totalAssets(). Deposits that would push the
    ///         vault above it are rejected; type(uint256).max means uncapped.
    /// @dev Enforced via maxDeposit/maxMint; production deploys use type(uint256).max.
    uint256 public immutable tvlCap;

    /// @notice Per-venue utilization ceiling in basis points. A market at or
    ///         above the ceiling receives no new allocation; funds spill to the
    ///         next venue or stay idle.
    /// @dev Entry gate only: exits never consult utilization, and drift above
    ///      the ceiling after allocation is tolerated until a later deposit or
    ///      rebalance re-routes. 10_000 only skips fully utilized markets.
    uint256 public immutable utilizationCeilingBps;

    /// @notice True for registered adapter addresses; only these (and WRBTC) may send native rBTC to the vault.
    mapping(address => bool) public isAdapter;

    /// @notice Emitted when deployed funds move from one adapter to another.
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

    /// @notice Emitted when idle funds are deployed to an adapter for the first time.
    /// @param adapter Adapter selected for the initial deployment.
    /// @param amount Amount of assets deployed.
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
    /// @param _adapterCapBps Per-adapter concentration cap in basis points of total assets.
    /// @param _tvlCap Ceiling on totalAssets(); use type(uint256).max for an uncapped vault.
    /// @param _utilizationCeilingBps Per-venue utilization ceiling in basis points; markets at or above it receive no new allocation.
    constructor(
        address _wrbtc,
        ILendingAdapter[] memory _adapters,
        uint256 _cooldownPeriod,
        uint256 _rateThreshold,
        uint256 _callerRewardBps,
        uint256 _maxSaneRate,
        uint256 _adapterCapBps,
        uint256 _tvlCap,
        uint256 _utilizationCeilingBps
    ) ERC4626(IERC20(_wrbtc)) ERC20("Rootstock Yield Vault", "ryRBTC") ERC20Permit("Rootstock Yield Vault") {
        require(_adapters.length >= 2, "need at least 2 adapters");
        require(_callerRewardBps <= 500, "reward too high"); // max 5%
        require(_maxSaneRate > 0, "zero max rate");
        require(_adapterCapBps > 0 && _adapterCapBps <= 10_000, "bad adapter cap");
        require(_adapterCapBps * _adapters.length >= 10_000, "caps cannot cover deposits");
        require(_tvlCap > 0, "tvlCap=0");
        require(_utilizationCeilingBps > 0 && _utilizationCeilingBps <= 10_000, "bad utilization ceiling");

        cooldownPeriod = _cooldownPeriod;
        rateThreshold = _rateThreshold;
        callerRewardBps = _callerRewardBps;
        maxSaneRate = _maxSaneRate;
        adapterCapBps = _adapterCapBps;
        tvlCap = _tvlCap;
        utilizationCeilingBps = _utilizationCeilingBps;
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

    /// @dev Adds 3 decimals of virtual share precision to blunt inflation/donation attacks.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 3;
    }

    /// @dev Resolves the ERC4626/ERC20Permit diamond: share decimals come from
    ///      ERC4626 (underlying decimals plus the virtual offset).
    function decimals() public view override(ERC4626, ERC20) returns (uint8) {
        return super.decimals();
    }

    /// @notice Assets still depositable before the immutable TVL cap binds.
    /// @dev type(uint256).max sentinel means uncapped; gates deposit(), mint()
    ///      and depositNative() since all consult maxDeposit.
    /// @return Remaining headroom under the cap (zero once full).
    function maxDeposit(address) public view override returns (uint256) {
        if (tvlCap == type(uint256).max) return type(uint256).max;
        uint256 ta = totalAssets();
        return ta >= tvlCap ? 0 : tvlCap - ta;
    }

    /// @notice Shares still mintable before the immutable TVL cap binds.
    /// @return Shares corresponding to the remaining cap headroom.
    function maxMint(address) public view override returns (uint256) {
        if (tvlCap == type(uint256).max) return type(uint256).max;
        return convertToShares(maxDeposit(address(0)));
    }

    /// @dev Checkpoints profit, then deploys deposited assets to the active
    ///      adapter (if one is set). Deployed principal is added to the tracked
    ///      baseline so it never counts as yield.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override nonReentrant {
        // Fail-closed on entry: a dark adapter under-counts totalAssets, so
        // minting would let a depositor enter at a depressed price. Exits stay
        // fail-open by design.
        (, bool healthy) = _strictDeployed();
        require(healthy, "adapter view down");
        _checkpointProfit();
        super._deposit(caller, receiver, assets, shares);
        if (address(activeAdapter) != address(0)) {
            // Waterfall full idle balance to sweep any previously stranded remainder.
            uint256 deployed = _deployWaterfall(IERC20(asset()).balanceOf(address(this)));
            trackedDeployed += deployed;
        }
    }

    /// @dev Checkpoints profit, then pulls from the active adapter when idle
    ///      WRBTC is insufficient. The tracked baseline drops by what was
    ///      actually pulled.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
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

        // Entry fail-closed: never mint against an under-counted total (see _deposit)
        (, bool healthy) = _strictDeployed();
        require(healthy, "adapter view down");

        _checkpointProfit();

        // Calculate shares BEFORE wrapping so totalAssets() isn't inflated
        shares = previewDeposit(assets);

        IWRBTC(asset()).deposit{value: assets}();
        _mint(receiver, shares);

        if (address(activeAdapter) != address(0)) {
            // Full idle balance, not just this deposit (see _deposit).
            uint256 deployed = _deployWaterfall(IERC20(asset()).balanceOf(address(this)));
            trackedDeployed += deployed;
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
    function withdrawNative(uint256 assets, address receiver, address owner)
        external
        nonReentrant
        returns (uint256 shares)
    {
        uint256 deployedNow = _checkpointProfit();

        require(assets <= maxWithdraw(owner), "withdraw exceeds max");
        shares = previewWithdraw(assets);

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 raw = idle + deployedNow;
        if (idle < assets && address(activeAdapter) != address(0)) {
            uint256 pulled = _pullWaterfall(assets - idle);
            trackedDeployed = trackedDeployed > pulled ? trackedDeployed - pulled : 0;
        }
        // Drop the exit's pro-rata share from the reward base (mulDiv: overflow-safe).
        if (raw > 0) {
            uint256 s = Math.mulDiv(rewardableYield, assets, raw);
            rewardableYield = rewardableYield > s ? rewardableYield - s : 0;
        }

        _burn(owner, shares);

        IWRBTC(asset()).withdraw(assets);
        (bool success,) = receiver.call{value: assets}("");
        require(success, "rBTC transfer failed");

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    // -- Rebalance --

    /// @notice Re-allocates all deployed funds across adapters by rate order,
    ///         respecting the per-adapter cap. Callable by anyone once the cooldown
    ///         has elapsed, provided the best sane rate beats the current primary
    ///         adapter's rate by more than rateThreshold. The caller is paid
    ///         callerRewardBps of the yield recognized since the last rebalance.
    /// @dev Adapters with rates above maxSaneRate are excluded from selection. The
    ///      withdrawals arrive as native rBTC; the caller reward is clamped to what
    ///      the rebalance actually withdrew, paid out, and the remainder is
    ///      waterfall-deployed (best adapter first, up to adapterCapBps each).
    function rebalance() external nonReentrant {
        require(address(activeAdapter) != address(0), "no active adapter");
        require(block.timestamp >= lastRebalanceTime + cooldownPeriod, "cooldown active");

        // Reverting rate query counts as zero so a sane alternative can replace a broken adapter.
        uint256 currentRate;
        try activeAdapter.getRate() returns (uint256 r) {
            currentRate = r;
        } catch {}
        (ILendingAdapter bestAdapter, uint256 bestRate) = _findBestRate();

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

        ILendingAdapter previousAdapter = activeAdapter;

        // Withdraw all positions; skip empties (Aave reverts on zero-amount).
        uint256 balanceBefore = address(this).balance;
        uint256 len = adapters.length;
        for (uint256 i = 0; i < len; ++i) {
            uint256 held;
            // skip adapters whose balance view reverts
            try adapters[i].getBalance() returns (uint256 b) {
                held = b;
            } catch {
                continue;
            }
            if (held > 0) {
                // Allow only sub-dust to stay behind; abort on material pull failure.
                try adapters[i].withdraw(held) {}
                catch {
                    require(held <= deployedBalance / 1e6, "rebalance pull failed");
                }
            }
        }
        uint256 received = address(this).balance - balanceBefore;

        // Pay reward last (after resync) to avoid a read-only reentrancy window.
        if (reward > received) reward = received;
        received -= reward;
        rewardableYield = 0;

        // Wrap, then re-allocate all idle assets across adapters.
        if (received > 0) {
            IWRBTC(asset()).deposit{value: received}();
        }
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
                try adapters[i].getBalance() returns (uint256 b) {
                    held = b;
                } catch {}
                if (held > maxHeld) maxHeld = held;
            }
            if (maxHeld > 0) {
                bool found;
                uint256 bestHeldRate;
                for (uint256 i = 0; i < len; ++i) {
                    uint256 held;
                    // skip adapters whose balance view reverts
                    try adapters[i].getBalance() returns (uint256 b) {
                        held = b;
                    } catch {
                        continue;
                    }
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
        // Re-sync the baseline to the post-move reality (reward still held back)
        trackedDeployed = _deployedBalance();

        // Pay reward after resync so totalAssets stays consistent across the call.
        if (reward > 0) {
            // Paid from locked-profit buffer; share price unchanged.
            lockedProfitStored -= reward;
            (bool success,) = msg.sender.call{value: reward}("");
            require(success, "reward transfer failed");
            emit RebalancerRewardPaid(msg.sender, reward, yieldAccrued);
        }

        emit Rebalanced(
            address(previousAdapter), address(bestAdapter), deployedBalance, currentRate, bestRate, msg.sender
        );
    }

    /// @notice Deploys the vault's idle WRBTC across adapters for the first time,
    ///         best rate first, respecting the per-adapter cap. Callable by anyone,
    ///         but only while no adapter is active.
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

        _deployWaterfall(idle);

        trackedDeployed = _deployedBalance();
        lastProfitCheckpoint = block.timestamp;

        emit InitialDepositDeployed(address(bestAdapter), idle);
    }

    /// @notice Burns `shares` and delivers the equivalent value IN KIND: a
    ///         pro-rata slice of the idle WRBTC plus a pro-rata slice of every
    ///         adapter's receipt-token position, transferred directly to
    ///         `receiver`. Needs no protocol interaction beyond ERC-20
    ///         transfers: Sovryn iTokens stay transferable when mint/burn is
    ///         paused, and LayerBank aTokens while the reserve is frozen. A
    ///         full Aave-style pause freezes aToken transfers too; that slice
    ///         is then skipped and stays in the vault for remaining holders.
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
        // raw uses the frozen checkpoint baseline, so value/raw stays
        // <= shares/supply: a dark-view in-kind exit under-claims (conservative;
        // the unclaimed slice stays for holders). Documented in KNOWN_ISSUES.
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

    /// @notice Returns the protocol name and current supply rate of every adapter.
    /// @return names Protocol name per adapter.
    /// @return rates Current supply rate per adapter (1e18 = 100% APR scale).
    function getAllRates() external view returns (string[] memory names, uint256[] memory rates) {
        uint256 len = adapters.length;
        names = new string[](len);
        rates = new uint256[](len);
        for (uint256 i = 0; i < len; ++i) {
            // Placeholder on revert; the full listing must not fail for one bad adapter.
            try adapters[i].getProtocolName() returns (string memory n) {
                names[i] = n;
            } catch {
                names[i] = "?";
            }
            try adapters[i].getRate() returns (uint256 r) {
                rates[i] = r;
            } catch {
                rates[i] = 0;
            }
        }
    }

    /// @notice Reports whether an adapter is currently usable: its contract
    ///         exists and both its rate and balance queries succeed.
    /// @param index Position of the adapter in the `adapters` array.
    /// @return True if the adapter responds to rate and balance queries.
    function isAdapterHealthy(uint256 index) public view returns (bool) {
        ILendingAdapter a = adapters[index];
        if (address(a).code.length == 0) return false;
        try a.getRate() {}
        catch {
            return false;
        }
        try a.getBalance() {}
        catch {
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

    /// @dev Entry gate: true when the venue may receive new allocation. A
    ///      reverting utilization view counts as at ceiling (fail-closed for
    ///      entry, consistent with the dark-adapter deposit policy); exit
    ///      paths never call this.
    function _underUtilizationCeiling(ILendingAdapter adapter) internal view returns (bool) {
        try adapter.getUtilization() returns (uint256 u) {
            return u < utilizationCeilingBps * 1e14; // bps to the 1e18 = 100% scale
        } catch {
            return false;
        }
    }

    /// @dev Scans all adapters and returns the one with the highest rate at or
    ///      below maxSaneRate, skipping venues at or above the utilization
    ///      ceiling. Returns the zero address (and zero rate) when none qualifies.
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
            if (rate > maxSaneRate) continue; // manipulated or illiquid
            if (!_underUtilizationCeiling(adapters[i])) continue; // too thin to exit
            if (rate > bestRate) {
                bestRate = rate;
                bestAdapter = adapters[i];
            }
        }
    }

    /// @dev Rate-sorted usable adapters (insertion sort; small fixed set).
    function _sortedSaneAdapters() internal view returns (ILendingAdapter[] memory sorted, uint256 count) {
        uint256 len = adapters.length;
        sorted = new ILendingAdapter[](len);
        uint256[] memory rates = new uint256[](len);
        for (uint256 i = 0; i < len; ++i) {
            uint256 rate;
            try adapters[i].getRate() returns (uint256 r) {
                rate = r;
            } catch {
                continue;
            }
            if (rate > maxSaneRate) continue;
            // insert keeping descending rate order
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

    /// @dev Deploys `amount` of idle WRBTC across sane adapters below the
    ///      utilization ceiling, in rate order, filling each up to its cap
    ///      share of the post-deployment total. Whatever cannot be placed
    ///      stays idle. Returns the amount deployed.
    function _deployWaterfall(uint256 amount) internal returns (uint256 deployed) {
        (ILendingAdapter[] memory sorted, uint256 count) = _sortedSaneAdapters();
        if (count == 0) return 0;

        // Cap base: everything the vault holds after this deployment
        uint256 capBase = IERC20(asset()).balanceOf(address(this)) + _deployedBalance();
        uint256 cap = capBase * adapterCapBps / 10_000;

        for (uint256 i = 0; i < count && amount > 0; ++i) {
            if (!_underUtilizationCeiling(sorted[i])) continue;
            uint256 held;
            try sorted[i].getBalance() returns (uint256 b) {
                held = b;
            } catch {
                continue;
            }
            if (held >= cap) continue;
            uint256 room = cap - held;
            uint256 place = amount < room ? amount : room;
            if (place == 0) continue;
            IWRBTC(asset()).withdraw(place);
            // Sub-dust slices may revert (e.g. Aave); leave idle on failure.
            try sorted[i].deposit{value: place}() {
                amount -= place;
                deployed += place;
            } catch {
                IWRBTC(asset()).deposit{value: place}();
            }
        }
    }

    /// @dev Pulls `amount` from adapters starting with the WORST rate so the
    ///      best-yielding allocations are drained last. Wraps everything that
    ///      arrived. Returns the amount actually pulled.
    function _pullWaterfall(uint256 amount) internal returns (uint256 pulled) {
        (ILendingAdapter[] memory sorted, uint256 count) = _sortedSaneAdapters();
        // Worst-rate first: iterate the sorted list backwards
        for (uint256 i = count; i > 0 && pulled < amount; --i) {
            ILendingAdapter a = sorted[i - 1];
            uint256 held;
            try a.getBalance() returns (uint256 b) {
                held = b;
            } catch {
                continue;
            }
            if (held == 0) continue;
            uint256 want = amount - pulled;
            uint256 take = want < held ? want : held;
            // Skip on revert; remainder covered by next adapter or fallback pass.
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
        // Wrap full native balance to avoid dust stranding.
        IWRBTC(asset()).deposit{value: address(this).balance}();
    }

    /// @notice Accepts native rBTC only from WRBTC (unwrapping) and registered adapters
    ///         (withdrawals); any other direct transfer reverts.
    /// @dev WRBTC takes the cheap early-return path because its withdraw() pays out via
    ///      transfer() with a 2300-gas stipend.
    receive() external payable {
        // Cheap early-return for WRBTC: its transfer() has only 2300 gas.
        if (msg.sender == asset()) return;
        require(isAdapter[msg.sender], "direct rBTC transfers not allowed");
    }
}
