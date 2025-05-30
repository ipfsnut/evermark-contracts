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

    // Simplified cycle data - no nested mappings
    struct CycleData {
        uint256 cycle;
        uint256 totalParticipants;
        uint256 totalVotes;
        uint256 rewardPool;
        bool finalized;
        uint256 finalizedAt;
    }

    // Constants
    uint256 public constant MAX_LEADERBOARD_SIZE = 50; // Reduced from 100
    uint256 public constant MAX_BATCH_SIZE = 20; // Reduced from 50

    // Storage - simplified
    IEvermarkVoting public evermarkVoting;
    IEvermarkNFT public evermarkNFT;
    IEvermarkRewards public evermarkRewards;
    
    mapping(uint256 => CycleData) public cycleData;
    mapping(uint256 => mapping(uint256 => LeaderboardEntry)) public leaderboardEntries; // cycle => rank => entry
    mapping(uint256 => mapping(uint256 => uint256)) public evermarkRanks; // cycle => evermarkId => rank
    
    uint256 public currentProcessedCycle;
    uint256 public emergencyPauseTimestamp;
    
    // Events
    event LeaderboardFinalized(uint256 indexed cycle, uint256 totalParticipants);
    event CreatorRewardsDistributed(uint256 indexed cycle, uint256 totalRewards, uint256 recipientCount);
    event LeaderboardConfigUpdated(address voting, address nft, address rewards);
    event EmergencyPauseSet(uint256 timestamp);

    modifier notInEmergency() {
        require(block.timestamp > emergencyPauseTimestamp, "Emergency pause active");
        _;
    }

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
        if (_evermarkRewards != address(0)) {
            evermarkRewards = IEvermarkRewards(_evermarkRewards);
        }
        
        currentProcessedCycle = 0;
        emergencyPauseTimestamp = 0;
    }

    // Simplified finalize function
    function finalizeLeaderboard(uint256 cycle) external onlyRole(LEADERBOARD_MANAGER_ROLE) whenNotPaused notInEmergency {
        require(cycle > 0, "Invalid cycle");
        require(!cycleData[cycle].finalized, "Already finalized");
        
        // Get voting data
        (, uint256 endTime, uint256 totalVotes,, bool votingFinalized,) = evermarkVoting.getCycleInfo(cycle);
        require(votingFinalized, "Voting cycle not finalized");
        require(block.timestamp >= endTime, "Cycle not ended");
        
        // Get top evermarks
        (uint256[] memory evermarkIds, uint256[] memory votes) = evermarkVoting.getTopBookmarksInCycle(cycle, MAX_LEADERBOARD_SIZE);
        
        // Store cycle data
        cycleData[cycle] = CycleData({
            cycle: cycle,
            totalParticipants: evermarkIds.length,
            totalVotes: totalVotes,
            rewardPool: 0,
            finalized: true,
            finalizedAt: block.timestamp
        });
        
        // Store entries one by one to avoid stack depth
        for (uint256 i = 0; i < evermarkIds.length; i++) {
            _storeEntry(cycle, evermarkIds[i], votes[i], i + 1);
        }
        
        currentProcessedCycle = cycle;
        emit LeaderboardFinalized(cycle, evermarkIds.length);
    }

    // Simple helper to store single entry
    function _storeEntry(uint256 cycle, uint256 evermarkId, uint256 voteCount, uint256 rank) internal {
        if (evermarkNFT.exists(evermarkId)) {
            address creator = evermarkNFT.getEvermarkCreator(evermarkId);
            
            leaderboardEntries[cycle][rank] = LeaderboardEntry({
                evermarkId: evermarkId,
                creator: creator,
                votes: voteCount,
                rank: rank
            });
            
            evermarkRanks[cycle][evermarkId] = rank;
        }
    }

    // Simplified reward distribution - no complex batching
    function distributeCreatorRewards(uint256 cycle, uint256 rewardPool) external onlyRole(LEADERBOARD_MANAGER_ROLE) notInEmergency {
        require(cycleData[cycle].finalized, "Leaderboard not finalized");
        require(rewardPool > 0, "No rewards to distribute");
        
        uint256 participantCount = cycleData[cycle].totalParticipants;
        if (participantCount == 0) return;
        
        // Simple distribution: equal rewards for top 10, then smaller amounts for others
        uint256 top10Reward = (rewardPool * 70) / 100; // 70% for top 10
        uint256 otherReward = rewardPool - top10Reward; // 30% for others
        
        uint256 top10Count = participantCount > 10 ? 10 : participantCount;
        uint256 otherCount = participantCount > 10 ? participantCount - 10 : 0;
        
        uint256 rewardPerTop10 = top10Count > 0 ? top10Reward / top10Count : 0;
        uint256 rewardPerOther = otherCount > 0 ? otherReward / otherCount : 0;
        
        // Distribute in small batches
        _distributeInBatches(cycle, rewardPerTop10, rewardPerOther, participantCount);
        
        cycleData[cycle].rewardPool = rewardPool;
        emit CreatorRewardsDistributed(cycle, rewardPool, participantCount);
    }

    // Simple batch distribution
    function _distributeInBatches(uint256 cycle, uint256 top10Reward, uint256 otherReward, uint256 totalCount) internal {
        if (address(evermarkRewards) == address(0)) return;
        
        uint256 batchSize = 10; // Small batches
        
        for (uint256 start = 1; start <= totalCount; start += batchSize) {
            uint256 end = start + batchSize - 1;
            if (end > totalCount) end = totalCount;
            
            _processSingleBatch(cycle, start, end, top10Reward, otherReward);
        }
    }

    // Process single batch - minimal variables
    function _processSingleBatch(uint256 cycle, uint256 startRank, uint256 endRank, uint256 top10Reward, uint256 otherReward) internal {
        uint256 batchSize = endRank - startRank + 1;
        address[] memory creators = new address[](batchSize);
        uint256[] memory amounts = new uint256[](batchSize);
        uint256 count = 0;
        
        for (uint256 rank = startRank; rank <= endRank; rank++) {
            LeaderboardEntry memory entry = leaderboardEntries[cycle][rank];
            if (entry.creator != address(0)) {
                creators[count] = entry.creator;
                amounts[count] = rank <= 10 ? top10Reward : otherReward;
                count++;
            }
        }
        
        if (count > 0) {
            // Trim arrays
            address[] memory finalCreators = new address[](count);
            uint256[] memory finalAmounts = new uint256[](count);
            
            for (uint256 i = 0; i < count; i++) {
                finalCreators[i] = creators[i];
                finalAmounts[i] = amounts[i];
            }
            
            try evermarkRewards.distributeCreatorRewards(finalCreators, finalAmounts) {
                // Success
            } catch {
                // Failed but continue
            }
        }
    }

    // Simple view functions
    function getLeaderboard(uint256 cycle, uint256 limit) external view returns (LeaderboardEntry[] memory) {
        require(cycleData[cycle].finalized, "Leaderboard not finalized");
        
        uint256 maxLimit = limit > MAX_LEADERBOARD_SIZE ? MAX_LEADERBOARD_SIZE : limit;
        uint256 count = maxLimit > cycleData[cycle].totalParticipants ? cycleData[cycle].totalParticipants : maxLimit;
        
        LeaderboardEntry[] memory entries = new LeaderboardEntry[](count);
        
        for (uint256 i = 0; i < count; i++) {
            entries[i] = leaderboardEntries[cycle][i + 1];
        }
        
        return entries;
    }

    function getLeaderboardEntry(uint256 cycle, uint256 rank) external view returns (LeaderboardEntry memory) {
        require(cycleData[cycle].finalized, "Leaderboard not finalized");
        return leaderboardEntries[cycle][rank];
    }

    function getEvermarkRank(uint256 cycle, uint256 evermarkId) external view returns (uint256) {
        return evermarkRanks[cycle][evermarkId];
    }

    function getCycleStats(uint256 cycle) external view returns (
        uint256 totalParticipants,
        uint256 totalVotes,
        uint256 rewardPool,
        bool finalized,
        uint256 finalizedAt
    ) {
        CycleData memory data = cycleData[cycle];
        return (data.totalParticipants, data.totalVotes, data.rewardPool, data.finalized, data.finalizedAt);
    }

    function isLeaderboardFinalized(uint256 cycle) external view returns (bool) {
        return cycleData[cycle].finalized;
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
        address _evermarkVoting,
        address _evermarkNFT, 
        address _evermarkRewards
    ) external onlyRole(ADMIN_ROLE) {
        require(_evermarkVoting != address(0), "Invalid voting address");
        require(_evermarkNFT != address(0), "Invalid NFT address");
        
        evermarkVoting = IEvermarkVoting(_evermarkVoting);
        evermarkNFT = IEvermarkNFT(_evermarkNFT);
        if (_evermarkRewards != address(0)) {
            evermarkRewards = IEvermarkRewards(_evermarkRewards);
        }
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

    // Emergency finalization
    function emergencyFinalizeLeaderboard(uint256 cycle) external onlyRole(ADMIN_ROLE) {
        require(!cycleData[cycle].finalized, "Already finalized");
        
        cycleData[cycle] = CycleData({
            cycle: cycle,
            totalParticipants: 0,
            totalVotes: 0,
            rewardPool: 0,
            finalized: true,
            finalizedAt: block.timestamp
        });
        
        emit LeaderboardFinalized(cycle, 0);
    }

    // Get top N entries with simple logic
    function getTopEntries(uint256 cycle, uint256 count) external view returns (LeaderboardEntry[] memory) {
        require(cycleData[cycle].finalized, "Leaderboard not finalized");
        
        uint256 maxCount = count > cycleData[cycle].totalParticipants ? cycleData[cycle].totalParticipants : count;
        maxCount = maxCount > MAX_BATCH_SIZE ? MAX_BATCH_SIZE : maxCount;
        
        LeaderboardEntry[] memory entries = new LeaderboardEntry[](maxCount);
        
        for (uint256 i = 0; i < maxCount; i++) {
            entries[i] = leaderboardEntries[cycle][i + 1];
        }
        
        return entries;
    }

    // Simple paginated view
    function getLeaderboardPage(uint256 cycle, uint256 page, uint256 pageSize) external view returns (
        LeaderboardEntry[] memory entries,
        uint256 totalPages,
        uint256 totalEntries
    ) {
        require(cycleData[cycle].finalized, "Leaderboard not finalized");
        require(pageSize <= MAX_BATCH_SIZE, "Page size too large");
        require(page > 0, "Page must be > 0");
        
        totalEntries = cycleData[cycle].totalParticipants;
        totalPages = (totalEntries + pageSize - 1) / pageSize; // Ceiling division
        
        if (page > totalPages) {
            return (new LeaderboardEntry[](0), totalPages, totalEntries);
        }
        
        uint256 startIndex = (page - 1) * pageSize + 1; // ranks start at 1
        uint256 endIndex = startIndex + pageSize - 1;
        if (endIndex > totalEntries) {
            endIndex = totalEntries;
        }
        
        uint256 resultSize = endIndex - startIndex + 1;
        entries = new LeaderboardEntry[](resultSize);
        
        for (uint256 i = 0; i < resultSize; i++) {
            entries[i] = leaderboardEntries[cycle][startIndex + i];
        }
    }

    // Get reward info for a specific rank
    function getRewardForRank(uint256 rank, uint256 totalParticipants, uint256 totalRewardPool) external pure returns (uint256) {
        if (totalParticipants == 0 || totalRewardPool == 0) return 0;
        
        uint256 top10Reward = (totalRewardPool * 70) / 100;
        uint256 otherReward = totalRewardPool - top10Reward;
        
        if (rank <= 10) {
            uint256 top10Count = totalParticipants > 10 ? 10 : totalParticipants;
            return top10Count > 0 ? top10Reward / top10Count : 0;
        } else {
            uint256 otherCount = totalParticipants > 10 ? totalParticipants - 10 : 0;
            return otherCount > 0 ? otherReward / otherCount : 0;
        }
    }

    // Required overrides
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
