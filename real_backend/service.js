require("dotenv").config();
const express = require("express");
const { ethers } = require("ethers");
const mongoose = require("mongoose");
const Job = require("./models/model");
const { fromUSDC, toUSDC } = require("./utils/web3Helper");

const DisputeArtifact = require("./out/TFADispute.sol/TFADispute.json");
const DAOVotingArtifact = require("./out/TFADaoVoting.sol/TFADAOVoting.json");

const app = express();
app.use(express.json());

const provider = new ethers.JsonRpcProvider(process.env.BASE_RPC_URL);
const aiWallet = new ethers.Wallet(process.env.AI_WALLET_PRIVATE_KEY, provider);

// Contract Instances
const disputeContract = new ethers.Contract(
  process.env.TFA_DISPUTE_ADDRESS,
  DisputeArtifact.abi,
  aiWallet
);
const daoContract = new ethers.Contract(
  process.env.TFA_DAO_VOTING_ADDRESS,
  DAOVotingArtifact.abi,
  aiWallet
);

/**
 * BLOCKCHAIN LISTENERS (Keep DB in sync with Chain)
 */
const startListeners = () => {
  // Sync Job Creation
  disputeContract.on("JobCreated", async (id, client, contractor, amount) => {
    console.log(`Syncing Job #${id} to Database...`);
    await Job.findOneAndUpdate(
      { jobId: Number(id) },
      {
        clientAddress: client,
        contractorAddress: contractor,
        amountUSDC: fromUSDC(amount),
        status: "Active",
      },
      { upsert: true }
    );
  });

  // Sync Dispute Status
  disputeContract.on("DisputeRaised", async (id, raisedBy) => {
    const job = await Job.findOneAndUpdate(
      { jobId: Number(id) },
      { status: "DisputeRaised" }
    );
    // Trigger AI Logic internally
    processAIDispute(Number(id), job.evidence);
  });
};


async function processAIDispute(jobId, evidence) {
  try {
    // Mock AI logic - determine split based on evidence
    const verdict = { percent: 60, reason: "Partially completed work." };

    console.log(`Submitting AI Verdict for Job #${jobId}...`);
    const tx = await disputeContract.submitAIVerdict(
      jobId,
      verdict.percent,
      verdict.reason
    );
    await tx.wait();

    await Job.findOneAndUpdate(
      { jobId },
      {
        status: "AIResolved",
        "aiVerdict.contractorPercent": verdict.percent,
        "aiVerdict.explanation": verdict.reason,
        "aiVerdict.deadline": new Date(Date.now() + 72 * 60 * 60 * 1000), // 72h window
      }
    );
  } catch (err) {
    console.error("AI Submission Failed:", err);
  }
}


// 1. Get Job Details (Abstracts away BigInts)
app.get("/api/job/:id", async (req, res) => {
  const job = await Job.findOne({ jobId: req.params.id });
  res.json(job);
});

// 2. Escalate to DAO (Backend handles the complex 2-argument call)
app.post("/api/job/:id/escalate", async (req, res) => {
  const { id } = req.params;
  const { durationSeconds } = req.body; // e.g., 432000 for 5 days

  try {
    // Call the updated startVoting function
    const tx = await daoContract.startVoting(id, durationSeconds);
    const receipt = await tx.wait();

    await Job.findOneAndUpdate({ jobId: id }, { status: "DAOEscalated" });
    res.json({ success: true, txHash: receipt.hash });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 3. Post Evidence (Off-chain storage for AI to read)
app.post("/api/job/:id/evidence", async (req, res) => {
  const { message, fileUrl, sender } = req.body;
  await Job.findOneAndUpdate(
    { jobId: req.params.id },
    { $push: { evidence: { sender, message, fileUrl, timestamp: new Date() } } }
  );
  res.json({ success: true });
});

mongoose.connect(process.env.MONGODB_URI).then(() => {
  app.listen(3000, () => {
    console.log("Server running on port 3000");
    startListeners();
  });
});
