import { useState } from "react";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import {
  useAccount,
  useReadContract,
  useWriteContract,
  useWaitForTransactionReceipt,
} from "wagmi";
import { parseEther, formatEther, formatUnits } from "viem";

function fmt(val, decimals = 18) {
  if (!val) return "0";
  const str = decimals === 18 ? formatEther(val) : formatUnits(val, decimals);
  const num = parseFloat(str);
  if (num === 0) return "0";
  if (num < 0.0001) return num.toExponential(2);
  return num.toFixed(6).replace(/\.?0+$/, "");
}
import { VAULT_ABI } from "./contracts/abi.js";
import { ADDRESSES } from "./contracts/addresses.js";
import "./App.css";

const VAULT = ADDRESSES.VAULT;

function App() {
  const { address, isConnected } = useAccount();

  const [depositAmt, setDepositAmt] = useState("");
  const [withdrawAmt, setWithdrawAmt] = useState("");

  const { writeContract, data: txHash, isPending } = useWriteContract();
  const { isLoading: isTxConfirming, isSuccess: isTxConfirmed } =
    useWaitForTransactionReceipt({ hash: txHash });

  const { data: totalAssets, refetch: refetchAssets } = useReadContract({
    address: VAULT,
    abi: VAULT_ABI,
    functionName: "totalAssets",
  });

  const { data: shares, refetch: refetchShares } = useReadContract({
    address: VAULT,
    abi: VAULT_ABI,
    functionName: "balanceOf",
    args: [address],
    query: { enabled: !!address },
  });

  const { data: maxWithdrawAmt, refetch: refetchMaxWithdraw } =
    useReadContract({
      address: VAULT,
      abi: VAULT_ABI,
      functionName: "maxWithdraw",
      args: [address],
      query: { enabled: !!address },
    });

  const { data: activeAdapter } = useReadContract({
    address: VAULT,
    abi: VAULT_ABI,
    functionName: "activeAdapter",
  });

  const { data: ratesData } = useReadContract({
    address: VAULT,
    abi: VAULT_ABI,
    functionName: "getAllRates",
  });

  const { data: shareValue } = useReadContract({
    address: VAULT,
    abi: VAULT_ABI,
    functionName: "convertToAssets",
    args: [shares || 0n],
    query: { enabled: !!shares && shares > 0n },
  });

  const refetchAll = () => {
    refetchAssets();
    refetchShares();
    refetchMaxWithdraw();
  };

  const handleDeposit = () => {
    if (!depositAmt) return;
    writeContract(
      {
        address: VAULT,
        abi: VAULT_ABI,
        functionName: "depositNative",
        args: [address],
        value: parseEther(depositAmt),
      },
      { onSuccess: () => setTimeout(refetchAll, 1000) }
    );
  };

  const handleWithdraw = () => {
    if (!withdrawAmt) return;
    writeContract(
      {
        address: VAULT,
        abi: VAULT_ABI,
        functionName: "withdrawNative",
        args: [parseEther(withdrawAmt), address, address],
      },
      { onSuccess: () => setTimeout(refetchAll, 1000) }
    );
  };

  const handleInitialDeposit = () => {
    writeContract(
      {
        address: VAULT,
        abi: VAULT_ABI,
        functionName: "initialDeposit",
      },
      { onSuccess: () => setTimeout(refetchAll, 1000) }
    );
  };

  const handleRebalance = () => {
    writeContract(
      {
        address: VAULT,
        abi: VAULT_ABI,
        functionName: "rebalance",
      },
      { onSuccess: () => setTimeout(refetchAll, 1000) }
    );
  };

  const isNoAdapter =
    activeAdapter === "0x0000000000000000000000000000000000000000";
  const adapterName =
    activeAdapter === ADDRESSES.TROPYKUS_ADAPTER
      ? "Tropykus"
      : activeAdapter === ADDRESSES.SOVRYN_ADAPTER
        ? "Sovryn"
        : isNoAdapter
          ? "None (call Initialize)"
          : activeAdapter?.slice(0, 10) + "...";

  return (
    <div className="app">
      <header>
        <h1>ryRBTC Yield Vault</h1>
        <p className="subtitle">ERC-4626 yield optimizer on Rootstock</p>
        <ConnectButton showBalance={false} />
      </header>

      <div className="stats-grid">
        <div className="stat-card">
          <span className="stat-label">Total Vault Assets</span>
          <span className="stat-value">
            {fmt(totalAssets)} rBTC
          </span>
        </div>
        <div className="stat-card">
          <span className="stat-label">Your Shares Value</span>
          <span className="stat-value">
            {fmt(shareValue)} rBTC
          </span>
        </div>
        <div className="stat-card">
          <span className="stat-label">Active Adapter</span>
          <span className="stat-value">{adapterName}</span>
        </div>
        <div className="stat-card">
          <span className="stat-label">Your Shares</span>
          <span className="stat-value">
            {fmt(shares, 21)} ryRBTC
          </span>
        </div>
      </div>

      {ratesData && (
        <div className="rates-section">
          <h2>Lending Rates</h2>
          <div className="rates-grid">
            {ratesData[0]?.map((name, i) => (
              <div
                key={name}
                className={`rate-card ${
                  (activeAdapter === ADDRESSES.TROPYKUS_ADAPTER &&
                    name === "Tropykus") ||
                  (activeAdapter === ADDRESSES.SOVRYN_ADAPTER &&
                    name === "Sovryn")
                    ? "active"
                    : ""
                }`}
              >
                <span className="rate-name">{name}</span>
                <span className="rate-value">
                  {((Number(ratesData[1][i]) / 1e18) * 100).toFixed(2)}% APR
                </span>
              </div>
            ))}
          </div>
        </div>
      )}

      {isConnected && (
        <div className="actions-section">
          <h2>Actions</h2>

          <div className="action-row">
            <input
              type="number"
              placeholder="Amount in rBTC"
              value={depositAmt}
              onChange={(e) => setDepositAmt(e.target.value)}
              step="0.01"
            />
            <button
              onClick={handleDeposit}
              disabled={isPending || !depositAmt}
              className="btn btn-primary"
            >
              {isPending ? "Depositing..." : "Deposit rBTC"}
            </button>
          </div>

          <div className="action-row">
            <input
              type="number"
              placeholder="Amount in rBTC"
              value={withdrawAmt}
              onChange={(e) => setWithdrawAmt(e.target.value)}
              step="0.01"
            />
            <button
              onClick={handleWithdraw}
              disabled={isPending || !withdrawAmt}
              className="btn btn-secondary"
            >
              {isPending ? "Withdrawing..." : "Withdraw rBTC"}
            </button>
            {maxWithdrawAmt > 0n && (
              <button
                onClick={() => setWithdrawAmt(fmt(maxWithdrawAmt))}
                className="btn btn-sm"
              >
                Max
              </button>
            )}
          </div>

          <div className="action-row">
            {isNoAdapter && (
              <button
                onClick={handleInitialDeposit}
                disabled={isPending}
                className="btn btn-primary"
              >
                Initialize Vault
              </button>
            )}
            <button
              onClick={handleRebalance}
              disabled={isPending || isNoAdapter}
              className="btn btn-secondary"
            >
              Rebalance
            </button>
          </div>

          {isTxConfirming && <p className="tx-status">Confirming...</p>}
          {isTxConfirmed && (
            <p className="tx-status success">Transaction confirmed!</p>
          )}
        </div>
      )}
    </div>
  );
}

export default App;
