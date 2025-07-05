// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

/*
 ██╗     ██╗██╗   ██╗███████╗    ██╗     ███████╗ █████╗ ██████╗ ███████╗██████╗ ██████╗  ██████╗  █████╗ ██████╗ ██████╗ 
 ██║     ██║██║   ██║██╔════╝    ██║     ██╔════╝██╔══██╗██╔══██╗██╔════╝██╔══██╗██╔══██╗██╔═══██╗██╔══██╗██╔══██╗██╔══██╗
 ██║     ██║██║   ██║█████╗      ██║     █████╗  ███████║██║  ██║█████╗  ██████╔╝██████╔╝██║   ██║███████║██████╔╝██║  ██║
 ██║     ██║╚██╗ ██╔╝██╔══╝      ██║     ██╔══╝  ██╔══██║██║  ██║██╔══╝  ██╔══██╗██╔══██╗██║   ██║██╔══██║██╔══██╗██║  ██║
 ███████╗██║ ╚████╔╝ ███████╗    ███████╗███████╗██║  ██║██████╔╝███████╗██║  ██║██████╔╝╚██████╔╝██║  ██║██║  ██║██████╔╝
 ╚══════╝╚═╝  ╚═══╝  ╚══════╝    ╚══════╝╚══════╝╚═╝  ╚═╝╚═════╝ ╚══════╝╚═╝  ╚═╝╚═════╝  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═════╝ 
*/

interface IEvermarkVoting {
    function getEvermarkVotesInCycle(uint256 cycle, uint256 evermarkId) external view returns (uint256);
    function getCurrentCycle() external view returns (uint256);
    function getCycleInfo(uint256 cycle) external view returns (
        uint256 startTime,
        uint256 endTime,
        uint256 totalVotes,
        uint256 totalDelegations,
        bool finalized,
        uint256 activeEvermarksCount
    );
}

interface IEvermarkNFT {
    function exists(uint256 tokenId) external view returns (bool);
    function getEvermarkCreator(uint256 tokenId) external view returns (address);
}

