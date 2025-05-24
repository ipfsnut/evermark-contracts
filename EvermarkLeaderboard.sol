// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

/*
 ██╗     ███████╗ █████╗ ██████╗ ███████╗██████╗ ██████╗  ██████╗  █████╗ ██████╗ ██████╗ 
 ██║     ██╔════╝██╔══██╗██╔══██╗██╔════╝██╔══██╗██╔══██╗██╔═══██╗██╔══██╗██╔══██╗██╔══██╗
 ██║     █████╗  ███████║██║  ██║█████╗  ██████╔╝██████╔╝██║   ██║███████║██████╔╝██║  ██║
 ██║     ██╔══╝  ██╔══██║██║  ██║██╔══╝  ██╔══██╗██╔══██╗██║   ██║██╔══██║██╔══██╗██║  ██║
 ███████╗███████╗██║  ██║██████╔╝███████╗██║  ██║██████╔╝╚██████╔╝██║  ██║██║  ██║██████╔╝
 ╚══════╝╚══════╝╚═╝  ╚═╝╚═════╝ ╚══════╝╚═╝  ╚═╝╚═════╝  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═════╝ 
*/

interface IEvermarkVoting {
    function getTopBookmarksInCycle(uint256 cycle, uint256 limit) external view returns (
        uint256[] memory bookmarkIds,
        uint256[] memory votes
    );
    function getCurrentCycle() external view returns (uint256);
    function getCycleInfo(uint256 cycle) external view returns (
        uint256 startTime,
        uint256 endTime,
        uint256 totalVotes,
        uint256 totalDelegations,
        bool finalized,
        uint256 activeBookmarksCount
    );
}

interface IEvermarkNFT {
    function getEvermarkCreator(uint256 tokenId) external view returns (address);
    function exists(uint256 tokenId) external view returns (bool);
}

interface IEvermarkRewards {
    function distributeCreatorRewards(address[] calldata creators, uint256[] calldata amounts) external;
}

