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

interface IStakingDataProvider {
    function getBatchStakingData(address[] calldata users) external view returns (
        uint256[] memory balances,
        uint256[] memory delegated,
        uint256 totalSupply
    );
}

interface IRewardDistributor {
    function processCreatorRewards(uint256 week, uint256 amount) external;
}

contract EvermarkRewards is 
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    
    uint256 private constant WEEK_DURATION = 7 days;
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant TOKEN_STAKER_BPS = 6000;
    uint256 private constant CREATOR_BPS = 4000;
    uint256 private constant BASE_VARIABLE_SPLIT = 5000;

    struct WeekData {
        uint128 rewardPool;
        uint128 creatorPool;
        uint32 finalizedAt;
        bool finalized;
        bool merkleGenerated;
    }
    
    struct StakingSnapshot {
        uint256 totalStaked;
        uint256 snapshotTime;
        uint256 blockNumber;
    }
    
    struct UserClaimData {
        uint128 totalClaimed;
        uint64 lastClaimWeek;
        uint64 lastClaimTime;
    }

    IERC20 public rewardToken;
    IStakingDataProvider public stakingProvider;
    IRewardDistributor public rewardDistributor;
    
    uint256 public currentWeek;
    uint256 public protocolStartTime;
    
    mapping(uint256 => WeekData) public weekData;
    mapping(uint256 => bytes32) public weeklyMerkleRoots;
    mapping(uint256 => mapping(uint256 => uint256)) public claimedBitmap;
    mapping(address => uint256) public userIndex;
    mapping(uint256 => address) public indexToUser;
    uint256 public nextUserIndex;
    mapping(address => UserClaimData) public userClaims;
    mapping(uint256 => StakingSnapshot) public stakingSnapshots;
    uint256 public emergencyPauseUntil;

    event WeekFinalized(uint256 indexed week, uint256 rewardPool, uint256 creatorPool);
    event MerkleRootSet(uint256 indexed week, bytes32 merkleRoot);
    event RewardsClaimed(address indexed user, uint256 indexed week, uint256 amount);
    event RewardsFunded(uint256 indexed week, uint256 amount);
    event StakingSnapshotCached(uint256 indexed week, uint256 totalStaked);

    modifier onlyWhenActive() {
        require(block.timestamp > emergencyPauseUntil, "Emergency pause active");
        _;
    }
    
    modifier validWeek(uint256 week) {
        require(week > 0 && week <= currentWeek, "Invalid week");
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _rewardToken,
        address _stakingProvider
    ) external initializer {
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(DISTRIBUTOR_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);

        rewardToken = IERC20(_rewardToken);
        stakingProvider = IStakingDataProvider(_stakingProvider);
        
        protocolStartTime = block.timestamp;
        currentWeek = 1;
        nextUserIndex = 1;
        
        emit WeekFinalized(1, 0, 0);
    }

    function fundWeeklyRewards(uint256 amount) external onlyRole(DISTRIBUTOR_ROLE) onlyWhenActive {
        require(amount > 0, "Amount must be > 0");
        
        _autoAdvanceWeek();
        
        rewardToken.transferFrom(msg.sender, address(this), amount);
        
        WeekData storage week = weekData[currentWeek];
        uint256 creatorAmount = (amount * CREATOR_BPS) / BASIS_POINTS;
        
        week.rewardPool += uint128(amount);
        week.creatorPool += uint128(creatorAmount);
        
        emit RewardsFunded(currentWeek, amount);
    }
    
    function _autoAdvanceWeek() internal {
        uint256 expectedWeek = _calculateCurrentWeek();
        if (expectedWeek > currentWeek) {
            currentWeek = expectedWeek;
            emit WeekFinalized(currentWeek, 0, 0);
        }
    }
    
    function _calculateCurrentWeek() internal view returns (uint256) {
        return ((block.timestamp - protocolStartTime) / WEEK_DURATION) + 1;
    }

    function finalizeWeek(
        uint256 week,
        uint256 stakingSnapshot
    ) external onlyRole(ADMIN_ROLE) validWeek(week) {
        require(!weekData[week].finalized, "Week already finalized");
        require(week < currentWeek, "Cannot finalize current week");
        
        WeekData storage weekDataItem = weekData[week];
        weekDataItem.finalized = true;
        weekDataItem.finalizedAt = uint32(block.timestamp);
        
        stakingSnapshots[week] = StakingSnapshot({
            totalStaked: stakingSnapshot,
            snapshotTime: block.timestamp,
            blockNumber: block.number
        });
        
        if (address(rewardDistributor) != address(0) && weekDataItem.creatorPool > 0) {
            rewardDistributor.processCreatorRewards(week, weekDataItem.creatorPool);
        }
        
        emit WeekFinalized(week, weekDataItem.rewardPool, weekDataItem.creatorPool);
        emit StakingSnapshotCached(week, stakingSnapshot);
    }

    function setWeeklyMerkleRoot(
        uint256 week,
        bytes32 merkleRoot
    ) external onlyRole(ADMIN_ROLE) validWeek(week) {
        require(weekData[week].finalized, "Week not finalized");
        require(merkleRoot != bytes32(0), "Invalid merkle root");
        
        weeklyMerkleRoots[week] = merkleRoot;
        weekData[week].merkleGenerated = true;
        
        emit MerkleRootSet(week, merkleRoot);
    }
    
    function batchClaimRewards(
        uint256[] calldata weekNumbers,
        uint256[] calldata amounts,
        bytes32[][] calldata merkleProofs
    ) external nonReentrant whenNotPaused onlyWhenActive {
        uint256 length = weekNumbers.length;
        require(length > 0 && length <= 50, "Invalid batch size");
        require(length == amounts.length && length == merkleProofs.length, "Array length mismatch");
        
        uint256 totalAmount = 0;
        uint256 userIdx = _getUserIndex(msg.sender);
        
        for (uint256 i = 0; i < length; i++) {
            uint256 week = weekNumbers[i];
            uint256 amount = amounts[i];
            
            require(week > 0 && week < currentWeek, "Invalid week");
            require(amount > 0, "Invalid amount");
            require(weeklyMerkleRoots[week] != bytes32(0), "Merkle root not set");
            
            require(!_isRewardClaimed(week, userIdx), "Already claimed");
            
            require(
                _verifyMerkleProof(merkleProofs[i], weeklyMerkleRoots[week], msg.sender, amount),
                "Invalid merkle proof"
            );
            
            _setRewardClaimed(week, userIdx);
            totalAmount += amount;
            
            emit RewardsClaimed(msg.sender, week, amount);
        }
        
        if (totalAmount > 0) {
            UserClaimData storage userData = userClaims[msg.sender];
            userData.totalClaimed += uint128(totalAmount);
            userData.lastClaimWeek = uint64(weekNumbers[length - 1]);
            userData.lastClaimTime = uint64(block.timestamp);
            
            rewardToken.transfer(msg.sender, totalAmount);
        }
    }
    
    function _getUserIndex(address user) internal returns (uint256) {
        uint256 idx = userIndex[user];
        if (idx == 0) {
            idx = nextUserIndex++;
            userIndex[user] = idx;
            indexToUser[idx] = user;
        }
        return idx;
    }
    
    function _isRewardClaimed(uint256 week, uint256 userIdx) internal view returns (bool) {
        uint256 wordIndex = userIdx / 256;
        uint256 bitIndex = userIdx % 256;
        return (claimedBitmap[week][wordIndex] >> bitIndex) & 1 == 1;
    }
    
    function _setRewardClaimed(uint256 week, uint256 userIdx) internal {
        uint256 wordIndex = userIdx / 256;
        uint256 bitIndex = userIdx % 256;
        claimedBitmap[week][wordIndex] |= (1 << bitIndex);
    }
    
    function _verifyMerkleProof(
        bytes32[] memory proof,
        bytes32 root,
        address user,
        uint256 amount
    ) internal pure returns (bool) {
        bytes32 leaf = keccak256(abi.encodePacked(user, amount));
        bytes32 computedHash = leaf;
        
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 proofElement = proof[i];
            if (computedHash <= proofElement) {
                computedHash = keccak256(abi.encodePacked(computedHash, proofElement));
            } else {
                computedHash = keccak256(abi.encodePacked(proofElement, computedHash));
            }
        }
        
        return computedHash == root;
    }

    function getCurrentWeekInfo() external view returns (
        uint256 week,
        uint256 timeRemaining,
        uint256 rewardPool,
        bool finalized
    ) {
        week = _calculateCurrentWeek();
        uint256 weekStart = protocolStartTime + (week - 1) * WEEK_DURATION;
        uint256 weekEnd = weekStart + WEEK_DURATION;
        timeRemaining = block.timestamp >= weekEnd ? 0 : weekEnd - block.timestamp;
        
        WeekData memory weekDataItem = weekData[week];
        rewardPool = weekDataItem.rewardPool;
        finalized = weekDataItem.finalized;
    }
    
    function getUserClaimSummary(address user) external view returns (
        uint256 totalClaimed,
        uint256 lastClaimWeek,
        uint256 lastClaimTime,
        uint256 userIdx
    ) {
        UserClaimData memory userData = userClaims[user];
        return (
            userData.totalClaimed,
            userData.lastClaimWeek,
            userData.lastClaimTime,
            userIndex[user]
        );
    }
    
    function checkClaimedStatus(
        address user,
        uint256[] calldata weekNumbers
    ) external view returns (bool[] memory claimed) {
        uint256 userIdx = userIndex[user];
        claimed = new bool[](weekNumbers.length);
        
        if (userIdx == 0) {
            return claimed;
        }
        
        for (uint256 i = 0; i < weekNumbers.length; i++) {
            claimed[i] = _isRewardClaimed(weekNumbers[i], userIdx);
        }
    }
    
    function getWeekData(uint256 week) external view validWeek(week) returns (
        uint256 rewardPool,
        uint256 creatorPool,
        uint256 finalizedAt,
        bool finalized,
        bool merkleGenerated,
        bytes32 merkleRoot
    ) {
        WeekData memory weekDataItem = weekData[week];
        return (
            weekDataItem.rewardPool,
            weekDataItem.creatorPool,
            weekDataItem.finalizedAt,
            weekDataItem.finalized,
            weekDataItem.merkleGenerated,
            weeklyMerkleRoots[week]
        );
    }

    function setEmergencyPause(uint256 pauseUntil) external onlyRole(ADMIN_ROLE) {
        emergencyPauseUntil = pauseUntil;
    }
    
    function setStakingProvider(address _stakingProvider) external onlyRole(ADMIN_ROLE) {
        require(_stakingProvider != address(0), "Invalid address");
        stakingProvider = IStakingDataProvider(_stakingProvider);
    }
    
    function setRewardDistributor(address _rewardDistributor) external onlyRole(ADMIN_ROLE) {
        rewardDistributor = IRewardDistributor(_rewardDistributor);
    }
    
    function emergencyWithdraw(
        address token,
        uint256 amount,
        address recipient
    ) external onlyRole(ADMIN_ROLE) {
        require(recipient != address(0), "Invalid recipient");
        IERC20(token).transfer(recipient, amount);
    }
    
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }
    
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function calculateRewardSplit(uint256 totalPool) external pure returns (
        uint256 tokenStakerPool,
        uint256 creatorPool,
        uint256 basePool,
        uint256 variablePool
    ) {
        tokenStakerPool = (totalPool * TOKEN_STAKER_BPS) / BASIS_POINTS;
        creatorPool = totalPool - tokenStakerPool;
        basePool = (tokenStakerPool * BASE_VARIABLE_SPLIT) / BASIS_POINTS;
        variablePool = tokenStakerPool - basePool;
    }
    
    function version() external pure returns (string memory) {
        return "2.0.0";
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
    
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
