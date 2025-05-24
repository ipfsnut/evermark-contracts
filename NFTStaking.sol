// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/*
 ███╗   ██╗███████╗████████╗    ███████╗████████╗ █████╗ ██╗  ██╗██╗███╗   ██╗ ██████╗ 
 ████╗  ██║██╔════╝╚══██╔══╝    ██╔════╝╚══██╔══╝██╔══██╗██║ ██╔╝██║████╗  ██║██╔════╝ 
 ██╔██╗ ██║█████╗     ██║       ███████╗   ██║   ███████║█████╔╝ ██║██╔██╗ ██║██║  ███╗
 ██║╚██╗██║██╔══╝     ██║       ╚════██║   ██║   ██╔══██║██╔═██╗ ██║██║╚██╗██║██║   ██║
 ██║ ╚████║██║        ██║       ███████║   ██║   ██║  ██║██║  ██╗██║██║ ╚████║╚██████╔╝
 ╚═╝  ╚═══╝╚═╝        ╚═╝       ╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝ ╚═════╝ 
*/

interface IEvermarkVoting {
    function getEvermarkVotesInCycle(uint256 cycle, uint256 evermarkId) external view returns (uint256);
    function getCurrentCycle() external view returns (uint256);
}

interface IEvermarkNFT {
    function getEvermarkCreator(uint256 tokenId) external view returns (address);
    function exists(uint256 tokenId) external view returns (bool);
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

    struct StakedNFT {
        address owner;
        uint256 stakedAt;
        uint256 lockPeriod;
        uint256 lastRewardCycle;
        uint256 accumulatedRewards;
        bool active;
    }

    // Storage
    IERC721 public evermarkNFT;
    IEvermarkVoting public evermarkVoting;
    IEvermarkNFT public evermarkNFTInterface;
    IERC20 public rewardToken; // EMARK token
    
    // NFT staking data
    mapping(uint256 => StakedNFT) public stakedNFTs;
    mapping(address => uint256[]) public userStakedNFTs;
    
    // Reward tracking per week/cycle
    mapping(uint256 => mapping(uint256 => uint256)) public nftVotesPerCycle; // cycle => tokenId => votes
    mapping(address => uint256) public pendingRewards;
    
    // Global stats
    uint256 public totalStakedNFTs;
    uint256 public totalRewardsDistributed;
    uint256 public currentCycle;
    
    // Events
    event NFTStaked(address indexed owner, uint256 indexed tokenId, uint256 lockPeriod);
    event NFTUnstaked(address indexed owner, uint256 indexed tokenId, uint256 rewards);
    event RewardsClaimed(address indexed user, uint256[] tokenIds, uint256 totalRewards);
    event VotesRecorded(uint256 indexed cycle, uint256 indexed tokenId, uint256 votes);
    event RewardsDistributed(address[] users, uint256[] amounts, uint256 totalDistributed);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _evermarkNFT,
        address _evermarkVoting,
        address _evermarkNFTInterface,
        address _rewardToken
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
        evermarkNFTInterface = IEvermarkNFT(_evermarkNFTInterface);
        rewardToken = IERC20(_rewardToken);
        
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
        require(evermarkNFTInterface.exists(tokenId), "NFT does not exist");

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

        // Calculate and add any pending rewards
        uint256 pendingRewardsAmount = calculatePendingRewards(tokenId);
        uint256 totalRewards = stakedNFT.accumulatedRewards + pendingRewardsAmount;

        // Mark as inactive
        stakedNFT.active = false;
        
        // Remove from user's staked list
        _removeFromUserStakedList(msg.sender, tokenId);
        totalStakedNFTs--;

        // Add rewards to user's pending balance
        if (totalRewards > 0) {
            pendingRewards[msg.sender] += totalRewards;
        }

        // Transfer NFT back to owner
        evermarkNFT.transferFrom(address(this), msg.sender, tokenId);

