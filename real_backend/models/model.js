const mongoose = require("mongoose");

const jobSchema = new mongoose.Schema(
  {
    jobId: { type: Number, unique: true }, 
    clientAddress: String,
    contractorAddress: String,
    amountUSDC: Number,
    status: {
      type: String,
      enum: [
        "PendingApproval",
        "Active",
        "DisputeRaised",
        "AIResolved",
        "DAOEscalated",
        "Resolved",
      ],
      default: "Active",
    },
    evidence: [
      {
        sender: String,
        message: String,
        fileUrl: String,
        timestamp: Date,
      },
    ],
    aiVerdict: {
      contractorPercent: Number,
      explanation: String,
      deadline: Date, 
      txHash: String,
    },
    daoSession: {
      endTime: Date,
      durationSeconds: Number,
      consensusPercent: Number,
    },
  },
  { timestamps: true }
);

module.exports = mongoose.model("Job", jobSchema);