contract EvermarkLeaderboard is 
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant LEADERBOARD_MANAGER_ROLE = keccak256("LEADERBOARD_MANAGER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    struct LeaderboardEntry {
        uint256 evermarkId;
        address creator;
        uint256 votes;
        uint256 rank;
    }

    struct CycleLeaderboard {
        uint256 cycle;
        uint256 totalParticipants;
        uint256 totalVotes;
        uint256 rewardPool;
        bool finalized;
        uint256 finalizedAt;
        mapping(uint256 => LeaderboardEntry) entries; // rank => entry
        mapping(uint256 => uint256) evermarkRanks; // evermarkId => rank
    }

    // Storage
    IEvermarkVoting public evermarkVoting;
    IEvermarkNFT public evermarkNFT;
    IEvermarkRewards public evermarkRewards;
    
    mapping(uint256 => CycleLeaderboard) public cycleLeaderboards;
    uint256 public currentProcessedCycle;
    
    // Reward configuration
    uint256 public constant TOP_10_REWARD_PERCENTAGE = 7000; // 70% to top 10
    uint256 public constant TOP_50_REWARD_PERCENTAGE = 2000; // 20% to top 11-50
    uint256 public constant PARTICIPATION_REWARD_PERCENTAGE = 1000; // 10% to others
    
    // Events
    event LeaderboardFinalized(uint256 indexed cycle, uint256 totalParticipants, uint256 rewardPool);
    event CreatorRewardsDistributed(uint256 indexed cycle, uint256 totalRewards, uint256 recipientCount);
    event LeaderboardConfigUpdated(address voting, address nft, address rewards);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _evermarkVoting,
        address _evermarkNFT,
        address _evermarkRewards
    ) external initializer {
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(LEADERBOARD_MANAGER_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);

        evermarkVoting = IEvermarkVoting(_evermarkVoting);
        evermarkNFT = IEvermarkNFT(_evermarkNFT);
        evermarkRewards = IEvermarkRewards(_evermarkRewards);
        
        currentProcessedCycle = 0;
    }

    // Finalize leaderboard for a completed cycle
    function finalizeLeaderboard(uint256 cycle) external onlyRole(LEADERBOARD_MANAGER_ROLE) whenNotPaused {
        require(cycle > 0, "Invalid cycle");
        require(!cycleLeaderboards[cycle].finalized, "Already finalized");
        
        // Verify cycle is complete
        (, uint256 endTime, uint256 totalVotes,, bool votingFinalized,) = evermarkVoting.getCycleInfo(cycle);
        require(votingFinalized, "Voting cycle not finalized");
        require(block.timestamp >= endTime, "Cycle not ended");
        
        // Get top evermarks (up to 100)
        (uint256[] memory evermarkIds, uint256[] memory votes) = evermarkVoting.getTopBookmarksInCycle(cycle, 100);
        
        CycleLeaderboard storage leaderboard = cycleLeaderboards[cycle];
        leaderboard.cycle = cycle;
        leaderboard.totalVotes = totalVotes;
        leaderboard.totalParticipants = evermarkIds.length;
        leaderboard.finalized = true;
        leaderboard.finalizedAt = block.timestamp;
        
        // Store leaderboard entries
        for (uint256 i = 0; i < evermarkIds.length; i++) {
            uint256 evermarkId = evermarkIds[i];
            uint256 rank = i + 1;
            
            if (evermarkNFT.exists(evermarkId)) {
                address creator = evermarkNFT.getEvermarkCreator(evermarkId);
                
                leaderboard.entries[rank] = LeaderboardEntry({
                    evermarkId: evermarkId,
                    creator: creator,
                    votes: votes[i],
                    rank: rank
                });
                
                leaderboard.evermarkRanks[evermarkId] = rank;
            }
        }
        
        currentProcessedCycle = cycle;
        emit LeaderboardFinalized(cycle, evermarkIds.length, 0); // rewardPool calculated separately
    }

    // Distribute creator rewards based on leaderboard ranking
    function distributeCreatorRewards(uint256 cycle, uint256 rewardPool) external onlyRole(LEADERBOARD_MANAGER_ROLE) {
        CycleLeaderboard storage leaderboard = cycleLeaderboards[cycle];
        require(leaderboard.finalized, "Leaderboard not finalized");
        require(rewardPool > 0, "No rewards to distribute");
        
        uint256 participantCount = leaderboard.totalParticipants;
        if (participantCount == 0) return;
        
        // Calculate reward distributions
        uint256 top10Pool = (rewardPool * TOP_10_REWARD_PERCENTAGE) / 10000;
        uint256 top50Pool = (rewardPool * TOP_50_REWARD_PERCENTAGE) / 10000;
        uint256 participationPool = rewardPool - top10Pool - top50Pool;
        
        address[] memory creators = new address[](participantCount);
        uint256[] memory amounts = new uint256[](participantCount);
        uint256 recipientCount = 0;
        
        // Distribute rewards by tier
        for (uint256 rank = 1; rank <= participantCount && rank <= 100; rank++) {
            LeaderboardEntry memory entry = leaderboard.entries[rank];
            if (entry.creator == address(0)) continue;
            
            uint256 reward = 0;
            
            if (rank <= 10) {
                // Top 10: Weighted distribution based on votes
                reward = _calculateWeightedReward(top10Pool, entry.votes, _getTierTotalVotes(cycle, 1, 10));
            } else if (rank <= 50) {
                // Rank 11-50: Equal distribution
                uint256 tier2Count = participantCount >= 50 ? 40 : (participantCount - 10);
                reward = tier2Count > 0 ? top50Pool / tier2Count : 0;
            } else {
                // Rank 51+: Equal participation reward
                uint256 tier3Count = participantCount - 50;
                reward = tier3Count > 0 ? participationPool / tier3Count : 0;
            }
            
            if (reward > 0) {
                creators[recipientCount] = entry.creator;
                amounts[recipientCount] = reward;
                recipientCount++;
            }
        }
        
        // Trim arrays to actual size
        address[] memory finalCreators = new address[](recipientCount);
        uint256[] memory finalAmounts = new uint256[](recipientCount);
        
        for (uint256 i = 0; i < recipientCount; i++) {
            finalCreators[i] = creators[i];
            finalAmounts[i] = amounts[i];
        }
        
        // Distribute through rewards contract
        if (recipientCount > 0) {
            evermarkRewards.distributeCreatorRewards(finalCreators, finalAmounts);
            leaderboard.rewardPool = rewardPool;
            emit CreatorRewardsDistributed(cycle, rewardPool, recipientCount);
        }
    }

    // Calculate weighted reward based on votes within a tier
    function _calculateWeightedReward(uint256 tierPool, uint256 userVotes, uint256 tierTotalVotes) internal pure returns (uint256) {
        if (tierTotalVotes == 0) return 0;
        return (tierPool * userVotes) / tierTotalVotes;
    }

    // Get total votes for a specific tier (rank range)
    function _getTierTotalVotes(uint256 cycle, uint256 startRank, uint256 endRank) internal view returns (uint256) {
        uint256 total = 0;
        CycleLeaderboard storage leaderboard = cycleLeaderboards[cycle];
        
        for (uint256 rank = startRank; rank <= endRank && rank <= leaderboard.totalParticipants; rank++) {
            total += leaderboard.entries[rank].votes;
        }
        
        return total;
    }

    // View functions
    function getLeaderboard(uint256 cycle, uint256 limit) external view returns (LeaderboardEntry[] memory) {
        CycleLeaderboard storage leaderboard = cycleLeaderboards[cycle];
        require(leaderboard.finalized, "Leaderboard not finalized");
        
        uint256 count = limit > leaderboard.totalParticipants ? leaderboard.totalParticipants : limit;
        LeaderboardEntry[] memory entries = new LeaderboardEntry[](count);
        
        for (uint256 i = 0; i < count; i++) {
            entries[i] = leaderboard.entries[i + 1]; // ranks start at 1
        }
        
        return entries;
    }

    function getEvermarkRank(uint256 cycle, uint256 evermarkId) external view returns (uint256) {
        return cycleLeaderboards[cycle].evermarkRanks[evermarkId];
    }

    function getCycleStats(uint256 cycle) external view returns (
        uint256 totalParticipants,
        uint256 totalVotes,
        uint256 rewardPool,
        bool finalized,
        uint256 finalizedAt
    ) {
        CycleLeaderboard storage leaderboard = cycleLeaderboards[cycle];
        return (
            leaderboard.totalParticipants,
            leaderboard.totalVotes,
            leaderboard.rewardPool,
            leaderboard.finalized,
            leaderboard.finalizedAt
        );
    }

    function isLeaderboardFinalized(uint256 cycle) external view returns (bool) {
        return cycleLeaderboards[cycle].finalized;
    }

    // Admin functions
    function updateContracts(
        address _evermarkVoting,
        address _evermarkNFT, 
        address _evermarkRewards
    ) external onlyRole(ADMIN_ROLE) {
        require(_evermarkVoting != address(0), "Invalid voting address");
        require(_evermarkNFT != address(0), "Invalid NFT address");
        require(_evermarkRewards != address(0), "Invalid rewards address");
        
        evermarkVoting = IEvermarkVoting(_evermarkVoting);
        evermarkNFT = IEvermarkNFT(_evermarkNFT);
        evermarkRewards = IEvermarkRewards(_evermarkRewards);
        
        emit LeaderboardConfigUpdated(_evermarkVoting, _evermarkNFT, _evermarkRewards);
    }

    function grantLeaderboardManagerRole(address manager) external onlyRole(ADMIN_ROLE) {
        grantRole(LEADERBOARD_MANAGER_ROLE, manager);
    }

    function revokeLeaderboardManagerRole(address manager) external onlyRole(ADMIN_ROLE) {
        revokeRole(LEADERBOARD_MANAGER_ROLE, manager);
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // Emergency functions
    function emergencyFinalizeLeaderboard(uint256 cycle) external onlyRole(ADMIN_ROLE) {
        finalizeLeaderboard(cycle);
    }

    // Required overrides
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}