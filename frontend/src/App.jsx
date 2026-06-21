import { useState, useEffect, useMemo } from "react";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import {
  useAccount,
  usePublicClient,
  useReadContract,
  useReadContracts,
  useWriteContract,
  useWaitForTransactionReceipt,
} from "wagmi";
import { parseEther, formatEther, formatUnits, maxUint256, decodeAbiParameters } from "viem";
import { VAULT_ABI, ERC20_VAULT_ABI, ERC20_ABI, ADAPTER_ABI } from "./contracts/abi.js";
import { VAULTS } from "./contracts/addresses.js";
import "./App.css";

const ZERO = "0x0000000000000000000000000000000000000000";
const EXPLORER = "https://rootstock-testnet.blockscout.com/address/";
const REPO = "https://github.com/Ursulovic/rootstock-yield-vault";
// Distinct colors per adapter slot, used for both the allocation bar and legend
const ADAPTER_COLORS = ["#3b82f6", "#ff9500", "#a855f7", "#10b981"];

// Dig the contract revert string out of a viem error. The RSK node reports
// reverts via nonstandard code -32015, which viem doesn't decode: the reason
// only appears as raw Error(string) hex in `data` and as text in `details`.
function extractReason(e) {
  for (let c = e; c; c = c.cause) {
    if (typeof c.reason === "string") return c.reason;
    if (c.data?.args?.length) return String(c.data.args[0]);
    if (typeof c.data === "string" && c.data.startsWith("0x08c379a0")) {
      try {
        return decodeAbiParameters([{ type: "string" }], "0x" + c.data.slice(10))[0];
      } catch { /* fall through to text matching */ }
    }
    const txt = [c.details, c.message].find((s) => typeof s === "string" && /revert/i.test(s));
    if (txt) {
      const m = txt.match(/revert(?:ed)?(?: with reason string)?:? *['"]?([^'"\n]+?)['"]?$/i);
      if (m && m[1].trim()) return m[1].trim();
    }
  }
  return e?.shortMessage || "Transaction would fail";
}

function fmt(val, decimals = 18) {
  if (!val) return "0";
  const str = decimals === 18 ? formatEther(val) : formatUnits(val, decimals);
  const num = parseFloat(str);
  if (num < 0.000001) return "0";
  return num.toFixed(6).replace(/\.?0+$/, "");
}

function pct(rate) {
  return (Number(rate) / 1e16).toFixed(2);
}

function formatDuration(secs) {
  if (secs <= 0) return null;
  const d = Math.floor(secs / 86400);
  const h = Math.floor((secs % 86400) / 3600);
  const m = Math.floor((secs % 3600) / 60);
  if (d > 0) return `${d}d ${h}h`;
  if (h > 0) return `${h}h ${m}m`;
  if (m > 0) return `${m}m`;
  return `${Math.floor(secs)}s`;
}

function HealthDot({ healthy }) {
  const color = healthy === undefined ? "#666" : healthy ? "#4caf50" : "#f44336";
  const label = healthy === undefined ? "unknown" : healthy ? "healthy" : "unreachable";
  return <span className="health-dot" style={{ background: color }} title={`Adapter ${label}`} />;
}

function VaultCard({ vault, selected, onClick }) {
  const abi = vault.type === "native" ? VAULT_ABI : ERC20_VAULT_ABI;
  const { data: totalAssets } = useReadContract({ address: vault.address, abi, functionName: "totalAssets" });
  const { data: activeAdapter } = useReadContract({
    address: vault.address, abi, functionName: "activeAdapter", query: { refetchInterval: 5000 },
  });
  const { data: ratesData } = useReadContract({
    address: vault.address, abi, functionName: "getAllRates", query: { refetchInterval: 5000 },
  });

  const adapterName = vault.adapters[activeAdapter] || "Not initialized";
  const bestRate = ratesData?.[1]?.length
    ? Math.max(...ratesData[1].map((r) => (Number(r) / 1e18) * 100))
    : 0;

  return (
    <div className={`vault-card ${selected ? "selected" : ""}`} onClick={onClick}>
      <span className="vault-token">{vault.shareSymbol}</span>
      <span className="vault-tvl">{fmt(totalAssets)} {vault.tokenSymbol}</span>
      <span className="vault-apr">{bestRate.toFixed(2)}% APR</span>
      <span className="vault-adapter">{adapterName}</span>
    </div>
  );
}

