require("dotenv").config();
const { ethers } = require("ethers");

// --- CONFIGURATION ---
const RPC_URL = process.env.RPC_URL;
const PRIVATE_KEY = process.env.PRIVATE_KEY;
const DISPUTE_ADDR = process.env.DISPUTE_CONTRACT_ADDRESS;
const ESCROW_ADDR = process.env.ESCROW_CONTRACT_ADDRESS;
const USDC_ADDR = process.env.USDC_CONTRACT_ADDRESS;

// --- ABIs ---
const DISPUTE_ABI = [
  "function createJob(address _contractor, uint256 _amount) external",
  "function raiseDispute(uint256 _jobId) external",
  "function resolveDispute(uint256 _jobId, uint256 _clientSplit, string calldata _explanation) external",
  "function nextJobId() external view returns (uint256)",
  "event JobCreated(uint256 indexed id, address client, address contractor, uint256 amount)",
  "event DisputeRaised(uint256 indexed id, address raisedBy)",
  "event DisputeResolved(uint256 indexed id, uint256 finalClientSplit)",
];

const USDC_ABI = [
  "function approve(address spender, uint256 amount) external returns (bool)",
  "function allowance(address owner, address spender) external view returns (uint256)",
  "function balanceOf(address account) external view returns (uint256)",
];

async function main() {
  console.clear();
  console.log(" STARTING FULL CLIENT DEMO ");
  console.log("=================================");

  // 1. Setup
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const wallet = new ethers.Wallet(PRIVATE_KEY, provider);

  const disputeContract = new ethers.Contract(
    DISPUTE_ADDR,
    DISPUTE_ABI,
    wallet
  );
  const usdcContract = new ethers.Contract(USDC_ADDR, USDC_ABI, wallet);

  console.log(` Actor: ${wallet.address}`);

  // Check USDC Balance
  const balance = await usdcContract.balanceOf(wallet.address);
  console.log(` USDC Balance: ${ethers.formatUnits(balance, 6)} USDC`);

  if (balance == 0n) {
    console.error(" ERROR: You need Base Sepolia USDC to run this demo!");
    console.error(" Get it here: https://faucet.circle.com/");
    process.exit(1);
  }

  // --- STEP 1: APPROVE ESCROW ---
  console.log("\n[1/4] Checking Approvals...");
  const amountToJob = ethers.parseUnits("0.1", 6); // 1 USDC
  const allowance = await usdcContract.allowance(wallet.address, ESCROW_ADDR);

  if (allowance < amountToJob) {
    console.log("   Approving Escrow to spend USDC...");
    const txApprove = await usdcContract.approve(
      ESCROW_ADDR,
      ethers.MaxUint256
    );
    await txApprove.wait();
    console.log("   Approved!");
  } else {
    console.log("   Already Approved");
  }

  // --- STEP 2: CREATE JOB ---
  console.log("\n[2/4] Creating Job (Client deposits funds)...");

  // For demo, we are both Client AND Contractor
  // This allows us to raise the dispute ourselves without switching wallets
  const myAddress = wallet.address;

  // Get expected Job ID
  const jobId = await disputeContract.nextJobId();
  console.log(`   Creating Job #${jobId}...`);

  const txCreate = await disputeContract.createJob(myAddress, amountToJob);
  console.log(`   Tx Sent: ${txCreate.hash}`);
  await txCreate.wait();
  console.log(`   Job #${jobId} Created & Funded!`);

  // --- STEP 3: RAISE DISPUTE ---
  console.log("\n[3/4] Raising Dispute (Simulating Contractor/Client)...");
  console.log("   Something went wrong with the job!");

  const txDispute = await disputeContract.raiseDispute(jobId);
  console.log(`   Tx Sent: ${txDispute.hash}`);
  await txDispute.wait();
  console.log(`   Dispute Raised! Funds are locked.`);

  // --- STEP 4: AI RESOLUTION ---
  console.log("\n[4/4] AI Agent Intervention...");
  console.log("   AI is analyzing chat logs...");
  await new Promise((r) => setTimeout(r, 2000)); // Fake delay

  console.log("   Verdict: 50/50 Split");

  const txResolve = await disputeContract.resolveDispute(
    jobId,
    50, // 50% to Client
    "Demo: AI determined partial completion."
  );
  console.log(`   Tx Sent: ${txResolve.hash}`);
  await txResolve.wait();

  console.log(`\n DEMO COMPLETE! Dispute Resolved.`);
  console.log("=================================");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
