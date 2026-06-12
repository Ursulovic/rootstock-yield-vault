# Demo Script

Run these commands in order during the demo recording.
Frontend should be open at http://localhost:5173

## Setup (before recording)

```bash
# Terminal 1: Start Anvil
pkill anvil; sleep 1
anvil --chain-id 31337 --port 8545

# Terminal 2: Deploy contracts
forge script script/DeployLocal.s.sol --rpc-url http://localhost:8545 --broadcast

# Terminal 3: Start frontend in LOCAL mode (defaults to testnet otherwise)
cd frontend && VITE_USE_LOCAL=true npm run dev
```

Add Anvil to MetaMask: Chain ID 31337, RPC http://127.0.0.1:8545
Import Anvil account: 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

IMPORTANT after every Anvil restart: MetaMask caches the old chain's nonces.
Settings -> Advanced -> Clear activity tab data, or the first tx fails with
"nonce too high".

Note: Sovryn's mock (like the real protocol) takes percent-scaled rates
(1e18 = 1%), LayerBank's mock takes fraction-scaled (1e18 = 100%) per asset.

## Demo Flow

### Step 1: Deposit
In frontend: type 1, click Deposit rBTC

### Step 2: Initialize
In frontend: click Initialize Vault
Result: Active Adapter changes to "LayerBank" (5% > 3%)

### Step 3: Change rates (make Sovryn better)
```bash
# Set Sovryn rate to 10% (percent scale: 10% = 10e18)
cast send 0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9 \
  "setSupplyInterestRate(uint256)" 10000000000000000000 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --rpc-url http://localhost:8545

# Skip 1 hour cooldown
cast rpc anvil_increaseTime 3601 --rpc-url http://localhost:8545
cast rpc anvil_mine 1 --rpc-url http://localhost:8545
```

### Step 4: Rebalance
In frontend: rates auto-refresh within ~5s, click Rebalance
Result: Active Adapter switches from "LayerBank" to "Sovryn"

### Step 4b (optional): Show yield accruing — the money shot
The vault is now in Sovryn. Drop 0.05 rBTC of "yield" into the Sovryn mock,
then trigger its accrual (the mock recomputes token price from its balance):
```bash
cast send 0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9 --value 50000000000000000 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --rpc-url http://localhost:8545
cast send 0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9 "accrueInterest()" \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --rpc-url http://localhost:8545
```
Result: "Your Position" value visibly increases within ~5s — shares are worth more rBTC.

### Step 5: Change rates back (make LayerBank better)
```bash
# Set LayerBank WRBTC rate to 15% (fraction scale: 15% = 0.15e18)
cast send 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512 \
  "setSupplyRate1e18(address,uint256)" \
  0x5FbDB2315678afecb367f032d93F642f64180aa3 150000000000000000 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --rpc-url http://localhost:8545

# Skip cooldown again
cast rpc anvil_increaseTime 3601 --rpc-url http://localhost:8545
cast rpc anvil_mine 1 --rpc-url http://localhost:8545
```

### Step 6: Rebalance again
In frontend: click Rebalance once the rates update
Result: Switches back to LayerBank

### Step 7: Withdraw
In frontend: click Max, click Withdraw rBTC
Result: Funds returned to wallet
