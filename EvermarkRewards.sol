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
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function getAvailableVotingPower(address user) external view returns (uint256);
    function getDelegatedVotingPower(address user) external view returns (uint256);
}

interface IEvermarkVoting {
    function getCurrentCycle() external view returns (uint256);
}

interface IEvermarkLeaderboard {
    function distributeCreatorRewards(uint256 cycle, uint256 rewardPool) external;
    function isLeaderboardFinalized(uint256 cycle) external view returns (bool);
}

interface INFTStaking {
    function getUserStakedNFTs(address user) external view returns (
        uint256[] memory tokenIds,
        uint256[] memory stakedTimes,
        uint256[] memory lockPeriods,
        uint256[] memory pendingRewards,
        bool[] memory canUnstake
    );
    function distributeRewards(address[] calldata users, uint256[] calldata amounts) external;
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

    struct WeeklyRewardCycle {
        uint256 week;
        uint256 startTime;
        uint256 endTime;
        uint256 totalRewardPool;
        uint256 tokenStakerPool;     // 60% of total
        uint256 creatorPool;         // 40% of total
        uint256 baseStakerPool;      // 50% of tokenStakerPool (30% of total)
        uint256 variableStakerPool;  // 50% of tokenStakerPool (30% of total)
        bool finalized;
        bool distributed;
        mapping(address => uint256) userBaseRewards;
        mapping(address => uint256) userVariableRewards;
        mapping(address => uint256) userNftRewards;
        mapping(address => bool) claimed;
    }

    struct UserRewardSummary {
        uint256 pendingBaseRewards;
        uint256 pendingVariableRewards;
        uint256 pendingNftRewards;
        uint256 pendingCreatorRewards;
        uint256 totalPending;
        uint256 totalClaimed;
    }

    // Constants
    uint256 public constant MAX_BATCH_SIZE = 100;
    uint256 public constant WEEK_DURATION = 7 days;

    // Storage
    ICardCatalog public cardCatalog;
    IEvermarkVoting public evermarkVoting;
    IEvermarkLeaderboard public evermarkLeaderboard;
    INFTStaking public nftStaking;
    IERC20 public rewardToken; // EMARK token
    
    uint256 public currentWeek;
    uint256 public weekStartTime;
    
    mapping(uint256 => WeeklyRewardCycle) public weeklyRewards;
    mapping(address => uint256) public totalUserClaimed;
    mapping(address => uint256) public pendingCreatorRewards;
    
    // Emergency circuit breaker
    uint256 public emergencyPauseTimestamp;
    
    // Global tracking
    uint256 public totalRewardsDistributed;
    uint256 public totalTokenStakerRewards;
    uint256 public totalCreatorRewards;
    uint256 public totalNftStakerRewards;
    
    // Events
    event WeeklyRewardsCalculated(
        uint256 indexed week,
        uint256 totalPool,
        uint256 tokenStakerPool,
        uint256 creatorPool
    );
    event RewardsClaimed(
        address indexed user,
        uint256 week,
        uint256 baseRewards,
        uint256 variableRewards,
        uint256 nftRewards,
        uint256 creatorRewards
    );
    event WeeklyRewardsDistributed(uint256 indexed week, uint256 totalDistributed);
    event EmergencyPauseSet(uint256 timestamp);
    event ContractsUpdated(address cardCatalog, address voting, address leaderboard, address nftStaking);

    modifier notInEmergency() {
        require(block.timestamp > emergencyPauseTimestamp, "Emergency pause active");
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _cardCatalog,
        address _evermarkVoting,
        address _evermarkLeaderboard,
        address _nftStaking,
        address _rewardToken
    ) external initializer {
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(REWARDS_DISTRIBUTOR_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);

        cardCatalog = ICardCatalog(_cardCatalog);
        evermarkVoting = IEvermarkVoting(_evermarkVoting);
        if (_evermarkLeaderboard != address(0)) {
            evermarkLeaderboard = IEvermarkLeaderboard(_evermarkLeaderboard);
        }
        nftStaking = INFTStaking(_nftStaking);
        rewardToken = IERC20(_rewardToken);
        
        emergencyPauseTimestamp = 0;
        
        // Start first week
        currentWeek = 1;
        weekStartTime = block.timestamp;
        
        WeeklyRewardCycle storage week = weeklyRewards[currentWeek];
        week.week = currentWeek;
        week.startTime = block.timestamp;
        week.endTime = block.timestamp + WEEK_DURATION;
    }

