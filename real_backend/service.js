require("dotenv").config();
const { ethers } = require("ethers");
const mongoose = require("mongoose");
const Job = require("./models/model");

const DisputeArtifact = require("./out/TFADispute.sol/TFADispute.json");
const DAOVotingArtifact = require("./out/TFADaoVoting.sol/TFADAOVoting.json");

const DISPUTE_ADDR = process.env.TFA_DISPUTE_ADDRESS;
const DAO_ADDR = process.env.TFA_DAO_VOTING_ADDRESS;
const PRIVATE_KEY = process.env.AI_WALLET_PRIVATE_KEY;
const RPC_URL = process.env.BASE_RPC_URL || "https://sepolia.base.org";

async function startProductionService() {
  try {
    await mongoose.connect(process.env.MONGODB_URI);
    console.log(" Production: Connected to MongoDB");
  } catch (err) {
    console.error(" MongoDB Connection Error:", err);
    process.exit(1);
  }

  // Blockchain Setup
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const wallet = new ethers.Wallet(PRIVATE_KEY, provider);

  const disputeContract = new ethers.Contract(
    DISPUTE_ADDR,
    DisputeArtifact.abi,
    wallet
  );
  const daoContract = new ethers.Contract(
    DAO_ADDR,
    DAOVotingArtifact.abi,
    wallet
  );

  console.log(`AI Agent Active: Listening on ${DISPUTE_ADDR}`);

  disputeContract.on("DisputeRaised", async (jobId, raisedBy) => {
    const id = Number(jobId);
    console.log(`[DISPUTE] Job #${id} triggered by ${raisedBy}`);

    try {
      const jobRecord = await Job.findOne({ jobId: id });
      if (!jobRecord) {
        console.warn(`[WARN] Job #${id} not found in database.`);
        return;
      }

      const verdict = {
        contractorPercent: 70,
        explanation:
          "Deliverables met the core requirements, but the final documentation was missing.",
      };

      console.log(`[TX] Submitting verdict for Job #${id}...`);
      const tx = await disputeContract.submitAIVerdict(
        id,
        verdict.contractorPercent,
        verdict.explanation
      );

      const receipt = await tx.wait();
      console.log(
        `[SUCCESS] On-chain verdict confirmed in block ${receipt.blockNumber}`
      );

      jobRecord.status = "AIResolved";
      jobRecord.aiVerdict = {
        contractorPercent: verdict.contractorPercent,
        explanation: verdict.explanation,
        deadline: new Date(Date.now() + 72 * 60 * 60 * 1000), 
      };
      await jobRecord.save();
    } catch (error) {
      console.error(`[ERROR] Failed to resolve Job #${id}:`, error.message);
    }
  });
}


async function escalateToDAO(jobId, durationSeconds) {
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
  const daoContract = new ethers.Contract(
    DAO_ADDR,
    DAOVotingArtifact.abi,
    wallet
  );

  console.log(
    `[DAO] Escalating Job #${jobId} with duration: ${durationSeconds}s`
  );

  try {
    const tx = await daoContract.startVoting(jobId, durationSeconds);
    await tx.wait();

    await Job.findOneAndUpdate(
      { jobId },
      {
        status: "DAOEscalated",
        daoDuration: durationSeconds,
      }
    );
    console.log(`[DAO] Job #${jobId} is now live for voting.`);
  } catch (err) {
    console.error(`[DAO ERROR] Job #${jobId} escalation failed:`, err.message);
  }
}

process.on("unhandledRejection", (reason, promise) => {
  console.error("Unhandled Rejection at:", promise, "reason:", reason);
});

startProductionService().catch(console.error);
