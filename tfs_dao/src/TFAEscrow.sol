// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title TFAEscrow
 * @notice Holds Native USDC funds for disputes.
 * @dev Only the Dispute Contract can authorize withdrawals.
 */
contract TFAEscrow is Ownable {
    
    IERC20 public immutable usdc;
    address public disputeContract;

    event FundsDeposited(uint256 indexed disputeId, address indexed payer, uint256 amount);
    event FundsReleased(uint256 indexed disputeId, address indexed recipient, uint256 amount);

    constructor(address _usdcAddress, address _initialOwner) Ownable(_initialOwner) {
        usdc = IERC20(_usdcAddress);
    }

    /**
     * @notice Connects the Dispute Contract. Can only be set once to prevent rug pulls.
     */
    function setDisputeContract(address _disputeContract) external onlyOwner {
        require(disputeContract == address(0), "Dispute contract already set");
        disputeContract = _disputeContract;
    }

    modifier onlyDisputeContract() {
        require(msg.sender == disputeContract, "Caller is not the Dispute Contract");
        _;
    }

    /**
     * @notice Client deposits funds for a specific dispute.
     * @dev Client must first call `usdc.approve(escrowAddress, amount)`
     * @param _payer The address of the user paying the funds (The Client)
     */
    function deposit(uint256 _disputeId, address _payer, uint256 _amount) external onlyDisputeContract {
        require(_amount > 0, "Amount must be > 0");
        
        // Transfer USDC from Payer -> Escrow
        // The Payer must have approved the Escrow Contract!
        bool success = usdc.transferFrom(_payer, address(this), _amount);
        require(success, "USDC transfer failed");

        emit FundsDeposited(_disputeId, _payer, _amount);
    }

    /**
     * @notice Releases funds. Only callable by the logic contract.
     */
    function releaseFunds(address _recipient, uint256 _amount, uint256 _disputeId) external onlyDisputeContract {
        require(usdc.balanceOf(address(this)) >= _amount, "Insufficient escrow balance");
        bool success = usdc.transfer(_recipient, _amount);
        require(success, "USDC release failed");
        
        emit FundsReleased(_disputeId, _recipient, _amount);
    }
}