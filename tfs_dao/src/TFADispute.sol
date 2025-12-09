// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { TFAEscrow } from "./TFAEscrow.sol";

/**
 * @title TFADispute
 * @notice Handles job creation, AI resolution (Layer 1), and escalation to DAO (Layer 2)
 * @dev First layer of dispute resolution using AI agent
 */
contract TFADispute is AccessControl {
    
    bytes32 public constant AI_AGENT_ROLE = keccak256("AI_AGENT_ROLE");

    enum JobState {
        Active,              // Money locked, work in progress (both fees deposited)
        DisputeRaised,       // Dispute raised, ready for AI resolution
        AIResolved,          // AI gave verdict, waiting for acceptance
        DAOEscalated,        // Escalated to DAO voting
        Resolved             // Money paid out (final state)
    }

    struct Job {
        uint256 id;
        address client;
        address contractor;
        uint256 contractAmount;         // The actual work payment
        uint256 feeAmount;              // Fee each party deposits (calculated as % of contract)
        JobState state;
        
        // AI Verdict Data (Layer 1)
        uint256 aiContractorPercent;    // 0-100: % of contract going to contractor
        string aiExplanation;
        uint256 aiVerdictTimestamp;
        bool clientAcceptedAI;
        bool contractorAcceptedAI;
        uint256 aiAcceptanceDeadline;   // 72 hours to accept/reject AI verdict
    }

    TFAEscrow public escrow;
    address public daoContract;
    uint256 public nextJobId;
    uint256 public feePercentage = 5; // 5% fee from each party
    
    mapping(uint256 => Job) public jobs;

    event JobCreated(uint256 indexed id, address client, address contractor, uint256 amount, uint256 feeAmount);
    event FundsReleased(uint256 indexed id, address to, uint256 amount);
    event DisputeRaised(uint256 indexed id, address raisedBy);
    event AIVerdictIssued(uint256 indexed id, uint256 contractorPercent, string explanation);
    event AIVerdictAccepted(uint256 indexed id, address acceptedBy);
    event AIVerdictRejected(uint256 indexed id, address rejectedBy);
    event EscalatedToDAO(uint256 indexed id);
    event DisputeResolved(uint256 indexed id, uint256 finalContractorPercent);

    constructor(address _escrowAddress, address _admin) {
        require(_escrowAddress != address(0), "Invalid Escrow Address");
        require(_admin != address(0), "Invalid Admin Address");
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        escrow = TFAEscrow(_escrowAddress);
    }

    function setDAOContract(address _daoContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_daoContract != address(0), "Invalid DAO Address");
        daoContract = _daoContract;
    }

    function setFeePercentage(uint256 _feePercentage) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_feePercentage <= 20, "Fee too high"); // Max 20%
        feePercentage = _feePercentage;
    }

    /**
     * @notice Client creates a job - BOTH client and contractor deposit fees upfront
     * @dev Contractor must approve this contract to spend their fee before job creation
     * @param _contractor Contractor address
     * @param _amount Contract amount in USDC
     */
    function createJob(address _contractor, uint256 _amount) external {
        require(_contractor != address(0), "Invalid Contractor");
        require(_contractor != msg.sender, "Cannot hire yourself");
        require(_amount > 0, "Amount must be > 0");

        uint256 jobId = nextJobId++;
        uint256 feeAmount = (_amount * feePercentage) / 100;
        require(feeAmount >= 10 * 10**6, "Fee too small"); // Minimum 10 USDC

        jobs[jobId] = Job({
            id: jobId,
            client: msg.sender,
            contractor: _contractor,
            contractAmount: _amount,
            feeAmount: feeAmount,
            state: JobState.Active,
            aiContractorPercent: 0,
            aiExplanation: "",
            aiVerdictTimestamp: 0,
            clientAcceptedAI: false,
            contractorAcceptedAI: false,
            aiAcceptanceDeadline: 0
        });

        emit JobCreated(jobId, msg.sender, _contractor, _amount, feeAmount);

        // Client deposits: contract amount + client fee
        escrow.deposit(jobId, msg.sender, _amount, false); // Contract amount
        escrow.deposit(jobId, msg.sender, feeAmount, true); // Client fee
        
        // Contractor deposits: their fee (must have approved this contract first!)
        escrow.deposit(jobId, _contractor, feeAmount, true); // Contractor fee
    }

    /**
     * @notice Client releases funds to contractor (happy path, no dispute)
     * @param _jobId Job identifier
     */
    function releaseToContractor(uint256 _jobId) external {
        Job storage j = jobs[_jobId];
        require(msg.sender == j.client, "Only client");
        require(j.state == JobState.Active, "Not active");
        
        // Update state
        j.state = JobState.Resolved;
        
        emit FundsReleased(_jobId, j.contractor, j.contractAmount);
        emit FundsReleased(_jobId, j.client, j.feeAmount); // Refund client fee
        emit FundsReleased(_jobId, j.contractor, j.feeAmount); // Refund contractor fee

        // Release contract amount to contractor
        escrow.releaseFunds(j.contractor, j.contractAmount, _jobId);
        // Refund both fees (no dispute = free for both parties)
        escrow.releaseFunds(j.client, j.feeAmount, _jobId);
        escrow.releaseFunds(j.contractor, j.feeAmount, _jobId);
    }

    /**
     * @notice Either party raises a dispute (fees already deposited)
     * @param _jobId Job identifier
     */
    function raiseDispute(uint256 _jobId) external {
        Job storage j = jobs[_jobId];
        require(msg.sender == j.client || msg.sender == j.contractor, "Not party");
        require(j.state == JobState.Active, "Not active");

        j.state = JobState.DisputeRaised;
        
        emit DisputeRaised(_jobId, msg.sender);
    }

    /**
     * @notice AI agent submits verdict (Layer 1 resolution)
     * @param _jobId Job identifier
     * @param _contractorPercent Percentage of contract going to contractor (0-100)
     * @param _explanation AI's reasoning
     */
    function submitAIVerdict(
        uint256 _jobId, 
        uint256 _contractorPercent, 
        string calldata _explanation
    ) external onlyRole(AI_AGENT_ROLE) {
        Job storage j = jobs[_jobId];
        require(j.state == JobState.DisputeRaised, "Not disputed");
        require(_contractorPercent <= 100, "Invalid percentage");

        j.aiContractorPercent = _contractorPercent;
        j.aiExplanation = _explanation;
        j.aiVerdictTimestamp = block.timestamp;
        j.aiAcceptanceDeadline = block.timestamp + 72 hours;
        j.state = JobState.AIResolved;

        emit AIVerdictIssued(_jobId, _contractorPercent, _explanation);
    }

    /**
     * @notice Party accepts AI verdict
     * @param _jobId Job identifier
     */
    function acceptAIVerdict(uint256 _jobId) external {
        Job storage j = jobs[_jobId];
        require(j.state == JobState.AIResolved, "Not in AI resolution");
        require(msg.sender == j.client || msg.sender == j.contractor, "Not party");
        require(block.timestamp <= j.aiAcceptanceDeadline, "Acceptance deadline passed");

        if (msg.sender == j.client) {
            j.clientAcceptedAI = true;
        } else {
            j.contractorAcceptedAI = true;
        }

        emit AIVerdictAccepted(_jobId, msg.sender);

        // If BOTH parties accept, execute AI verdict with FULL fee refunds
        if (j.clientAcceptedAI && j.contractorAcceptedAI) {
            _executeAIVerdict(_jobId);
        }
    }

    /**
     * @notice Party rejects AI verdict - escalates to DAO
     * @param _jobId Job identifier
     */
    function rejectAIVerdict(uint256 _jobId) external {
        Job storage j = jobs[_jobId];
        require(j.state == JobState.AIResolved, "Not in AI resolution");
        require(msg.sender == j.client || msg.sender == j.contractor, "Not party");

        emit AIVerdictRejected(_jobId, msg.sender);
        
        _escalateToDAO(_jobId);
    }

    /**
     * @notice Auto-escalate to DAO if acceptance deadline passes without both accepting
     * @param _jobId Job identifier
     */
    function checkAIDeadline(uint256 _jobId) external {
        Job storage j = jobs[_jobId];
        require(j.state == JobState.AIResolved, "Not in AI resolution");
        require(block.timestamp > j.aiAcceptanceDeadline, "Deadline not passed");

        // If not both accepted by deadline, escalate to DAO
        if (!j.clientAcceptedAI || !j.contractorAcceptedAI) {
            _escalateToDAO(_jobId);
        }
    }

    /**
     * @dev Internal function to execute AI verdict (both parties accepted)
     * AI resolution is FREE - both parties get 100% fee refunds
     */
    function _executeAIVerdict(uint256 _jobId) internal {
        Job storage j = jobs[_jobId];
        
        j.state = JobState.Resolved;
        
        uint256 contractorAmount = (j.contractAmount * j.aiContractorPercent) / 100;
        uint256 clientAmount = j.contractAmount - contractorAmount;

        emit DisputeResolved(_jobId, j.aiContractorPercent);

        // Pay contract amounts
        if (contractorAmount > 0) {
            escrow.releaseFunds(j.contractor, contractorAmount, _jobId);
        }
        if (clientAmount > 0) {
            escrow.releaseFunds(j.client, clientAmount, _jobId);
        }

        // FULL fee refunds (AI resolution is free!)
        escrow.releaseFunds(j.client, j.feeAmount, _jobId);
        escrow.releaseFunds(j.contractor, j.feeAmount, _jobId);
    }

    /**
     * @dev Internal function to escalate to DAO
     */
    function _escalateToDAO(uint256 _jobId) internal {
        Job storage j = jobs[_jobId];
        j.state = JobState.DAOEscalated;
        
        emit EscalatedToDAO(_jobId);
    }

    /**
     * @notice Called by DAO contract after voting completes
     * @param _jobId Job identifier
     * @param _contractorPercent Final verdict percentage to contractor
     */
    function resolveFromDAO(uint256 _jobId, uint256 _contractorPercent) external {
        require(msg.sender == daoContract, "Only DAO contract");
        Job storage j = jobs[_jobId];
        require(j.state == JobState.DAOEscalated, "Not escalated");
        require(_contractorPercent <= 100, "Invalid percentage");

        j.state = JobState.Resolved;
        
        uint256 contractorAmount = (j.contractAmount * _contractorPercent) / 100;
        uint256 clientAmount = j.contractAmount - contractorAmount;

        emit DisputeResolved(_jobId, _contractorPercent);

        // Pay contract amounts
        if (contractorAmount > 0) {
            escrow.releaseFunds(j.contractor, contractorAmount, _jobId);
        }
        if (clientAmount > 0) {
            escrow.releaseFunds(j.client, clientAmount, _jobId);
        }

        // Fee distribution handled by DAO contract (proportional reversed logic)
    }
}
