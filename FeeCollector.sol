// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/*
 ███████╗███████╗███████╗     ██████╗ ██████╗ ██╗     ██╗     ███████╗ ██████╗████████╗ ██████╗ ██████╗ 
 ██╔════╝██╔════╝██╔════╝    ██╔════╝██╔═══██╗██║     ██║     ██╔════╝██╔════╝╚══██╔══╝██╔═══██╗██╔══██╗
 █████╗  █████╗  █████╗      ██║     ██║   ██║██║     ██║     █████╗  ██║        ██║   ██║   ██║██████╔╝
 ██╔══╝  ██╔══╝  ██╔══╝      ██║     ██║   ██║██║     ██║     ██╔══╝  ██║        ██║   ██║   ██║██╔══██╗
 ██║     ███████╗███████╗    ╚██████╗╚██████╔╝███████╗███████╗███████╗╚██████╗   ██║   ╚██████╔╝██║  ██║
 ╚═╝     ╚══════╝╚══════╝     ╚═════╝ ╚═════╝ ╚══════╝╚══════╝╚══════╝ ╚═════╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝
*/

interface IEvermarkRewards {
    function distributeProtocolFees(uint256 amount) external;
}

contract FeeCollector is Ownable, ReentrancyGuard {
    address public evermarkRewards;
    address public treasuryWallet;
    address public devWallet;
    IERC20 public emarkToken;
    
    uint256 public totalEmarkCollected;
    uint256 public totalEthCollected; 
    uint256 public totalNftFeesCollected;
    uint256 public totalAuctionFeesCollected;
    
    uint256 public pendingTreasuryEth;
    uint256 public pendingDevEth;
    uint256 public pendingRewardsEth;
    
    uint256 public treasuryPercentage = 3000;
    uint256 public devPercentage = 1000;
    uint256 public rewardsPercentage = 6000;
    
    uint256 public emergencyPauseTimestamp;
    
    event EmarkFeesCollected(uint256 amount);
    event EthFeesCollected(uint256 amount);
    event NftFeesCollected(uint256 amount);
    event AuctionFeesCollected(uint256 amount);
    event FeesRouted(address indexed destination, uint256 amount, string feeType);
    event FeePercentagesUpdated(uint256 treasury, uint256 dev, uint256 rewards);
    event ContractUpdated(string contractType, address indexed oldAddress, address indexed newAddress);
    event FeesStored(uint256 treasury, uint256 dev, uint256 rewards);
    event EmergencyPauseSet(uint256 timestamp);
    
    modifier notInEmergency() {
        require(block.timestamp > emergencyPauseTimestamp, "Emergency pause active");
        _;
    }
    
    constructor(
        address _treasuryWallet,
        address _devWallet
    ) Ownable(msg.sender) {
        require(_treasuryWallet != address(0), "Invalid treasury wallet");
        require(_devWallet != address(0), "Invalid dev wallet");
        
        treasuryWallet = _treasuryWallet;
        devWallet = _devWallet;
        emergencyPauseTimestamp = 0;
    }
    
    function collectNftCreationFees() external payable notInEmergency {
        require(msg.value > 0, "No fees to collect");
        totalNftFeesCollected += msg.value;
        totalEthCollected += msg.value;
        emit NftFeesCollected(msg.value);
        
        _storeFees(msg.value);
    }
    
    function collectAuctionFees() external payable notInEmergency {
        require(msg.value > 0, "No fees to collect");
        totalAuctionFeesCollected += msg.value;
        totalEthCollected += msg.value;
        emit AuctionFeesCollected(msg.value);
        
        _storeFees(msg.value);
    }
    
    function _storeFees(uint256 amount) internal {
        if (amount == 0) return;
        
        uint256 toTreasury = (amount * treasuryPercentage) / 10000;
        uint256 toDev = (amount * devPercentage) / 10000;
        uint256 toRewards = amount - toTreasury - toDev;
        
        pendingTreasuryEth += toTreasury;
        pendingDevEth += toDev;
        pendingRewardsEth += toRewards;
        
        emit FeesStored(toTreasury, toDev, toRewards);
    }
    
    function distributePendingEthFees() external nonReentrant notInEmergency {
        uint256 toTreasury = pendingTreasuryEth;
        uint256 toDev = pendingDevEth;
        uint256 toRewards = pendingRewardsEth;
        
        pendingTreasuryEth = 0;
        pendingDevEth = 0;
        pendingRewardsEth = 0;
        
        if (toTreasury > 0 && treasuryWallet != address(0)) {
            (bool success, ) = payable(treasuryWallet).call{value: toTreasury}("");
            if (success) {
                emit FeesRouted(treasuryWallet, toTreasury, "Treasury ETH");
            } else {
                pendingTreasuryEth += toTreasury;
            }
        }
        
        if (toDev > 0 && devWallet != address(0)) {
            (bool success, ) = payable(devWallet).call{value: toDev}("");
            if (success) {
                emit FeesRouted(devWallet, toDev, "Dev ETH");
            } else {
                pendingDevEth += toDev;
            }
        }
        
        if (toRewards > 0) {
            emit FeesRouted(address(this), toRewards, "Rewards ETH Reserve");
        }
    }
    
    function distributeTreasuryFees() external nonReentrant notInEmergency {
        uint256 amount = pendingTreasuryEth;
        require(amount > 0, "No treasury fees to distribute");
        require(treasuryWallet != address(0), "Treasury wallet not set");
        
        pendingTreasuryEth = 0;
        
        (bool success, ) = payable(treasuryWallet).call{value: amount}("");
        if (success) {
            emit FeesRouted(treasuryWallet, amount, "Treasury ETH");
        } else {
            pendingTreasuryEth = amount;
            revert("Treasury transfer failed");
        }
    }
    
    function distributeDevFees() external nonReentrant notInEmergency {
        uint256 amount = pendingDevEth;
        require(amount > 0, "No dev fees to distribute");
        require(devWallet != address(0), "Dev wallet not set");
        
        pendingDevEth = 0;
        
        (bool success, ) = payable(devWallet).call{value: amount}("");
        if (success) {
            emit FeesRouted(devWallet, amount, "Dev ETH");
        } else {
            pendingDevEth = amount;
            revert("Dev transfer failed");
        }
    }
    
    function collectEmarkTradingFees(uint256 amount) external notInEmergency {
        require(amount > 0, "No fees to collect");
        require(address(emarkToken) != address(0), "EMARK token not set");
        
        emarkToken.transferFrom(msg.sender, address(this), amount);
        totalEmarkCollected += amount;
        emit EmarkFeesCollected(amount);
    }
    
    function depositEmarkFees(uint256 amount) external notInEmergency {
        require(amount > 0, "No fees to deposit");
        require(address(emarkToken) != address(0), "EMARK token not set");
        
        emarkToken.transferFrom(msg.sender, address(this), amount);
        totalEmarkCollected += amount;
        emit EmarkFeesCollected(amount);
    }
    
    function routeEmarkToRewards() external nonReentrant notInEmergency {
        require(address(emarkToken) != address(0), "EMARK token not set");
        require(evermarkRewards != address(0), "Rewards contract not set");
        
        uint256 amount = emarkToken.balanceOf(address(this));
        require(amount > 0, "No EMARK to route");
        
        bool transferSuccess = emarkToken.transfer(evermarkRewards, amount);
        require(transferSuccess, "EMARK transfer failed");
        
        try IEvermarkRewards(evermarkRewards).distributeProtocolFees(amount) {
            emit FeesRouted(evermarkRewards, amount, "EMARK");
        } catch {
            emit FeesRouted(evermarkRewards, amount, "EMARK (notification failed)");
        }
    }
    
    function updateFeePercentages(
        uint256 _treasuryPercentage,
        uint256 _devPercentage,
        uint256 _rewardsPercentage
    ) external onlyOwner {
        require(
            _treasuryPercentage + _devPercentage + _rewardsPercentage == 10000,
            "Percentages must sum to 100%"
        );
        
        treasuryPercentage = _treasuryPercentage;
        devPercentage = _devPercentage;
        rewardsPercentage = _rewardsPercentage;
        
        emit FeePercentagesUpdated(_treasuryPercentage, _devPercentage, _rewardsPercentage);
    }
    
    function setEvermarkRewards(address _evermarkRewards) external onlyOwner {
        address oldAddress = evermarkRewards;
        evermarkRewards = _evermarkRewards;
        emit ContractUpdated("EvermarkRewards", oldAddress, _evermarkRewards);
    }
    
    function setEmarkToken(address _emarkToken) external onlyOwner {
        address oldAddress = address(emarkToken);
        emarkToken = IERC20(_emarkToken);
        emit ContractUpdated("EmarkToken", oldAddress, _emarkToken);
    }
    
    function setTreasuryWallet(address _treasuryWallet) external onlyOwner {
        require(_treasuryWallet != address(0), "Invalid treasury wallet");
        address oldAddress = treasuryWallet;
        treasuryWallet = _treasuryWallet;
        emit ContractUpdated("TreasuryWallet", oldAddress, _treasuryWallet);
    }
    
    function setDevWallet(address _devWallet) external onlyOwner {
        require(_devWallet != address(0), "Invalid dev wallet");
        address oldAddress = devWallet;
        devWallet = _devWallet;
        emit ContractUpdated("DevWallet", oldAddress, _devWallet);
    }
    
    function getFeeBreakdown(uint256 amount) external view returns (
        uint256 treasuryAmount,
        uint256 devAmount,
        uint256 rewardsAmount
    ) {
        treasuryAmount = (amount * treasuryPercentage) / 10000;
        devAmount = (amount * devPercentage) / 10000;
        rewardsAmount = amount - treasuryAmount - devAmount;
    }
    
    function getCollectedFees() external view returns (
        uint256 emarkFees,
        uint256 ethFees,
        uint256 nftFees,
        uint256 auctionFees
    ) {
        return (totalEmarkCollected, totalEthCollected, totalNftFeesCollected, totalAuctionFeesCollected);
    }
    
    function getPendingEthFees() external view returns (
        uint256 treasury,
        uint256 dev,
        uint256 rewards,
        uint256 total
    ) {
        return (
            pendingTreasuryEth,
            pendingDevEth,
            pendingRewardsEth,
            pendingTreasuryEth + pendingDevEth + pendingRewardsEth
        );
    }
    
    function setEmergencyPause(uint256 pauseUntilTimestamp) external onlyOwner {
        emergencyPauseTimestamp = pauseUntilTimestamp;
        emit EmergencyPauseSet(pauseUntilTimestamp);
    }
    
    function clearEmergencyPause() external onlyOwner {
        emergencyPauseTimestamp = 0;
        emit EmergencyPauseSet(0);
    }
    
    function emergencyWithdrawEth(address payable recipient) external onlyOwner {
        require(recipient != address(0), "Invalid recipient");
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH to withdraw");
        
        pendingTreasuryEth = 0;
        pendingDevEth = 0;
        pendingRewardsEth = 0;
        
        (bool success, ) = recipient.call{value: balance}("");
        require(success, "Emergency withdrawal failed");
    }
    
    function emergencyWithdrawToken(
        address token,
        address recipient,
        uint256 amount
    ) external onlyOwner {
        require(recipient != address(0), "Invalid recipient");
        require(token != address(0), "Invalid token");
        
        IERC20(token).transfer(recipient, amount);
    }
    
    function batchDistributeEmarkFees() external nonReentrant notInEmergency {
        require(address(emarkToken) != address(0), "EMARK token not set");
        require(evermarkRewards != address(0), "Rewards contract not set");
        
        uint256 emarkBalance = emarkToken.balanceOf(address(this));
        if (emarkBalance > 0) {
            try this.routeEmarkToRewards() {
            } catch {
            }
        }
        
        try this.distributePendingEthFees() {
        } catch {
        }
    }
    
    receive() external payable {
        if (msg.value > 0) {
            totalEthCollected += msg.value;
            emit EthFeesCollected(msg.value);
            _storeFees(msg.value);
        }
    }
    
    fallback() external payable {
        if (msg.value > 0) {
            totalEthCollected += msg.value;
            emit EthFeesCollected(msg.value);
            _storeFees(msg.value);
        }
    }
}