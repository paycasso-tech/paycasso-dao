// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./TFAEscrow.sol";

/**
 * @title TFADispute (Stage 1 Only)
 * @notice Manages AI-based dispute resolution.
 * @dev This version ONLY supports AI verdicts. Stage 2 (Human Appeal) is disabled.
 */
contract TFADispute is AccessControl {
    
    // ROLES
    bytes32 public constant AI_AGENT_ROLE = keccak256("AI_AGENT_ROLE");

    // STATE MACHINE
    enum DisputeState {
        Created,        // Funds deposited, waiting for evidence
        AI_Pending,     // Evidence uploaded, AI analyzing
        AI_Verdict,     // AI has spoken, waiting for time window
        Resolved        // Final payout executed
    }

    struct Dispute {
        uint256 id;
        address client;
        address contractor;
        uint256 totalAmount;
        string evidenceIpfsHash;
        DisputeState state;
        
        // Stage 1: AI Data
        uint256 aiClientSplit; // Percentage 0-100
        string aiExplanationIpfs;
        uint256 aiVerdictTimestamp;
    }

    TFAEscrow public escrow;
    uint256 public nextDisputeId;
    
    // Time window to allow parties to read the verdict before payout (e.g. 3 days)
    uint256 public constant REVIEW_WINDOW = 3 days;

    mapping(uint256 => Dispute) public disputes;

    // EVENTS
    event DisputeCreated(uint256 indexed id, address client, address contractor, uint256 amount);
    event EvidenceSubmitted(uint256 indexed id, string ipfsHash);
    event AiVerdictSubmitted(uint256 indexed id, uint256 clientSplit, string explanationHash);
    event DisputeResolved(uint256 indexed id, uint256 finalClientSplit, string authority);

    constructor(address _escrowAddress, address _admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        escrow = TFAEscrow(_escrowAddress);
    }

    // ------------------------------------------------------------------
    // 1. INITIALIZATION
    // ------------------------------------------------------------------

    /**
     * @notice Starts a dispute and locks funds.
     * @dev User must have approved the Escrow contract to spend their USDC.
     */
    function createDispute(address _contractor, uint256 _amount) external {
        uint256 disputeId = nextDisputeId++;
        
        disputes[disputeId] = Dispute({
            id: disputeId,
            client: msg.sender,
            contractor: _contractor,
            totalAmount: _amount,
            evidenceIpfsHash: "",
            state: DisputeState.Created,
            aiClientSplit: 0,
            aiExplanationIpfs: "",
            aiVerdictTimestamp: 0
        });

        // Lock funds in Escrow
        // CHANGE: Pass msg.sender (The Client) as the payer
        escrow.deposit(disputeId, msg.sender, _amount);

        emit DisputeCreated(disputeId, msg.sender, _contractor, _amount);
    }

    /**
     * @notice Uploads evidence hash. Can be called by Client or Contractor.
     * Moves state to AI_Pending.
     */
    function submitEvidence(uint256 _disputeId, string calldata _ipfsHash) external {
        Dispute storage d = disputes[_disputeId];
        require(msg.sender == d.client || msg.sender == d.contractor, "Not a party to dispute");
        require(d.state == DisputeState.Created, "Invalid state");

        d.evidenceIpfsHash = _ipfsHash;
        d.state = DisputeState.AI_Pending;

        emit EvidenceSubmitted(_disputeId, _ipfsHash);
    }

    // ------------------------------------------------------------------
    // 2. STAGE 1: AI VERDICT
    // ------------------------------------------------------------------

    /**
     * @notice AI Agent submits its analysis.
     */
    function submitAiVerdict(uint256 _disputeId, uint256 _clientSplit, string calldata _explanation) 
        external 
        onlyRole(AI_AGENT_ROLE) 
    {
        Dispute storage d = disputes[_disputeId];
        require(d.state == DisputeState.AI_Pending, "AI not required currently");
        require(_clientSplit <= 100, "Split must be 0-100");

        d.aiClientSplit = _clientSplit;
        d.aiExplanationIpfs = _explanation;
        d.aiVerdictTimestamp = block.timestamp;
        d.state = DisputeState.AI_Verdict;

        emit AiVerdictSubmitted(_disputeId, _clientSplit, _explanation);
    }

    /**
     * @notice Executes the AI verdict after the review window passes.
     */
    function finalizeAiVerdict(uint256 _disputeId) external {
        Dispute storage d = disputes[_disputeId];
        require(d.state == DisputeState.AI_Verdict, "Invalid state");
        require(block.timestamp >= d.aiVerdictTimestamp + REVIEW_WINDOW, "Review window still open");

        // Execute Payout based on AI's decision
        _executePayout(_disputeId, d.aiClientSplit, "AI_Final_Stage1");
    }

    // ------------------------------------------------------------------
    // INTERNAL LOGIC
    // ------------------------------------------------------------------

    function _executePayout(uint256 _disputeId, uint256 _clientSplit, string memory _authority) internal {
        Dispute storage d = disputes[_disputeId];
        require(d.state != DisputeState.Resolved, "Already resolved");

        uint256 clientAmount = (d.totalAmount * _clientSplit) / 100;
        uint256 contractorAmount = d.totalAmount - clientAmount;

        if (clientAmount > 0) {
            escrow.releaseFunds(d.client, clientAmount, _disputeId);
        }
        if (contractorAmount > 0) {
            escrow.releaseFunds(d.contractor, contractorAmount, _disputeId);
        }

        d.state = DisputeState.Resolved;
        emit DisputeResolved(_disputeId, _clientSplit, _authority);
    }
}