contract LiveLeaderboard is 
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
        uint256 votes;
        address creator;
    }

    uint256 public constant LEADERBOARD_SIZE = 1000;
    uint256 public constant MAX_BATCH_SIZE = 100;
    uint256 public constant MAX_QUERY_SIZE = 200;

    IEvermarkVoting public evermarkVoting;
    IEvermarkNFT public evermarkNFT;
    
    mapping(uint256 => LeaderboardEntry[]) public cycleLeaderboards;
    mapping(uint256 => mapping(uint256 => uint256)) public evermarkPositions;
    mapping(uint256 => bool) public cycleInitialized;
    
    mapping(uint256 => uint256) public lastUpdateBlock;
    
    mapping(uint256 => uint256) public cycleUpdateCount;
    mapping(uint256 => mapping(uint256 => uint256)) public evermarkLastUpdate;
    
    uint256 public emergencyPauseTimestamp;
    
    event LeaderboardUpdated(uint256 indexed cycle, uint256 indexed evermarkId, uint256 newVotes, uint256 position);
    event CycleInitialized(uint256 indexed cycle);
    event LeaderboardOptimizationUsed(uint256 indexed cycle, uint256 evermarkId, string optimizationType);
    event GasOptimizationSkipped(uint256 indexed cycle, uint256 evermarkId, string reason);

    modifier notInEmergency() {
        require(block.timestamp > emergencyPauseTimestamp, "Emergency pause active");
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _evermarkVoting,
        address _evermarkNFT
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
        
        emergencyPauseTimestamp = 0;
    }

    function updateEvermarkInLeaderboard(uint256 cycle, uint256 evermarkId) 
        external 
        onlyRole(LEADERBOARD_MANAGER_ROLE) 
        whenNotPaused 
        notInEmergency 
    {
        _initializeCycleIfNeeded(cycle);
        
        if (evermarkLastUpdate[cycle][evermarkId] == block.number) {
            emit GasOptimizationSkipped(cycle, evermarkId, "Already updated this block");
            return;
        }
        
        uint256 currentVotes = evermarkVoting.getEvermarkVotesInCycle(cycle, evermarkId);
        
        if (currentVotes > 0 && evermarkNFT.exists(evermarkId)) {
            address creator = evermarkNFT.getEvermarkCreator(evermarkId);
            _updateLeaderboard(cycle, evermarkId, currentVotes, creator);
        } else {
            _removeFromLeaderboard(cycle, evermarkId);
        }
        
        lastUpdateBlock[cycle] = block.number;
        cycleUpdateCount[cycle]++;
        evermarkLastUpdate[cycle][evermarkId] = block.number;
    }

    function batchUpdateLeaderboard(uint256 cycle, uint256[] calldata evermarkIds) 
        external 
        onlyRole(LEADERBOARD_MANAGER_ROLE) 
        whenNotPaused 
        notInEmergency 
    {
        require(evermarkIds.length <= MAX_BATCH_SIZE, "Batch too large");
        _initializeCycleIfNeeded(cycle);
        
        uint256 updatesPerformed = 0;
        
        for (uint256 i = 0; i < evermarkIds.length; i++) {
            uint256 evermarkId = evermarkIds[i];
            
            if (evermarkLastUpdate[cycle][evermarkId] == block.number) {
                continue;
            }
            
            uint256 currentVotes = evermarkVoting.getEvermarkVotesInCycle(cycle, evermarkId);
            
            if (currentVotes > 0 && evermarkNFT.exists(evermarkId)) {
                address creator = evermarkNFT.getEvermarkCreator(evermarkId);
                _updateLeaderboard(cycle, evermarkId, currentVotes, creator);
            } else {
                _removeFromLeaderboard(cycle, evermarkId);
            }
            
            evermarkLastUpdate[cycle][evermarkId] = block.number;
            updatesPerformed++;
        }
        
        lastUpdateBlock[cycle] = block.number;
        cycleUpdateCount[cycle] += updatesPerformed;
        
        if (updatesPerformed < evermarkIds.length) {
            emit LeaderboardOptimizationUsed(cycle, 0, "Batch update skipped duplicates");
        }
    }

    function _initializeCycleIfNeeded(uint256 cycle) internal {
        if (!cycleInitialized[cycle]) {
            cycleInitialized[cycle] = true;
            emit CycleInitialized(cycle);
        }
    }

    function _updateLeaderboard(uint256 cycle, uint256 evermarkId, uint256 newVotes, address creator) internal {
        uint256 currentPosition = evermarkPositions[cycle][evermarkId];
        
        if (currentPosition == 0) {
            _addToLeaderboard(cycle, evermarkId, newVotes, creator);
        } else {
            _updateExistingEntry(cycle, currentPosition, newVotes);
        }
        
        emit LeaderboardUpdated(cycle, evermarkId, newVotes, evermarkPositions[cycle][evermarkId]);
    }

    function _addToLeaderboard(uint256 cycle, uint256 evermarkId, uint256 newVotes, address creator) internal {
        if (cycleLeaderboards[cycle].length < LEADERBOARD_SIZE) {
            cycleLeaderboards[cycle].push(LeaderboardEntry({
                evermarkId: evermarkId,
                votes: newVotes,
                creator: creator
            }));
            uint256 newPosition = cycleLeaderboards[cycle].length;
            evermarkPositions[cycle][evermarkId] = newPosition;
            _bubbleUp(cycle, newPosition - 1);
        } else if (newVotes > cycleLeaderboards[cycle][LEADERBOARD_SIZE - 1].votes) {
            uint256 removedId = cycleLeaderboards[cycle][LEADERBOARD_SIZE - 1].evermarkId;
            evermarkPositions[cycle][removedId] = 0;
            
            cycleLeaderboards[cycle][LEADERBOARD_SIZE - 1] = LeaderboardEntry({
                evermarkId: evermarkId,
                votes: newVotes,
                creator: creator
            });
            evermarkPositions[cycle][evermarkId] = LEADERBOARD_SIZE;
            _bubbleUp(cycle, LEADERBOARD_SIZE - 1);
        }
    }

    function _updateExistingEntry(uint256 cycle, uint256 position, uint256 newVotes) internal {
        uint256 arrayIndex = position - 1;
        
        uint256 oldVotes = cycleLeaderboards[cycle][arrayIndex].votes;
        cycleLeaderboards[cycle][arrayIndex].votes = newVotes;
        
        if (newVotes > oldVotes && arrayIndex > 0) {
            _bubbleUp(cycle, arrayIndex);
        } else if (newVotes < oldVotes && arrayIndex < cycleLeaderboards[cycle].length - 1) {
            _bubbleDown(cycle, arrayIndex);
        }
    }

    function _bubbleUp(uint256 cycle, uint256 startIndex) internal {
        uint256 currentIndex = startIndex;
        
        while (currentIndex > 0 && cycleLeaderboards[cycle][currentIndex].votes > cycleLeaderboards[cycle][currentIndex - 1].votes) {
            _swapEntries(cycle, currentIndex, currentIndex - 1);
            currentIndex--;
        }
    }

    function _bubbleDown(uint256 cycle, uint256 startIndex) internal {
        uint256 currentIndex = startIndex;
        
        while (currentIndex < cycleLeaderboards[cycle].length - 1 && 
               cycleLeaderboards[cycle][currentIndex].votes < cycleLeaderboards[cycle][currentIndex + 1].votes) {
            _swapEntries(cycle, currentIndex, currentIndex + 1);
            currentIndex++;
        }
    }

    function _swapEntries(uint256 cycle, uint256 index1, uint256 index2) internal {
        LeaderboardEntry memory temp = cycleLeaderboards[cycle][index1];
        cycleLeaderboards[cycle][index1] = cycleLeaderboards[cycle][index2];
        cycleLeaderboards[cycle][index2] = temp;
        
        evermarkPositions[cycle][cycleLeaderboards[cycle][index1].evermarkId] = index1 + 1;
        evermarkPositions[cycle][cycleLeaderboards[cycle][index2].evermarkId] = index2 + 1;
    }

    function _removeFromLeaderboard(uint256 cycle, uint256 evermarkId) internal {
        uint256 position = evermarkPositions[cycle][evermarkId];
        if (position == 0) return;
        
        uint256 arrayIndex = position - 1;
        
        evermarkPositions[cycle][evermarkId] = 0;
        
        for (uint256 i = arrayIndex; i < cycleLeaderboards[cycle].length - 1; i++) {
            cycleLeaderboards[cycle][i] = cycleLeaderboards[cycle][i + 1];
            evermarkPositions[cycle][cycleLeaderboards[cycle][i].evermarkId] = i + 1;
        }
        
        cycleLeaderboards[cycle].pop();
    }

    function getLeaderboard(uint256 cycle, uint256 startRank, uint256 count) 
        external 
        view 
        returns (LeaderboardEntry[] memory) 
    {
        require(count <= MAX_QUERY_SIZE, "Query too large");
        
        uint256 startIndex = startRank > 0 ? startRank - 1 : 0;
        uint256 endIndex = startIndex + count;
        
        if (endIndex > cycleLeaderboards[cycle].length) {
            endIndex = cycleLeaderboards[cycle].length;
        }
        
        uint256 actualCount = endIndex > startIndex ? endIndex - startIndex : 0;
        LeaderboardEntry[] memory result = new LeaderboardEntry[](actualCount);
        
        for (uint256 i = 0; i < actualCount; i++) {
            result[i] = cycleLeaderboards[cycle][startIndex + i];
        }
        
        return result;
    }

    function getTopN(uint256 cycle, uint256 n) external view returns (LeaderboardEntry[] memory) {
        require(n <= MAX_QUERY_SIZE, "Query too large");
        return this.getLeaderboard(cycle, 1, n);
    }

    function getEvermarkRank(uint256 cycle, uint256 evermarkId) external view returns (uint256) {
        return evermarkPositions[cycle][evermarkId];
    }

    function getLeaderboardSize(uint256 cycle) external view returns (uint256) {
        return cycleLeaderboards[cycle].length;
    }

    function isEvermarkOnLeaderboard(uint256 cycle, uint256 evermarkId) external view returns (bool) {
        return evermarkPositions[cycle][evermarkId] > 0;
    }

    function getCycleStats(uint256 cycle) external view returns (
        uint256 totalUpdates,
        uint256 leaderboardSize,
        uint256 lastUpdate,
        bool initialized
    ) {
        return (
            cycleUpdateCount[cycle],
            cycleLeaderboards[cycle].length,
            lastUpdateBlock[cycle],
            cycleInitialized[cycle]
        );
    }

    function getEvermarkUpdateInfo(uint256 cycle, uint256 evermarkId) external view returns (
        uint256 position,
        uint256 lastUpdateBlockNum,
        bool onLeaderboard
    ) {
        return (
            evermarkPositions[cycle][evermarkId],
            evermarkLastUpdate[cycle][evermarkId],
            evermarkPositions[cycle][evermarkId] > 0
        );
    }

    function setEmergencyPause(uint256 pauseUntilTimestamp) external onlyRole(ADMIN_ROLE) {
        emergencyPauseTimestamp = pauseUntilTimestamp;
    }

    function updateContracts(
        address _evermarkVoting,
        address _evermarkNFT
    ) external onlyRole(ADMIN_ROLE) {
        if (_evermarkVoting != address(0)) evermarkVoting = IEvermarkVoting(_evermarkVoting);
        if (_evermarkNFT != address(0)) evermarkNFT = IEvermarkNFT(_evermarkNFT);
    }

    function pause() external onlyRole(ADMIN_ROLE) { 
        _pause(); 
    }
    
    function unpause() external onlyRole(ADMIN_ROLE) { 
        _unpause(); 
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
