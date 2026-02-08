// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Script.sol";
import "../src/TFADaoVoting.sol";

interface ISetsDAO {
    function setDAOContract(address _dao) external;
}

contract RedeployDAO is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address admin = vm.addr(deployerPrivateKey);
        
        address escrowAddr = 0x6C737A9F86818C825F491B01148F7b855a8c4a9B;
        address disputeAddr = 0x75e8bcB81EAC942B27545e50F1516FcD7357BB87;

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy NEW DAO with the 1-second duration fix already applied to source
        TFADAOVoting dao = new TFADAOVoting(escrowAddr, disputeAddr, admin);

        // 2. Update existing contracts to point to new DAO
        ISetsDAO(escrowAddr).setDAOContract(address(dao));
        ISetsDAO(disputeAddr).setDAOContract(address(dao));

        vm.stopBroadcast();
        
        console.log("SUCCESS: New DAO Deployed and Linked");
        console.log("New DAO Voting Address:", address(dao));
    }
}