    // Fund the current week's reward pool
    function fundWeeklyRewards(uint256 amount) external onlyRole(REWARDS_DISTRIBUTOR_ROLE) notInEmergency {
        require(amount > 0, "Amount must be > 0");
        require(rewardToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        _checkAndStartNewWeek();
        
        WeeklyRewardCycle storage week = weeklyRewards[currentWeek];
        week.totalRewardPool += amount;
        
        // Split the pool: 60% token stakers, 40% creators
        uint256 tokenStakerAllocation = (amount * 6000) / 10000; // 60%
        uint256 creatorAllocation = amount - tokenStakerAllocation; // 40%
        
        week.tokenStakerPool += tokenStakerAllocation;
        week.creatorPool += creatorAllocation;
        
        // Split token staker pool: 50% base, 50% variable
        week.baseStakerPool += tokenStakerAllocation / 2;
        week.variableStakerPool += tokenStakerAllocation / 2;
    }

    // Finalize a completed week and calculate rewards
    function finalizeWeek(uint256 week) external onlyRole(REWARDS_DISTRIBUTOR_ROLE) notInEmergency {
        require(week < currentWeek, "Week not completed");
        require(!weeklyRewards[week].finalized, "Week already finalized");
        require(weeklyRewards[week].totalRewardPool > 0, "No rewards to distribute");
        
        WeeklyRewardCycle storage weekData = weeklyRewards[week];
        weekData.finalized = true;
        
        // Distribute creator rewards via leaderboard if available
        if (weekData.creatorPool > 0 && address(evermarkLeaderboard) != address(0)) {
            try evermarkLeaderboard.distributeCreatorRewards(week, weekData.creatorPool) {
                // Creator rewards distributed successfully
            } catch {
                // If leaderboard distribution fails, keep rewards for manual distribution
            }
        }
        
        emit WeeklyRewardsCalculated(
            week,
            weekData.totalRewardPool,
            weekData.tokenStakerPool,
            weekData.creatorPool
        );
    }

    // Calculate rewards for a user in a specific week
    function calculateUserWeeklyRewards(
        address user,
        uint256 week
    ) external view returns (
        uint256 baseRewards,
        uint256 variableRewards,
        uint256 nftRewards
    ) {
        WeeklyRewardCycle storage weekData = weeklyRewards[week];
        if (!weekData.finalized) return (0, 0, 0);
        
        uint256 userStake = cardCatalog.balanceOf(user);
        uint256 totalStaked = cardCatalog.totalSupply();
        
        // Division by zero protection
        if (userStake == 0 || totalStaked == 0) return (0, 0, 0);
        
        // Base rewards: equal distribution based on stake
        baseRewards = (weekData.baseStakerPool * userStake) / totalStaked;
        
        // Variable rewards: based on delegation percentage
        uint256 userDelegated = cardCatalog.getDelegatedVotingPower(user);
        uint256 delegationPercentage = userStake > 0 ? (userDelegated * 10000) / userStake : 0;
        
        uint256 userMaxVariable = (weekData.variableStakerPool * userStake) / totalStaked;
        variableRewards = (userMaxVariable * delegationPercentage) / 10000;
        
        // NFT rewards: placeholder for now
        nftRewards = 0;
    }

    // Batch calculate rewards with size limits and error handling
    function batchCalculateRewards(
        uint256 week,
        address[] calldata users
    ) external onlyRole(REWARDS_DISTRIBUTOR_ROLE) {
        require(users.length <= MAX_BATCH_SIZE, "Batch size too large");
        require(weeklyRewards[week].finalized, "Week not finalized");
        
        WeeklyRewardCycle storage weekData = weeklyRewards[week];
        
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            
            try this.calculateUserWeeklyRewards(user, week) returns (
                uint256 baseRewards, 
                uint256 variableRewards, 
                uint256 nftRewards
            ) {
                weekData.userBaseRewards[user] = baseRewards;
                weekData.userVariableRewards[user] = variableRewards;
                weekData.userNftRewards[user] = nftRewards;
            } catch {
                // Skip users with calculation errors
                continue;
            }
        }
        
        weekData.distributed = true;
    }

