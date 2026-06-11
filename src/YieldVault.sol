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

    // Hard ceiling on any rate considered when selecting an adapter. A rate
    // above this means the market is either being manipulated (flash-loan
    // utilization spike) or too illiquid to safely enter — never chase it.
    uint256 public immutable maxSaneRate;

    mapping(address => bool) public isAdapter;

    event Rebalanced(
        address indexed fromAdapter,
        address indexed toAdapter,
        uint256 amount,
        uint256 oldRate,
        uint256 newRate,
        address indexed caller
    );

    event InitialDepositDeployed(address indexed adapter, uint256 amount);

    event RebalancerRewardPaid(address indexed rebalancer, uint256 reward, uint256 yieldAccrued);

    constructor(
        address _wrbtc,
        ILendingAdapter[] memory _adapters,
        uint256 _cooldownPeriod,
        uint256 _rateThreshold,
        uint256 _callerRewardBps,
        uint256 _maxSaneRate
    ) ERC4626(IERC20(_wrbtc)) ERC20("Rootstock Yield Vault", "ryRBTC") {
        require(_adapters.length >= 2, "need at least 2 adapters");
        require(_callerRewardBps <= 500, "reward too high"); // max 5%
        require(_maxSaneRate > 0, "zero max rate");

        cooldownPeriod = _cooldownPeriod;
        rateThreshold = _rateThreshold;
        callerRewardBps = _callerRewardBps;
        maxSaneRate = _maxSaneRate;

        for (uint256 i = 0; i < _adapters.length; i++) {
            adapters.push(_adapters[i]);
            isAdapter[address(_adapters[i])] = true;
            _adapters[i].setVault(address(this));
        }
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
        lastTotalAssets = lastTotalAssets > assets ? lastTotalAssets - assets : 0;
    }

    // -- Native rBTC convenience functions --

    function depositNative(address receiver) external payable nonReentrant returns (uint256 shares) {
        uint256 assets = msg.value;
        require(assets > 0, "zero deposit");
        require(assets <= maxDeposit(receiver), "deposit exceeds max");

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
        require(assets <= maxWithdraw(owner), "withdraw exceeds max");
        shares = previewWithdraw(assets);

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle < assets && address(activeAdapter) != address(0)) {
            _pullFromAdapter(assets - idle);
        }

        _burn(owner, shares);
        lastTotalAssets = lastTotalAssets > assets ? lastTotalAssets - assets : 0;

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
        uint256 balanceBefore = address(this).balance;
        activeAdapter.withdraw(deployedBalance);
        uint256 received = address(this).balance - balanceBefore;

        // Pay caller reward from native rBTC
        if (reward > received) reward = received;
        if (reward > 0) {
            (bool success,) = msg.sender.call{value: reward}("");
            require(success, "reward transfer failed");
            received -= reward;
            emit RebalancerRewardPaid(msg.sender, reward, yieldAccrued);
        }

        // Deposit remainder into best adapter
        if (received > 0) {
            bestAdapter.deposit{value: received}();
        }

        activeAdapter = bestAdapter;
        lastRebalanceTime = block.timestamp;
        lastTotalAssets = received + IERC20(asset()).balanceOf(address(this));

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
        require(address(bestAdapter) != address(0), "no adapter within sane rate");

        IWRBTC(asset()).withdraw(idle);
        bestAdapter.deposit{value: idle}();

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

    function _findBestRate() internal view returns (ILendingAdapter bestAdapter, uint256 bestRate) {
        uint256 len = adapters.length;
        for (uint256 i = 0; i < len; ++i) {
            uint256 rate = adapters[i].getRate();
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

    function _pullFromAdapter(uint256 amount) internal {
        activeAdapter.withdraw(amount);
        IWRBTC(asset()).deposit{value: amount}();
    }

    receive() external payable {
        // WRBTC checked first: its withdraw() pays out via transfer() with a
        // 2300-gas stipend, which leaves no room for the isAdapter storage read
        if (msg.sender == asset()) return;
        require(isAdapter[msg.sender], "direct rBTC transfers not allowed");
    }
}
