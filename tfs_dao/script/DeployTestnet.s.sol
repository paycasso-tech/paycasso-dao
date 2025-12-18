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
        
        address usdcAddress = 0x036CbD53842c5426634e7929541eC2318f3dCF7e; 

        vm.startBroadcast(deployerPrivateKey);

        TFAEscrow escrow = new TFAEscrow(usdcAddress, admin);

        TFADispute dispute = new TFADispute(address(escrow), admin);

        TFADAOVoting dao = new TFADAOVoting(address(escrow), address(dispute), admin);

        escrow.setDisputeContract(address(dispute));
        escrow.setDAOContract(address(dao));
        dispute.setDAOContract(address(dao));


        vm.stopBroadcast();
        
        console.log("SUCCESS: TFA System Deployed to Base Sepolia");
        console.log("Escrow:", address(escrow));
        console.log("Dispute:", address(dispute));
        console.log("DAO Voting:", address(dao));
    }
}