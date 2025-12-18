const mongoose = require("mongoose");

const jobSchema = new mongoose.Schema(
  {
    jobId: { type: Number, unique: true, required: true },
    client: String,
    contractor: String,
    amount: String,
    status: {
      type: String,
      enum: [
        "Active",
        "DisputeRaised",
        "AIResolved",
        "DAOEscalated",
        "Resolved",
      ],
      default: "Active",
    },
    evidence: [String], 
    aiVerdict: {
      contractorPercent: Number,
      explanation: String,
      timestamp: Date,
    },
  },
  { timestamps: true }
);

module.exports = mongoose.model("Job", jobSchema);
