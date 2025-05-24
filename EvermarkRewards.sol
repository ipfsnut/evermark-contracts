// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/*
 ██████╗ ███████╗██╗    ██╗ █████╗ ██████╗ ██████╗ ███████╗
 ██╔══██╗██╔════╝██║    ██║██╔══██╗██╔══██╗██╔══██╗██╔════╝
 ██████╔╝█████╗  ██║ █╗ ██║███████║██████╔╝██║  ██║███████╗
 ██╔══██╗██╔══╝  ██║███╗██║██╔══██║██╔══██╗██║  ██║╚════██║
 ██║  ██║███████╗╚███╔███╔╝██║  ██║██║  ██║██████╔╝███████║
 ╚═╝  ╚═╝╚══════╝ ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═════╝ ╚══════╝
*/

interface ICardCatalog {
    function getTotalVotingPower(address user) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

contract EvermarkRewards is 
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant REWARDS_DISTRIBUTOR_ROLE = keccak256("REWARDS_DISTRIBUTOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    struct RewardSource {
        uint256 stakingRewards;
        uint256 protocolFeeRewards; 
        uint256 creatorRewards;
        uint256 nftStakingRewards;
        uint256 lastUpdated;
    }

    struct RewardConfiguration {
        uint256 stakingRewardPercentage;    // % of protocol fees for stakers
        uint256 creatorRewardPercentage;    // % of protocol fees for creators
        uint256 nftStakingPercentage;       // % of protocol fees for NFT stakers
        uint256 lastUpdated;
    }

    // Storage
    ICardCatalog public cardCatalog;
    IERC20 public rewardToken;
    
    mapping(address => RewardSource) public userRewards;
    mapping(address => uint256) public lastClaimTime;
    mapping(address => uint256) public totalClaimed;
    
    RewardConfiguration public rewardConfig;
    
    // Global tracking
    uint256 public totalStakingRewards;
    uint256 public totalCreatorRewards;
    uint256 public totalProtocolFees;
    uint256 public totalNftStakingRewards;
    uint256 public totalRewardsClaimed;
    
    // Staking power snapshots for fair distribution
    mapping(address => uint256) public stakingPowerSnapshot;
    uint256 public lastSnapshotTime;
    uint256 public totalStakingPowerSnapshot;
    
