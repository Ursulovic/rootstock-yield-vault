import { useState, useEffect } from "react";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import {
  useAccount,
  useReadContract,
  useWriteContract,
  useWaitForTransactionReceipt,
} from "wagmi";
import { parseEther, formatEther, formatUnits } from "viem";
import { VAULT_ABI } from "./contracts/abi.js";
import { ADDRESSES } from "./contracts/addresses.js";
import "./App.css";

function fmt(val, decimals = 18) {
  if (!val) return "0";
  const str = decimals === 18 ? formatEther(val) : formatUnits(val, decimals);
  const num = parseFloat(str);
  if (num < 0.000001) return "0";
  return num.toFixed(6).replace(/\.?0+$/, "");
}

const VAULT = ADDRESSES.VAULT;

function App() {
  const { address, isConnected } = useAccount();

  const [depositAmt, setDepositAmt] = useState("");
  const [withdrawAmt, setWithdrawAmt] = useState("");
  const [error, setError] = useState("");

  const {
    writeContract,
    data: txHash,
    isPending,
    error: writeError,
    reset: resetWrite,
  } = useWriteContract();

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

  const { data: activeAdapter, refetch: refetchAdapter } = useReadContract({
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
    refetchAdapter();
  };

  // Refetch when tx confirms (not on a timer)
  useEffect(() => {
    if (isTxConfirmed) {
      refetchAll();
      setDepositAmt("");
      setWithdrawAmt("");
    }
  }, [isTxConfirmed]);

  // Show write errors
  useEffect(() => {
    if (writeError) {
      const msg = writeError.shortMessage || writeError.message || "Transaction failed";
      setError(msg);
      setTimeout(() => setError(""), 8000);
    }
  }, [writeError]);

  const doWrite = (config) => {
    setError("");
    resetWrite();
    writeContract(config);
  };

  const handleDeposit = () => {
    if (!depositAmt) return;
    doWrite({
      address: VAULT,
      abi: VAULT_ABI,
      functionName: "depositNative",
      args: [address],
      value: parseEther(depositAmt),
    });
  };

  const handleWithdraw = () => {
    if (!withdrawAmt) return;
    doWrite({
      address: VAULT,
      abi: VAULT_ABI,
      functionName: "withdrawNative",
      args: [parseEther(withdrawAmt), address, address],
    });
  };

  const handleInitialDeposit = () => {
    doWrite({
      address: VAULT,
      abi: VAULT_ABI,
      functionName: "initialDeposit",
    });
  };

  const handleRebalance = () => {
    doWrite({
      address: VAULT,
      abi: VAULT_ABI,
      functionName: "rebalance",
    });
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
          <span className="stat-value">{fmt(totalAssets)} rBTC</span>
        </div>
        <div className="stat-card">
          <span className="stat-label">Your Shares Value</span>
          <span className="stat-value">{fmt(shareValue)} rBTC</span>
        </div>
        <div className="stat-card">
          <span className="stat-label">Active Adapter</span>
          <span className="stat-value">{adapterName}</span>
        </div>
        <div className="stat-card">
          <span className="stat-label">Your Shares</span>
          <span className="stat-value">{fmt(shares, 18)} ryRBTC</span>
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
              step="0.001"
            />
            <button
              onClick={handleDeposit}
              disabled={isPending || isTxConfirming || !depositAmt}
              className="btn btn-primary"
            >
              {isPending ? "Confirm in wallet..." : isTxConfirming ? "Confirming..." : "Deposit rBTC"}
            </button>
          </div>

          <div className="action-row">
            <input
              type="number"
              placeholder="Amount in rBTC"
              value={withdrawAmt}
              onChange={(e) => setWithdrawAmt(e.target.value)}
              step="0.001"
            />
            <button
              onClick={handleWithdraw}
              disabled={isPending || isTxConfirming || !withdrawAmt}
              className="btn btn-secondary"
            >
              {isPending ? "Confirm in wallet..." : isTxConfirming ? "Confirming..." : "Withdraw rBTC"}
            </button>
            {maxWithdrawAmt > 0n && (
              <button
                onClick={() => {
                  const raw = formatEther(maxWithdrawAmt);
                  const parts = raw.split(".");
                  const trimmed = parts[1]
                    ? parts[0] + "." + parts[1].slice(0, 6).replace(/0+$/, "")
                    : parts[0];
                  setWithdrawAmt(
                    trimmed.endsWith(".") ? trimmed.slice(0, -1) : trimmed
                  );
                }}
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
                disabled={isPending || isTxConfirming}
                className="btn btn-primary"
              >
                {isPending ? "Confirm in wallet..." : isTxConfirming ? "Confirming..." : "Initialize Vault"}
              </button>
            )}
            <button
              onClick={handleRebalance}
              disabled={isPending || isTxConfirming || isNoAdapter}
              className="btn btn-secondary"
            >
              {isPending ? "Confirm in wallet..." : isTxConfirming ? "Confirming..." : "Rebalance"}
            </button>
          </div>

          {isTxConfirming && <p className="tx-status">Waiting for block confirmation (~30s)...</p>}
          {isTxConfirmed && <p className="tx-status success">Transaction confirmed!</p>}
          {error && <p className="tx-status error">{error}</p>}
        </div>
      )}
    </div>
  );
}

export default App;