    // Claim all pending rewards for a user
    function claimAllRewards() external nonReentrant whenNotPaused notInEmergency returns (uint256 totalClaimed) {
        address user = msg.sender;
        
        // Calculate total pending rewards across all weeks
        for (uint256 week = 1; week < currentWeek; week++) {
            if (weeklyRewards[week].distributed && !weeklyRewards[week].claimed[user]) {
                WeeklyRewardCycle storage weekData = weeklyRewards[week];
                
                uint256 baseRewards = weekData.userBaseRewards[user];
                uint256 variableRewards = weekData.userVariableRewards[user];
                uint256 nftRewards = weekData.userNftRewards[user];
                uint256 creatorRewards = week == currentWeek - 1 ? pendingCreatorRewards[user] : 0; // Only latest week creator rewards
                
                uint256 weekTotal = baseRewards + variableRewards + nftRewards + creatorRewards;
                
                if (weekTotal > 0) {
                    totalClaimed += weekTotal;
                    weekData.claimed[user] = true;
                    
                    emit RewardsClaimed(
                        user,
                        week,
                        baseRewards,
                        variableRewards,
                        nftRewards,
                        creatorRewards
                    );
                }
            }
        }
        
        // Reset creator rewards
        pendingCreatorRewards[user] = 0;
        
        if (totalClaimed > 0) {
            totalUserClaimed[user] += totalClaimed;
            totalRewardsDistributed += totalClaimed;
            
            require(rewardToken.transfer(user, totalClaimed), "Reward transfer failed");
        }
    }

    // Claim specific week with better error handling
    function claimWeeklyRewards(uint256 week) external nonReentrant whenNotPaused notInEmergency returns (uint256 totalClaimed) {
        address user = msg.sender;
        require(weeklyRewards[week].distributed, "Week not distributed");
        require(!weeklyRewards[week].claimed[user], "Already claimed");
        
        WeeklyRewardCycle storage weekData = weeklyRewards[week];
        
        uint256 baseRewards = weekData.userBaseRewards[user];
        uint256 variableRewards = weekData.userVariableRewards[user];
        uint256 nftRewards = weekData.userNftRewards[user];
        uint256 creatorRewards = week == currentWeek - 1 ? pendingCreatorRewards[user] : 0; // Only latest week creator rewards
        
        totalClaimed = baseRewards + variableRewards + nftRewards + creatorRewards;
        
        if (totalClaimed > 0) {
            weekData.claimed[user] = true;
            
            if (creatorRewards > 0) {
                pendingCreatorRewards[user] = 0;
            }
            
            totalUserClaimed[user] += totalClaimed;
            totalRewardsDistributed += totalClaimed;
            
            require(rewardToken.transfer(user, totalClaimed), "Reward transfer failed");
            
            emit RewardsClaimed(
                user,
                week,
                baseRewards,
                variableRewards,
                nftRewards,
                creatorRewards
            );
        }
    }

    // Get comprehensive reward summary for a user
    function getUserRewardSummary(address user) external view returns (UserRewardSummary memory summary) {
        for (uint256 week = 1; week < currentWeek; week++) {
            if (weeklyRewards[week].distributed && !weeklyRewards[week].claimed[user]) {
                WeeklyRewardCycle storage weekData = weeklyRewards[week];
                
                summary.pendingBaseRewards += weekData.userBaseRewards[user];
                summary.pendingVariableRewards += weekData.userVariableRewards[user];
                summary.pendingNftRewards += weekData.userNftRewards[user];
            }
        }
        
        summary.pendingCreatorRewards = pendingCreatorRewards[user];
        summary.totalPending = summary.pendingBaseRewards + 
                              summary.pendingVariableRewards + 
                              summary.pendingNftRewards + 
                              summary.pendingCreatorRewards;
        summary.totalClaimed = totalUserClaimed[user];
    }

    // Check and start new week if needed
    function _checkAndStartNewWeek() internal {
        if (block.timestamp >= weeklyRewards[currentWeek].endTime) {
            _startNewWeek();
        }
    }

    // Start a new reward week
    function _startNewWeek() internal {
        currentWeek++;
        weekStartTime = block.timestamp;
        
        WeeklyRewardCycle storage newWeek = weeklyRewards[currentWeek];
        newWeek.week = currentWeek;
        newWeek.startTime = block.timestamp;
        newWeek.endTime = block.timestamp + WEEK_DURATION;
    }

    // Force start new week (admin only)
    function forceStartNewWeek() external onlyRole(ADMIN_ROLE) {
        _startNewWeek();
    }

    // Get current week info
    function getCurrentWeekInfo() external view returns (
        uint256 week,
        uint256 startTime,
        uint256 endTime,
        uint256 totalPool,
        uint256 timeRemaining,
        bool finalized
    ) {
        WeeklyRewardCycle storage weekData = weeklyRewards[currentWeek];
        week = currentWeek;
        startTime = weekData.startTime;
        endTime = weekData.endTime;
        totalPool = weekData.totalRewardPool;
        timeRemaining = block.timestamp >= endTime ? 0 : endTime - block.timestamp;
        finalized = weekData.finalized;
    }

