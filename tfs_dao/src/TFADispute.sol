// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        escrow = TFAEscrow(_escrowAddress);
    }

    // --- 1. START ---
    function createJob(address _contractor, uint256 _amount) external {
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

        escrow.deposit(jobId, msg.sender, _amount);
        emit JobCreated(jobId, msg.sender, _contractor, _amount);
    }

    // --- 2. HAPPY ENDING ---
    function releaseToContractor(uint256 _jobId) external {
        Job storage j = jobs[_jobId];
        require(msg.sender == j.client, "Only client");
        require(j.state == JobState.Active, "Not active");
        
        escrow.releaseFunds(j.contractor, j.totalAmount, _jobId);
        j.state = JobState.Resolved;
        emit FundsReleased(_jobId, j.contractor, j.totalAmount);
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

        // FIX: Actually save the explanation!
        j.aiExplanation = _explanation;
        j.aiClientSplit = _clientSplit;
        j.aiVerdictTimestamp = block.timestamp;

        uint256 clientAmt = (j.totalAmount * _clientSplit) / 100;
        uint256 contractorAmt = j.totalAmount - clientAmt;

        if (clientAmt > 0) escrow.releaseFunds(j.client, clientAmt, _jobId);
        if (contractorAmt > 0) escrow.releaseFunds(j.contractor, contractorAmt, _jobId);

        j.state = JobState.Resolved;
        emit DisputeResolved(_jobId, _clientSplit);
    }
}