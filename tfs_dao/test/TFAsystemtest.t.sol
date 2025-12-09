// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { TFADispute } from "../src/TFADispute.sol";
import { TFAEscrow } from "../src/TFAEscrow.sol";
import { TFADAOVoting } from "../src/TFADaoVoting.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock USDC for testing
contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {
        _mint(msg.sender, 1000000 * 10**6); // 1M USDC with 6 decimals
    }
    
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract TFASystemTest is Test {
    TFADispute public disputeContract;
    TFAEscrow public escrow;
    TFADAOVoting public daoVoting;
    MockUSDC public usdc;

    address admin = address(1);
    address aiAgent = address(2);
    address client = address(3);
    address contractor = address(4);
    
    // DAO Voters
    address voter1 = address(10);
    address voter2 = address(11);
    address voter3 = address(12);
    address voter4 = address(13);
    address voter5 = address(14);

    function setUp() public {
        vm.startPrank(admin);
        
        // Deploy contracts
        usdc = new MockUSDC();
        escrow = new TFAEscrow(address(usdc), admin);
        disputeContract = new TFADispute(address(escrow), admin);
        daoVoting = new TFADAOVoting(address(escrow), address(disputeContract), admin);

        // Connect contracts
        escrow.setDisputeContract(address(disputeContract));
        escrow.setDAOContract(address(daoVoting));
        disputeContract.setDAOContract(address(daoVoting));
        
        // Grant roles
        disputeContract.grantRole(disputeContract.AI_AGENT_ROLE(), aiAgent);
        
        // Register DAO voters
        daoVoting.registerVoter(voter1);
        daoVoting.registerVoter(voter2);
        daoVoting.registerVoter(voter3);
        daoVoting.registerVoter(voter4);
        daoVoting.registerVoter(voter5);

        // Fund participants (USDC has 6 decimals)
        usdc.transfer(client, 100000 * 10**6); // 100k USDC
        usdc.transfer(contractor, 10000 * 10**6); // 10k USDC
        
        vm.stopPrank();
    }

    // Helper function to create job with both fees deposited
    function createJobWithFees(uint256 contractAmount) internal returns (uint256 feeAmount) {
        feeAmount = (contractAmount * 5) / 100; // 5%
        
        // Both parties approve
        vm.prank(client);
        usdc.approve(address(escrow), contractAmount + feeAmount);
        
        vm.prank(contractor);
        usdc.approve(address(escrow), feeAmount);
        
        // Client creates job
        vm.prank(client);
        disputeContract.createJob(contractor, contractAmount);
    }

    // ==================== TEST 1: Happy Path (No Dispute) ====================
    function testHappyPath() public {
        uint256 contractAmount = 1000 * 10**6; // 1000 USDC
        uint256 feeAmount = createJobWithFees(contractAmount);

        // Check balances - both fees deposited
        assertEq(usdc.balanceOf(address(escrow)), contractAmount + (2 * feeAmount));
        assertEq(usdc.balanceOf(client), 99000 * 10**6 - feeAmount);
        assertEq(usdc.balanceOf(contractor), 10000 * 10**6 - feeAmount);

        // Client releases to contractor (no dispute)
        vm.prank(client);
        disputeContract.releaseToContractor(0);

        // Verify final balances - both get fee refunds
        assertEq(usdc.balanceOf(contractor), 10000 * 10**6 + contractAmount);
        assertEq(usdc.balanceOf(client), 99000 * 10**6);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    // ==================== TEST 2: AI Resolution Accepted ====================
    function testAIResolutionAccepted() public {
        uint256 contractAmount = 1000 * 10**6;
        uint256 feeAmount = createJobWithFees(contractAmount);

        // Raise dispute
        vm.prank(client);
        disputeContract.raiseDispute(0);

        // AI submits verdict: 70% to contractor
        vm.prank(aiAgent);
        disputeContract.submitAIVerdict(0, 70, "Work 70% complete");

        // Both parties accept
        vm.prank(client);
        disputeContract.acceptAIVerdict(0);
        
        vm.prank(contractor);
        disputeContract.acceptAIVerdict(0);

        // Check final balances: AI verdict executed with FULL fee refunds
        assertEq(usdc.balanceOf(contractor), 10000 * 10**6 + 700 * 10**6); // 70% + fee refund
        assertEq(usdc.balanceOf(client), 99000 * 10**6 + 300 * 10**6); // 30% + fee refund
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    // ==================== TEST 3: Full DAO Resolution ====================
    function testFullDAOResolution() public {
        uint256 contractAmount = 1000 * 10**6;
        uint256 feeAmount = createJobWithFees(contractAmount);

        // Raise dispute
        vm.prank(contractor);
        disputeContract.raiseDispute(0);

        // AI submits verdict
        vm.prank(aiAgent);
        disputeContract.submitAIVerdict(0, 70, "Test");

        // Client rejects -> escalates to DAO
        vm.prank(client);
        disputeContract.rejectAIVerdict(0);

        // DAO voting starts
        daoVoting.startVoting(0);

        // Voters cast votes
        vm.prank(voter1);
        daoVoting.castVote(0, 75);
        
        vm.prank(voter2);
        daoVoting.castVote(0, 80);
        
        vm.prank(voter3);
        daoVoting.castVote(0, 78);
        
        vm.prank(voter4);
        daoVoting.castVote(0, 82);
        
        vm.prank(voter5);
        daoVoting.castVote(0, 20); // Outlier

        // Fast forward 6 days
        vm.warp(block.timestamp + 6 days);

        // Finalize voting
        daoVoting.finalizeVoting(0);

        // Check DAO executed the resolution
        // Weighted median should be around 78%
        assertGt(usdc.balanceOf(contractor), 10000 * 10**6); // Got some money
        assertGt(usdc.balanceOf(client), 99000 * 10**6 - 1000 * 10**6); // Got some back
    }

    // ==================== TEST 4: Proportional Fee Distribution ====================
    function testProportionalFeeDistribution() public {
        uint256 contractAmount = 1000 * 10**6;
        uint256 feeAmount = createJobWithFees(contractAmount);

        vm.prank(contractor);
        disputeContract.raiseDispute(0);

        vm.prank(aiAgent);
        disputeContract.submitAIVerdict(0, 70, "Test");

        vm.prank(client);
        disputeContract.rejectAIVerdict(0);

        daoVoting.startVoting(0);

        // Cast votes
        vm.prank(voter1);
        daoVoting.castVote(0, 78);
        
        vm.prank(voter2);
        daoVoting.castVote(0, 80);
        
        vm.prank(voter3);
        daoVoting.castVote(0, 76);

        vm.warp(block.timestamp + 6 days);
        daoVoting.finalizeVoting(0);

        // Verify proportional fees distributed
        // If consensus ~78%, contractor gets ~78% fee refund, client gets ~22%
        uint256 contractorFinal = usdc.balanceOf(contractor);
        uint256 clientFinal = usdc.balanceOf(client);
        
        // Contractor should get: ~780 USDC (78% of contract) + ~39 USDC (78% of fee) - some to voters
        // Client should get: ~220 USDC (22% of contract) + ~11 USDC (22% of fee) - some to voters
        
        assertGt(contractorFinal, 10000 * 10**6 + 750 * 10**6); // At least 75%
        assertLt(contractorFinal, 10000 * 10**6 + 850 * 10**6); // At most 85%
    }

    // ==================== TEST 5: Karma System ====================
    function testKarmaSystem() public {
        uint256 contractAmount = 1000 * 10**6;
        createJobWithFees(contractAmount);

        vm.prank(contractor);
        disputeContract.raiseDispute(0);

        vm.prank(aiAgent);
        disputeContract.submitAIVerdict(0, 70, "Test");

        vm.prank(client);
        disputeContract.rejectAIVerdict(0);

        daoVoting.startVoting(0);

        // voter1 votes accurately (70)
        vm.prank(voter1);
        daoVoting.castVote(0, 70);
        
        // voter2 votes way off (outlier)
        vm.prank(voter2);
        daoVoting.castVote(0, 10);
        
        // voter3 votes close
        vm.prank(voter3);
        daoVoting.castVote(0, 72);

        vm.warp(block.timestamp + 6 days);
        daoVoting.finalizeVoting(0);

        // Check karma updates
        uint256 voter1Karma = daoVoting.getVoterKarma(voter1);
        uint256 voter2Karma = daoVoting.getVoterKarma(voter2);
        uint256 voter3Karma = daoVoting.getVoterKarma(voter3);

        // voter1 should have gained karma (accurate vote)
        assertGt(voter1Karma, 100);
        
        // voter2 should have lost karma (outlier)
        assertLt(voter2Karma, 100);
        
        // voter3 should have gained some karma (close vote)
        assertGt(voter3Karma, 100);
    }

    // ==================== TEST 6: Multiple Disputes (Karma Accumulation) ====================
    function testMultipleDisputes() public {
        for (uint256 i = 0; i < 3; i++) {
            uint256 contractAmount = 1000 * 10**6;
            createJobWithFees(contractAmount);

            vm.prank(contractor);
            disputeContract.raiseDispute(i);

            vm.prank(aiAgent);
            disputeContract.submitAIVerdict(i, 70, "Test");

            vm.prank(client);
            disputeContract.rejectAIVerdict(i);

            daoVoting.startVoting(i);
            
            // voter1 always accurate
            vm.prank(voter1);
            daoVoting.castVote(i, 70);
            
            // voter2 always way off
            vm.prank(voter2);
            daoVoting.castVote(i, 10);
            
            vm.prank(voter3);
            daoVoting.castVote(i, 72);

            vm.warp(block.timestamp + 6 days);
            daoVoting.finalizeVoting(i);
            
            vm.warp(block.timestamp + 1 days); // Space out disputes
        }

        // After 3 disputes, voter1 should have high karma, voter2 very low
        uint256 voter1Karma = daoVoting.getVoterKarma(voter1);
        uint256 voter2Karma = daoVoting.getVoterKarma(voter2);

        assertGt(voter1Karma, 105); // Multiple rewards
        assertLt(voter2Karma, 50);  // Multiple penalties
    }

    // ==================== TEST 7: Voter Management ====================
    function testVoterManagement() public {
        address newVoter = address(20);
        
        // Admin registers new voter
        vm.prank(admin);
        daoVoting.registerVoter(newVoter);
        
        // Check voter registered
        assertEq(daoVoting.getVoterKarma(newVoter), 100);
        (bool isVoter, uint256 karma, bool canVote) = daoVoting.getVoterInfo(newVoter);
        assertTrue(isVoter);
        assertEq(karma, 100);
        assertTrue(canVote);
        
        // Remove voter
        vm.prank(admin);
        daoVoting.removeVoter(newVoter);
        
        // Check voter removed (can't vote but karma preserved)
        (isVoter, karma, canVote) = daoVoting.getVoterInfo(newVoter);
        assertFalse(isVoter);
        assertEq(karma, 100); // Karma still there
        assertFalse(canVote);
    }

    // ==================== TEST 8: Ban Voter ====================
    function testBanVoter() public {
        // Give voter2 some voting history first
        uint256 contractAmount = 1000 * 10**6;
        createJobWithFees(contractAmount);

        vm.prank(contractor);
        disputeContract.raiseDispute(0);

        vm.prank(aiAgent);
        disputeContract.submitAIVerdict(0, 70, "Test");

        vm.prank(client);
        disputeContract.rejectAIVerdict(0);

        daoVoting.startVoting(0);
        
        // FIX: We need at least 3 votes to finalize!
        vm.prank(voter1);
        daoVoting.castVote(0, 70);

        vm.prank(voter2);
        daoVoting.castVote(0, 70);

        vm.prank(voter3);
        daoVoting.castVote(0, 70);

        vm.warp(block.timestamp + 6 days);
        
        // Now this will succeed because we have 3 votes
        daoVoting.finalizeVoting(0);

        // Now ban voter2
        uint256 karmaBeforeBan = daoVoting.getVoterKarma(voter2);
        assertGt(karmaBeforeBan, 0); // Has some karma
        
        vm.prank(admin);
        daoVoting.banVoter(voter2);
        
        // Check voter banned (karma reset to 0)
        (bool isVoter, uint256 karma, bool canVote) = daoVoting.getVoterInfo(voter2);
        assertFalse(isVoter);
        assertEq(karma, 0); // Karma RESET!
        assertFalse(canVote);
    }
    // ==================== TEST 9: Cannot Register Twice ====================
    function testCannotRegisterTwice() public {
        address newVoter = address(21);
        
        vm.startPrank(admin);
        daoVoting.registerVoter(newVoter);
        
        // Try to register again - should fail
        vm.expectRevert("Already registered");
        daoVoting.registerVoter(newVoter);
        vm.stopPrank();
    }

    // ==================== TEST 10: Removed Voter Cannot Vote ====================
    function testRemovedVoterCannotVote() public {
        // Remove voter3
        vm.prank(admin);
        daoVoting.removeVoter(voter3);
        
        // Try to vote
        uint256 contractAmount = 1000 * 10**6;
        createJobWithFees(contractAmount);

        vm.prank(contractor);
        disputeContract.raiseDispute(0);

        vm.prank(aiAgent);
        disputeContract.submitAIVerdict(0, 70, "Test");

        vm.prank(client);
        disputeContract.rejectAIVerdict(0);

        daoVoting.startVoting(0);
        
        // voter3 tries to vote - should fail
        vm.prank(voter3);
        vm.expectRevert(); // Will fail on onlyRole(VOTER_ROLE)
        daoVoting.castVote(0, 70);
    }

    // ==================== TEST 11: Admin Karma Adjustment ====================
    function testAdminKarmaAdjustment() public {
        uint256 oldKarma = daoVoting.getVoterKarma(voter1);
        
        // Admin adjusts karma
        vm.prank(admin);
        daoVoting.adjustVoterKarma(voter1, 150);
        
        uint256 newKarma = daoVoting.getVoterKarma(voter1);
        assertEq(newKarma, 150);
        assertNotEq(newKarma, oldKarma);
    }

    // ==================== TEST 12: Both Parties Deposit Fees Upfront ====================
    function testBothPartiesDepositFeesUpfront() public {
        uint256 contractAmount = 1000 * 10**6;
        uint256 feeAmount = 50 * 10**6;
        
        uint256 clientBalBefore = usdc.balanceOf(client);
        uint256 contractorBalBefore = usdc.balanceOf(contractor);
        
        createJobWithFees(contractAmount);
        
        // Verify both fees were deposited
        assertEq(usdc.balanceOf(client), clientBalBefore - contractAmount - feeAmount);
        assertEq(usdc.balanceOf(contractor), contractorBalBefore - feeAmount);
        assertEq(usdc.balanceOf(address(escrow)), contractAmount + (2 * feeAmount));
    }
}
