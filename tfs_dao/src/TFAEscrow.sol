// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title TFAEscrow
 * @notice Enhanced escrow contract that holds contract funds + dispute fees
 * @dev Supports both contract amounts and separate fee deposits
 */
contract TFAEscrow is Ownable {
    
    IERC20 public immutable USDC;
    address public disputeContract;
    address public daoContract;

    event FundsDeposited(uint256 indexed jobId, address indexed payer, uint256 amount, bool isFee);
    event FundsReleased(uint256 indexed jobId, address indexed recipient, uint256 amount);
    event FundsRescued(address indexed token, address indexed to, uint256 amount);

    constructor(address _usdcAddress, address _initialOwner) Ownable(_initialOwner) {
        require(_usdcAddress != address(0), "Invalid USDC Address");
        require(_initialOwner != address(0), "Invalid Owner Address");
        USDC = IERC20(_usdcAddress);
    }

    function setDisputeContract(address _disputeContract) external onlyOwner {
        require(_disputeContract != address(0), "Invalid Address");
        disputeContract = _disputeContract;
    }

    function setDAOContract(address _daoContract) external onlyOwner {
        require(_daoContract != address(0), "Invalid Address");
        daoContract = _daoContract;
    }

    modifier onlyAuthorized() {
        require(
            msg.sender == disputeContract || msg.sender == daoContract,
            "Caller not authorized"
        );
        _;
    }

    /**
     * @notice Deposit contract amount or dispute fee
     * @param _jobId The job identifier
     * @param _payer Address paying the deposit
     * @param _amount Amount to deposit
     * @param _isFee Whether this is a dispute fee (true) or contract amount (false)
     */
    function deposit(
        uint256 _jobId, 
        address _payer, 
        uint256 _amount,
        bool _isFee
    ) external onlyAuthorized {
        require(_amount > 0, "Amount must be > 0");
        
        bool success = USDC.transferFrom(_payer, address(this), _amount);
        require(success, "USDC transfer failed");

        emit FundsDeposited(_jobId, _payer, _amount, _isFee);
    }

    /**
     * @notice Release funds to recipient
     * @param _recipient Address to receive funds
     * @param _amount Amount to release
     * @param _jobId Job identifier for event tracking
     */
    function releaseFunds(
        address _recipient, 
        uint256 _amount, 
        uint256 _jobId
    ) external onlyAuthorized {
        require(USDC.balanceOf(address(this)) >= _amount, "Insufficient escrow balance");
        
        bool success = USDC.transfer(_recipient, _amount);
        require(success, "USDC release failed");
        
        emit FundsReleased(_jobId, _recipient, _amount);
    }

    /**
     * @notice Emergency function to rescue stuck tokens
     * @param _token Token address
     * @param _to Recipient address
     * @param _amount Amount to rescue
     */
    function rescueFunds(address _token, address _to, uint256 _amount) external onlyOwner {
        bool success = IERC20(_token).transfer(_to, _amount);
        require(success, "Rescue transfer failed");
        
        emit FundsRescued(_token, _to, _amount);
    }
}
