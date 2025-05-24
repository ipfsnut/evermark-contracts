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
    // Contracts
    address public evermarkRewards;
    address public treasuryWallet;
    address public devWallet;
    IERC20 public emarkToken;
    
    // Fee tracking
    uint256 public totalEmarkCollected;
    uint256 public totalEthCollected; 
    uint256 public totalNftFeesCollected;
    
    // Fee split percentages (basis points, 10000 = 100%)
    uint256 public treasuryPercentage = 3000; // 30%
    uint256 public devPercentage = 1000;      // 10%
    uint256 public rewardsPercentage = 6000;  // 60%
    
    // Events
    event EmarkFeesCollected(uint256 amount);
    event EthFeesCollected(uint256 amount);
    event NftFeesCollected(uint256 amount);
    event FeesRouted(address indexed destination, uint256 amount, string feeType);
    event FeePercentagesUpdated(uint256 treasury, uint256 dev, uint256 rewards);
    event ContractUpdated(string contractType, address indexed oldAddress, address indexed newAddress);
    
    constructor(
        address _treasuryWallet,
        address _devWallet
    ) {
        require(_treasuryWallet != address(0), "Invalid treasury wallet");
        require(_devWallet != address(0), "Invalid dev wallet");
        
        treasuryWallet = _treasuryWallet;
        devWallet = _devWallet;
    }
    
    // NFT creation fee collection - called by EvermarkNFT contract
    function collectNftCreationFees() external payable {
        require(msg.value > 0, "No fees to collect");
        totalNftFeesCollected += msg.value;
        totalEthCollected += msg.value;
        emit NftFeesCollected(msg.value);
        
        // Automatically distribute ETH fees
        _distributeEthFees(msg.value);
    }
    
    // EMARK trading fee collection - called by DEX or other contracts
    function collectEmarkTradingFees(uint256 amount) external {
        require(amount > 0, "No fees to collect");
        require(address(emarkToken) != address(0), "EMARK token not set");
        
        emarkToken.transferFrom(msg.sender, address(this), amount);
        totalEmarkCollected += amount;
        emit EmarkFeesCollected(amount);
    }
    
    // Manual EMARK fee collection with approval
    function depositEmarkFees(uint256 amount) external {
        require(amount > 0, "No fees to deposit");
        require(address(emarkToken) != address(0), "EMARK token not set");
        
        emarkToken.transferFrom(msg.sender, address(this), amount);
        totalEmarkCollected += amount;
        emit EmarkFeesCollected(amount);
    }
    
    // Route EMARK fees to rewards contract
    function routeEmarkToRewards() external nonReentrant {
        require(address(emarkToken) != address(0), "EMARK token not set");
        require(evermarkRewards != address(0), "Rewards contract not set");
        
        uint256 amount = emarkToken.balanceOf(address(this));
        require(amount > 0, "No EMARK to route");
        
        emarkToken.transfer(evermarkRewards, amount);
        IEvermarkRewards(evermarkRewards).distributeProtocolFees(amount);
        
        emit FeesRouted(evermarkRewards, amount, "EMARK");
    }
    
    // Internal function to distribute ETH fees immediately
    function _distributeEthFees(uint256 amount) internal {
        if (amount == 0) return;
        
        uint256 toTreasury = (amount * treasuryPercentage) / 10000;
        uint256 toDev = (amount * devPercentage) / 10000;
        uint256 toRewards = amount - toTreasury - toDev; // Remaining goes to rewards
        
        // Send to treasury
        if (toTreasury > 0 && treasuryWallet != address(0)) {
            (bool success, ) = payable(treasuryWallet).call{value: toTreasury}("");
            require(success, "Treasury transfer failed");
            emit FeesRouted(treasuryWallet, toTreasury, "Treasury ETH");
        }
        
        // Send to dev
        if (toDev > 0 && devWallet != address(0)) {
            (bool success, ) = payable(devWallet).call{value: toDev}("");
            require(success, "Dev transfer failed");
            emit FeesRouted(devWallet, toDev, "Dev ETH");
        }
        
        // Keep remaining for potential rewards contract (if implemented for ETH)
        if (toRewards > 0) {
            emit FeesRouted(address(this), toRewards, "Rewards ETH Reserve");
        }
    }
    
    // Manual distribution of accumulated ETH fees
    function distributeAccumulatedEthFees() external nonReentrant onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH to distribute");
        
        _distributeEthFees(balance);
    }
    
    // Update fee percentages
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
    
    // Update contract addresses
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
    
    // View functions
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
        uint256 nftFees
    ) {
        return (totalEmarkCollected, totalEthCollected, totalNftFeesCollected);
    }
    
    // Emergency functions
    function emergencyWithdrawEth(address payable recipient) external onlyOwner {
        require(recipient != address(0), "Invalid recipient");
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH to withdraw");
        
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
    
    // Batch operations for efficiency
    function batchDistributeEmarkFees() external nonReentrant {
        require(address(emarkToken) != address(0), "EMARK token not set");
        require(evermarkRewards != address(0), "Rewards contract not set");
        
        uint256 emarkBalance = emarkToken.balanceOf(address(this));
        if (emarkBalance > 0) {
            routeEmarkToRewards();
        }
        
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            _distributeEthFees(ethBalance);
        }
    }
    
    // Allow contract to receive ETH
    receive() external payable {
        totalEthCollected += msg.value;
        emit EthFeesCollected(msg.value);
        _distributeEthFees(msg.value);
    }
    
    fallback() external payable {
        totalEthCollected += msg.value;
        emit EthFeesCollected(msg.value);
        _distributeEthFees(msg.value);
    }
}