// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract TFAEscrow is Ownable {
    
    IERC20 public immutable USDC;
    address public disputeContract;

    event FundsDeposited(uint256 indexed disputeId, address indexed payer, uint256 amount);
    event FundsReleased(uint256 indexed disputeId, address indexed recipient, uint256 amount);

    constructor(address _usdcAddress, address _initialOwner) Ownable(_initialOwner) {
        USDC = IERC20(_usdcAddress);
    }

    function setDisputeContract(address _disputeContract) external onlyOwner {
        require(disputeContract == address(0), "Dispute contract already set");
        disputeContract = _disputeContract;
    }

    modifier onlyDisputeContract() {
        _checkDisputeContract();
        _;
    }

    function _checkDisputeContract() internal view {
        require(msg.sender == disputeContract, "Caller is not the Dispute Contract");
    }

    function deposit(uint256 _disputeId, address _payer, uint256 _amount) external onlyDisputeContract {
        require(_amount > 0, "Amount must be > 0");
        
        // Transfer USDC from Payer -> Escrow
        bool success = USDC.transferFrom(_payer, address(this), _amount);
        require(success, "USDC transfer failed");

        emit FundsDeposited(_disputeId, _payer, _amount);
    }

    function releaseFunds(address _recipient, uint256 _amount, uint256 _disputeId) external onlyDisputeContract {
        require(USDC.balanceOf(address(this)) >= _amount, "Insufficient escrow balance");
        
        bool success = USDC.transfer(_recipient, _amount);
        require(success, "USDC release failed");
        
        emit FundsReleased(_disputeId, _recipient, _amount);
    }
}