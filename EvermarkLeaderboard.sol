// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

/*
 ██╗   ██╗ ██████╗ ████████╗██╗███╗   ██╗ ██████╗ 
 ██║   ██║██╔═══██╗╚══██╔══╝██║████╗  ██║██╔════╝ 
 ██║   ██║██║   ██║   ██║   ██║██╔██╗ ██║██║  ███╗
 ╚██╗ ██╔╝██║   ██║   ██║   ██║██║╚██╗██║██║   ██║
  ╚████╔╝ ╚██████╔╝   ██║   ██║██║ ╚████║╚██████╔╝
   ╚═══╝   ╚═════╝    ╚═╝   ╚═╝╚═╝  ╚═══╝ ╚═════╝ 
*/

interface ICardCatalog {
    function getTotalVotingPower(address user) external view returns (uint256);
    function getAvailableVotingPower(address user) external view returns (uint256);
    function reserveVotingPower(address user, uint256 amount) external;
    function releaseVotingPower(address user, uint256 amount) external;
}

interface IEvermarkNFT {
    function exists(uint256 tokenId) external view returns (bool);
    function getEvermarkCreator(uint256 tokenId) external view returns (address);
}

interface ILiveLeaderboard {
    function updateEvermarkInLeaderboard(uint256 cycle, uint256 evermarkId) external;
    function batchUpdateLeaderboard(uint256 cycle, uint256[] calldata evermarkIds) external;
    function getLeaderboardSize(uint256 cycle) external view returns (uint256);
}

