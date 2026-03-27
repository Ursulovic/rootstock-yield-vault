// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20LendingAdapter} from "./interfaces/IERC20LendingAdapter.sol";

contract ERC20YieldVault is ERC4626, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    IERC20LendingAdapter[] public adapters;
    IERC20LendingAdapter public activeAdapter;

    uint256 public lastRebalanceTime;
    uint256 public lastTotalAssets;

    uint256 public immutable cooldownPeriod;
    uint256 public immutable rateThreshold;
    uint256 public immutable callerRewardBps;
    address public immutable guardian;

    event Rebalanced(
        address indexed fromAdapter,
        address indexed toAdapter,
        uint256 amount,
        uint256 oldRate,
        uint256 newRate,
        address indexed caller
    );

    event InitialDepositDeployed(address indexed adapter, uint256 amount);

    modifier onlyGuardian() {
        require(msg.sender == guardian, "only guardian");
        _;
    }

    constructor(
        address _asset,
        IERC20LendingAdapter[] memory _adapters,
        uint256 _cooldownPeriod,
        uint256 _rateThreshold,
        uint256 _callerRewardBps,
        string memory _name,
        string memory _symbol,
        address _guardian
    ) ERC4626(IERC20(_asset)) ERC20(_name, _symbol) {
        require(_adapters.length >= 2, "need at least 2 adapters");
        require(_callerRewardBps <= 500, "reward too high");
        require(_guardian != address(0), "zero guardian");

        cooldownPeriod = _cooldownPeriod;
        rateThreshold = _rateThreshold;
        callerRewardBps = _callerRewardBps;
        guardian = _guardian;

        for (uint256 i = 0; i < _adapters.length; i++) {
            adapters.push(_adapters[i]);
            _adapters[i].setVault(address(this));
            IERC20(_asset).forceApprove(address(_adapters[i]), type(uint256).max);
        }
    }

    // -- Guardian functions --

    function pause() external onlyGuardian {
        _pause();
    }

    function unpause() external onlyGuardian {
        _unpause();
    }

    // -- ERC-4626 overrides --

    function totalAssets() public view override returns (uint256) {
        uint256 total = IERC20(asset()).balanceOf(address(this));
        uint256 len = adapters.length;
        for (uint256 i = 0; i < len; ++i) {
            total += adapters[i].getBalance();
        }
        return total;
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 3;
    }

    function maxDeposit(address) public view override returns (uint256) {
        return paused() ? 0 : super.maxDeposit(address(0));
    }

    function maxMint(address) public view override returns (uint256) {
        return paused() ? 0 : super.maxMint(address(0));
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override nonReentrant whenNotPaused {
        super._deposit(caller, receiver, assets, shares);
        if (address(activeAdapter) != address(0)) {
            _deployToActiveAdapter(assets);
        }
        lastTotalAssets += assets;
    }

    // Withdrawals always work, even when paused — users must be able to exit
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override nonReentrant {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle < assets && address(activeAdapter) != address(0)) {
            _pullFromAdapter(assets - idle);
        }
        super._withdraw(caller, receiver, owner, assets, shares);
        lastTotalAssets = lastTotalAssets > assets ? lastTotalAssets - assets : 0;
    }

    // -- Rebalance --

    function rebalance() external nonReentrant whenNotPaused {
        require(address(activeAdapter) != address(0), "no active adapter");
        require(block.timestamp >= lastRebalanceTime + cooldownPeriod, "cooldown active");

        uint256 currentRate = activeAdapter.getRate();
        (IERC20LendingAdapter bestAdapter, uint256 bestRate) = _findBestRate();

        require(bestRate > currentRate + rateThreshold, "rate improvement too small");

        uint256 currentTotal = totalAssets();
        uint256 yieldAccrued = currentTotal > lastTotalAssets ? currentTotal - lastTotalAssets : 0;
        uint256 reward = yieldAccrued * callerRewardBps / 10_000;

        uint256 deployedBalance = activeAdapter.getBalance();
        IERC20LendingAdapter previousAdapter = activeAdapter;

        uint256 balanceBefore = IERC20(asset()).balanceOf(address(this));
        activeAdapter.withdraw(deployedBalance);
        uint256 received = IERC20(asset()).balanceOf(address(this)) - balanceBefore;

        if (reward > 0 && reward <= received) {
            IERC20(asset()).safeTransfer(msg.sender, reward);
            received -= reward;
        }

        bestAdapter.deposit(received);

        activeAdapter = bestAdapter;
        lastRebalanceTime = block.timestamp;
        lastTotalAssets = IERC20(asset()).balanceOf(address(this)) + bestAdapter.getBalance();

        emit Rebalanced(
            address(previousAdapter),
            address(bestAdapter),
            deployedBalance,
            currentRate,
            bestRate,
            msg.sender
        );
    }

    function initialDeposit() external nonReentrant whenNotPaused {
        require(address(activeAdapter) == address(0), "already initialized");
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        require(idle > 0, "no funds to deploy");

        (IERC20LendingAdapter bestAdapter,) = _findBestRate();

        bestAdapter.deposit(idle);

        activeAdapter = bestAdapter;
        lastRebalanceTime = block.timestamp;
        lastTotalAssets = totalAssets();

        emit InitialDepositDeployed(address(bestAdapter), idle);
    }

    // -- View helpers --

    function getAdapterCount() external view returns (uint256) {
        return adapters.length;
    }

    function getAllRates() external view returns (string[] memory names, uint256[] memory rates) {
        uint256 len = adapters.length;
        names = new string[](len);
        rates = new uint256[](len);
        for (uint256 i = 0; i < len; ++i) {
            names[i] = adapters[i].getProtocolName();
            rates[i] = adapters[i].getRate();
        }
    }

    // -- Internal helpers --

    function _findBestRate() internal view returns (IERC20LendingAdapter bestAdapter, uint256 bestRate) {
        uint256 len = adapters.length;
        for (uint256 i = 0; i < len; ++i) {
            uint256 rate = adapters[i].getRate();
            if (rate > bestRate) {
                bestRate = rate;
                bestAdapter = adapters[i];
            }
        }
    }

    function _deployToActiveAdapter(uint256 amount) internal {
        activeAdapter.deposit(amount);
    }

    function _pullFromAdapter(uint256 amount) internal {
        activeAdapter.withdraw(amount);
    }
}
