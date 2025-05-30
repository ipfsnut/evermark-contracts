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
    function updateVotingPowerDelegation(address user, uint256 delegated) external;
}

interface IEvermarkNFT {
    function exists(uint256 tokenId) external view returns (bool);
    function getEvermarkCreator(uint256 tokenId) external view returns (address);
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
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    uint256 public constant CYCLE_DURATION = 7 days;
    uint256 public constant MAX_BATCH_SIZE = 20;
    uint256 public constant MAX_ACTIVE_EVERMARKS_PER_CYCLE = 1000;
    uint256 public constant MAX_LEADERBOARD_SIZE = 100;

    struct VotingCycle {
        uint256 startTime;
        uint256 endTime;
        uint256 totalVotes;
        uint256 totalDelegations;
        bool finalized;
        mapping(uint256 => uint256) evermarkVotes;
        mapping(address => uint256) userTotalVotes;
        mapping(address => mapping(uint256 => uint256)) userEvermarkVotes;
        uint256[] activeEvermarks;
    }

    struct LeaderboardEntry {
        uint256 evermarkId;
        uint256 votes;
    }

    ICardCatalog public cardCatalog;
    IEvermarkNFT public evermarkNFT;
    
    uint256 public currentCycle;
    uint256 public cycleStartTime;
    
    mapping(uint256 => VotingCycle) public votingCycles;
    mapping(uint256 => LeaderboardEntry[]) public cycleLeaderboards;
    mapping(uint256 => bool) public leaderboardComputed;
    
    uint256 public emergencyPauseTimestamp;
    
    mapping(uint256 => uint256) public totalEvermarkVotes;
    mapping(address => uint256) public totalUserDelegations;
    
    event NewVotingCycle(uint256 indexed cycleNumber, uint256 timestamp);
    event VoteDelegated(address indexed user, uint256 indexed evermarkId, uint256 amount, uint256 indexed cycle);
    event VoteUndelegated(address indexed user, uint256 indexed evermarkId, uint256 amount, uint256 indexed cycle);
    event CycleFinalized(uint256 indexed cycleNumber, uint256 totalVotes, uint256 totalEvermarks);
    event LeaderboardComputed(uint256 indexed cycle, uint256 entryCount);
    event EmergencyPauseSet(uint256 timestamp);

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
        _grantRole(UPGRADER_ROLE, msg.sender);

        cardCatalog = ICardCatalog(_cardCatalog);
        evermarkNFT = IEvermarkNFT(_evermarkNFT);
        
        emergencyPauseTimestamp = 0;
        
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
        
        if (cycle.evermarkVotes[evermarkId] == 0) {
            require(cycle.activeEvermarks.length < MAX_ACTIVE_EVERMARKS_PER_CYCLE, "Too many active evermarks this cycle");
        }
        
        cycle.evermarkVotes[evermarkId] += amount;
        cycle.userTotalVotes[msg.sender] += amount;
        cycle.userEvermarkVotes[msg.sender][evermarkId] += amount;
        cycle.totalVotes += amount;
        cycle.totalDelegations++;
        
        if (cycle.userEvermarkVotes[msg.sender][evermarkId] == amount) {
            _addToActiveEvermarks(currentCycle, evermarkId);
        }
        
        totalEvermarkVotes[evermarkId] += amount;
        totalUserDelegations[msg.sender] += amount;
        
        uint256 totalDelegated = _getUserTotalDelegatedPower(msg.sender);
        cardCatalog.updateVotingPowerDelegation(msg.sender, totalDelegated);
        