    // Events
    event RewardsClaimed(
        address indexed user, 
        uint256 stakingReward, 
        uint256 protocolReward, 
        uint256 creatorReward,
        uint256 nftStakingReward
    );
    event ProtocolFeesDistributed(uint256 amount, uint256 timestamp);
    event CreatorRewardDistributed(address indexed creator, uint256 amount);
    event StakingRewardAllocated(uint256 amount);
    event NftStakingRewardAllocated(uint256 amount);
    event RewardConfigUpdated(uint256 staking, uint256 creator, uint256 nftStaking);
    event StakingPowerUpdated(address indexed user, uint256 newPower);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _cardCatalog, address _rewardToken) external initializer {
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(REWARDS_DISTRIBUTOR_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);

        cardCatalog = ICardCatalog(_cardCatalog);
        rewardToken = IERC20(_rewardToken);
        
        // Default reward split: 40% staking, 30% creators, 30% NFT staking
        rewardConfig = RewardConfiguration({
            stakingRewardPercentage: 4000,
            creatorRewardPercentage: 3000,
            nftStakingPercentage: 3000,
            lastUpdated: block.timestamp
        });
        
        lastSnapshotTime = block.timestamp;
    }

    // Protocol fee distribution - called by FeeCollector
    function distributeProtocolFees(uint256 amount) external onlyRole(REWARDS_DISTRIBUTOR_ROLE) {
        require(amount > 0, "No fees to distribute");
        
        totalProtocolFees += amount;
        
        uint256 stakingPortion = (amount * rewardConfig.stakingRewardPercentage) / 10000;
        uint256 creatorPortion = (amount * rewardConfig.creatorRewardPercentage) / 10000;
        uint256 nftStakingPortion = amount - stakingPortion - creatorPortion;
        
        _distributeToStakers(stakingPortion);
        _distributeToNftStakers(nftStakingPortion);
        
        // Creator rewards are distributed separately when leaderboard is finalized
        totalCreatorRewards += creatorPortion;
        
        emit ProtocolFeesDistributed(amount, block.timestamp);
    }

    // Internal function to distribute rewards to token stakers
    function _distributeToStakers(uint256 amount) internal {
        if (amount == 0) return;
        
        totalStakingRewards += amount;
        _updateStakingPowerSnapshots();
        
        emit StakingRewardAllocated(amount);
    }

    // Internal function to distribute rewards to NFT stakers
    function _distributeToNftStakers(uint256 amount) internal {
        if (amount == 0) return;
        
        totalNftStakingRewards += amount;
        emit NftStakingRewardAllocated(amount);
    }

    // Update staking power snapshots for fair distribution
    function _updateStakingPowerSnapshots() internal {
        // Update total staking power
        totalStakingPowerSnapshot = cardCatalog.totalSupply();
        lastSnapshotTime = block.timestamp;
    }

    // Update individual user's staking power
    function updateStakingPower(address user) external {
        uint256 newPower = cardCatalog.balanceOf(user);
        stakingPowerSnapshot[user] = newPower;
        emit StakingPowerUpdated(user, newPower);
    }

    // Batch update staking power for multiple users
    function batchUpdateStakingPower(address[] calldata users) external {
        for (uint256 i = 0; i < users.length; i++) {
            uint256 newPower = cardCatalog.balanceOf(users[i]);
            stakingPowerSnapshot[users[i]] = newPower;
            emit StakingPowerUpdated(users[i], newPower);
        }
    }

    // Distribute rewards to specific creators (called by leaderboard contract)
    function distributeCreatorRewards(address[] calldata creators, uint256[] calldata amounts) 
        external onlyRole(REWARDS_DISTRIBUTOR_ROLE) {
        require(creators.length == amounts.length, "Array length mismatch");
        
        uint256 totalDistributed = 0;
        for (uint256 i = 0; i < creators.length; i++) {
            if (amounts[i] > 0) {
                userRewards[creators[i]].creatorRewards += amounts[i];
                userRewards[creators[i]].lastUpdated = block.timestamp;
                totalDistributed += amounts[i];
                emit CreatorRewardDistributed(creators[i], amounts[i]);
            }
        }
        
        require(totalDistributed <= totalCreatorRewards, "Insufficient creator rewards");
        totalCreatorRewards -= totalDistributed;
    }

    // Calculate pending staking rewards for a user
    function calculateStakingRewards(address user) public view returns (uint256) {
        uint256 userStakingPower = stakingPowerSnapshot[user];
        if (userStakingPower == 0 || totalStakingPowerSnapshot == 0) {
            return 0;
        }
        
        // Calculate user's share of total staking rewards
        uint256 userShare = (totalStakingRewards * userStakingPower) / totalStakingPowerSnapshot;
        
        // Subtract what they've already been allocated
        return userShare > userRewards[user].stakingRewards ? 
               userShare - userRewards[user].stakingRewards : 0;
    }

    // Get total pending rewards for a user
    function getPendingRewards(address user) external view returns (uint256) {
        RewardSource memory rewards = userRewards[user];
        uint256 pendingStaking = calculateStakingRewards(user);
        
        return rewards.stakingRewards + 
               rewards.protocolFeeRewards + 
               rewards.creatorRewards + 
               rewards.nftStakingRewards + 
               pendingStaking;
    }

    // Get rewards breakdown for a user
    function getRewardsBreakdown(address user) external view returns (
        uint256 staking,
        uint256 protocolFees, 
        uint256 creator,
        uint256 nftStaking,
        uint256 total
    ) {
        RewardSource memory rewards = userRewards[user];
        uint256 pendingStaking = calculateStakingRewards(user);
        
        staking = rewards.stakingRewards + pendingStaking;
        protocolFees = rewards.protocolFeeRewards;
        creator = rewards.creatorRewards;
        nftStaking = rewards.nftStakingRewards;
        total = staking + protocolFees + creator + nftStaking;
    }

    // Claim all pending rewards
    function claimRewards() external nonReentrant whenNotPaused returns (uint256) {
        address user = msg.sender;
        
        // Update staking power first
        updateStakingPower(user);
        
        // Calculate total rewards
        uint256 pendingStaking = calculateStakingRewards(user);
        RewardSource storage rewards = userRewards[user];
        
        uint256 stakingReward = rewards.stakingRewards + pendingStaking;
        uint256 protocolReward = rewards.protocolFeeRewards;
        uint256 creatorReward = rewards.creatorRewards;
        uint256 nftStakingReward = rewards.nftStakingRewards;
        
        uint256 total = stakingReward + protocolReward + creatorReward + nftStakingReward;
        require(total > 0, "No rewards to claim");
        
        // Reset balances
        rewards.stakingRewards = pendingStaking; // Keep the pending amount for next calculation
        rewards.protocolFeeRewards = 0;
        rewards.creatorRewards = 0;
        rewards.nftStakingRewards = 0;
        rewards.lastUpdated = block.timestamp;
        
        // Update claim tracking
        lastClaimTime[user] = block.timestamp;
        totalClaimed[user] += total;
        totalRewardsClaimed += total;
        
        // Transfer rewards
        require(rewardToken.transfer(user, total), "Reward transfer failed");
        
        emit RewardsClaimed(user, stakingReward, protocolReward, creatorReward, nftStakingReward);
        return total;
    }

    // Admin functions
    function updateRewardConfiguration(
        uint256 _stakingRewardPercentage,
        uint256 _creatorRewardPercentage,
        uint256 _nftStakingPercentage
    ) external onlyRole(ADMIN_ROLE) {
        require(
            _stakingRewardPercentage + _creatorRewardPercentage + _nftStakingPercentage == 10000,
            "Percentages must sum to 100%"
        );
        
        rewardConfig.stakingRewardPercentage = _stakingRewardPercentage;
        rewardConfig.creatorRewardPercentage = _creatorRewardPercentage;
        rewardConfig.nftStakingPercentage = _nftStakingPercentage;
        rewardConfig.lastUpdated = block.timestamp;
        
        emit RewardConfigUpdated(_stakingRewardPercentage, _creatorRewardPercentage, _nftStakingPercentage);
    }

    function setCardCatalog(address _cardCatalog) external onlyRole(ADMIN_ROLE) {
        require(_cardCatalog != address(0), "Invalid address");
        cardCatalog = ICardCatalog(_cardCatalog);
    }

    function setRewardToken(address _rewardToken) external onlyRole(ADMIN_ROLE) {
        require(_rewardToken != address(0), "Invalid address");
        rewardToken = IERC20(_rewardToken);
    }

    function grantRewardsDistributorRole(address distributor) external onlyRole(ADMIN_ROLE) {
        grantRole(REWARDS_DISTRIBUTOR_ROLE, distributor);
    }

    function revokeRewardsDistributorRole(address distributor) external onlyRole(ADMIN_ROLE) {
        revokeRole(REWARDS_DISTRIBUTOR_ROLE, distributor);
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // Emergency functions
    function emergencyWithdraw(uint256 amount, address recipient) external onlyRole(ADMIN_ROLE) {
        require(recipient != address(0), "Invalid recipient");
        require(amount <= rewardToken.balanceOf(address(this)), "Insufficient balance");
        
        rewardToken.transfer(recipient, amount);
    }

    // View functions for analytics
    function getGlobalStats() external view returns (
        uint256 totalProtocolFeesCollected,
        uint256 totalStakingRewardsAllocated,
        uint256 totalCreatorRewardsAllocated,
        uint256 totalNftStakingRewardsAllocated,
        uint256 totalRewardsClaimedAmount
    ) {
        return (
            totalProtocolFees,
            totalStakingRewards,
            totalCreatorRewards,
            totalNftStakingRewards,
            totalRewardsClaimed
        );
    }

    function getUserStats(address user) external view returns (
        uint256 totalClaimedAmount,
        uint256 lastClaimTimestamp,
        uint256 currentStakingPower
    ) {
        return (
            totalClaimed[user],
            lastClaimTime[user],
            stakingPowerSnapshot[user]
        );
    }

    // Required overrides
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}