        emit NFTUnstaked(msg.sender, tokenId, totalRewards);
    }

    // Calculate pending rewards based on votes received
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
                // Base reward calculation (simplified)
                uint256 baseReward = votes * 1e15; // 0.001 EMARK per vote
                uint256 multiplier = _getMultiplier(stakedNFT.lockPeriod);
                rewards += (baseReward * multiplier) / 100;
            }
        }

        return rewards;
    }

    // Get lock period multiplier
    function _getMultiplier(uint256 lockPeriod) internal pure returns (uint256) {
        if (lockPeriod == LOCK_PERIOD_30_DAYS) return 300; // 3x
        if (lockPeriod == LOCK_PERIOD_14_DAYS) return 200; // 2x  
        if (lockPeriod == LOCK_PERIOD_7_DAYS) return 150;  // 1.5x
        return 100; // 1x (fallback)
    }

    // Sync votes from voting contract for a specific cycle
    function syncVotesFromVotingContract(uint256 cycle, uint256[] calldata tokenIds) external {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            if (stakedNFTs[tokenId].active) {
                uint256 votes = evermarkVoting.getEvermarkVotesInCycle(cycle, tokenId);
                nftVotesPerCycle[cycle][tokenId] = votes;
                emit VotesRecorded(cycle, tokenId, votes);
            }
        }
    }

    // Manual vote recording (for admin/rewards manager)
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

    // Claim all pending rewards
    function claimRewards() external whenNotPaused nonReentrant returns (uint256) {
        address user = msg.sender;
        uint256 totalRewards = pendingRewards[user];
        
        // Add any unclaimed staking rewards
        uint256[] memory userTokens = userStakedNFTs[user];
        for (uint256 i = 0; i < userTokens.length; i++) {
            uint256 tokenId = userTokens[i];
            if (stakedNFTs[tokenId].active && stakedNFTs[tokenId].owner == user) {
                uint256 pending = calculatePendingRewards(tokenId);
                if (pending > 0) {
                    stakedNFTs[tokenId].accumulatedRewards += pending;
                    stakedNFTs[tokenId].lastRewardCycle = currentCycle;
                    totalRewards += pending;
                }
            }
        }
        
        require(totalRewards > 0, "No rewards to claim");
        
        // Reset pending rewards
        pendingRewards[user] = 0;
        
        // Update tracking
        totalRewardsDistributed += totalRewards;
        
        // Transfer EMARK tokens
        require(rewardToken.transfer(user, totalRewards), "Reward transfer failed");
        
        emit RewardsClaimed(user, userTokens, totalRewards);
        return totalRewards;
    }

    // Distribute rewards to users (called by EvermarkRewards contract)
    function distributeRewards(
        address[] calldata users,
        uint256[] calldata amounts
    ) external onlyRole(REWARDS_MANAGER_ROLE) {
        require(users.length == amounts.length, "Array length mismatch");
        
        uint256 totalDistributed = 0;
        for (uint256 i = 0; i < users.length; i++) {
            if (amounts[i] > 0) {
                pendingRewards[users[i]] += amounts[i];
                totalDistributed += amounts[i];
            }
        }
        
        emit RewardsDistributed(users, amounts, totalDistributed);
    }

    // Get user's staked NFTs and their status
    function getUserStakedNFTs(address user) external view returns (
        uint256[] memory tokenIds,
        uint256[] memory stakedTimes,
        uint256[] memory lockPeriods,
        uint256[] memory pendingRewardsAmounts,
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
        pendingRewardsAmounts = new uint256[](activeCount);
        canUnstake = new bool[](activeCount);
        
        uint256 index = 0;
        for (uint256 i = 0; i < userTokens.length; i++) {
            uint256 tokenId = userTokens[i];
            StakedNFT memory stakedNFT = stakedNFTs[tokenId];
            
            if (stakedNFT.active) {
                tokenIds[index] = tokenId;
                stakedTimes[index] = stakedNFT.stakedAt;
                lockPeriods[index] = stakedNFT.lockPeriod;
                pendingRewardsAmounts[index] = calculatePendingRewards(tokenId);
                canUnstake[index] = (block.timestamp - stakedNFT.stakedAt) >= stakedNFT.lockPeriod;
                index++;
            }
        }
    }

    // Get user's total pending rewards (including from pending balance)
    function getUserTotalPendingRewards(address user) external view returns (uint256) {
        uint256 total = pendingRewards[user];
        
        uint256[] memory userTokens = userStakedNFTs[user];
        for (uint256 i = 0; i < userTokens.length; i++) {
            uint256 tokenId = userTokens[i];
            if (stakedNFTs[tokenId].active && stakedNFTs[tokenId].owner == user) {
                total += calculatePendingRewards(tokenId);
            }
        }
        
        return total;
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

    function setRewardToken(address _rewardToken) external onlyRole(ADMIN_ROLE) {
        require(_rewardToken != address(0), "Invalid token address");
        rewardToken = IERC20(_rewardToken);
    }

    function setContracts(
        address _evermarkVoting,
        address _evermarkNFTInterface
    ) external onlyRole(ADMIN_ROLE) {
        require(_evermarkVoting != address(0), "Invalid voting address");
        require(_evermarkNFTInterface != address(0), "Invalid NFT interface address");
        
        evermarkVoting = IEvermarkVoting(_evermarkVoting);
        evermarkNFTInterface = IEvermarkNFT(_evermarkNFTInterface);
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // Emergency functions
    function emergencyWithdrawTokens(uint256 amount, address recipient) external onlyRole(ADMIN_ROLE) {
        require(recipient != address(0), "Invalid recipient");
        require(amount <= rewardToken.balanceOf(address(this)), "Insufficient balance");
        
        rewardToken.transfer(recipient, amount);
    }

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