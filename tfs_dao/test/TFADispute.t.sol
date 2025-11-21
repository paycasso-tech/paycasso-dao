// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TFADispute.sol";
import "../src/TFAEscrow.sol";

// Mock USDC for testing
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {
        _mint(msg.sender, 1000000 * 10**18);
    }
}

contract TFADisputeTest is Test {
    TFADispute dispute;
    TFAEscrow escrow;
    MockUSDC usdc;

    address admin = address(1);
    address aiAgent = address(2);
    address client = address(4);
    address contractor = address(5);

    function setUp() public {
        // 1. Deploy Mock USDC
        vm.startPrank(admin);
        usdc = new MockUSDC();
        
        // 2. Deploy Escrow & Dispute
        // CHANGE: Pass the MockUSDC address to the Escrow
        escrow = new TFAEscrow(address(usdc), admin);
        
        dispute = new TFADispute(address(escrow), admin);

        // 3. Setup Permissions & Links
        escrow.setDisputeContract(address(dispute));
        dispute.grantRole(dispute.AI_AGENT_ROLE(), aiAgent);

        // 4. Fund Client
        usdc.transfer(client, 1000 ether);
        vm.stopPrank();
    }

    function testStage1HappyPath() public {
        // --- STEP 1: Create Dispute ---
        vm.startPrank(client);
        usdc.approve(address(escrow), 100 ether); 
        dispute.createDispute(contractor, 100 ether);
        
        // Verify Escrow holds the money
        assertEq(usdc.balanceOf(address(escrow)), 100 ether);
        vm.stopPrank();
        
        // --- STEP 2: Submit Evidence ---
        vm.prank(contractor);
        dispute.submitEvidence(0, "QmChatHistoryHash");

        // --- STEP 3: AI Verdict ---
        vm.prank(aiAgent);
        // AI decides: 80% to Client, 20% to Contractor
        dispute.submitAiVerdict(0, 80, "QmReasonHash");

        // --- STEP 4: Wait Window (3 Days) ---
        // Try to finalize too early (should fail)
        vm.expectRevert("Review window still open");
        dispute.finalizeAiVerdict(0);

        // Warp time forward
        vm.warp(block.timestamp + 4 days);

        // --- STEP 5: Finalize ---
        dispute.finalizeAiVerdict(0);

        // --- CHECK RESULTS ---
        // Client should get 80
        assertEq(usdc.balanceOf(client), 980 ether); // Started with 1000, spent 100, got 80 back = 980
        // Contractor should get 20
        assertEq(usdc.balanceOf(contractor), 20 ether);
        // Escrow should be empty
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }
}