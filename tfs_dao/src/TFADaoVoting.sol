// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { TFAEscrow } from "./TFAEscrow.sol";
import { TFADispute } from "./TFADispute.sol";

/**
 * @title TFADAOVoting
 * @notice Complete DAO voting system (Layer 2) with karma-based weighted voting
 * @dev Implements:
 *      - Karma system (100 start, 20-200 range)
 *      - Weighted median consensus calculation
 *      - MAD-based outlier detection
 *      - Quadratic karma penalties
 *      - Proportional fee refunds (reversed logic)
 */
contract TFADAOVoting is AccessControl {
    
    bytes32 public constant VOTER_ROLE = keccak256("VOTER_ROLE");

    // Karma constants
    uint256 public constant STARTING_KARMA = 100;
    uint256 public constant MIN_KARMA = 20;
    uint256 public constant MAX_KARMA = 200;
    
    // Outlier detection constants
    uint256 public constant MAD_MULTIPLIER = 3;
    uint256 public constant MIN_DEVIATION_THRESHOLD = 15; // 15% minimum threshold
    
    // Karma rewards/penalties
    uint256 public constant EXCELLENT_REWARD = 3;    // Within ±5%
    uint256 public constant GOOD_REWARD = 1;         // Within ±10%
    uint256 public constant MAX_KARMA_LOSS = 30;     // Cap on penalty per vote

    struct Vote {
        address voter;
        uint256 contractorPercent;  // 0-100
        uint256 karma;              // Voter's karma at time of vote
        bool isOutlier;
        uint256 deviation;          // Distance from consensus
    }

    struct VotingSession {
        uint256 jobId;
        bool isActive;
        uint256 startTime;
        uint256 endTime;
        uint256 totalVotes;
        mapping(address => bool) hasVoted;
        mapping(uint256 => Vote) votes; // index => Vote
        
        // Results
        bool isFinalized;
        uint256 consensusPercent;
        uint256 mad;                // Median Absolute Deviation
        uint256 outlierThreshold;
    }

    TFAEscrow public escrow;
    TFADispute public disputeContract;
    
    mapping(address => uint256) public voterKarma;
    mapping(uint256 => VotingSession) public votingSessions; // jobId => session
    
    uint256 public votingDuration = 5 days;
    uint256 public minVotersRequired = 3;

    event VotingSessionStarted(uint256 indexed jobId, uint256 endTime);
    event VoteCast(uint256 indexed jobId, address indexed voter, uint256 contractorPercent, uint256 karma);
    event VotingFinalized(uint256 indexed jobId, uint256 consensusPercent, uint256 mad);
    event OutlierIdentified(uint256 indexed jobId, address indexed voter, uint256 deviation);
    event KarmaUpdated(address indexed voter, uint256 oldKarma, uint256 newKarma);
    event FeesDistributed(uint256 indexed jobId, address indexed voter, uint256 amount);
    
    // Voter management events
    event VoterRegistered(address indexed voter, uint256 startingKarma);
    event VoterRemoved(address indexed voter, uint256 finalKarma);
    event VoterBanned(address indexed voter, uint256 finalKarma);
    event KarmaAdjustedByAdmin(address indexed voter, uint256 oldKarma, uint256 newKarma);

    constructor(
        address _escrowAddress,
        address _disputeAddress,
        address _admin
    ) {
        require(_escrowAddress != address(0), "Invalid escrow");
        require(_disputeAddress != address(0), "Invalid dispute");
        require(_admin != address(0), "Invalid admin");
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        
        escrow = TFAEscrow(_escrowAddress);
        disputeContract = TFADispute(_disputeAddress);
    }

    /**
     * @notice Register a new voter with starting karma (ADMIN ONLY)
     * @dev Only admins can add voters to maintain quality control
     * @param _voter Address to register as voter
     */
    function registerVoter(address _voter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_voter != address(0), "Invalid voter address");
        require(voterKarma[_voter] == 0, "Already registered");
        
        voterKarma[_voter] = STARTING_KARMA;
        _grantRole(VOTER_ROLE, _voter);
        
        emit VoterRegistered(_voter, STARTING_KARMA);
    }

    /**
     * @notice Remove a voter (ADMIN ONLY)
     * @dev Removes voting rights but keeps karma history
     * @param _voter Address to remove
     */
    function removeVoter(address _voter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(hasRole(VOTER_ROLE, _voter), "Not a voter");
        
        _revokeRole(VOTER_ROLE, _voter);
        
        emit VoterRemoved(_voter, voterKarma[_voter]);
    }

    /**
     * @notice Completely ban a voter and reset their karma (ADMIN ONLY)
     * @dev Use this for malicious voters - removes role AND resets karma
     * @param _voter Address to ban
     */
    function banVoter(address _voter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(hasRole(VOTER_ROLE, _voter), "Not a voter");
        
        uint256 oldKarma = voterKarma[_voter];
        voterKarma[_voter] = 0; // Reset karma to 0 (can't re-register easily)
        _revokeRole(VOTER_ROLE, _voter);
        
        emit VoterBanned(_voter, oldKarma);
    }

    /**
     * @notice Manually adjust voter karma (ADMIN ONLY - emergency use)
     * @dev Use sparingly, system should self-regulate via voting
     * @param _voter Address of voter
     * @param _newKarma New karma value (must be within bounds)
     */
    function adjustVoterKarma(
        address _voter, 
        uint256 _newKarma
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(hasRole(VOTER_ROLE, _voter), "Not a voter");
        require(_newKarma >= MIN_KARMA && _newKarma <= MAX_KARMA, "Karma out of bounds");
        
        uint256 oldKarma = voterKarma[_voter];
        voterKarma[_voter] = _newKarma;
        
        emit KarmaAdjustedByAdmin(_voter, oldKarma, _newKarma);
    }

    /**
     * @notice Start a voting session for a disputed job
     * @param _jobId Job identifier from TFADispute
     */
    function startVoting(uint256 _jobId) external {
        VotingSession storage session = votingSessions[_jobId];
        require(!session.isActive, "Already active");
        require(!session.isFinalized, "Already finalized");

        // Verify job is in DAOEscalated state
        (,,,,,TFADispute.JobState state,,,,,,) = disputeContract.jobs(_jobId);
        require(state == TFADispute.JobState.DAOEscalated, "Not escalated to DAO");

        session.jobId = _jobId;
        session.isActive = true;
        session.startTime = block.timestamp;
        session.endTime = block.timestamp + votingDuration;
        session.totalVotes = 0;
        session.isFinalized = false;

        emit VotingSessionStarted(_jobId, session.endTime);
    }

    /**
     * @notice Cast a vote on a job dispute
     * @param _jobId Job identifier
     * @param _contractorPercent Voter's verdict: % of contract to contractor (0-100)
     */
    function castVote(uint256 _jobId, uint256 _contractorPercent) external onlyRole(VOTER_ROLE) {
        VotingSession storage session = votingSessions[_jobId];
        require(session.isActive, "Voting not active");
        require(block.timestamp <= session.endTime, "Voting ended");
        require(!session.hasVoted[msg.sender], "Already voted");
        require(_contractorPercent <= 100, "Invalid percentage");
        require(voterKarma[msg.sender] >= MIN_KARMA, "Insufficient karma");
        require(hasRole(VOTER_ROLE, msg.sender), "Voter role revoked"); // Extra check

        uint256 voterCurrentKarma = voterKarma[msg.sender];
        
        session.votes[session.totalVotes] = Vote({
            voter: msg.sender,
            contractorPercent: _contractorPercent,
            karma: voterCurrentKarma,
            isOutlier: false,
            deviation: 0
        });
        
        session.hasVoted[msg.sender] = true;
        session.totalVotes++;

        emit VoteCast(_jobId, msg.sender, _contractorPercent, voterCurrentKarma);
    }

    /**
     * @notice Finalize voting and calculate results
     * @param _jobId Job identifier
     */
    function finalizeVoting(uint256 _jobId) external {
        VotingSession storage session = votingSessions[_jobId];
        require(session.isActive, "Not active");
        require(block.timestamp > session.endTime, "Voting still ongoing");
        require(!session.isFinalized, "Already finalized");
        require(session.totalVotes >= minVotersRequired, "Not enough votes");

        // Step 1: Calculate weighted median (consensus)
        session.consensusPercent = _calculateWeightedMedian(session);
        
        // Step 2: Calculate MAD (Median Absolute Deviation)
        session.mad = _calculateMAD(session);
        
        // Step 3: Determine outlier threshold
        session.outlierThreshold = _max(
            session.mad * MAD_MULTIPLIER,
            MIN_DEVIATION_THRESHOLD
        );
        
        // Step 4: Identify outliers and calculate deviations
        _identifyOutliers(session);
        
        // Step 5: Update karma for all voters
        _updateKarmaScores(session);
        
        // Step 6: Distribute fees (proportional reversed logic)
        _distributeFees(session);
        
        // Step 7: Notify dispute contract of final verdict
        session.isActive = false;
        session.isFinalized = true;

        emit VotingFinalized(_jobId, session.consensusPercent, session.mad);

        // Tell dispute contract the final verdict
        disputeContract.resolveFromDAO(_jobId, session.consensusPercent);
    }

    /**
     * @dev Calculate weighted median of all votes
     * The vote where cumulative karma crosses 50% is the consensus
     */
    function _calculateWeightedMedian(VotingSession storage session) internal view returns (uint256) {
        uint256 totalVotes = session.totalVotes;
        require(totalVotes > 0, "No votes");

        // Create temporary array for sorting
        uint256[] memory percentages = new uint256[](totalVotes);
        uint256[] memory karmas = new uint256[](totalVotes);
        
        for (uint256 i = 0; i < totalVotes; i++) {
            percentages[i] = session.votes[i].contractorPercent;
            karmas[i] = session.votes[i].karma;
        }

        // Sort by percentage (bubble sort - fine for small N)
        for (uint256 i = 0; i < totalVotes; i++) {
            for (uint256 j = i + 1; j < totalVotes; j++) {
                if (percentages[i] > percentages[j]) {
                    // Swap percentages
                    (percentages[i], percentages[j]) = (percentages[j], percentages[i]);
                    // Swap corresponding karmas
                    (karmas[i], karmas[j]) = (karmas[j], karmas[i]);
                }
            }
        }

        // Calculate total karma
        uint256 totalKarma = 0;
        for (uint256 i = 0; i < totalVotes; i++) {
            totalKarma += karmas[i];
        }

        // Find weighted median (where cumulative karma crosses 50%)
        uint256 halfKarma = totalKarma / 2;
        uint256 cumulativeKarma = 0;
        
        for (uint256 i = 0; i < totalVotes; i++) {
            cumulativeKarma += karmas[i];
            if (cumulativeKarma >= halfKarma) {
                return percentages[i];
            }
        }

        // Fallback (shouldn't reach here)
        return percentages[totalVotes / 2];
    }

    /**
     * @dev Calculate Median Absolute Deviation (MAD)
     * MAD = median of |vote - consensus|
     */
    function _calculateMAD(VotingSession storage session) internal view returns (uint256) {
        uint256 totalVotes = session.totalVotes;
        uint256 consensus = session.consensusPercent;
        
        uint256[] memory deviations = new uint256[](totalVotes);
        
        for (uint256 i = 0; i < totalVotes; i++) {
            uint256 votePercent = session.votes[i].contractorPercent;
            deviations[i] = _abs(int256(votePercent) - int256(consensus));
        }

        // Sort deviations
        for (uint256 i = 0; i < totalVotes; i++) {
            for (uint256 j = i + 1; j < totalVotes; j++) {
                if (deviations[i] > deviations[j]) {
                    (deviations[i], deviations[j]) = (deviations[j], deviations[i]);
                }
            }
        }

        // Return median
        return deviations[totalVotes / 2];
    }

    /**
     * @dev Identify outliers based on deviation from consensus
     */
    function _identifyOutliers(VotingSession storage session) internal {
        uint256 consensus = session.consensusPercent;
        uint256 threshold = session.outlierThreshold;
        
        for (uint256 i = 0; i < session.totalVotes; i++) {
            Vote storage vote = session.votes[i];
            uint256 deviation = _abs(int256(vote.contractorPercent) - int256(consensus));
            vote.deviation = deviation;
            
            if (deviation > threshold) {
                vote.isOutlier = true;
                emit OutlierIdentified(session.jobId, vote.voter, deviation);
            }
        }
    }

    /**
     * @dev Update karma scores based on vote quality
     */
    function _updateKarmaScores(VotingSession storage session) internal {
        for (uint256 i = 0; i < session.totalVotes; i++) {
            Vote storage vote = session.votes[i];
            address voter = vote.voter;
            uint256 oldKarma = voterKarma[voter];
            uint256 newKarma = oldKarma;
            
            if (vote.isOutlier) {
                // Quadratic penalty: deviation^2 / 100, capped at MAX_KARMA_LOSS
                uint256 penalty = (vote.deviation * vote.deviation) / 100;
                if (penalty > MAX_KARMA_LOSS) penalty = MAX_KARMA_LOSS;
                
                if (newKarma > penalty + MIN_KARMA) {
                    newKarma -= penalty;
                } else {
                    newKarma = MIN_KARMA;
                }
            } else {
                // Reward based on accuracy
                if (vote.deviation <= 5) {
                    // Excellent: within ±5%
                    newKarma += EXCELLENT_REWARD;
                } else if (vote.deviation <= 10) {
                    // Good: within ±10%
                    newKarma += GOOD_REWARD;
                }
                // Within ±15%: no change (neutral)
                
                // Apply redemption boost if below starting karma
                if (oldKarma < STARTING_KARMA && newKarma > oldKarma) {
                    uint256 bonus = newKarma - oldKarma;
                    newKarma = oldKarma + (bonus * 2); // 2x gains
                }
                
                // Cap at MAX_KARMA
                if (newKarma > MAX_KARMA) newKarma = MAX_KARMA;
            }
            
            if (newKarma != oldKarma) {
                voterKarma[voter] = newKarma;
                emit KarmaUpdated(voter, oldKarma, newKarma);
            }
        }
    }

    /**
     * @dev Distribute fees using proportional reversed logic
     * Winner gets more fee refund, loser's fee goes to voters
     */
    function _distributeFees(VotingSession storage session) internal {
        (
            ,                   // 1. id
            address client,     // 2. client
            address contractor, // 3. contractor
            ,                   // 4. contractAmount
            uint256 feeAmount,  // 5. feeAmount
            ,                   // 6. state
            ,                   // 7. aiContractorPercent
            ,                   // 8. aiExplanation
            ,                   // 9. aiVerdictTimestamp
            ,                   // 10. clientAcceptedAI
            ,                   // 11. contractorAcceptedAI
                                // 12. aiAcceptanceDeadline (Implicitly ignored)
        ) = disputeContract.jobs(session.jobId);

        uint256 contractorPercent = session.consensusPercent;
        uint256 clientPercent = 100 - contractorPercent;

        // REVERSED FEE LOGIC:
        // Contractor wins 80% → gets 80% of fee back, loses 20%
        // Client loses 80% → loses 80% of fee, gets 20% back
        
        uint256 contractorFeeRefund = (feeAmount * contractorPercent) / 100;
        uint256 clientFeeRefund = (feeAmount * clientPercent) / 100;
        
        uint256 contractorFeeToVoters = feeAmount - contractorFeeRefund;
        uint256 clientFeeToVoters = feeAmount - clientFeeRefund;
        uint256 totalVoterPool = contractorFeeToVoters + clientFeeToVoters;

        // Refund proportional fees to parties
        if (contractorFeeRefund > 0) {
            escrow.releaseFunds(contractor, contractorFeeRefund, session.jobId);
        }
        if (clientFeeRefund > 0) {
            escrow.releaseFunds(client, clientFeeRefund, session.jobId);
        }

        // Distribute to voters (excluding outliers, weighted by karma)
        _distributeToVoters(session, totalVoterPool);
    }

    /**
     * @dev Distribute voter pool among valid voters weighted by karma
     */
    function _distributeToVoters(VotingSession storage session, uint256 totalPool) internal {
        if (totalPool == 0) return;

        // Calculate total karma of non-outlier voters
        uint256 totalValidKarma = 0;
        for (uint256 i = 0; i < session.totalVotes; i++) {
            Vote storage vote = session.votes[i];
            if (!vote.isOutlier) {
                totalValidKarma += vote.karma;
            }
        }

        require(totalValidKarma > 0, "No valid voters");

        // Distribute proportionally
        for (uint256 i = 0; i < session.totalVotes; i++) {
            Vote storage vote = session.votes[i];
            
            if (!vote.isOutlier) {
                uint256 voterShare = (totalPool * vote.karma) / totalValidKarma;
                
                if (voterShare > 0) {
                    escrow.releaseFunds(vote.voter, voterShare, session.jobId);
                    emit FeesDistributed(session.jobId, vote.voter, voterShare);
                }
            }
            // Outliers get 0
        }
    }

    // Helper functions
    function _abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }

    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    // View functions for frontend
    function getVoterKarma(address _voter) external view returns (uint256) {
        return voterKarma[_voter];
    }

    function isActiveVoter(address _voter) external view returns (bool) {
        return hasRole(VOTER_ROLE, _voter) && voterKarma[_voter] >= MIN_KARMA;
    }

    function getVoterInfo(address _voter) external view returns (
        bool isVoter,
        uint256 karma,
        bool canVote
    ) {
        isVoter = hasRole(VOTER_ROLE, _voter);
        karma = voterKarma[_voter];
        canVote = isVoter && karma >= MIN_KARMA;
    }

    function getVote(uint256 _jobId, uint256 _voteIndex) external view returns (
        address voter,
        uint256 contractorPercent,
        uint256 karma,
        bool isOutlier,
        uint256 deviation
    ) {
        Vote storage vote = votingSessions[_jobId].votes[_voteIndex];
        return (
            vote.voter,
            vote.contractorPercent,
            vote.karma,
            vote.isOutlier,
            vote.deviation
        );
    }

    function getSessionInfo(uint256 _jobId) external view returns (
        bool isActive,
        uint256 endTime,
        uint256 totalVotes,
        bool isFinalized,
        uint256 consensusPercent
    ) {
        VotingSession storage session = votingSessions[_jobId];
        return (
            session.isActive,
            session.endTime,
            session.totalVotes,
            session.isFinalized,
            session.consensusPercent
        );
    }
}
