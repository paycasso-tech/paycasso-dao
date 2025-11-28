// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { TFAEscrow } from "./TFAEscrow.sol";

contract TFADispute is AccessControl {
    
    bytes32 public constant AI_AGENT_ROLE = keccak256("AI_AGENT_ROLE");

    enum JobState {
        Active,         // Money locked, Work in progress
        Disputed,       // Backend is analyzing chat logs
        Resolved        // Money paid out
    }

    struct Job {
        uint256 id;
        address client;
        address contractor;
        uint256 totalAmount;
        JobState state;
        // AI Verdict Data
        uint256 aiClientSplit;
        string aiExplanation;
        uint256 aiVerdictTimestamp;
    }

    TFAEscrow public escrow;
    uint256 public nextJobId;
    mapping(uint256 => Job) public jobs;

    event JobCreated(uint256 indexed id, address client, address contractor, uint256 amount);
    event FundsReleased(uint256 indexed id, address to, uint256 amount);
    event DisputeRaised(uint256 indexed id, address raisedBy);
    event DisputeResolved(uint256 indexed id, uint256 finalClientSplit);

    constructor(address _escrowAddress, address _admin) {
        require(_escrowAddress != address(0), "Invalid Escrow Address");
        require(_admin != address(0), "Invalid Admin Address");
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        escrow = TFAEscrow(_escrowAddress);
    }

    // --- 1. START ---
    function createJob(address _contractor, uint256 _amount) external {
        require(_contractor != address(0), "Invalid Contractor");
        require(_amount > 0, "Amount must be > 0");

        uint256 jobId = nextJobId++;
        jobs[jobId] = Job({
            id: jobId,
            client: msg.sender,
            contractor: _contractor,
            totalAmount: _amount,
            state: JobState.Active,
            aiClientSplit: 0,
            aiExplanation: "",
            aiVerdictTimestamp: 0
        });

        // 1. Emit Event
        emit JobCreated(jobId, msg.sender, _contractor, _amount);

        // 2. Interaction (External Call)
        escrow.deposit(jobId, msg.sender, _amount);
    }

    // --- 2. HAPPY ENDING ---
    function releaseToContractor(uint256 _jobId) external {
        Job storage j = jobs[_jobId];
        require(msg.sender == j.client, "Only client");
        require(j.state == JobState.Active, "Not active");
        
        // EFFECT: Update state FIRST (Fixes Reentrancy)
        j.state = JobState.Resolved; 
        
        emit FundsReleased(_jobId, j.contractor, j.totalAmount);

        // INTERACTION: Transfer funds LAST
        escrow.releaseFunds(j.contractor, j.totalAmount, _jobId);
    }

    // --- 3. DISPUTE TRIGGER ---
    function raiseDispute(uint256 _jobId) external {
        Job storage j = jobs[_jobId];
        require(msg.sender == j.client || msg.sender == j.contractor, "Not party");
        require(j.state == JobState.Active, "Not active");

        j.state = JobState.Disputed; 
        emit DisputeRaised(_jobId, msg.sender);
    }

    // --- 4. AI VERDICT ---
    function resolveDispute(uint256 _jobId, uint256 _clientSplit, string calldata _explanation) 
        external 
        onlyRole(AI_AGENT_ROLE) 
    {
        Job storage j = jobs[_jobId];
        require(j.state == JobState.Disputed, "Not disputed");
        require(_clientSplit <= 100, "Split cannot exceed 100%"); // Safety Check

        // EFFECT: Update State
        j.aiExplanation = _explanation;
        j.aiClientSplit = _clientSplit;
        j.aiVerdictTimestamp = block.timestamp;
        j.state = JobState.Resolved;

        emit DisputeResolved(_jobId, _clientSplit);

        // INTERACTION: Move Funds
        uint256 clientAmt = (j.totalAmount * _clientSplit) / 100;
        uint256 contractorAmt = j.totalAmount - clientAmt;

        if (clientAmt > 0) escrow.releaseFunds(j.client, clientAmt, _jobId);
        if (contractorAmt > 0) escrow.releaseFunds(j.contractor, contractorAmt, _jobId);
    }
}