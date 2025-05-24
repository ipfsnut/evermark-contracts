// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

/*
 ███╗   ██╗███████╗████████╗    ███████╗████████╗ █████╗ ██╗  ██╗██╗███╗   ██╗ ██████╗ 
 ████╗  ██║██╔════╝╚══██╔══╝    ██╔════╝╚══██╔══╝██╔══██╗██║ ██╔╝██║████╗  ██║██╔════╝ 
 ██╔██╗ ██║█████╗     ██║       ███████╗   ██║   ███████║█████╔╝ ██║██╔██╗ ██║██║  ███╗
 ██║╚██╗██║██╔══╝     ██║       ╚════██║   ██║   ██╔══██║██╔═██╗ ██║██║╚██╗██║██║   ██║
 ██║ ╚████║██║        ██║       ███████║   ██║   ██║  ██║██║  ██╗██║██║ ╚████║╚██████╔╝
 ╚═╝  ╚═══╝╚═╝        ╚═╝       ╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝ ╚═════╝ 
*/

interface IEvermarkVoting {
    function getBookmarkVotesInCycle(uint256 cycle, uint256 bookmarkId) external view returns (uint256);
    function getCurrentCycle() external view returns (uint256);
}

interface IEvermarkRewards {
    function distributeNftStakingRewards(address[] calldata users, uint256[] calldata amounts) external;
}