// Stacked allocation bar + per-adapter legend (name, health, %, balance, rate),
// with the immutable concentration cap drawn as a marker.
function AllocationPanel({ adapters, capBps, symbol }) {
  const totalDeployed = adapters.reduce((s, a) => s + (a.balance ?? 0n), 0n);
  const capPct = Number(capBps) / 100;

  return (
    <div className="alloc-section">
      <div className="alloc-head">
        <h3>Allocation</h3>
        <span className="alloc-cap-note">{capPct}% per-adapter cap</span>
      </div>

      {totalDeployed > 0n ? (
        <div className="alloc-bar" style={{ position: "relative" }}>
          {adapters.map((a, i) => {
            const share = Number((a.balance * 10000n) / totalDeployed) / 100;
            if (share <= 0) return null;
            return (
              <div
                key={a.address ?? a.name}
                className="alloc-seg"
                style={{ width: `${share}%`, background: ADAPTER_COLORS[i % ADAPTER_COLORS.length] }}
                title={`${a.name}: ${share.toFixed(1)}%`}
              >
                {share >= 12 ? `${share.toFixed(0)}%` : ""}
              </div>
            );
          })}
          <div className="alloc-cap-line" style={{ left: `${capPct}%` }} title={`${capPct}% cap`} />
        </div>
      ) : (
        <div className="alloc-empty">No funds deployed yet — deposit to bootstrap allocation.</div>
      )}

      <div className="alloc-legend">
        {adapters.map((a, i) => {
          const share = totalDeployed > 0n ? Number((a.balance * 10000n) / totalDeployed) / 100 : 0;
          const over = share > capPct + 0.5;
          return (
            <div key={a.address ?? a.name} className="legend-row">
              <span className="legend-name">
                <span className="legend-swatch" style={{ background: ADAPTER_COLORS[i % ADAPTER_COLORS.length] }} />
                <HealthDot healthy={a.healthy} />
                {a.address ? (
                  <a href={EXPLORER + a.address} target="_blank" rel="noreferrer">{a.name}</a>
                ) : a.name}
              </span>
              <span className="legend-meta">
                <span className={`legend-share ${over ? "over-cap" : ""}`}>{share.toFixed(1)}%</span>
                <span className="legend-bal">{fmt(a.balance)} {symbol}</span>
                <span className="legend-rate">{pct(a.rate)}% APR</span>
              </span>
            </div>
          );
        })}
      </div>
    </div>
  );
}

// Replicates the on-chain rebalance gate (cooldown + rate-improvement over the
// current primary, sane rates only) so the UI explains availability rather than
// failing silently.
function RebalanceStatus({ adapters, activeAdapter, lastRebalanceTime, cooldownPeriod, rateThreshold, maxSaneRate, now }) {
  // cooldownPeriod is in the same read batch as lastRebalanceTime but a partial
  // batch failure could leave it undefined — guard both so cooldownLeft never NaNs
  if (!adapters.length || lastRebalanceTime === undefined || cooldownPeriod === undefined) return null;
  if (!activeAdapter || activeAdapter === ZERO) {
    return <div className="rebal-status idle"><span className="rebal-dot" /> Vault not initialized — first deposit bootstraps it.</div>;
  }

  const active = adapters.find((a) => a.address?.toLowerCase() === activeAdapter.toLowerCase());
  // A primary that isn't in the rate list would make currentRate default to 0
  // and spuriously report "rebalance available" — show a neutral state instead
  if (!active) {
    return <div className="rebal-status idle"><span className="rebal-dot" /> Primary adapter not in the rate list.</div>;
  }

  const cooldownLeft = Number(lastRebalanceTime) + Number(cooldownPeriod) - now;
  const currentRate = active.rate;
  const sane = adapters.filter((a) => maxSaneRate !== undefined && a.rate <= maxSaneRate);
  const best = sane.reduce((b, a) => (a.rate > b.rate ? a : b), { rate: 0n, name: "—" });
  const improves = rateThreshold !== undefined && best.rate > currentRate + rateThreshold;

  if (cooldownLeft > 0) {
    return (
      <div className="rebal-status cooldown">
        <span className="rebal-dot" /> Rebalance on cooldown — ready in {formatDuration(cooldownLeft)}
      </div>
    );
  }
  if (!improves) {
    return (
      <div className="rebal-status optimal">
        <span className="rebal-dot" /> {active?.name ?? "Primary"} already optimal — no better rate to move to
      </div>
    );
  }
  return (
    <div className="rebal-status ready">
      <span className="rebal-dot" /> Rebalance available → {best.name} ({pct(best.rate)}% APR)
    </div>
  );
}

