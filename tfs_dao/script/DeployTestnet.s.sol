// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Script.sol";
import "../src/TFAEscrow.sol";
import "../src/TFADispute.sol";
import "../src/TFADaoVoting.sol";

contract DeployTestnet is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address admin = vm.addr(deployerPrivateKey);
        
        // Base Sepolia USDC Address
        address usdcAddress = 0x036CbD53842c5426634e7929541eC2318f3dCF7e; 

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy Escrow
        TFAEscrow escrow = new TFAEscrow(usdcAddress, admin);

        // Step 2: Deploy Dispute
        TFADispute dispute = new TFADispute(address(escrow), admin);

        // Step 3: Deploy DAO Voting
        TFADAOVoting dao = new TFADAOVoting(address(escrow), address(dispute), admin);

        // Step 4: Critical Cross-Linking
        escrow.setDisputeContract(address(dispute));
        escrow.setDAOContract(address(dao));
        dispute.setDAOContract(address(dao));

        // Step 5: Grant AI Agent Role (Optional but recommended now)
        // bytes32 AI_ROLE = keccak256("AI_AGENT_ROLE");
        // dispute.grantRole(AI_ROLE, <YOUR_BACKEND_WALLET_ADDRESS>);

        vm.stopBroadcast();
        
        console.log("SUCCESS: TFA System Deployed to Base Sepolia");
        console.log("Escrow:", address(escrow));
        console.log("Dispute:", address(dispute));
        console.log("DAO Voting:", address(dao));
    }
}