contract NFTStaking is 
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    ERC721Holder
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant REWARDS_MANAGER_ROLE = keccak256("REWARDS_MANAGER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // Lock periods in seconds
    uint256 public constant LOCK_PERIOD_7_DAYS = 7 days;
    uint256 public constant LOCK_PERIOD_14_DAYS = 14 days; 
    uint256 public constant LOCK_PERIOD_30_DAYS = 30 days;

    // Base reward rate (tokens per vote per week)
    uint256 public constant BASE_REWARD_PER_VOTE = 1e15; // 0.001 tokens per vote

    struct StakedNFT {
        address owner;
        uint256 stakedAt;
        uint256 lockPeriod;
        uint256 lastRewardCycle;
        uint256 accumulatedRewards;
        bool active;
    }

    struct RewardCycle {
        uint256 cycle;
        uint256 totalVotes;
        uint256 rewardMultiplier;
        bool processed;
    }

    // Storage
    IERC721 public evermarkNFT;
    IEvermarkVoting public evermarkVoting;
    IEvermarkRewards public evermarkRewards;
    
    // NFT staking data
    mapping(uint256 => StakedNFT) public stakedNFTs;
    mapping(address => uint256[]) public userStakedNFTs;
    
    // Reward tracking
    mapping(uint256 => mapping(uint256 => uint256)) public nftVotesPerCycle; // cycle => tokenId => votes
    mapping(uint256 => RewardCycle) public rewardCycles;
    
    // Global stats
    uint256 public totalStakedNFTs;
    uint256 public totalRewardsDistributed;
    uint256 public currentCycle;
    
    // Events
    event NFTStaked(address indexed owner, uint256 indexed tokenId, uint256 lockPeriod);
    event NFTUnstaked(address indexed owner, uint256 indexed tokenId, uint256 rewards);
    event RewardsCalculated(uint256 indexed cycle, uint256 totalNFTs, uint256 totalRewards);
    event RewardsClaimed(address indexed user, uint256[] tokenIds, uint256 totalRewards);
    event VotesRecorded(uint256 indexed cycle, uint256 indexed tokenId, uint256 votes);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _evermarkNFT,
        address _evermarkVoting,
        address _evermarkRewards
    ) external initializer {
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(REWARDS_MANAGER_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);

        evermarkNFT = IERC721(_evermarkNFT);
        evermarkVoting = IEvermarkVoting(_evermarkVoting);
        evermarkRewards = IEvermarkRewards(_evermarkRewards);
        
        currentCycle = 1;
    }

    // Stake NFT with lock period selection
    function stakeNFT(uint256 tokenId, uint256 lockPeriod) external whenNotPaused nonReentrant {
        require(
            lockPeriod == LOCK_PERIOD_7_DAYS || 
            lockPeriod == LOCK_PERIOD_14_DAYS ||
            lockPeriod == LOCK_PERIOD_30_DAYS,
            "Invalid lock period"
        );
        require(evermarkNFT.ownerOf(tokenId) == msg.sender, "Not the owner");
        require(!stakedNFTs[tokenId].active, "NFT already staked");

        // Transfer NFT to contract
        evermarkNFT.transferFrom(msg.sender, address(this), tokenId);

        // Record staking data
        stakedNFTs[tokenId] = StakedNFT({
            owner: msg.sender,
            stakedAt: block.timestamp,
            lockPeriod: lockPeriod,
            lastRewardCycle: currentCycle,
            accumulatedRewards: 0,
            active: true
        });

        // Track user's staked NFTs
        userStakedNFTs[msg.sender].push(tokenId);
        totalStakedNFTs++;

        emit NFTStaked(msg.sender, tokenId, lockPeriod);
    }

    // Batch stake multiple NFTs
    function batchStakeNFTs(uint256[] calldata tokenIds, uint256 lockPeriod) external whenNotPaused nonReentrant {
        require(tokenIds.length > 0 && tokenIds.length <= 20, "Invalid batch size");
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            require(evermarkNFT.ownerOf(tokenId) == msg.sender, "Not the owner");
            require(!stakedNFTs[tokenId].active, "NFT already staked");

            // Transfer NFT to contract
            evermarkNFT.transferFrom(msg.sender, address(this), tokenId);

            // Record staking data
            stakedNFTs[tokenId] = StakedNFT({
                owner: msg.sender,
                stakedAt: block.timestamp,
                lockPeriod: lockPeriod,
                lastRewardCycle: currentCycle,
                accumulatedRewards: 0,
                active: true
            });

            userStakedNFTs[msg.sender].push(tokenId);
            emit NFTStaked(msg.sender, tokenId, lockPeriod);
        }
        
        totalStakedNFTs += tokenIds.length;
    }

    // Unstake NFT after lock period
    function unstakeNFT(uint256 tokenId) external whenNotPaused nonReentrant {
        StakedNFT storage stakedNFT = stakedNFTs[tokenId];
        require(stakedNFT.active, "NFT not staked");
        require(stakedNFT.owner == msg.sender, "Not the owner");
        
        uint256 timeStaked = block.timestamp - stakedNFT.stakedAt;
        require(timeStaked >= stakedNFT.lockPeriod, "Lock period not complete");

        // Calculate and claim any pending rewards
        uint256 pendingRewards = calculatePendingRewards(tokenId);
        uint256 totalRewards = stakedNFT.accumulatedRewards + pendingRewards;

        // Mark as inactive
        stakedNFT.active = false;
        
        // Remove from user's staked list
        _removeFromUserStakedList(msg.sender, tokenId);
        totalStakedNFTs--;

        // Transfer NFT back to owner
        evermarkNFT.transferFrom(address(this), msg.sender, tokenId);

        emit NFTUnstaked(msg.sender, tokenId, totalRewards);
    }

    // Calculate rewards based on votes received in previous cycles
    function calculatePendingRewards(uint256 tokenId) public view returns (uint256) {
        StakedNFT memory stakedNFT = stakedNFTs[tokenId];
        if (!stakedNFT.active) return 0;

        uint256 rewards = 0;
        uint256 cycleToProcess = stakedNFT.lastRewardCycle;
        uint256 latestCycle = currentCycle > 1 ? currentCycle - 1 : 1;

        // Calculate rewards for completed cycles
        for (uint256 cycle = cycleToProcess; cycle <= latestCycle; cycle++) {
            uint256 votes = nftVotesPerCycle[cycle][tokenId];
            if (votes > 0) {
                uint256 baseReward = votes * BASE_REWARD_PER_VOTE;
                uint256 multiplier = _getMultiplier(stakedNFT.lockPeriod);
                rewards += (baseReward * multiplier) / 100;
            }
        }

        return rewards;
    }

    // Calculate projected rewards for next cycle
    function calculateProjectedRewards(uint256 tokenId) external view returns (uint256) {
        StakedNFT memory stakedNFT = stakedNFTs[tokenId];
        if (!stakedNFT.active) return 0;

        // Get votes from previous cycle to project
        uint256 previousCycle = currentCycle > 1 ? currentCycle - 1 : 1;
        uint256 lastCycleVotes = nftVotesPerCycle[previousCycle][tokenId];
        
        if (lastCycleVotes > 0) {
            uint256 baseReward = lastCycleVotes * BASE_REWARD_PER_VOTE;
            uint256 multiplier = _getMultiplier(stakedNFT.lockPeriod);
            return (baseReward * multiplier) / 100;
        }
        
        return 0;
    }

    // Get lock period multiplier
    function _getMultiplier(uint256 lockPeriod) internal pure returns (uint256) {
        if (lockPeriod == LOCK_PERIOD_30_DAYS) return 300; // 3x
        if (lockPeriod == LOCK_PERIOD_14_DAYS) return 200; // 2x  
        if (lockPeriod == LOCK_PERIOD_7_DAYS) return 150;  // 1.5x
        return 100; // 1x (fallback)
    }

    // Record votes for NFTs (called by voting contract or admin)
    function recordVotesForCycle(
        uint256 cycle,
        uint256[] calldata tokenIds,
        uint256[] calldata votes
    ) external onlyRole(REWARDS_MANAGER_ROLE) {
        require(tokenIds.length == votes.length, "Array length mismatch");
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (stakedNFTs[tokenIds[i]].active) {
                nftVotesPerCycle[cycle][tokenIds[i]] = votes[i];
                emit VotesRecorded(cycle, tokenIds[i], votes[i]);
            }
        }
    }

    // Batch update votes from voting contract
    function syncVotesFromVotingContract(uint256 cycle, uint256[] calldata tokenIds) external {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            if (stakedNFTs[tokenId].active) {
                uint256 votes = evermarkVoting.getBookmarkVotesInCycle(cycle, tokenId);
                nftVotesPerCycle[cycle][tokenId] = votes;
                emit VotesRecorded(cycle, tokenId, votes);
            }
        }
    }

    // Claim accumulated rewards for multiple NFTs
    function claimRewards(uint256[] calldata tokenIds) external whenNotPaused nonReentrant {
        require(tokenIds.length > 0, "No tokens specified");
        
        uint256 totalRewards = 0;
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            StakedNFT storage stakedNFT = stakedNFTs[tokenId];
            
            require(stakedNFT.active, "NFT not staked");
            require(stakedNFT.owner == msg.sender, "Not the owner");
            
            uint256 pendingRewards = calculatePendingRewards(tokenId);
            if (pendingRewards > 0) {
                stakedNFT.accumulatedRewards += pendingRewards;
                stakedNFT.lastRewardCycle = currentCycle;
                totalRewards += pendingRewards;
            }
        }
        
        require(totalRewards > 0, "No rewards to claim");
        
        // Note: In production, this would mint or transfer reward tokens
        // For now, we just emit the event and update internal accounting
        totalRewardsDistributed += totalRewards;
        
        emit RewardsClaimed(msg.sender, tokenIds, totalRewards);
    }

    // Get user's staked NFTs and their status
    function getUserStakedNFTs(address user) external view returns (
        uint256[] memory tokenIds,
        uint256[] memory stakedTimes,
        uint256[] memory lockPeriods,
        uint256[] memory pendingRewards,
        bool[] memory canUnstake
    ) {
        uint256[] memory userTokens = userStakedNFTs[user];
        uint256 activeCount = 0;
        
        // Count active stakes
        for (uint256 i = 0; i < userTokens.length; i++) {
            if (stakedNFTs[userTokens[i]].active) {
                activeCount++;
            }
        }
        
        // Prepare return arrays
        tokenIds = new uint256[](activeCount);
        stakedTimes = new uint256[](activeCount);
        lockPeriods = new uint256[](activeCount);
        pendingRewards = new uint256[](activeCount);
        canUnstake = new bool[](activeCount);
        
        uint256 index = 0;
        for (uint256 i = 0; i < userTokens.length; i++) {
            uint256 tokenId = userTokens[i];
            StakedNFT memory stakedNFT = stakedNFTs[tokenId];
            
            if (stakedNFT.active) {
                tokenIds[index] = tokenId;
                stakedTimes[index] = stakedNFT.stakedAt;
                lockPeriods[index] = stakedNFT.lockPeriod;
                pendingRewards[index] = calculatePendingRewards(tokenId);
                canUnstake[index] = (block.timestamp - stakedNFT.stakedAt) >= stakedNFT.lockPeriod;
                index++;
            }
        }
    }

    // Get staking statistics
    function getStakingStats() external view returns (
        uint256 totalStaked,
        uint256 totalRewards,
        uint256 currentCycleNumber,
        uint256 averageRewardPerNFT
    ) {
        totalStaked = totalStakedNFTs;
        totalRewards = totalRewardsDistributed;
        currentCycleNumber = currentCycle;
        averageRewardPerNFT = totalStakedNFTs > 0 ? totalRewardsDistributed / totalStakedNFTs : 0;
    }

    // Remove NFT from user's staked list
    function _removeFromUserStakedList(address user, uint256 tokenId) internal {
        uint256[] storage userTokens = userStakedNFTs[user];
        for (uint256 i = 0; i < userTokens.length; i++) {
            if (userTokens[i] == tokenId) {
                userTokens[i] = userTokens[userTokens.length - 1];
                userTokens.pop();
                break;
            }
        }
    }

    // Admin functions
    function updateCurrentCycle(uint256 newCycle) external onlyRole(ADMIN_ROLE) {
        require(newCycle > currentCycle, "Cycle must be greater than current");
        currentCycle = newCycle;
    }

    function setEvermarkVoting(address _evermarkVoting) external onlyRole(ADMIN_ROLE) {
        require(_evermarkVoting != address(0), "Invalid address");
        evermarkVoting = IEvermarkVoting(_evermarkVoting);
    }

    function setEvermarkRewards(address _evermarkRewards) external onlyRole(ADMIN_ROLE) {
        require(_evermarkRewards != address(0), "Invalid address");
        evermarkRewards = IEvermarkRewards(_evermarkRewards);
    }

    function grantRewardsManagerRole(address manager) external onlyRole(ADMIN_ROLE) {
        grantRole(REWARDS_MANAGER_ROLE, manager);
    }

    function revokeRewardsManagerRole(address manager) external onlyRole(ADMIN_ROLE) {
        revokeRole(REWARDS_MANAGER_ROLE, manager);
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // Emergency NFT recovery
    function emergencyUnstakeNFT(uint256 tokenId, address owner) external onlyRole(ADMIN_ROLE) {
        require(stakedNFTs[tokenId].active, "NFT not staked");
        
        stakedNFTs[tokenId].active = false;
        _removeFromUserStakedList(stakedNFTs[tokenId].owner, tokenId);
        totalStakedNFTs--;
        
        evermarkNFT.transferFrom(address(this), owner, tokenId);
    }

    // Required overrides
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}