function VestingRow({ lockedProfit, lastCheckpoint, unlockPeriod, symbol, now }) {
  if (lockedProfit === undefined || !lastCheckpoint || !unlockPeriod) return null;
  const remaining = Number(lastCheckpoint) + Number(unlockPeriod) - now;
  if (lockedProfit > 0n && remaining > 0) {
    return (
      <div className="vesting-row active">
        <span className="vesting-label">Profit vesting</span>
        <span className="vesting-val">
          {fmt(lockedProfit)} {symbol} unlocking over {formatDuration(remaining)}
        </span>
      </div>
    );
  }
  return (
    <div className="vesting-row">
      <span className="vesting-label">Profit vesting</span>
      <span className="vesting-val muted">Nothing vesting — new yield unlocks linearly over 3 days</span>
    </div>
  );
}

function VaultDetail({ vault }) {
  const { address } = useAccount();
  const publicClient = usePublicClient();
  const abi = vault.type === "native" ? VAULT_ABI : ERC20_VAULT_ABI;

  const [depositAmt, setDepositAmt] = useState("");
  const [withdrawAmt, setWithdrawAmt] = useState("");
  const [error, setError] = useState("");
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));

  // Tick once a second so the cooldown / vesting countdowns stay live
  useEffect(() => {
    const id = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(id);
  }, []);

  const {
    writeContract, data: txHash, isPending, error: writeError, reset: resetWrite,
  } = useWriteContract();

  const { isLoading: isTxConfirming, isSuccess: isTxConfirmed } =
    useWaitForTransactionReceipt({ hash: txHash });

  const { data: totalAssets, refetch: refetchAssets } = useReadContract({
    address: vault.address, abi, functionName: "totalAssets", query: { refetchInterval: 5000 },
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
    address: vault.address, abi, functionName: "activeAdapter", query: { refetchInterval: 5000 },
  });
  const { data: ratesData } = useReadContract({
    address: vault.address, abi, functionName: "getAllRates", query: { refetchInterval: 5000 },
  });
  const { data: shareValue } = useReadContract({
    address: vault.address, abi, functionName: "convertToAssets",
    args: [shares || 0n], query: { enabled: !!shares && shares > 0n },
  });

  // Protocol-state views (no wallet needed) — allocation, health, vesting, gate
  const { data: protocol, refetch: refetchProtocol } = useReadContracts({
    contracts: [
      { address: vault.address, abi, functionName: "getAdapterHealth" },
      { address: vault.address, abi, functionName: "adapterCapBps" },
      { address: vault.address, abi, functionName: "maxSaneRate" },
      { address: vault.address, abi, functionName: "lockedProfit" },
      { address: vault.address, abi, functionName: "lastProfitCheckpoint" },
      { address: vault.address, abi, functionName: "PROFIT_UNLOCK_PERIOD" },
      { address: vault.address, abi, functionName: "lastRebalanceTime" },
      { address: vault.address, abi, functionName: "cooldownPeriod" },
      { address: vault.address, abi, functionName: "rateThreshold" },
    ],
    query: { refetchInterval: 5000 },
  });
  const [health, capBps, maxSaneRate, lockedProfit, lastCheckpoint, unlockPeriod, lastRebalanceTime, cooldownPeriod, rateThreshold] =
    (protocol ?? []).map((r) => r?.result);

  // Map each adapter (canonical getAllRates order) to its address + per-adapter balance
  const adapterAddrByName = useMemo(() => {
    const inv = {};
    for (const [addr, name] of Object.entries(vault.adapters)) inv[name] = addr;
    return inv;
  }, [vault]);

  const names = ratesData?.[0] ?? [];
  const { data: balances, refetch: refetchBalances } = useReadContracts({
    contracts: names.map((name) => ({
      address: adapterAddrByName[name], abi: ADAPTER_ABI, functionName: "getBalance",
    })),
    query: { enabled: names.length > 0, refetchInterval: 5000 },
  });

  const adapters = names.map((name, i) => ({
    name,
    rate: ratesData[1][i],
    address: adapterAddrByName[name],
    healthy: health?.[i],
    balance: balances?.[i]?.result ?? 0n,
  }));

  // ERC-20 specific: token allowance and balance
  const { data: allowance, refetch: refetchAllowance } = useReadContract({
    address: vault.tokenAddress, abi: ERC20_ABI, functionName: "allowance",
    args: [address, vault.address], query: { enabled: vault.type === "erc20" && !!address },
  });
  const { data: walletBalance } = useReadContract({
    address: vault.tokenAddress, abi: ERC20_ABI, functionName: "balanceOf",
    args: [address], query: { enabled: vault.type === "erc20" && !!address },
  });

  const refetchAll = () => {
    refetchAssets(); refetchShares(); refetchMaxWithdraw(); refetchAdapter();
    refetchProtocol(); refetchBalances(); if (vault.type === "erc20") refetchAllowance();
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

  useEffect(() => {
    setDepositAmt(""); setWithdrawAmt(""); setError(""); resetWrite();
  }, [vault.address]);

  // Simulate first: the RSK public node turns failed submissions into an
  // opaque "RPC submit: Internal server error", but eth_call returns the real
  // revert reason — so surface that and never send a doomed transaction
  const doWrite = async (config) => {
    setError("");
    resetWrite();
    try {
      await publicClient.simulateContract({ ...config, account: address });
    } catch (e) {
      setError(extractReason(e));
      setTimeout(() => setError(""), 8000);
      return;
    }
    writeContract(config);
  };

  const needsApproval = vault.type === "erc20" && depositAmt &&
    (allowance === undefined || allowance < parseEther(depositAmt || "0"));

  const handleApprove = () => doWrite({
    address: vault.tokenAddress, abi: ERC20_ABI, functionName: "approve", args: [vault.address, maxUint256],
  });

  const handleDeposit = () => {
    if (!depositAmt) return;
    if (vault.type === "native") {
      doWrite({ address: vault.address, abi, functionName: "depositNative", args: [address], value: parseEther(depositAmt) });
    } else {
      doWrite({ address: vault.address, abi, functionName: "deposit", args: [parseEther(depositAmt), address] });
    }
  };

  const handleWithdraw = () => {
    if (!withdrawAmt) return;
    if (vault.type === "native") {
      doWrite({ address: vault.address, abi, functionName: "withdrawNative", args: [parseEther(withdrawAmt), address, address] });
    } else {
      doWrite({ address: vault.address, abi, functionName: "withdraw", args: [parseEther(withdrawAmt), address, address] });
    }
  };

  const handleInitialDeposit = () => doWrite({ address: vault.address, abi, functionName: "initialDeposit" });
  const handleRebalance = () => doWrite({ address: vault.address, abi, functionName: "rebalance" });

  const isNoAdapter = !activeAdapter || activeAdapter === ZERO;
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
          <span className="stat-label">Active Adapter</span>
          <span className="stat-value">{adapterName}</span>
        </div>
        <div className="stat-card">
          <span className="stat-label">Your Shares Value</span>
          <span className="stat-value">{address ? `${fmt(shareValue)} ${vault.tokenSymbol}` : "—"}</span>
        </div>
        <div className="stat-card">
          <span className="stat-label">Your Shares</span>
          <span className="stat-value">
            {!address ? "—" : fmt(shareValue) === "0" ? "0" : fmt(shares, 18)} {address ? vault.shareSymbol : ""}
          </span>
        </div>
      </div>

      {adapters.length > 0 && capBps !== undefined && (
        <AllocationPanel adapters={adapters} capBps={capBps} symbol={vault.tokenSymbol} />
      )}

      <RebalanceStatus
        adapters={adapters} activeAdapter={activeAdapter}
        lastRebalanceTime={lastRebalanceTime} cooldownPeriod={cooldownPeriod}
        rateThreshold={rateThreshold} maxSaneRate={maxSaneRate} now={now}
      />

      <VestingRow
        lockedProfit={lockedProfit} lastCheckpoint={lastCheckpoint}
        unlockPeriod={unlockPeriod} symbol={vault.tokenSymbol} now={now}
      />

      {address ? (
        <div className="actions-section">
          {vault.type === "erc20" && (
            <p className="wallet-bal">Wallet: {fmt(walletBalance)} {vault.tokenSymbol}</p>
          )}

          <div className="action-row">
            <input type="number" placeholder={`Amount in ${vault.tokenSymbol}`}
              value={depositAmt} onChange={(e) => setDepositAmt(e.target.value)} step="0.001" />
            {needsApproval ? (
              <button onClick={handleApprove} disabled={isPending || isTxConfirming} className="btn btn-primary">
                {isPending ? "Confirm..." : "Approve"}
              </button>
            ) : (
              <button onClick={handleDeposit} disabled={isPending || isTxConfirming || !depositAmt} className="btn btn-primary">
                {isPending ? "Confirm..." : isTxConfirming ? "Confirming..." : `Deposit ${vault.tokenSymbol}`}
              </button>
            )}
          </div>

          <div className="action-row">
            <input type="number" placeholder={`Amount in ${vault.tokenSymbol}`}
              value={withdrawAmt} onChange={(e) => setWithdrawAmt(e.target.value)} step="0.001" />
            <button onClick={handleWithdraw} disabled={isPending || isTxConfirming || !withdrawAmt} className="btn btn-secondary">
              {isPending ? "Confirm..." : isTxConfirming ? "Confirming..." : `Withdraw ${vault.tokenSymbol}`}
            </button>
            {maxWithdrawAmt > 0n && (
              <button onClick={() => {
                const raw = formatEther(maxWithdrawAmt);
                const parts = raw.split(".");
                const trimmed = parts[1] ? parts[0] + "." + parts[1].slice(0, 6).replace(/0+$/, "") : parts[0];
                setWithdrawAmt(trimmed.endsWith(".") ? trimmed.slice(0, -1) : trimmed);
              }} className="btn btn-sm">Max</button>
            )}
          </div>

          <div className="action-row">
            {isNoAdapter && (
              <button onClick={handleInitialDeposit} disabled={isPending || isTxConfirming} className="btn btn-primary">
                Initialize Vault
              </button>
            )}
            <button onClick={handleRebalance} disabled={isPending || isTxConfirming || isNoAdapter} className="btn btn-secondary">
              Rebalance
            </button>
          </div>

          {isTxConfirming && <p className="tx-status">Waiting for confirmation...</p>}
          {isTxConfirmed && <p className="tx-status success">Transaction confirmed!</p>}
          {error && <p className="tx-status error">{error}</p>}
        </div>
      ) : (
        <p className="connect-hint">Connect a wallet to deposit, withdraw, or rebalance.</p>
      )}
    </div>
  );
}

function App() {
  const [selectedIdx, setSelectedIdx] = useState(0);

  return (
    <div className="app">
      <header>
        <div className="brand">
          <h1>Rootstock Yield Vaults</h1>
          <span className="net-badge">Testnet</span>
        </div>
        <p className="subtitle">ERC-4626 yield optimizer — auto-rebalance between LayerBank and Sovryn</p>
        <ConnectButton showBalance={false} />
      </header>

      <div className="vault-cards">
        {VAULTS.map((v, i) => (
          <VaultCard key={v.address} vault={v} selected={i === selectedIdx} onClick={() => setSelectedIdx(i)} />
        ))}
      </div>

      <VaultDetail vault={VAULTS[selectedIdx]} />

      <footer className="app-footer">
        <a href={REPO} target="_blank" rel="noreferrer">GitHub</a>
        <span className="dot-sep">·</span>
        <a href={EXPLORER + VAULTS[0].address} target="_blank" rel="noreferrer">Vault on Blockscout</a>
        <span className="dot-sep">·</span>
        <span className="muted">No admin · no upgrade · no pause</span>
      </footer>
    </div>
  );
}

export default App;
