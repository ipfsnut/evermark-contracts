// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";

/*
 ██████╗ █████╗ ██╗      ██████╗██╗   ██╗██╗      █████╗ ████████╗ ██████╗ ██████╗ 
██╔════╝██╔══██╗██║     ██╔════╝██║   ██║██║     ██╔══██╗╚══██╔══╝██╔═══██╗██╔══██╗
██║     ███████║██║     ██║     ██║   ██║██║     ███████║   ██║   ██║   ██║██████╔╝
██║     ██╔══██║██║     ██║     ██║   ██║██║     ██╔══██║   ██║   ██║   ██║██╔══██╗
╚██████╗██║  ██║███████╗╚██████╗╚██████╔╝███████╗██║  ██║   ██║   ╚██████╔╝██║  ██║
 ╚═════╝╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚═════╝ ╚══════╝╚═╝  ╚═╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝
            OPTIMIZED REWARD CALCULATION & MERKLE GENERATION
*/

interface ICardCatalog {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function getDelegatedVotingPower(address user) external view returns (uint256);
}

/**
 * @title RewardCalculatorHelper
 * @dev Helper contract for calculating rewards and generating merkle tree data
 * This contract does the heavy computation off-chain friendly
 */
contract RewardCalculatorHelper is Ownable {
    
    ICardCatalog public cardCatalog;
    
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant TOKEN_STAKER_BPS = 6000;  // 60%
    uint256 private constant BASE_VARIABLE_SPLIT = 5000; // 50/50 split
    
    struct UserRewardData {
        address user;
        uint256 baseReward;
        uint256 variableReward;
        uint256 totalReward;
    }
    
    struct RewardCalculationInput {
        uint256 totalRewardPool;
        uint256 totalStaked;
        address[] users;
        uint256[] userStakes;
        uint256[] userDelegated;
    }
    
    event RewardsCalculated(uint256 indexed week, uint256 userCount, uint256 totalDistributed);
    
    constructor(address _cardCatalog) Ownable(msg.sender) {
        cardCatalog = ICardCatalog(_cardCatalog);
    }
    
    /**
     * @notice Calculate rewards for a batch of users - optimized for off-chain usage
     * @param input Packed input data to avoid stack too deep
     * @return rewards Array of user reward data
     */
    function calculateBatchRewards(
        RewardCalculationInput calldata input
    ) external view returns (UserRewardData[] memory rewards) {
        require(input.users.length == input.userStakes.length, "Array length mismatch");
        require(input.users.length == input.userDelegated.length, "Array length mismatch");
        require(input.totalStaked > 0, "Total staked cannot be zero");
        
        uint256 userCount = input.users.length;
        rewards = new UserRewardData[](userCount);
        
        // Calculate pool splits
        uint256 tokenStakerPool = (input.totalRewardPool * TOKEN_STAKER_BPS) / BASIS_POINTS;
        uint256 basePool = (tokenStakerPool * BASE_VARIABLE_SPLIT) / BASIS_POINTS;
        uint256 variablePool = tokenStakerPool - basePool;
        
        // Calculate rewards for each user
        for (uint256 i = 0; i < userCount; i++) {
            address user = input.users[i];
            uint256 userStake = input.userStakes[i];
            uint256 userDelegated = input.userDelegated[i];
            
            // Base rewards: proportional to stake
            uint256 baseReward = (basePool * userStake) / input.totalStaked;
            
            // Variable rewards: based on delegation percentage
            uint256 delegationPercentage = userStake > 0 ? (userDelegated * BASIS_POINTS) / userStake : 0;
            uint256 userMaxVariable = (variablePool * userStake) / input.totalStaked;
            uint256 variableReward = (userMaxVariable * delegationPercentage) / BASIS_POINTS;
            
            rewards[i] = UserRewardData({
                user: user,
                baseReward: baseReward,
                variableReward: variableReward,
                totalReward: baseReward + variableReward
            });
        }
        
        return rewards;
    }
    
    /**
     * @notice Calculate rewards using live data from CardCatalog
     * @param week Week number for event emission
     * @param totalRewardPool Total reward pool for the week
     * @param users Array of user addresses
     * @return rewards Array of calculated rewards
     */
    function calculateRewardsLive(
        uint256 week,
        uint256 totalRewardPool,
        address[] calldata users
    ) external returns (UserRewardData[] memory rewards) {
        uint256 userCount = users.length;
        require(userCount > 0 && userCount <= 1000, "Invalid user count");
        
        // Get total staked from CardCatalog
        uint256 totalStaked = cardCatalog.totalSupply();
        require(totalStaked > 0, "No tokens staked");
        
        // Prepare arrays for batch calculation
        uint256[] memory userStakes = new uint256[](userCount);
        uint256[] memory userDelegated = new uint256[](userCount);
        
        // Batch fetch user data
        for (uint256 i = 0; i < userCount; i++) {
            userStakes[i] = cardCatalog.balanceOf(users[i]);
            userDelegated[i] = cardCatalog.getDelegatedVotingPower(users[i]);
        }
        
        // Create input struct
        RewardCalculationInput memory input = RewardCalculationInput({
            totalRewardPool: totalRewardPool,
            totalStaked: totalStaked,
            users: users,
            userStakes: userStakes,
            userDelegated: userDelegated
        });
        
        // Calculate rewards
        rewards = this.calculateBatchRewards(input);
        
        // Calculate total distributed for event
        uint256 totalDistributed = 0;
        for (uint256 i = 0; i < userCount; i++) {
            totalDistributed += rewards[i].totalReward;
        }
        
        emit RewardsCalculated(week, userCount, totalDistributed);
        
        return rewards;
    }
    
    /**
     * @notice Generate merkle tree leaf data for rewards
     * @param rewards Array of user reward data
     * @return leaves Array of merkle tree leaves
     */
    function generateMerkleLeaves(
        UserRewardData[] calldata rewards
    ) external pure returns (bytes32[] memory leaves) {
        uint256 length = rewards.length;
        leaves = new bytes32[](length);
        
        for (uint256 i = 0; i < length; i++) {
            leaves[i] = keccak256(abi.encodePacked(
                rewards[i].user,
                rewards[i].totalReward
            ));
        }
        
        return leaves;
    }
    
    /**
     * @notice Simulate reward distribution to check for errors
     * @param totalRewardPool Total reward pool
     * @param users Array of user addresses to simulate
     * @return success Whether simulation succeeded
     * @return totalDistributed Total amount that would be distributed
     * @return userCount Number of users that would receive rewards
     */
    function simulateRewardDistribution(
        uint256 totalRewardPool,
        address[] calldata users
    ) external view returns (
        bool success,
        uint256 totalDistributed,
        uint256 userCount
    ) {
        try this.calculateRewardsLive(0, totalRewardPool, users) returns (UserRewardData[] memory rewards) {
            totalDistributed = 0;
            userCount = 0;
            
            for (uint256 i = 0; i < rewards.length; i++) {
                if (rewards[i].totalReward > 0) {
                    totalDistributed += rewards[i].totalReward;
                    userCount++;
                }
            }
            
            success = true;
        } catch {
            success = false;
            totalDistributed = 0;
            userCount = 0;
        }
    }
    
    /**
     * @notice Get reward calculation constants
     */
    function getRewardConstants() external pure returns (
        uint256 tokenStakerBps,
        uint256 creatorBps,
        uint256 baseVariableSplit,
        uint256 basisPoints
    ) {
        return (TOKEN_STAKER_BPS, BASIS_POINTS - TOKEN_STAKER_BPS, BASE_VARIABLE_SPLIT, BASIS_POINTS);
    }
    
    /**
     * @notice Update CardCatalog address
     */
    function setCardCatalog(address _cardCatalog) external onlyOwner {
        require(_cardCatalog != address(0), "Invalid address");
        cardCatalog = ICardCatalog(_cardCatalog);
    }
    
    /**
     * @notice Calculate expected rewards for a single user
     */
    function calculateUserReward(
        uint256 totalRewardPool,
        uint256 totalStaked,
        uint256 userStake,
        uint256 userDelegated
    ) external pure returns (
        uint256 baseReward,
        uint256 variableReward,
        uint256 totalReward
    ) {
        require(totalStaked > 0, "Total staked cannot be zero");
        
        uint256 tokenStakerPool = (totalRewardPool * TOKEN_STAKER_BPS) / BASIS_POINTS;
        uint256 basePool = (tokenStakerPool * BASE_VARIABLE_SPLIT) / BASIS_POINTS;
        uint256 variablePool = tokenStakerPool - basePool;
        
        // Base rewards: proportional to stake
        baseReward = (basePool * userStake) / totalStaked;
        
        // Variable rewards: based on delegation percentage
        uint256 delegationPercentage = userStake > 0 ? (userDelegated * BASIS_POINTS) / userStake : 0;
        uint256 userMaxVariable = (variablePool * userStake) / totalStaked;
        variableReward = (userMaxVariable * delegationPercentage) / BASIS_POINTS;
        
        totalReward = baseReward + variableReward;
    }
}
