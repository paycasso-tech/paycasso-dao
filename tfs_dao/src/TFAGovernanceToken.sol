// SPDX-License-Identifier: MIT 
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";


contract TFAGovernanceToken is ERC20, Ownable {
    constructor(address initialOwner) ERC20("TFA Juror Token", "GOV") Ownable(initialOwner) {
        // Mint initial supply to the deployer (e.g., 1 million tokens)
        _mint(initialOwner, 1_000_000 * 10**decimals());
    }

    // Function to mint more tokens (e.g., for rewards) - controlled by DAO
    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }
}