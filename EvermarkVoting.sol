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

    // Cycle duration (1 week)
    uint256 public constant CYCLE_DURATION = 7 days;

    struct VotingCycle {
        uint256 startTime;
        uint256 endTime;
        uint256 totalVotes;
        uint256 totalDelegations;
        bool finalized;
        mapping(uint256 => uint256) bookmarkVotes; // bookmarkId => total votes
        mapping(address => uint256) userTotalVotes; // user => total votes delegated this cycle
        mapping(address => mapping(uint256 => uint256)) userBookmarkVotes; // user => bookmarkId => votes
        uint256[] activeBookmarks; // bookmarks with votes this cycle
    }

    // Storage
    ICardCatalog public cardCatalog;
    IEvermarkNFT public evermarkNFT;
    
    uint256 public currentCycle;
    uint256 public cycleStartTime;
    
    mapping(uint256 => VotingCycle) public votingCycles;
    
    // Global tracking
    mapping(uint256 => uint256) public totalBookmarkVotes; // bookmarkId => all-time total votes
    mapping(address => uint256) public totalUserDelegations; // user => all-time delegations
    
    // Events
    event NewVotingCycle(uint256 indexed cycleNumber, uint256 timestamp);
    event VoteDelegated(address indexed user, uint256 indexed bookmarkId, uint256 amount, uint256 indexed cycle);
    event VoteUndelegated(address indexed user, uint256 indexed bookmarkId, uint256 amount, uint256 indexed cycle);
    event CycleFinalized(uint256 indexed cycleNumber, uint256 totalVotes, uint256 totalBookmarks);

    /// @custom:oz-upgrades-unsafe-allow constructor
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
        
        // Start first cycle
        currentCycle = 1;
        cycleStartTime = block.timestamp;
        
        VotingCycle storage cycle = votingCycles[currentCycle];
        cycle.startTime = block.timestamp;
        cycle.endTime = block.timestamp + CYCLE_DURATION;
        cycle.finalized = false;
        
        emit NewVotingCycle(currentCycle, block.timestamp);
    }

    // Delegate votes to an Evermark
    function delegateVotes(uint256 bookmarkId, uint256 amount) external whenNotPaused nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        require(evermarkNFT.exists(bookmarkId), "Bookmark does not exist");
        
        // Check if user has enough available voting power
        uint256 availablePower = cardCatalog.getAvailableVotingPower(msg.sender);
        require(availablePower >= amount, "Insufficient voting power");
        
        // Prevent voting on own Evermarks
        address bookmarkCreator = evermarkNFT.getEvermarkCreator(bookmarkId);
        require(bookmarkCreator != msg.sender, "Cannot vote on own Evermark");
        
        // Check and start new cycle if needed
        _checkAndStartNewCycle();
        
        VotingCycle storage cycle = votingCycles[currentCycle];
        require(!cycle.finalized, "Current cycle is finalized");
        
        // Record vote delegation
        cycle.bookmarkVotes[bookmarkId] += amount;
        cycle.userTotalVotes[msg.sender] += amount;
        cycle.userBookmarkVotes[msg.sender][bookmarkId] += amount;
        cycle.totalVotes += amount;
        cycle.totalDelegations++;
        
        // Add to active bookmarks if first vote
        if (cycle.userBookmarkVotes[msg.sender][bookmarkId] == amount) {
            _addToActiveBookmarks(currentCycle, bookmarkId);
        }
        
        // Update global tracking
        totalBookmarkVotes[bookmarkId] += amount;
        totalUserDelegations[msg.sender] += amount;
        
        // Update user's delegation in CardCatalog
        uint256 totalDelegated = _getUserTotalDelegatedPower(msg.sender);
        cardCatalog.updateVotingPowerDelegation(msg.sender, totalDelegated);
        
        emit VoteDelegated(msg.sender, bookmarkId, amount, currentCycle);
    }

    // Undelegate votes from an Evermark
    function undelegateVotes(uint256 bookmarkId, uint256 amount) external whenNotPaused nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        
        // Check and start new cycle if needed
        _checkAndStartNewCycle();
        
        VotingCycle storage cycle = votingCycles[currentCycle];
        require(!cycle.finalized, "Current cycle is finalized");
        
        uint256 userVotes = cycle.userBookmarkVotes[msg.sender][bookmarkId];
        require(userVotes >= amount, "Insufficient delegated votes");
        
        // Update vote records
        cycle.bookmarkVotes[bookmarkId] -= amount;
        cycle.userTotalVotes[msg.sender] -= amount;
        cycle.userBookmarkVotes[msg.sender][bookmarkId] -= amount;
        cycle.totalVotes -= amount;
        
        // Update global tracking
        totalBookmarkVotes[bookmarkId] -= amount;
        totalUserDelegations[msg.sender] -= amount;
        
        // Update user's delegation in CardCatalog
        uint256 totalDelegated = _getUserTotalDelegatedPower(msg.sender);
        cardCatalog.updateVotingPowerDelegation(msg.sender, totalDelegated);
        
        emit VoteUndelegated(msg.sender, bookmarkId, amount, currentCycle);
    }

    // Batch delegate votes to multiple Evermarks
    function delegateVotesBatch(
        uint256[] calldata bookmarkIds,
        uint256[] calldata amounts
    ) external whenNotPaused nonReentrant {
        require(bookmarkIds.length == amounts.length, "Array length mismatch");
        require(bookmarkIds.length <= 20, "Batch size too large");
        
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            totalAmount += amounts[i];
        }
        
        uint256 availablePower = cardCatalog.getAvailableVotingPower(msg.sender);
        require(availablePower >= totalAmount, "Insufficient voting power");
        
        for (uint256 i = 0; i < bookmarkIds.length; i++) {
            if (amounts[i] > 0) {
                _delegateVotesInternal(bookmarkIds[i], amounts[i]);
            }
        }
    }

    // Internal delegation function
    function _delegateVotesInternal(uint256 bookmarkId, uint256 amount) internal {
        require(evermarkNFT.exists(bookmarkId), "Bookmark does not exist");
        
        address bookmarkCreator = evermarkNFT.getEvermarkCreator(bookmarkId);
        require(bookmarkCreator != msg.sender, "Cannot vote on own Evermark");
        
        _checkAndStartNewCycle();
        
        VotingCycle storage cycle = votingCycles[currentCycle];
        require(!cycle.finalized, "Current cycle is finalized");
        
        // Record vote delegation
        cycle.bookmarkVotes[bookmarkId] += amount;
        cycle.userTotalVotes[msg.sender] += amount;
        cycle.userBookmarkVotes[msg.sender][bookmarkId] += amount;
        cycle.totalVotes += amount;
        cycle.totalDelegations++;
        
        // Add to active bookmarks if first vote
        if (cycle.userBookmarkVotes[msg.sender][bookmarkId] == amount) {
            _addToActiveBookmarks(currentCycle, bookmarkId);
        }
        
        // Update global tracking
        totalBookmarkVotes[bookmarkId] += amount;
        totalUserDelegations[msg.sender] += amount;
        
        emit VoteDelegated(msg.sender, bookmarkId, amount, currentCycle);
    }

    // Check if new cycle should start
    function _checkAndStartNewCycle() internal {
        VotingCycle storage cycle = votingCycles[currentCycle];
        
        if (block.timestamp >= cycle.endTime && !cycle.finalized) {
            startNewVotingCycle();
        }
    }

    // Start a new voting cycle
    function startNewVotingCycle() public onlyRole(CYCLE_MANAGER_ROLE) {
        VotingCycle storage oldCycle = votingCycles[currentCycle];
        
        // Finalize current cycle
        if (!oldCycle.finalized) {
            oldCycle.finalized = true;
            emit CycleFinalized(currentCycle, oldCycle.totalVotes, oldCycle.activeBookmarks.length);
        }
        
        // Start new cycle
        currentCycle++;
        cycleStartTime = block.timestamp;
        
        VotingCycle storage newCycle = votingCycles[currentCycle];
        newCycle.startTime = block.timestamp;
        newCycle.endTime = block.timestamp + CYCLE_DURATION;
        newCycle.finalized = false;
        
        emit NewVotingCycle(currentCycle, block.timestamp);
    }

    // Add bookmark to active list if not already present
    function _addToActiveBookmarks(uint256 cycleNum, uint256 bookmarkId) internal {
        uint256[] storage activeBookmarks = votingCycles[cycleNum].activeBookmarks;
        
        // Check if already in list
        for (uint256 i = 0; i < activeBookmarks.length; i++) {
            if (activeBookmarks[i] == bookmarkId) {
                return;
            }
        }
        
        activeBookmarks.push(bookmarkId);
    }

    // Calculate user's total delegated power across all active cycles
    function _getUserTotalDelegatedPower(address user) internal view returns (uint256) {
        // For simplicity, just return current cycle votes
        // In production, might need to track across multiple active cycles
        return votingCycles[currentCycle].userTotalVotes[user];
    }

    // View functions
    function getCurrentCycle() external view returns (uint256) {
        return currentCycle;
    }

    function getBookmarkVotes(uint256 bookmarkId) external view returns (uint256) {
        return totalBookmarkVotes[bookmarkId];
    }

    function getBookmarkVotesInCycle(uint256 cycle, uint256 bookmarkId) external view returns (uint256) {
        return votingCycles[cycle].bookmarkVotes[bookmarkId];
    }

    function getUserVotesForBookmark(address user, uint256 bookmarkId) external view returns (uint256) {
        return votingCycles[currentCycle].userBookmarkVotes[user][bookmarkId];
    }

    function getUserVotesInCycle(uint256 cycle, address user, uint256 bookmarkId) external view returns (uint256) {
        return votingCycles[cycle].userBookmarkVotes[user][bookmarkId];
    }

    function getTotalUserVotesInCurrentCycle(address user) external view returns (uint256) {
        return votingCycles[currentCycle].userTotalVotes[user];
    }

    function getTotalUserVotesInCycle(uint256 cycle, address user) external view returns (uint256) {
        return votingCycles[cycle].userTotalVotes[user];
    }

    function getBookmarksWithVotesInCycle(uint256 cycle) external view returns (uint256[] memory) {
        return votingCycles[cycle].activeBookmarks;
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
        uint256 activeBookmarksCount
    ) {
        VotingCycle storage cycleData = votingCycles[cycle];
        return (
            cycleData.startTime,
            cycleData.endTime,
            cycleData.totalVotes,
            cycleData.totalDelegations,
            cycleData.finalized,
            cycleData.activeBookmarks.length
        );
    }

    // Get top bookmarks for a cycle (for leaderboard)
    function getTopBookmarksInCycle(uint256 cycle, uint256 limit) external view returns (
        uint256[] memory bookmarkIds,
        uint256[] memory votes
    ) {
        uint256[] memory activeBookmarks = votingCycles[cycle].activeBookmarks;
        uint256 count = activeBookmarks.length > limit ? limit : activeBookmarks.length;
        
        bookmarkIds = new uint256[](count);
        votes = new uint256[](count);
        
        // Simple sorting (in production, use more efficient sorting)
        for (uint256 i = 0; i < count; i++) {
            uint256 maxVotes = 0;
            uint256 maxIndex = 0;
            
            for (uint256 j = 0; j < activeBookmarks.length; j++) {
                uint256 bookmarkVotes = votingCycles[cycle].bookmarkVotes[activeBookmarks[j]];
                if (bookmarkVotes > maxVotes) {
                    bool alreadyIncluded = false;
                    for (uint256 k = 0; k < i; k++) {
                        if (bookmarkIds[k] == activeBookmarks[j]) {
                            alreadyIncluded = true;
                            break;
                        }
                    }
                    if (!alreadyIncluded) {
                        maxVotes = bookmarkVotes;
                        maxIndex = j;
                    }
                }
            }
            
            if (maxVotes > 0) {
                bookmarkIds[i] = activeBookmarks[maxIndex];
                votes[i] = maxVotes;
            }
        }
    }

    // Admin functions
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

    // Emergency cycle management
    function emergencyFinalizeCycle(uint256 cycle) external onlyRole(ADMIN_ROLE) {
        VotingCycle storage cycleData = votingCycles[cycle];
        require(!cycleData.finalized, "Cycle already finalized");
        
        cycleData.finalized = true;
        emit CycleFinalized(cycle, cycleData.totalVotes, cycleData.activeBookmarks.length);
    }

    function emergencyStartNewCycle() external onlyRole(ADMIN_ROLE) {
        startNewVotingCycle();
    }

    // Check if cycle should auto-advance
    function checkAndStartNewCycle() external returns (bool) {
        VotingCycle storage cycle = votingCycles[currentCycle];
        
        if (block.timestamp >= cycle.endTime && !cycle.finalized) {
            startNewVotingCycle();
            return true;
        }
        
        return false;
    }

    // Required overrides
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}