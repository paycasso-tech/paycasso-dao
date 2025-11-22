

````markdown
# 🛠️ TFA Smart Contract Integration Guide

## 👋 Overview
This document explains how the Backend (Node.js/Python) interacts with the TFA Dispute Resolution Smart Contract on the **Base Blockchain**.

**Your Role:**
1.  **Listen** for events (New Jobs, Disputes).
2.  **Read** data (Job details).
3.  **Write** data (Submit AI Verdicts) *only when a dispute happens*.

---

## ⚙️ Configuration

### 1. Blockchain Connection
You need an RPC URL to talk to the blockchain.
* **Base Sepolia (Testnet):** `https://sepolia.base.org`
* **Base Mainnet (Production):** `https://mainnet.base.org`

### 2. Contract Addresses
* **TFA Dispute Contract:** `0x...` (Ask Blockchain Dev for deployed address)
* **USDC Contract (Base Sepolia):** `0x036CbD53842c5426634e7929541eC2318f3dCF7e`
* **USDC Contract (Base Mainnet):** `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`

### 3. Secrets (Environment Variables)
Add these to your `.env` file:
```env
# The private key of the wallet acting as the AI Agent
# MUST have the AI_AGENT_ROLE on the smart contract
AI_WALLET_PRIVATE_KEY=0xabc123...

# RPC URL (Use a provider like Alchemy/Infura for better stability)
BASE_RPC_URL=[https://sepolia.base.org](https://sepolia.base.org)
````

-----

## 📜 Contract ABI (Interface)

You need this JSON snippet to interact with the contract.

```json
[
  "event JobCreated(uint256 indexed id, address client, address contractor, uint256 amount)",
  "event FundsReleased(uint256 indexed id, address to, uint256 amount)",
  "event DisputeRaised(uint256 indexed id, address raisedBy)",
  "event DisputeResolved(uint256 indexed id, uint256 finalClientSplit)",
  "function resolveDispute(uint256 _jobId, uint256 _clientSplit, string calldata _explanation) external"
]
```

-----

## 📡 Workflow & Logic

### 1\. The Happy Path (Automatic)

  * **Trigger:** User creates a job on Frontend.
  * **Event:** `JobCreated(id, client, contractor, amount)`
  * **Backend Action:** Create a record in your DB: `Job #{id} = Active`.
  * *Later...*
  * **Trigger:** Client releases funds on Frontend.
  * **Event:** `FundsReleased(id, ...)`
  * **Backend Action:** Mark `Job #{id} = Completed`.

### 2\. The Dispute Path (Requires AI)

  * **Trigger:** Contractor/Client clicks "Raise Dispute".
  * **Event:** `DisputeRaised(id, raisedBy)`
  * **Backend Action:**
    1.  **FETCH:** Get chat logs/files for `Job #{id}` from DB.
    2.  **ANALYZE:** Send to AI for verdict.
    3.  **EXECUTE:** Call `resolveDispute()` on blockchain.

-----

## 💻 Code Implementation (Node.js / Ethers.js)

### Prerequisite

```bash
npm install ethers dotenv
```

### `service.js`

```javascript
require('dotenv').config();
const { ethers } = require("ethers");

// CONFIGURATION
const CONTRACT_ADDRESS = "0xYourDeployedContractAddress"; // UPDATE THIS
const RPC_URL = process.env.BASE_RPC_URL;
const PRIVATE_KEY = process.env.AI_WALLET_PRIVATE_KEY;

// MINIMAL ABI
const ABI = [
    "event JobCreated(uint256 indexed id, address client, address contractor, uint256 amount)",
    "event DisputeRaised(uint256 indexed id, address raisedBy)",
    "function resolveDispute(uint256 _jobId, uint256 _clientSplit, string calldata _explanation) external"
];

async function startService() {
    // 1. Connect to Blockchain
    const provider = new ethers.JsonRpcProvider(RPC_URL);
    
    // 2. Create Wallet (Only needed for writing transactions)
    const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
    
    // 3. Create Contract Instance
    // Use 'provider' for listening, 'wallet' for writing
    const contract = new ethers.Contract(CONTRACT_ADDRESS, ABI, wallet);

    console.log("Listening for TFA Dispute events on Base...");

    // --- LISTENER: NEW JOBS ---
    contract.on("JobCreated", (id, client, contractor, amount) => {
        console.log(`[NEW JOB] ID: ${id} | Amount: ${ethers.formatUnits(amount, 6)} USDC`);
        
        // TODO: Save to database
        // db.createJob({ chainId: id, client, contractor, status: 'ACTIVE' });
    });

    // --- LISTENER: DISPUTES (CRITICAL) ---
    contract.on("DisputeRaised", async (id, raisedBy) => {
        console.log(`[DISPUTE] ID: ${id} raised by ${raisedBy}`);
        
        // TODO: Fetch Evidence from DB
        // const evidence = db.getChatLogs(id);
        
        // TODO: Run AI Logic
        // const verdict = await runAI(evidence); 
        
        // MOCK VERDICT FOR DEMO:
        const mockVerdict = {
            clientWinPercentage: 100, // 100% Refund to Client
            reason: "Contractor did not deliver files."
        };

        // SUBMIT VERDICT
        await submitVerdict(contract, id, mockVerdict);
    });
}

async function submitVerdict(contract, jobId, verdict) {
    try {
        console.log(`🤖 Submitting verdict for Job #${jobId}...`);
        
        const tx = await contract.resolveDispute(
            jobId,
            verdict.clientWinPercentage,
            verdict.reason
        );

        console.log(`Transaction sent: ${tx.hash}`);
        await tx.wait(); // Wait for block confirmation
        console.log(`Dispute Resolved on-chain!`);

    } catch (error) {
        console.error("Failed to submit verdict:", error);
    }
}

startService();
```

-----

##  FAQ

**Q: Do I need to hold ETH?**
A: Yes. The `AI_WALLET` needs a tiny amount of Base ETH (approx $0.05 worth) to pay for gas fees when calling `resolveDispute`.

**Q: What is `_clientSplit`?**
A: It is an integer from 0 to 100 representing the **Client's share**.

  * `100` = Client gets full refund.
  * `0` = Contractor gets full payment.
  * `50` = Split 50/50.

**Q: Can I update the verdict later?**
A: No. Once `resolveDispute` is mined, the money is moved instantly. The decision is final.

```
```