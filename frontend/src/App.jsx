import { useState, useEffect } from "react";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import {
  useAccount,
  useReadContract,
  useWriteContract,
  useWaitForTransactionReceipt,
} from "wagmi";
import { parseEther, formatEther, formatUnits, maxUint256 } from "viem";
import { VAULT_ABI, ERC20_VAULT_ABI, ERC20_ABI } from "./contracts/abi.js";
import { VAULTS } from "./contracts/addresses.js";
import "./App.css";

function fmt(val, decimals = 18) {
  if (!val) return "0";
  const str = decimals === 18 ? formatEther(val) : formatUnits(val, decimals);
  const num = parseFloat(str);
  if (num < 0.000001) return "0";
  return num.toFixed(6).replace(/\.?0+$/, "");
}

function VaultCard({ vault, selected, onClick }) {
  const { data: totalAssets } = useReadContract({
    address: vault.address,
    abi: vault.type === "native" ? VAULT_ABI : ERC20_VAULT_ABI,
    functionName: "totalAssets",
  });

  const { data: activeAdapter } = useReadContract({
    address: vault.address,
    abi: vault.type === "native" ? VAULT_ABI : ERC20_VAULT_ABI,
    functionName: "activeAdapter",
  });

  const { data: ratesData } = useReadContract({
    address: vault.address,
    abi: vault.type === "native" ? VAULT_ABI : ERC20_VAULT_ABI,
    functionName: "getAllRates",
  });

  const adapterName = vault.adapters[activeAdapter] || "Not initialized";
  const bestRate = ratesData
    ? Math.max(...ratesData[1].map((r) => Number(r) / 1e18 * 100))
    : 0;

  return (
    <div
      className={`vault-card ${selected ? "selected" : ""}`}
      onClick={onClick}
    >
      <span className="vault-token">{vault.shareSymbol}</span>
      <span className="vault-tvl">{fmt(totalAssets)} {vault.tokenSymbol}</span>
      <span className="vault-apr">{bestRate.toFixed(2)}% APR</span>
      <span className="vault-adapter">{adapterName}</span>
    </div>
  );
}