contract EvermarkVoting is 
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant CYCLE_MANAGER_ROLE = keccak256("CYCLE_MANAGER_ROLE");
    bytes32 public constant LEADERBOARD_MANAGER_ROLE = keccak256("LEADERBOARD_MANAGER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    uint256 public constant CYCLE_DURATION = 7 days;
    uint256 public constant MAX_BATCH_SIZE = 20;
    uint256 public constant MAX_ACTIVE_EVERMARKS_PER_CYCLE = 1000;

    struct VotingCycle {
        uint256 startTime;
        uint256 endTime;
        uint256 totalVotes;
        uint256 totalDelegations;
        bool finalized;
        uint256 activeEvermarksCount;
    }

    struct LeaderboardEntry {
        uint256 evermarkId;
        uint256 votes;
    }

    ICardCatalog public cardCatalog;
    IEvermarkNFT public evermarkNFT;
    ILiveLeaderboard public liveLeaderboard;
    
    uint256 public currentCycle;
    uint256 public cycleStartTime;
    
    mapping(uint256 => VotingCycle) public votingCycles;
    mapping(uint256 => mapping(uint256 => uint256)) public cycleEvermarkVotes;
    mapping(uint256 => mapping(address => uint256)) public cycleUserTotalVotes;
    mapping(uint256 => mapping(address => mapping(uint256 => uint256))) public cycleUserEvermarkVotes;
    
    mapping(uint256 => uint256[]) public cycleActiveEvermarks;
    mapping(uint256 => mapping(uint256 => bool)) public isEvermarkActiveInCycle;
    mapping(uint256 => mapping(uint256 => uint256)) public evermarkIndexInCycle;
    
    mapping(uint256 => LeaderboardEntry[]) public cycleLeaderboards;
    mapping(uint256 => bool) public leaderboardSubmitted;
    
    bool public autoUpdateLeaderboard;
    
    uint256 public emergencyPauseTimestamp;
    
    event NewVotingCycle(uint256 indexed cycleNumber, uint256 timestamp);
    event VoteDelegated(address indexed user, uint256 indexed evermarkId, uint256 amount, uint256 indexed cycle);
    event VoteUndelegated(address indexed user, uint256 indexed evermarkId, uint256 amount, uint256 indexed cycle);
    event CycleFinalized(uint256 indexed cycleNumber, uint256 totalVotes, uint256 totalEvermarks);
    event LeaderboardSubmitted(uint256 indexed cycle, uint256 entryCount);
    event EmergencyPauseSet(uint256 timestamp);
    event LiveLeaderboardUpdated(address indexed leaderboard);
    event AutoUpdateToggled(bool enabled);
    event LeaderboardUpdateFailed(uint256 indexed cycle, uint256 indexed evermarkId, string reason);
    event BatchLeaderboardUpdateFailed(uint256 indexed cycle, uint256[] evermarkIds, string reason);
    event LeaderboardValidationFailed(address leaderboard, string reason);

    modifier notInEmergency() {
        require(block.timestamp > emergencyPauseTimestamp, "Emergency pause active");
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _cardCatalog,
        address _evermarkNFT
    ) external initializer {
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(CYCLE_MANAGER_ROLE, msg.sender);
        _grantRole(LEADERBOARD_MANAGER_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);

        cardCatalog = ICardCatalog(_cardCatalog);
        evermarkNFT = IEvermarkNFT(_evermarkNFT);
        
        emergencyPauseTimestamp = 0;
        autoUpdateLeaderboard = false;
        
        currentCycle = 1;
        cycleStartTime = block.timestamp;
        
        VotingCycle storage cycle = votingCycles[currentCycle];
        cycle.startTime = block.timestamp;
        cycle.endTime = block.timestamp + CYCLE_DURATION;
        cycle.finalized = false;
        
        emit NewVotingCycle(currentCycle, block.timestamp);
    }

    function delegateVotes(uint256 evermarkId, uint256 amount) external whenNotPaused notInEmergency nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        require(evermarkNFT.exists(evermarkId), "Evermark does not exist");
        
        uint256 availablePower = cardCatalog.getAvailableVotingPower(msg.sender);
        require(availablePower >= amount, "Insufficient voting power");
        
        address evermarkCreator = evermarkNFT.getEvermarkCreator(evermarkId);
        require(evermarkCreator != msg.sender, "Cannot vote on own Evermark");
        
        _checkAndStartNewCycle();
        
        VotingCycle storage cycle = votingCycles[currentCycle];
        require(!cycle.finalized, "Current cycle is finalized");
        
        cardCatalog.reserveVotingPower(msg.sender, amount);
        
        bool isNewEvermark = cycleEvermarkVotes[currentCycle][evermarkId] == 0;
        
        cycleEvermarkVotes[currentCycle][evermarkId] += amount;
        cycleUserTotalVotes[currentCycle][msg.sender] += amount;
        cycleUserEvermarkVotes[currentCycle][msg.sender][evermarkId] += amount;
        cycle.totalVotes += amount;
        cycle.totalDelegations++;
        
        if (isNewEvermark) {
            cycle.activeEvermarksCount++;
            require(cycle.activeEvermarksCount <= MAX_ACTIVE_EVERMARKS_PER_CYCLE, "Too many active evermarks this cycle");
            
            cycleActiveEvermarks[currentCycle].push(evermarkId);
            isEvermarkActiveInCycle[currentCycle][evermarkId] = true;
            evermarkIndexInCycle[currentCycle][evermarkId] = cycleActiveEvermarks[currentCycle].length - 1;
        }
        
        _updateLiveLeaderboardIfEnabled(currentCycle, evermarkId);
        
        emit VoteDelegated(msg.sender, evermarkId, amount, currentCycle);
    }

    function undelegateVotes(uint256 evermarkId, uint256 amount) external whenNotPaused notInEmergency nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        
        _checkAndStartNewCycle();
        
        VotingCycle storage cycle = votingCycles[currentCycle];
        require(!cycle.finalized, "Current cycle is finalized");
        
        uint256 userVotes = cycleUserEvermarkVotes[currentCycle][msg.sender][evermarkId];
        require(userVotes >= amount, "Insufficient delegated votes");
        
        cycleEvermarkVotes[currentCycle][evermarkId] -= amount;
        cycleUserTotalVotes[currentCycle][msg.sender] -= amount;
        cycleUserEvermarkVotes[currentCycle][msg.sender][evermarkId] -= amount;
        cycle.totalVotes -= amount;
        
        cardCatalog.releaseVotingPower(msg.sender, amount);
        
        _updateLiveLeaderboardIfEnabled(currentCycle, evermarkId);
        
        emit VoteUndelegated(msg.sender, evermarkId, amount, currentCycle);
    }

    function delegateVotesBatch(
        uint256[] calldata evermarkIds,
        uint256[] calldata amounts
    ) external whenNotPaused notInEmergency nonReentrant {
        require(evermarkIds.length == amounts.length, "Array length mismatch");
        require(evermarkIds.length <= MAX_BATCH_SIZE, "Batch size too large");
        
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            totalAmount += amounts[i];
        }
        
        uint256 availablePower = cardCatalog.getAvailableVotingPower(msg.sender);
        require(availablePower >= totalAmount, "Insufficient voting power");
        
        cardCatalog.reserveVotingPower(msg.sender, totalAmount);
        
        _checkAndStartNewCycle();
        VotingCycle storage cycle = votingCycles[currentCycle];
        require(!cycle.finalized, "Current cycle is finalized");
        
        uint256[] memory updatedEvermarkIds;
        uint256 updateCount = 0;
        
        for (uint256 i = 0; i < evermarkIds.length; i++) {
            if (amounts[i] > 0) {
                updateCount++;
            }
        }
        
        if (updateCount > 0) {
            updatedEvermarkIds = new uint256[](updateCount);
            uint256 currentIndex = 0;
            
            for (uint256 i = 0; i < evermarkIds.length; i++) {
                if (amounts[i] > 0) {
                    _delegateVotesInternal(evermarkIds[i], amounts[i], cycle);
                    updatedEvermarkIds[currentIndex] = evermarkIds[i];
                    currentIndex++;
                }
            }
            
            if (autoUpdateLeaderboard && address(liveLeaderboard) != address(0)) {
                try liveLeaderboard.batchUpdateLeaderboard(currentCycle, updatedEvermarkIds) {
                    
                } catch Error(string memory reason) {
                    emit BatchLeaderboardUpdateFailed(currentCycle, updatedEvermarkIds, reason);
                } catch {
                    emit BatchLeaderboardUpdateFailed(currentCycle, updatedEvermarkIds, "Unknown error");
                }
            }
        }
    }

    function _delegateVotesInternal(uint256 evermarkId, uint256 amount, VotingCycle storage cycle) internal {
        require(evermarkNFT.exists(evermarkId), "Evermark does not exist");
        
        address evermarkCreator = evermarkNFT.getEvermarkCreator(evermarkId);
        require(evermarkCreator != msg.sender, "Cannot vote on own Evermark");
        
        bool isNewEvermark = cycleEvermarkVotes[currentCycle][evermarkId] == 0;
        
        cycleEvermarkVotes[currentCycle][evermarkId] += amount;
        cycleUserTotalVotes[currentCycle][msg.sender] += amount;
        cycleUserEvermarkVotes[currentCycle][msg.sender][evermarkId] += amount;
        cycle.totalVotes += amount;
        cycle.totalDelegations++;
        
        if (isNewEvermark) {
            cycle.activeEvermarksCount++;
            require(cycle.activeEvermarksCount <= MAX_ACTIVE_EVERMARKS_PER_CYCLE, "Too many active evermarks this cycle");
            
            cycleActiveEvermarks[currentCycle].push(evermarkId);
            isEvermarkActiveInCycle[currentCycle][evermarkId] = true;
            evermarkIndexInCycle[currentCycle][evermarkId] = cycleActiveEvermarks[currentCycle].length - 1;
        }
        
        emit VoteDelegated(msg.sender, evermarkId, amount, currentCycle);
    }

    function _updateLiveLeaderboardIfEnabled(uint256 cycle, uint256 evermarkId) internal {
        if (autoUpdateLeaderboard && address(liveLeaderboard) != address(0)) {
            try liveLeaderboard.updateEvermarkInLeaderboard(cycle, evermarkId) {
                
            } catch Error(string memory reason) {
                emit LeaderboardUpdateFailed(cycle, evermarkId, reason);
            } catch {
                emit LeaderboardUpdateFailed(cycle, evermarkId, "Unknown error");
            }
        }
    }

    function updateLeaderboard(uint256 cycle, uint256 evermarkId) external onlyRole(LEADERBOARD_MANAGER_ROLE) {
        require(address(liveLeaderboard) != address(0), "LiveLeaderboard not set");
        liveLeaderboard.updateEvermarkInLeaderboard(cycle, evermarkId);
    }

    function batchUpdateLeaderboard(uint256 cycle, uint256[] calldata evermarkIds) external onlyRole(LEADERBOARD_MANAGER_ROLE) {
        require(address(liveLeaderboard) != address(0), "LiveLeaderboard not set");
        liveLeaderboard.batchUpdateLeaderboard(cycle, evermarkIds);
    }

    function getActiveEvermarksInCycle(uint256 cycle) external view returns (uint256[] memory evermarkIds, uint256[] memory votes) {
        uint256[] memory activeIds = cycleActiveEvermarks[cycle];
        uint256[] memory voteAmounts = new uint256[](activeIds.length);
        
        for (uint256 i = 0; i < activeIds.length; i++) {
            voteAmounts[i] = cycleEvermarkVotes[cycle][activeIds[i]];
        }
        
        return (activeIds, voteAmounts);
    }

    function syncLeaderboardForCycle(uint256 cycle, uint256[] calldata evermarkIds) external onlyRole(LEADERBOARD_MANAGER_ROLE) {
        require(address(liveLeaderboard) != address(0), "LiveLeaderboard not set");
        require(votingCycles[cycle].finalized || cycle != currentCycle, "Cannot sync active cycle");
        
        uint256 processed = 0;
        while (processed < evermarkIds.length) {
            uint256 batchEnd = processed + MAX_BATCH_SIZE;
            if (batchEnd > evermarkIds.length) {
                batchEnd = evermarkIds.length;
            }
            
            uint256[] memory batch = new uint256[](batchEnd - processed);
            for (uint256 i = 0; i < batch.length; i++) {
                batch[i] = evermarkIds[processed + i];
            }
            
            try liveLeaderboard.batchUpdateLeaderboard(cycle, batch) {
                
            } catch Error(string memory reason) {
                emit BatchLeaderboardUpdateFailed(cycle, batch, reason);
            } catch {
                emit BatchLeaderboardUpdateFailed(cycle, batch, "Unknown error");
            }
            
            processed = batchEnd;
        }
    }

    function validateLiveLeaderboard() external view returns (bool) {
        if (address(liveLeaderboard) == address(0)) return false;
        
        try liveLeaderboard.getLeaderboardSize(currentCycle) returns (uint256) {
            return true;
        } catch {
            return false;
        }
    }

    function _checkAndStartNewCycle() internal {
        VotingCycle storage cycle = votingCycles[currentCycle];
        
        if (block.timestamp >= cycle.endTime && !cycle.finalized) {
            startNewVotingCycle();
        }
    }

    function startNewVotingCycle() public onlyRole(CYCLE_MANAGER_ROLE) {
        VotingCycle storage oldCycle = votingCycles[currentCycle];
        
        if (!oldCycle.finalized) {
            oldCycle.finalized = true;
            emit CycleFinalized(currentCycle, oldCycle.totalVotes, oldCycle.activeEvermarksCount);
        }
        
        currentCycle++;
        cycleStartTime = block.timestamp;
        
        VotingCycle storage newCycle = votingCycles[currentCycle];
        newCycle.startTime = block.timestamp;
        newCycle.endTime = block.timestamp + CYCLE_DURATION;
        newCycle.finalized = false;
        
        emit NewVotingCycle(currentCycle, block.timestamp);
    }

    function submitLeaderboard(
        uint256 cycle,
        uint256[] calldata evermarkIds,
        uint256[] calldata votes
    ) external onlyRole(LEADERBOARD_MANAGER_ROLE) {
        require(votingCycles[cycle].finalized, "Cycle not finalized");
        require(!leaderboardSubmitted[cycle], "Leaderboard already submitted");
        require(evermarkIds.length == votes.length, "Array length mismatch");
        require(evermarkIds.length <= 100, "Too many entries");
        
        for (uint256 i = 1; i < votes.length; i++) {
            require(votes[i] <= votes[i-1], "Votes not properly sorted");
        }
        
        for (uint256 i = 0; i < evermarkIds.length; i++) {
            uint256 expectedVotes = cycleEvermarkVotes[cycle][evermarkIds[i]];
            require(votes[i] == expectedVotes, "Vote count mismatch");
        }
        
        delete cycleLeaderboards[cycle];
        
        for (uint256 i = 0; i < evermarkIds.length; i++) {
            cycleLeaderboards[cycle].push(LeaderboardEntry({
                evermarkId: evermarkIds[i],
                votes: votes[i]
            }));
        }
        
        leaderboardSubmitted[cycle] = true;
        emit LeaderboardSubmitted(cycle, evermarkIds.length);
    }

    function getTopEvermarksInCycle(uint256 cycle, uint256 limit) external view returns (
        uint256[] memory evermarkIds,
        uint256[] memory votes
    ) {
        require(leaderboardSubmitted[cycle], "Leaderboard not submitted for this cycle");
        
        LeaderboardEntry[] memory leaderboard = cycleLeaderboards[cycle];
        uint256 count = leaderboard.length > limit ? limit : leaderboard.length;
        
        evermarkIds = new uint256[](count);
        votes = new uint256[](count);
        
        for (uint256 i = 0; i < count; i++) {
            evermarkIds[i] = leaderboard[i].evermarkId;
            votes[i] = leaderboard[i].votes;
        }
        
        return (evermarkIds, votes);
    }

    function getCurrentCycle() external view returns (uint256) {
        return currentCycle;
    }

    function getEvermarkVotesInCycle(uint256 cycle, uint256 evermarkId) external view returns (uint256) {
        return cycleEvermarkVotes[cycle][evermarkId];
    }

    function getUserVotesInCycle(uint256 cycle, address user, uint256 evermarkId) external view returns (uint256) {
        return cycleUserEvermarkVotes[cycle][user][evermarkId];
    }

    function getTotalUserVotesInCurrentCycle(address user) external view returns (uint256) {
        return cycleUserTotalVotes[currentCycle][user];
    }

    function getTotalUserVotesInCycle(uint256 cycle, address user) external view returns (uint256) {
        return cycleUserTotalVotes[cycle][user];
    }

    function getRemainingVotingPower(address user) external view returns (uint256) {
        return cardCatalog.getAvailableVotingPower(user);
    }

    function getTimeRemainingInCurrentCycle() external view returns (uint256) {
        VotingCycle storage cycle = votingCycles[currentCycle];
        if (block.timestamp >= cycle.endTime) {
            return 0;
        }
        return cycle.endTime - block.timestamp;
    }

    function getCycleInfo(uint256 cycle) external view returns (
        uint256 startTime,
        uint256 endTime,
        uint256 totalVotes,
        uint256 totalDelegations,
        bool finalized,
        uint256 activeEvermarksCount
    ) {
        VotingCycle storage cycleData = votingCycles[cycle];
        return (
            cycleData.startTime,
            cycleData.endTime,
            cycleData.totalVotes,
            cycleData.totalDelegations,
            cycleData.finalized,
            cycleData.activeEvermarksCount
        );
    }

    function isLeaderboardSubmitted(uint256 cycle) external view returns (bool) {
        return leaderboardSubmitted[cycle];
    }

    function getLeaderboard(uint256 cycle) external view returns (LeaderboardEntry[] memory) {
        require(leaderboardSubmitted[cycle], "Leaderboard not submitted");
        return cycleLeaderboards[cycle];
    }

    function setLiveLeaderboard(address _liveLeaderboard) external onlyRole(ADMIN_ROLE) {
        if (_liveLeaderboard != address(0)) {
            try ILiveLeaderboard(_liveLeaderboard).getLeaderboardSize(currentCycle) returns (uint256) {
                
            } catch {
                emit LeaderboardValidationFailed(_liveLeaderboard, "Invalid leaderboard contract");
                revert("Invalid leaderboard contract");
            }
        }
        
        liveLeaderboard = ILiveLeaderboard(_liveLeaderboard);
        emit LiveLeaderboardUpdated(_liveLeaderboard);
    }

    function setAutoUpdateLeaderboard(bool _enabled) external onlyRole(ADMIN_ROLE) {
        autoUpdateLeaderboard = _enabled;
        emit AutoUpdateToggled(_enabled);
    }

    function getLiveLeaderboardAddress() external view returns (address) {
        return address(liveLeaderboard);
    }

    function isAutoUpdateEnabled() external view returns (bool) {
        return autoUpdateLeaderboard;
    }

    function setEmergencyPause(uint256 pauseUntilTimestamp) external onlyRole(ADMIN_ROLE) {
        emergencyPauseTimestamp = pauseUntilTimestamp;
        emit EmergencyPauseSet(pauseUntilTimestamp);
    }

    function clearEmergencyPause() external onlyRole(ADMIN_ROLE) {
        emergencyPauseTimestamp = 0;
        emit EmergencyPauseSet(0);
    }

    function updateCardCatalog(address _cardCatalog) external onlyRole(ADMIN_ROLE) {
        require(_cardCatalog != address(0), "Invalid address");
        cardCatalog = ICardCatalog(_cardCatalog);
    }

    function updateEvermarkNFT(address _evermarkNFT) external onlyRole(ADMIN_ROLE) {
        require(_evermarkNFT != address(0), "Invalid address");
        evermarkNFT = IEvermarkNFT(_evermarkNFT);
    }

    function grantCycleManagerRole(address manager) external onlyRole(ADMIN_ROLE) {
        grantRole(CYCLE_MANAGER_ROLE, manager);
    }

    function revokeCycleManagerRole(address manager) external onlyRole(ADMIN_ROLE) {
        revokeRole(CYCLE_MANAGER_ROLE, manager);
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

    function emergencyFinalizeCycle(uint256 cycle) external onlyRole(ADMIN_ROLE) {
        VotingCycle storage cycleData = votingCycles[cycle];
        require(!cycleData.finalized, "Cycle already finalized");
        
        cycleData.finalized = true;
        emit CycleFinalized(cycle, cycleData.totalVotes, cycleData.activeEvermarksCount);
    }

    function emergencyStartNewCycle() external onlyRole(ADMIN_ROLE) {
        startNewVotingCycle();
    }

    function checkAndStartNewCycle() external returns (bool) {
        VotingCycle storage cycle = votingCycles[currentCycle];
        
        if (block.timestamp >= cycle.endTime && !cycle.finalized) {
            startNewVotingCycle();
            return true;
        }
        
        return false;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
