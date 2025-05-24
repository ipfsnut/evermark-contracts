// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/*
 ██████╗ █████╗ ██████╗ ██████╗      ██████╗ █████╗ ████████╗ █████╗ ██╗      ██████╗  ██████╗ 
██╔════╝██╔══██╗██╔══██╗██╔══██╗    ██╔════╝██╔══██╗╚══██╔══╝██╔══██╗██║     ██╔═══██╗██╔════╝ 
██║     ███████║██████╔╝██║  ██║    ██║     ███████║   ██║   ███████║██║     ██║   ██║██║  ███╗
██║     ██╔══██║██╔══██╗██║  ██║    ██║     ██╔══██║   ██║   ██╔══██║██║     ██║   ██║██║   ██║
╚██████╗██║  ██║██║  ██║██████╔╝    ╚██████╗██║  ██║   ██║   ██║  ██║███████╗╚██████╔╝╚██████╔╝
 ╚═════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═════╝      ╚═════╝╚═╝  ╚═╝   ╚═╝   ╚═╝  ╚═╝╚══════╝ ╚═════╝  ╚═════╝ 
*/

contract CardCatalog is 
    Initializable,
    ERC20Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    struct UnbondingRequest {
        uint256 amount;
        uint256 releaseTime;
    }

    // Constants
    uint256 public constant UNBONDING_PERIOD = 7 days;

    // Storage
    IERC20 public nsiToken;
    
    // Unbonding requests per user
    mapping(address => UnbondingRequest[]) public unbondingRequests;
    
    // Voting power delegation tracking
    mapping(address => uint256) public delegatedVotingPower;
    mapping(address => uint256) public availableVotingPower;
    
    // Global stats
    uint256 public totalUnbondingAmount;
    
    // Events
    event Wrapped(address indexed user, uint256 amount);
    event UnwrapRequested(address indexed user, uint256 amount, uint256 releaseTime);
    event UnwrapCompleted(address indexed user, uint256 amount);
    event UnbondingCancelled(address indexed user, uint256 amount, uint256 requestIndex);
    event VotingPowerUpdated(address indexed user, uint256 available, uint256 delegated);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address nsiTokenAddress,
        string memory name,
        string memory symbol
    ) external initializer {
        __ERC20_init(name, symbol);
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);

        nsiToken = IERC20(nsiTokenAddress);
    }

    // Wrap NSI tokens to get voting power (staking)
    function wrap(uint256 amount) external whenNotPaused {
        require(amount > 0, "Amount must be greater than 0");
        
        // Transfer NSI tokens from user
        nsiToken.transferFrom(msg.sender, address(this), amount);
        
        // Mint wrapped tokens (voting power)
        _mint(msg.sender, amount);
        
        // Update available voting power
        availableVotingPower[msg.sender] += amount;
        
        emit Wrapped(msg.sender, amount);
        emit VotingPowerUpdated(msg.sender, availableVotingPower[msg.sender], delegatedVotingPower[msg.sender]);
    }

    // Request unwrapping (unstaking) with time delay
    function requestUnwrap(uint256 amount) external whenNotPaused {
        require(amount > 0, "Amount must be greater than 0");
        require(balanceOf(msg.sender) >= amount, "Insufficient wrapped balance");
        require(availableVotingPower[msg.sender] >= amount, "Amount exceeds available voting power");
        
        // Burn wrapped tokens
        _burn(msg.sender, amount);
        
        // Reduce available voting power
        availableVotingPower[msg.sender] -= amount;
        
        // Create unbonding request
        uint256 releaseTime = block.timestamp + UNBONDING_PERIOD;
        unbondingRequests[msg.sender].push(UnbondingRequest({
            amount: amount,
            releaseTime: releaseTime
        }));
        
        totalUnbondingAmount += amount;
        
        emit UnwrapRequested(msg.sender, amount, releaseTime);
        emit VotingPowerUpdated(msg.sender, availableVotingPower[msg.sender], delegatedVotingPower[msg.sender]);
    }

    // Complete unwrapping after unbonding period
    function completeUnwrap(uint256 requestIndex) external whenNotPaused {
        UnbondingRequest[] storage requests = unbondingRequests[msg.sender];
        require(requestIndex < requests.length, "Invalid request index");
        
        UnbondingRequest memory request = requests[requestIndex];
        require(block.timestamp >= request.releaseTime, "Unbonding period not complete");
        require(request.amount > 0, "Request already completed");
        
        uint256 amount = request.amount;
        
        // Remove the request (swap with last element and pop)
        requests[requestIndex] = requests[requests.length - 1];
        requests.pop();
        
        totalUnbondingAmount -= amount;
        
        // Transfer NSI tokens back to user
        nsiToken.transfer(msg.sender, amount);
        
        emit UnwrapCompleted(msg.sender, amount);
    }

    // Cancel an unbonding request and get wrapped tokens back
    function cancelUnbonding(uint256 requestIndex) external whenNotPaused {
        UnbondingRequest[] storage requests = unbondingRequests[msg.sender];
        require(requestIndex < requests.length, "Invalid request index");
        
        UnbondingRequest memory request = requests[requestIndex];
        require(request.amount > 0, "Request already completed");
        
        uint256 amount = request.amount;
        
        // Remove the request
        requests[requestIndex] = requests[requests.length - 1];
        requests.pop();
        
        totalUnbondingAmount -= amount;
        
        // Mint wrapped tokens back
        _mint(msg.sender, amount);
        
        // Restore available voting power
        availableVotingPower[msg.sender] += amount;
        
        emit UnbondingCancelled(msg.sender, amount, requestIndex);
        emit VotingPowerUpdated(msg.sender, availableVotingPower[msg.sender], delegatedVotingPower[msg.sender]);
    }

    // Update voting power delegation (called by voting contract)
    function updateVotingPowerDelegation(address user, uint256 delegated) external onlyRole(ADMIN_ROLE) {
        uint256 totalPower = balanceOf(user);
        require(delegated <= totalPower, "Delegated power exceeds balance");
        
        delegatedVotingPower[user] = delegated;
        availableVotingPower[user] = totalPower - delegated;
        
        emit VotingPowerUpdated(user, availableVotingPower[user], delegatedVotingPower[user]);
    }

    // View functions
    function getTotalVotingPower(address user) external view returns (uint256) {
        return balanceOf(user);
    }

    function getAvailableVotingPower(address user) external view returns (uint256) {
        return availableVotingPower[user];
    }

    function getDelegatedVotingPower(address user) external view returns (uint256) {
        return delegatedVotingPower[user];
    }

    function getUnbondingRequests(address user) external view returns (UnbondingRequest[] memory) {
        return unbondingRequests[user];
    }

    function getUnbondingAmount(address user) external view returns (uint256) {
        UnbondingRequest[] memory requests = unbondingRequests[user];
        uint256 total = 0;
        for (uint256 i = 0; i < requests.length; i++) {
            total += requests[i].amount;
        }
        return total;
    }

    // Check if an unbonding request is ready to complete
    function isUnbondingReady(address user, uint256 requestIndex) external view returns (bool) {
        UnbondingRequest[] memory requests = unbondingRequests[user];
        if (requestIndex >= requests.length) return false;
        return block.timestamp >= requests[requestIndex].releaseTime;
    }

    // Get count of unbonding requests for a user
    function getUnbondingRequestCount(address user) external view returns (uint256) {
        return unbondingRequests[user].length;
    }

    // Get total NSI tokens held by contract
    function getTotalStakedNsi() external view returns (uint256) {
        return nsiToken.balanceOf(address(this));
    }

    // Override transfer functions to update voting power
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        super._beforeTokenTransfer(from, to, amount);
        
        // Update voting power tracking when tokens are transferred
        if (from != address(0) && from != to) {
            // Reduce sender's available power by the transferred amount
            uint256 fromAvailable = availableVotingPower[from];
            if (fromAvailable >= amount) {
                availableVotingPower[from] = fromAvailable - amount;
            } else {
                // If not enough available power, reduce delegated power too
                uint256 shortfall = amount - fromAvailable;
                availableVotingPower[from] = 0;
                delegatedVotingPower[from] = delegatedVotingPower[from] > shortfall ? 
                    delegatedVotingPower[from] - shortfall : 0;
            }
        }
        
        if (to != address(0) && from != to) {
            // Increase receiver's available power
            availableVotingPower[to] += amount;
        }
    }

    // Disable transfers to prevent manipulation
    function transfer(address, uint256) public pure override returns (bool) {
        revert("Transfers disabled - use unwrap to redeem NSI");
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert("Transfers disabled - use unwrap to redeem NSI");
    }

    // Admin functions
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function setNsiToken(address _nsiToken) external onlyRole(ADMIN_ROLE) {
        require(_nsiToken != address(0), "Invalid token address");
        nsiToken = IERC20(_nsiToken);
    }

    // Emergency functions
    function emergencyWithdraw(address token, uint256 amount, address recipient) external onlyRole(ADMIN_ROLE) {
        require(recipient != address(0), "Invalid recipient");
        
        if (token == address(0)) {
            // Withdraw ETH
            (bool success, ) = payable(recipient).call{value: amount}("");
            require(success, "ETH withdrawal failed");
        } else {
            // Withdraw tokens
            IERC20(token).transfer(recipient, amount);
        }
    }

    // Batch operations for gas efficiency
    function batchCompleteUnwrap(uint256[] calldata requestIndices) external whenNotPaused {
        for (uint256 i = 0; i < requestIndices.length; i++) {
            // Call completeUnwrap for each valid index
            if (requestIndices[i] < unbondingRequests[msg.sender].length) {
                completeUnwrap(requestIndices[i]);
            }
        }
    }

    function batchCancelUnbonding(uint256[] calldata requestIndices) external whenNotPaused {
        for (uint256 i = 0; i < requestIndices.length; i++) {
            if (requestIndices[i] < unbondingRequests[msg.sender].length) {
                cancelUnbonding(requestIndices[i]);
            }
        }
    }

    // Get user's complete staking summary
    function getUserStakingSummary(address user) external view returns (
        uint256 totalWrapped,
        uint256 availablePower,
        uint256 delegatedPower,
        uint256 unbondingAmount,
        uint256 unbondingRequests
    ) {
        totalWrapped = balanceOf(user);
        availablePower = availableVotingPower[user];
        delegatedPower = delegatedVotingPower[user];
        unbondingAmount = getUnbondingAmount(user);
        unbondingRequests = getUnbondingRequestCount(user);
    }

    // Required overrides
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}