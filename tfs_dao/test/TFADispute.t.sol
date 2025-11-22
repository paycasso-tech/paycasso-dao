// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


import { Test } from "forge-std/Test.sol";
import { TFADispute } from "../src/TFADispute.sol";
import { TFAEscrow } from "../src/TFAEscrow.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";


// Mock USDC for testing
contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {
        _mint(msg.sender, 1000000 * 10**18);
    }
}

contract TFADisputeTest is Test {
    TFADispute disputeContract;
    TFAEscrow escrow;
    MockUSDC usdc;

    address admin = address(1);
    address aiAgent = address(2);
    address client = address(3);
    address contractor = address(4);

    function setUp() public {
        vm.startPrank(admin);
        usdc = new MockUSDC();
        escrow = new TFAEscrow(address(usdc), admin);
        disputeContract = new TFADispute(address(escrow), admin);

        escrow.setDisputeContract(address(disputeContract));
        disputeContract.grantRole(disputeContract.AI_AGENT_ROLE(), aiAgent);

        // FIX 1: Check return value to silence warning
        bool success = usdc.transfer(client, 1000 ether);
        require(success, "Setup transfer failed");
        
        vm.stopPrank();
    }

    // --- TEST 1: Happy Path (No Dispute) ---
    function testHappyPath() public {
        vm.startPrank(client);
        
        // FIX 1: Check return value for approve
        bool success = usdc.approve(address(escrow), 100 ether);
        require(success, "Approve failed");

        disputeContract.createJob(contractor, 100 ether);
        
        // ... Contractor does work off-chain ...
        
        // Client releases funds
        disputeContract.releaseToContractor(0); 
        vm.stopPrank();

        // Check balances
        assertEq(usdc.balanceOf(contractor), 100 ether);
        assertEq(usdc.balanceOf(client), 900 ether);
        
        // FIX 2: Correct number of commas (4 before, 3 after = 8 total fields)
        (,,,, TFADispute.JobState state,,,) = disputeContract.jobs(0);
        assertEq(uint(state), uint(TFADispute.JobState.Resolved));
    }

    // --- TEST 2: Dispute Path (AI Intervenes) ---
    function testDisputePath() public {
        vm.startPrank(client);
        
        // FIX 1: Check return value
        bool success = usdc.approve(address(escrow), 100 ether);
        require(success, "Approve failed");

        disputeContract.createJob(contractor, 100 ether);
        vm.stopPrank();

        // Contractor raises dispute
        vm.prank(contractor); 
        disputeContract.raiseDispute(0);

        // FIX 2: Correct number of commas
        (,,,, TFADispute.JobState state,,,) = disputeContract.jobs(0);
        assertEq(uint(state), uint(TFADispute.JobState.Disputed));

        // AI Agent resolves it (50/50 Split)
        vm.prank(aiAgent);
        disputeContract.resolveDispute(0, 50, "Partial work completed");

        // Check: Both get 50
        assertEq(usdc.balanceOf(client), 950 ether);
        assertEq(usdc.balanceOf(contractor), 50 ether);
    }
    
    // --- TEST 3: Security - Random person cannot raise dispute ---
    function testRandomCannotRaiseDispute() public {
        vm.startPrank(client);
        bool success = usdc.approve(address(escrow), 100 ether);
        require(success, "Approve failed");
        
        disputeContract.createJob(contractor, 100 ether);
        vm.stopPrank();

        vm.prank(address(99)); // Hacker
        
        // FIX: Match the exact string from TFADispute.sol ("Not party")
        vm.expectRevert("Not party"); 
        disputeContract.raiseDispute(0);
    }
}