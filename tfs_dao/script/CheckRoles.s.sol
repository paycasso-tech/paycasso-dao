// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Script.sol";
import "../src/TFADispute.sol";

contract CheckRoles is Script {
    function run() external {
        uint256 adminPrivateKey = vm.envUint("PRIVATE_KEY");
        address admin = vm.addr(adminPrivateKey);
        
        uint256 aiPrivateKey = vm.envUint("AI_WALLET_PRIVATE_KEY");
        address aiWallet = vm.addr(aiPrivateKey);
        
        address disputeAddress = 0x75e8bcB81EAC942B27545e50F1516FcD7357BB87; // New Dispute Address
        TFADispute dispute = TFADispute(disputeAddress);
        
        bytes32 DEFAULT_ADMIN_ROLE = 0x00;
        bytes32 AI_AGENT_ROLE = keccak256("AI_AGENT_ROLE");

        console.log("Checking Roles for New Dispute Contract:", disputeAddress);
        console.log("---------------------------------------------------");
        
        bool isAdmin = dispute.hasRole(DEFAULT_ADMIN_ROLE, admin);
        console.log("Admin Address:", admin);
        console.log("Has DEFAULT_ADMIN_ROLE:", isAdmin);
        
        bool isAi = dispute.hasRole(AI_AGENT_ROLE, aiWallet);
        console.log("AI Wallet Address:", aiWallet);
        console.log("Has AI_AGENT_ROLE:", isAi);
        
        if (!isAi) {
            console.log("---------------------------------------------------");
            console.log("AI_AGENT_ROLE is MISSING! Attempting to grant it now...");
            vm.startBroadcast(adminPrivateKey);
            dispute.grantRole(AI_AGENT_ROLE, aiWallet);
            vm.stopBroadcast();
            console.log("Role Granted. Re-checking...");
            console.log("Has AI_AGENT_ROLE:", dispute.hasRole(AI_AGENT_ROLE, aiWallet));
        }
    }
}