function VaultDetail({ vault }) {
  const { address } = useAccount();
  const abi = vault.type === "native" ? VAULT_ABI : ERC20_VAULT_ABI;

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
    address: vault.address, abi, functionName: "totalAssets",
  });

  const { data: shares, refetch: refetchShares } = useReadContract({
    address: vault.address, abi, functionName: "balanceOf",
    args: [address], query: { enabled: !!address },
  });

  const { data: maxWithdrawAmt, refetch: refetchMaxWithdraw } = useReadContract({
    address: vault.address, abi, functionName: "maxWithdraw",
    args: [address], query: { enabled: !!address },
  });

  const { data: activeAdapter, refetch: refetchAdapter } = useReadContract({
    address: vault.address, abi, functionName: "activeAdapter",
  });

  const { data: ratesData } = useReadContract({
    address: vault.address, abi, functionName: "getAllRates",
  });

  const { data: shareValue } = useReadContract({
    address: vault.address, abi, functionName: "convertToAssets",
    args: [shares || 0n], query: { enabled: !!shares && shares > 0n },
  });

  // ERC-20 specific: token allowance and balance
  const { data: allowance, refetch: refetchAllowance } = useReadContract({
    address: vault.tokenAddress, abi: ERC20_ABI, functionName: "allowance",
    args: [address, vault.address],
    query: { enabled: vault.type === "erc20" && !!address },
  });

  const { data: walletBalance } = useReadContract({
    address: vault.tokenAddress, abi: ERC20_ABI, functionName: "balanceOf",
    args: [address],
    query: { enabled: vault.type === "erc20" && !!address },
  });

  const refetchAll = () => {
    refetchAssets(); refetchShares(); refetchMaxWithdraw();
    refetchAdapter(); if (vault.type === "erc20") refetchAllowance();
  };

  useEffect(() => {
    if (isTxConfirmed) { refetchAll(); setDepositAmt(""); setWithdrawAmt(""); }
  }, [isTxConfirmed]);

  useEffect(() => {
    if (writeError) {
      setError(writeError.shortMessage || writeError.message || "Transaction failed");
      setTimeout(() => setError(""), 8000);
    }
  }, [writeError]);

  // Reset state when switching vaults
  useEffect(() => {
    setDepositAmt(""); setWithdrawAmt(""); setError(""); resetWrite();
  }, [vault.address]);

  const doWrite = (config) => { setError(""); resetWrite(); writeContract(config); };

  const needsApproval = vault.type === "erc20" && depositAmt &&
    (allowance === undefined || allowance < parseEther(depositAmt || "0"));

  const handleApprove = () => {
    doWrite({
      address: vault.tokenAddress, abi: ERC20_ABI,
      functionName: "approve", args: [vault.address, maxUint256],
    });
  };

  const handleDeposit = () => {
    if (!depositAmt) return;
    if (vault.type === "native") {
      doWrite({
        address: vault.address, abi, functionName: "depositNative",
        args: [address], value: parseEther(depositAmt),
      });
    } else {
      doWrite({
        address: vault.address, abi, functionName: "deposit",
        args: [parseEther(depositAmt), address],
      });
    }
  };

  const handleWithdraw = () => {
    if (!withdrawAmt) return;
    if (vault.type === "native") {
      doWrite({
        address: vault.address, abi, functionName: "withdrawNative",
        args: [parseEther(withdrawAmt), address, address],
      });
    } else {
      doWrite({
        address: vault.address, abi, functionName: "withdraw",
        args: [parseEther(withdrawAmt), address, address],
      });
    }
  };

  const handleInitialDeposit = () => {
    doWrite({ address: vault.address, abi, functionName: "initialDeposit" });
  };

  const handleRebalance = () => {
    doWrite({ address: vault.address, abi, functionName: "rebalance" });
  };

  const isNoAdapter = activeAdapter === "0x0000000000000000000000000000000000000000";
  const adapterName = vault.adapters[activeAdapter] || (isNoAdapter ? "None" : "Unknown");

  return (
    <div className="vault-detail">
      <h2>{vault.shareSymbol} Vault</h2>

      <div className="stats-grid">
        <div className="stat-card">
          <span className="stat-label">Total Vault Assets</span>
          <span className="stat-value">{fmt(totalAssets)} {vault.tokenSymbol}</span>
        </div>
        <div className="stat-card">
          <span className="stat-label">Your Shares Value</span>
          <span className="stat-value">{fmt(shareValue)} {vault.tokenSymbol}</span>
        </div>
        <div className="stat-card">
          <span className="stat-label">Active Adapter</span>
          <span className="stat-value">{adapterName}</span>
        </div>
        <div className="stat-card">
          <span className="stat-label">Your Shares</span>
          <span className="stat-value">
            {fmt(shareValue) === "0" ? "0" : fmt(shares, 18)} {vault.shareSymbol}
          </span>
        </div>
      </div>

      {ratesData && (
        <div className="rates-section">
          <h3>Lending Rates</h3>
          <div className="rates-grid">
            {ratesData[0]?.map((name, i) => {
              const isActive = vault.adapters[activeAdapter] === name;
              return (
                <div key={name} className={`rate-card ${isActive ? "active" : ""}`}>
                  <span className="rate-name">{name}</span>
                  <span className="rate-value">
                    {((Number(ratesData[1][i]) / 1e18) * 100).toFixed(2)}% APR
                  </span>
                </div>
              );
            })}
          </div>
        </div>
      )}

      {address && (
        <div className="actions-section">
          {vault.type === "erc20" && (
            <p className="wallet-bal">
              Wallet: {fmt(walletBalance)} {vault.tokenSymbol}
            </p>
          )}

          <div className="action-row">
            <input
              type="number" placeholder={`Amount in ${vault.tokenSymbol}`}
              value={depositAmt} onChange={(e) => setDepositAmt(e.target.value)}
              step="0.001"
            />
            {needsApproval ? (
              <button onClick={handleApprove} disabled={isPending || isTxConfirming}
                className="btn btn-primary">
                {isPending ? "Confirm..." : "Approve"}
              </button>
            ) : (
              <button onClick={handleDeposit}
                disabled={isPending || isTxConfirming || !depositAmt}
                className="btn btn-primary">
                {isPending ? "Confirm..." : isTxConfirming ? "Confirming..." : `Deposit ${vault.tokenSymbol}`}
              </button>
            )}
          </div>

          <div className="action-row">
            <input
              type="number" placeholder={`Amount in ${vault.tokenSymbol}`}
              value={withdrawAmt} onChange={(e) => setWithdrawAmt(e.target.value)}
              step="0.001"
            />
            <button onClick={handleWithdraw}
              disabled={isPending || isTxConfirming || !withdrawAmt}
              className="btn btn-secondary">
              {isPending ? "Confirm..." : isTxConfirming ? "Confirming..." : `Withdraw ${vault.tokenSymbol}`}
            </button>
            {maxWithdrawAmt > 0n && (
              <button onClick={() => {
                const raw = formatEther(maxWithdrawAmt);
                const parts = raw.split(".");
                const trimmed = parts[1]
                  ? parts[0] + "." + parts[1].slice(0, 6).replace(/0+$/, "")
                  : parts[0];
                setWithdrawAmt(trimmed.endsWith(".") ? trimmed.slice(0, -1) : trimmed);
              }} className="btn btn-sm">Max</button>
            )}
          </div>

          <div className="action-row">
            {isNoAdapter && (
              <button onClick={handleInitialDeposit}
                disabled={isPending || isTxConfirming} className="btn btn-primary">
                Initialize Vault
              </button>
            )}
            <button onClick={handleRebalance}
              disabled={isPending || isTxConfirming || isNoAdapter}
              className="btn btn-secondary">
              Rebalance
            </button>
          </div>

          {isTxConfirming && <p className="tx-status">Waiting for confirmation...</p>}
          {isTxConfirmed && <p className="tx-status success">Transaction confirmed!</p>}
          {error && <p className="tx-status error">{error}</p>}
        </div>
      )}
    </div>
  );
}

function App() {
  const { isConnected } = useAccount();
  const [selectedIdx, setSelectedIdx] = useState(0);

  return (
    <div className="app">
      <header>
        <h1>Rootstock Yield Vaults</h1>
        <p className="subtitle">ERC-4626 yield optimizer — auto-rebalance between Tropykus and Sovryn</p>
        <ConnectButton showBalance={false} />
      </header>

      <div className="vault-cards">
        {VAULTS.map((v, i) => (
          <VaultCard
            key={v.address}
            vault={v}
            selected={i === selectedIdx}
            onClick={() => setSelectedIdx(i)}
          />
        ))}
      </div>

      {isConnected && <VaultDetail vault={VAULTS[selectedIdx]} />}
    </div>
  );
}

export default App;
