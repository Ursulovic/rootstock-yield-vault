# Demo Script

Run these commands in order during the demo recording.
Frontend should be open at http://localhost:5174

## Setup (before recording)

```bash
# Terminal 1: Start Anvil
pkill anvil; sleep 1
anvil --chain-id 31337 --port 8545

# Terminal 2: Deploy contracts
forge script script/DeployLocal.s.sol --rpc-url http://localhost:8545 --broadcast

# Terminal 3: Start frontend
cd frontend && npm run dev
```

Add Anvil to MetaMask: Chain ID 31337, RPC http://127.0.0.1:8545
Import Anvil account: 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

## Demo Flow

### Step 1: Deposit
In frontend: type 1, click Deposit rBTC

### Step 2: Initialize
In frontend: click Initialize Vault
Result: Active Adapter changes to "Tropykus" (5% > 3%)

### Step 3: Change rates (make Sovryn better)
```bash
# Set Sovryn rate to 10%
cast send 0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0 \
  "setSupplyInterestRate(uint256)" 100000000000000000 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --rpc-url http://localhost:8545

# Skip 1 hour cooldown
cast rpc anvil_increaseTime 3601 --rpc-url http://localhost:8545
cast rpc anvil_mine 1 --rpc-url http://localhost:8545
```

### Step 4: Rebalance
In frontend: refresh page (to see new rates), click Rebalance
Result: Active Adapter switches from "Tropykus" to "Sovryn"

### Step 5: Change rates back (make Tropykus better)
```bash
# Set Tropykus rate to 15%
cast send 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512 \
  "setSupplyRatePerBlock(uint256)" 142694063926 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --rpc-url http://localhost:8545

# Skip cooldown again
cast rpc anvil_increaseTime 3601 --rpc-url http://localhost:8545
cast rpc anvil_mine 1 --rpc-url http://localhost:8545
```

### Step 6: Rebalance again
In frontend: refresh, click Rebalance
Result: Switches back to Tropykus

### Step 7: Withdraw
In frontend: click Max, click Withdraw rBTC
Result: Funds returned to wallet
