// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable@4.8.0/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable@4.8.0/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable@4.8.0/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable@4.8.0/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable@4.8.0/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable@4.8.0/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts@4.8.0/token/ERC20/IERC20.sol";

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
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    uint256 public constant UNBONDING_PERIOD = 7 days;

    IERC20 public emarkToken;
    mapping(address => uint256) public unbondingAmount;
    mapping(address => uint256) public unbondingReleaseTime;
    mapping(address => uint256) public delegatedVotingPower;
    
    uint256 public totalUnbondingAmount;
    uint256 public emergencyPauseTimestamp;
    
    event Wrapped(address indexed user, uint256 amount);
    event UnwrapRequested(address indexed user, uint256 amount, uint256 releaseTime);
    event UnwrapCompleted(address indexed user, uint256 amount);
    event UnbondingCancelled(address indexed user, uint256 amount);
    event VotingPowerDelegated(address indexed user, uint256 delegated);
    event EmergencyPauseSet(uint256 timestamp);

    modifier notInEmergency() {
        require(block.timestamp > emergencyPauseTimestamp, "Emergency pause active");
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address emarkTokenAddress,
        string memory name,
        string memory symbol
    ) external initializer {
        require(emarkTokenAddress != address(0), "Invalid token address");
        
        __ERC20_init(name, symbol);
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);

        emarkToken = IERC20(emarkTokenAddress);
        emergencyPauseTimestamp = 0;
    }

    function wrap(uint256 amount) external whenNotPaused notInEmergency nonReentrant {
        require(amount > 0, "Amount must be > 0");
        
        emarkToken.transferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, amount);
        
        emit Wrapped(msg.sender, amount);
    }

    function requestUnwrap(uint256 amount) external whenNotPaused notInEmergency nonReentrant {
        require(amount > 0, "Amount must be > 0");
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");
        require(balanceOf(msg.sender) - delegatedVotingPower[msg.sender] >= amount, "Exceeds available power");
        require(unbondingAmount[msg.sender] == 0, "Already have active unbonding");
        
        _burn(msg.sender, amount);
        
        unbondingAmount[msg.sender] = amount;
        unbondingReleaseTime[msg.sender] = block.timestamp + UNBONDING_PERIOD;
        totalUnbondingAmount += amount;
        
        emit UnwrapRequested(msg.sender, amount, unbondingReleaseTime[msg.sender]);
    }

    function completeUnwrap() external whenNotPaused notInEmergency nonReentrant {
        uint256 amount = unbondingAmount[msg.sender];
        require(amount > 0, "No active unbonding");
        require(block.timestamp >= unbondingReleaseTime[msg.sender], "Unbonding period not complete");
        
        unbondingAmount[msg.sender] = 0;
        unbondingReleaseTime[msg.sender] = 0;
        totalUnbondingAmount -= amount;
        
        emarkToken.transfer(msg.sender, amount);
        
        emit UnwrapCompleted(msg.sender, amount);
    }

    function cancelUnbonding() external whenNotPaused notInEmergency nonReentrant {
        uint256 amount = unbondingAmount[msg.sender];
        require(amount > 0, "No active unbonding");
        
        unbondingAmount[msg.sender] = 0;
        unbondingReleaseTime[msg.sender] = 0;
        totalUnbondingAmount -= amount;
        
        _mint(msg.sender, amount);
        
        emit UnbondingCancelled(msg.sender, amount);
    }

    function updateVotingPowerDelegation(address user, uint256 delegated) external onlyRole(ADMIN_ROLE) {
        require(delegated <= balanceOf(user), "Delegated exceeds balance");
        delegatedVotingPower[user] = delegated;
        emit VotingPowerDelegated(user, delegated);
    }

    function getTotalVotingPower(address user) public view returns (uint256) {
        return balanceOf(user);
    }

    function getAvailableVotingPower(address user) public view returns (uint256) {
        return balanceOf(user) - delegatedVotingPower[user];
    }

    function getDelegatedVotingPower(address user) public view returns (uint256) {
        return delegatedVotingPower[user];
    }

    function getUnbondingInfo(address user) external view returns (
        uint256 amount,
        uint256 releaseTime,
        bool canClaim
    ) {
        amount = unbondingAmount[user];
        releaseTime = unbondingReleaseTime[user];
        canClaim = amount > 0 && block.timestamp >= releaseTime;
    }

    function getUserSummary(address user) external view returns (
        uint256 stakedBalance,
        uint256 availableVotingPower,
        uint256 delegatedPower,
        uint256 unbondingAmount_,
        uint256 unbondingReleaseTime_,
        bool canClaimUnbonding
    ) {
        stakedBalance = balanceOf(user);
        availableVotingPower = stakedBalance - delegatedVotingPower[user];
        delegatedPower = delegatedVotingPower[user];
        unbondingAmount_ = unbondingAmount[user];
        unbondingReleaseTime_ = unbondingReleaseTime[user];
        canClaimUnbonding = unbondingAmount_ > 0 && block.timestamp >= unbondingReleaseTime_;
    }

    function getTotalStakedEmark() external view returns (uint256) {
        return emarkToken.balanceOf(address(this));
    }

    function setEmergencyPause(uint256 pauseUntilTimestamp) external onlyRole(ADMIN_ROLE) {
        emergencyPauseTimestamp = pauseUntilTimestamp;
        emit EmergencyPauseSet(pauseUntilTimestamp);
    }

    function clearEmergencyPause() external onlyRole(ADMIN_ROLE) {
        emergencyPauseTimestamp = 0;
        emit EmergencyPauseSet(0);
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function setEmarkToken(address _emarkToken) external onlyRole(ADMIN_ROLE) {
        require(_emarkToken != address(0), "Invalid address");
        emarkToken = IERC20(_emarkToken);
    }

    function emergencyWithdraw(address token, uint256 amount, address recipient) external onlyRole(ADMIN_ROLE) {
        require(recipient != address(0), "Invalid recipient");
        
        if (token == address(0)) {
            (bool success, ) = payable(recipient).call{value: amount}("");
            require(success, "ETH withdrawal failed");
        } else {
            IERC20(token).transfer(recipient, amount);
        }
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        // Only admin can upgrade
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    // Override transfer functions to disable them (tokens should not be transferable)
    function transfer(address, uint256) public pure override returns (bool) {
        revert("Transfers disabled");
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert("Transfers disabled");
    }
}