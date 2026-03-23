// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ILendingAdapter} from "./interfaces/ILendingAdapter.sol";
import {IWRBTC} from "./interfaces/IWRBTC.sol";

contract YieldVault is ERC4626, ReentrancyGuard {
    ILendingAdapter[] public adapters;
    ILendingAdapter public activeAdapter;

    uint256 public lastRebalanceTime;
    uint256 public lastTotalAssets;

    uint256 public immutable cooldownPeriod;
    uint256 public immutable rateThreshold;
    uint256 public immutable callerRewardBps;

    event Rebalanced(
        address indexed fromAdapter,
        address indexed toAdapter,
        uint256 amount,
        uint256 oldRate,
        uint256 newRate,
        address indexed caller
    );

    constructor(
        address _wrbtc,
        ILendingAdapter[] memory _adapters,
        uint256 _cooldownPeriod,
        uint256 _rateThreshold,
        uint256 _callerRewardBps
    ) ERC4626(IERC20(_wrbtc)) ERC20("Rootstock Yield Vault", "ryRBTC") {
        require(_adapters.length >= 2, "need at least 2 adapters");
        require(_callerRewardBps <= 500, "reward too high"); // max 5%

        cooldownPeriod = _cooldownPeriod;
        rateThreshold = _rateThreshold;
        callerRewardBps = _callerRewardBps;

        for (uint256 i = 0; i < _adapters.length; i++) {
            adapters.push(_adapters[i]);
            _adapters[i].setVault(address(this));
        }
    }

    // -- ERC-4626 overrides --

    function totalAssets() public view override returns (uint256) {
        uint256 total = IERC20(asset()).balanceOf(address(this));
        for (uint256 i = 0; i < adapters.length; i++) {
            total += adapters[i].getBalance();
        }
        return total;
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 3;
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override nonReentrant {
        super._deposit(caller, receiver, assets, shares);
        if (address(activeAdapter) != address(0)) {
            _deployToActiveAdapter(assets);
        }
        lastTotalAssets += assets;
    }

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
        lastTotalAssets -= assets;
    }

    // -- Native rBTC convenience functions --

    function depositNative(address receiver) external payable nonReentrant returns (uint256 shares) {
        uint256 assets = msg.value;
        require(assets > 0, "zero deposit");

        // Calculate shares BEFORE wrapping so totalAssets() isn't inflated
        shares = previewDeposit(assets);

        IWRBTC(asset()).deposit{value: assets}();
        _mint(receiver, shares);

        if (address(activeAdapter) != address(0)) {
            _deployToActiveAdapter(assets);
        }
        lastTotalAssets += assets;

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function withdrawNative(
        uint256 assets,
        address receiver,
        address owner
    ) external nonReentrant returns (uint256 shares) {
        shares = previewWithdraw(assets);

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle < assets && address(activeAdapter) != address(0)) {
            _pullFromAdapter(assets - idle);
        }

        _burn(owner, shares);
        lastTotalAssets -= assets;

        IWRBTC(asset()).withdraw(assets);
        (bool success,) = receiver.call{value: assets}("");
        require(success, "rBTC transfer failed");

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    // -- Rebalance --

    function rebalance() external nonReentrant {
        require(address(activeAdapter) != address(0), "no active adapter");
        require(block.timestamp >= lastRebalanceTime + cooldownPeriod, "cooldown active");

        uint256 currentRate = activeAdapter.getRate();
        (ILendingAdapter bestAdapter, uint256 bestRate) = _findBestRate();

        require(bestRate > currentRate + rateThreshold, "rate improvement too small");

        uint256 currentTotal = totalAssets();
        uint256 yieldAccrued = currentTotal > lastTotalAssets ? currentTotal - lastTotalAssets : 0;
        uint256 reward = yieldAccrued * callerRewardBps / 10_000;

        uint256 deployedBalance = activeAdapter.getBalance();
        ILendingAdapter previousAdapter = activeAdapter;

        // Withdraw everything from current adapter (native rBTC arrives here)
        activeAdapter.withdraw(deployedBalance);

        // Pay caller reward from native rBTC
        if (reward > 0) {
            (bool success,) = msg.sender.call{value: reward}("");
            require(success, "reward transfer failed");
        }

        // Deposit remainder into best adapter
        uint256 toRedeploy = address(this).balance;
        bestAdapter.deposit{value: toRedeploy}();

        activeAdapter = bestAdapter;
        lastRebalanceTime = block.timestamp;
        lastTotalAssets = totalAssets();

        emit Rebalanced(
            address(previousAdapter),
            address(bestAdapter),
            deployedBalance,
            currentRate,
            bestRate,
            msg.sender
        );
    }

    function initialDeposit() external nonReentrant {
        require(address(activeAdapter) == address(0), "already initialized");
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        require(idle > 0, "no funds to deploy");

        (ILendingAdapter bestAdapter,) = _findBestRate();

        IWRBTC(asset()).withdraw(idle);
        bestAdapter.deposit{value: idle}();

        activeAdapter = bestAdapter;
        lastRebalanceTime = block.timestamp;
        lastTotalAssets = totalAssets();
    }

    // -- View helpers --

    function getAdapterCount() external view returns (uint256) {
        return adapters.length;
    }

    function getAllRates() external view returns (string[] memory names, uint256[] memory rates) {
        names = new string[](adapters.length);
        rates = new uint256[](adapters.length);
        for (uint256 i = 0; i < adapters.length; i++) {
            names[i] = adapters[i].getProtocolName();
            rates[i] = adapters[i].getRate();
        }
    }

    // -- Internal helpers --

    function _findBestRate() internal view returns (ILendingAdapter bestAdapter, uint256 bestRate) {
        for (uint256 i = 0; i < adapters.length; i++) {
            uint256 rate = adapters[i].getRate();
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

    function _pullFromAdapter(uint256 amount) internal {
        activeAdapter.withdraw(amount);
        IWRBTC(asset()).deposit{value: amount}();
    }

    receive() external payable {}
}