        emit VoteDelegated(msg.sender, evermarkId, amount, currentCycle);
    }

    function undelegateVotes(uint256 evermarkId, uint256 amount) external whenNotPaused notInEmergency nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        
        _checkAndStartNewCycle();
        
        VotingCycle storage cycle = votingCycles[currentCycle];
        require(!cycle.finalized, "Current cycle is finalized");
        
        uint256 userVotes = cycle.userEvermarkVotes[msg.sender][evermarkId];
        require(userVotes >= amount, "Insufficient delegated votes");
        
        cycle.evermarkVotes[evermarkId] -= amount;
        cycle.userTotalVotes[msg.sender] -= amount;
        cycle.userEvermarkVotes[msg.sender][evermarkId] -= amount;
        cycle.totalVotes -= amount;
        
        totalEvermarkVotes[evermarkId] -= amount;
        totalUserDelegations[msg.sender] -= amount;
        
        uint256 totalDelegated = _getUserTotalDelegatedPower(msg.sender);
        cardCatalog.updateVotingPowerDelegation(msg.sender, totalDelegated);
        
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
        
        for (uint256 i = 0; i < evermarkIds.length; i++) {
            if (amounts[i] > 0) {
                _delegateVotesInternal(evermarkIds[i], amounts[i]);
            }
        }
    }

    function _delegateVotesInternal(uint256 evermarkId, uint256 amount) internal {
        require(evermarkNFT.exists(evermarkId), "Evermark does not exist");
        
        address evermarkCreator = evermarkNFT.getEvermarkCreator(evermarkId);
        require(evermarkCreator != msg.sender, "Cannot vote on own Evermark");
        
        _checkAndStartNewCycle();
        
        VotingCycle storage cycle = votingCycles[currentCycle];
        require(!cycle.finalized, "Current cycle is finalized");
        
        if (cycle.evermarkVotes[evermarkId] == 0) {
            require(cycle.activeEvermarks.length < MAX_ACTIVE_EVERMARKS_PER_CYCLE, "Too many active evermarks this cycle");
        }
        
        cycle.evermarkVotes[evermarkId] += amount;
        cycle.userTotalVotes[msg.sender] += amount;
        cycle.userEvermarkVotes[msg.sender][evermarkId] += amount;
        cycle.totalVotes += amount;
        cycle.totalDelegations++;
        
        if (cycle.userEvermarkVotes[msg.sender][evermarkId] == amount) {
            _addToActiveEvermarks(currentCycle, evermarkId);
        }
        
        totalEvermarkVotes[evermarkId] += amount;
        totalUserDelegations[msg.sender] += amount;
        
        emit VoteDelegated(msg.sender, evermarkId, amount, currentCycle);
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
            emit CycleFinalized(currentCycle, oldCycle.totalVotes, oldCycle.activeEvermarks.length);
        }
        
        currentCycle++;
        cycleStartTime = block.timestamp;
        
        VotingCycle storage newCycle = votingCycles[currentCycle];
        newCycle.startTime = block.timestamp;
        newCycle.endTime = block.timestamp + CYCLE_DURATION;
        newCycle.finalized = false;
        
        emit NewVotingCycle(currentCycle, block.timestamp);
    }

    function _addToActiveEvermarks(uint256 cycleNum, uint256 evermarkId) internal {
        uint256[] storage activeEvermarks = votingCycles[cycleNum].activeEvermarks;
        
        for (uint256 i = 0; i < activeEvermarks.length; i++) {
            if (activeEvermarks[i] == evermarkId) {
                return;
            }
        }
        
        activeEvermarks.push(evermarkId);
    }

    function _getUserTotalDelegatedPower(address user) internal view returns (uint256) {
        return votingCycles[currentCycle].userTotalVotes[user];
    }

    function computeLeaderboard(uint256 cycle) external onlyRole(CYCLE_MANAGER_ROLE) {
        require(votingCycles[cycle].finalized, "Cycle not finalized");
        require(!leaderboardComputed[cycle], "Leaderboard already computed");
        
        uint256[] memory activeEvermarks = votingCycles[cycle].activeEvermarks;
        uint256 evermarkCount = activeEvermarks.length;
        
        LeaderboardEntry[] memory tempEntries = new LeaderboardEntry[](evermarkCount);
        
        for (uint256 i = 0; i < evermarkCount; i++) {
            uint256 evermarkId = activeEvermarks[i];
            tempEntries[i] = LeaderboardEntry({
                evermarkId: evermarkId,
                votes: votingCycles[cycle].evermarkVotes[evermarkId]
            });
        }
        
        _insertionSort(tempEntries);
        
        uint256 entriesToStore = evermarkCount > MAX_LEADERBOARD_SIZE ? MAX_LEADERBOARD_SIZE : evermarkCount;
        
        delete cycleLeaderboards[cycle];
        
        for (uint256 i = 0; i < entriesToStore; i++) {
            cycleLeaderboards[cycle].push(tempEntries[i]);
        }
        
        leaderboardComputed[cycle] = true;
        emit LeaderboardComputed(cycle, entriesToStore);
    }

    function _insertionSort(LeaderboardEntry[] memory arr) internal pure {
        for (uint256 i = 1; i < arr.length; i++) {
            LeaderboardEntry memory key = arr[i];
            uint256 j = i;
            
            while (j > 0 && arr[j - 1].votes < key.votes) {
                arr[j] = arr[j - 1];
                j--;
            }
            arr[j] = key;
        }
    }

    function getCurrentCycle() external view returns (uint256) {
        return currentCycle;
    }

    function getEvermarkVotes(uint256 evermarkId) external view returns (uint256) {
        return totalEvermarkVotes[evermarkId];
    }

    function getEvermarkVotesInCycle(uint256 cycle, uint256 evermarkId) external view returns (uint256) {
        return votingCycles[cycle].evermarkVotes[evermarkId];
    }

    function getUserVotesForEvermark(address user, uint256 evermarkId) external view returns (uint256) {
        return votingCycles[currentCycle].userEvermarkVotes[user][evermarkId];
    }

    function getUserVotesInCycle(uint256 cycle, address user, uint256 evermarkId) external view returns (uint256) {
        return votingCycles[cycle].userEvermarkVotes[user][evermarkId];
    }

    function getTotalUserVotesInCurrentCycle(address user) external view returns (uint256) {
        return votingCycles[currentCycle].userTotalVotes[user];
    }

    function getTotalUserVotesInCycle(uint256 cycle, address user) external view returns (uint256) {
        return votingCycles[cycle].userTotalVotes[user];
    }

    function getEvermarksWithVotesInCycle(uint256 cycle) external view returns (uint256[] memory) {
        return votingCycles[cycle].activeEvermarks;
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
            cycleData.activeEvermarks.length
        );
    }

    function getTopEvermarksInCycle(uint256 cycle, uint256 limit) external view returns (
        uint256[] memory evermarkIds,
        uint256[] memory votes
    ) {
        require(leaderboardComputed[cycle], "Leaderboard not computed for this cycle");
        
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

    function getTopEvermarksInCycleFallback(uint256 cycle, uint256 limit) external view returns (
        uint256[] memory evermarkIds,
        uint256[] memory votes
    ) {
        uint256[] memory activeEvermarks = votingCycles[cycle].activeEvermarks;
        require(activeEvermarks.length <= 500, "Too many evermarks for fallback method");
        
        uint256 count = activeEvermarks.length > limit ? limit : activeEvermarks.length;
        
        evermarkIds = new uint256[](count);
        votes = new uint256[](count);
        
        for (uint256 i = 0; i < count; i++) {
            uint256 maxVotes = 0;
            uint256 maxIndex = 0;
            
            for (uint256 j = 0; j < activeEvermarks.length; j++) {
                uint256 evermarkVotes = votingCycles[cycle].evermarkVotes[activeEvermarks[j]];
                if (evermarkVotes > maxVotes) {
                    bool alreadyIncluded = false;
                    for (uint256 k = 0; k < i; k++) {
                        if (evermarkIds[k] == activeEvermarks[j]) {
                            alreadyIncluded = true;
                            break;
                        }
                    }
                    if (!alreadyIncluded) {
                        maxVotes = evermarkVotes;
                        maxIndex = j;
                    }
                }
            }
            
            if (maxVotes > 0) {
                evermarkIds[i] = activeEvermarks[maxIndex];
                votes[i] = maxVotes;
            }
        }
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
        emit CycleFinalized(cycle, cycleData.totalVotes, cycleData.activeEvermarks.length);
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