    // Get week info for any week
    function getWeekInfo(uint256 weekNumber) external view returns (
        uint256 week,
        uint256 startTime,
        uint256 endTime,
        uint256 totalPool,
        uint256 tokenStakerPool,
        uint256 creatorPool,
        bool finalized,
        bool distributed
    ) {
        WeeklyRewardCycle storage weekData = weeklyRewards[weekNumber];
        return (
            weekData.week,
            weekData.startTime,
            weekData.endTime,
            weekData.totalRewardPool,
            weekData.tokenStakerPool,
            weekData.creatorPool,
            weekData.finalized,
            weekData.distributed
        );
    }

    // Distribute creator rewards (called by leaderboard)
    function distributeCreatorRewards(
        address[] calldata creators,
        uint256[] calldata amounts
    ) external onlyRole(REWARDS_DISTRIBUTOR_ROLE) {
        require(creators.length == amounts.length, "Array length mismatch");
        require(creators.length <= MAX_BATCH_SIZE, "Batch size too large");
        
        for (uint256 i = 0; i < creators.length; i++) {
            if (amounts[i] > 0) {
                pendingCreatorRewards[creators[i]] += amounts[i];
                totalCreatorRewards += amounts[i];
            }
        }
    }

    // Protocol fee distribution (new function)
    function distributeProtocolFees(uint256 amount) external onlyRole(REWARDS_DISTRIBUTOR_ROLE) {
        require(amount > 0, "Amount must be > 0");
        
        // Add to current week's pool
        _checkAndStartNewWeek();
        
        WeeklyRewardCycle storage week = weeklyRewards[currentWeek];
        week.totalRewardPool += amount;
        
        // Split the pool: 60% token stakers, 40% creators
        uint256 tokenStakerAllocation = (amount * 6000) / 10000; // 60%
        uint256 creatorAllocation = amount - tokenStakerAllocation; // 40%
        
        week.tokenStakerPool += tokenStakerAllocation;
        week.creatorPool += creatorAllocation;
        
        // Split token staker pool: 50% base, 50% variable
        week.baseStakerPool += tokenStakerAllocation / 2;
        week.variableStakerPool += tokenStakerAllocation / 2;
    }

    // Emergency functions
    function setEmergencyPause(uint256 pauseUntilTimestamp) external onlyRole(ADMIN_ROLE) {
        emergencyPauseTimestamp = pauseUntilTimestamp;
        emit EmergencyPauseSet(pauseUntilTimestamp);
    }

    function clearEmergencyPause() external onlyRole(ADMIN_ROLE) {
        emergencyPauseTimestamp = 0;
        emit EmergencyPauseSet(0);
    }

    // Admin functions
    function updateContracts(
        address _cardCatalog,
        address _evermarkVoting,
        address _evermarkLeaderboard,
        address _nftStaking
    ) external onlyRole(ADMIN_ROLE) {
        require(_cardCatalog != address(0), "Invalid card catalog");
        require(_evermarkVoting != address(0), "Invalid voting");
        require(_nftStaking != address(0), "Invalid NFT staking");
        
        cardCatalog = ICardCatalog(_cardCatalog);
        evermarkVoting = IEvermarkVoting(_evermarkVoting);
        if (_evermarkLeaderboard != address(0)) {
            evermarkLeaderboard = IEvermarkLeaderboard(_evermarkLeaderboard);
        }
        nftStaking = INFTStaking(_nftStaking);
        
        emit ContractsUpdated(_cardCatalog, _evermarkVoting, _evermarkLeaderboard, _nftStaking);
    }

    function setRewardToken(address _rewardToken) external onlyRole(ADMIN_ROLE) {
        require(_rewardToken != address(0), "Invalid token address");
        rewardToken = IERC20(_rewardToken);
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

    // Get user rewards for specific week
    function getUserWeekRewards(address user, uint256 week) external view returns (
        uint256 baseRewards,
        uint256 variableRewards,
        uint256 nftRewards,
        bool claimed
    ) {
        WeeklyRewardCycle storage weekData = weeklyRewards[week];
        return (
            weekData.userBaseRewards[user],
            weekData.userVariableRewards[user],
            weekData.userNftRewards[user],
            weekData.claimed[user]
        );
    }

    // Get global stats
    function getGlobalStats() external view returns (
        uint256 totalDistributed,
        uint256 totalTokenStaker,
        uint256 totalCreator,
        uint256 totalNftStaker,
        uint256 currentWeekNumber
    ) {
        return (
            totalRewardsDistributed,
            totalTokenStakerRewards,
            totalCreatorRewards,
            totalNftStakerRewards,
            currentWeek
        );
    }

    // Required overrides
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}