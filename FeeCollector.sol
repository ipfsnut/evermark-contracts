// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/*
 ███████╗███████╗███████╗     ██████╗ ██████╗ ██╗     ██╗     ███████╗ ██████╗████████╗ ██████╗ ██████╗ 
 ██╔════╝██╔════╝██╔════╝    ██╔════╝██╔═══██╗██║     ██║     ██╔════╝██╔════╝╚══██╔══╝██╔═══██╗██╔══██╗
 █████╗  █████╗  █████╗      ██║     ██║   ██║██║     ██║     █████╗  ██║        ██║   ██║   ██║██████╔╝
 ██╔══╝  ██╔══╝  ██╔══╝      ██║     ██║   ██║██║     ██║     ██╔══╝  ██║        ██║   ██║   ██║██╔══██╗
 ██║     ███████╗███████╗    ╚██████╗╚██████╔╝███████╗███████╗███████╗╚██████╗   ██║   ╚██████╔╝██║  ██║
 ╚═╝     ╚══════╝╚══════╝     ╚═════╝ ╚═════╝ ╚══════╝╚══════╝╚══════╝ ╚═════╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝
*/

// Interface for EvermarkRewards contract
interface IEvermarkRewards {
    function fundWethRewards(uint256 amount) external;
    function fundEmarkRewards(uint256 amount) external;
}

// Interface for WETH contract
interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

contract FeeCollector is 
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    struct TokenConfig {
        bool supported;
        address tokenAddress; // address(0) for ETH
        string name;
        uint256 totalCollected;
    }

    struct FeeDestination {
        address destination;
        uint256 basisPoints; // Out of 10000 (100.00%)
        string name;
        bool active;
    }

    // Supported tokens
    mapping(string => TokenConfig) public supportedTokens; // "ETH", "WETH", "EMARK", etc.
    string[] public tokenSymbols;
    
    // Fee routing: tokenSymbol => destinations[]
    mapping(string => FeeDestination[]) public feeDestinations;
    
    // Special contract integrations
    IEvermarkRewards public evermarkRewards;
    
    // Emergency controls
    uint256 public emergencyPauseTimestamp;
    
    // Statistics tracking
    uint256 public totalEthCollected;
    uint256 public totalTokensProcessed;
    
    // Events
    event FeeCollected(string indexed tokenSymbol, uint256 amount, address indexed from, string source);
    event FeeRouted(string indexed tokenSymbol, address indexed to, uint256 amount, string destinationName);
    event TokenAdded(string symbol, address tokenAddress, string name);
    event DestinationConfigured(string tokenSymbol, address destination, uint256 basisPoints, string name);
    event EvermarkRewardsUpdated(address indexed newContract);
    event BatchProcessed(string tokenSymbol, uint256 totalAmount, uint256 destinationCount);
    event EmergencyPauseSet(uint256 timestamp);
    event EthWrappedForRewards(uint256 amount); // NEW: Track ETH→WETH conversions

    modifier notInEmergency() {
        require(block.timestamp > emergencyPauseTimestamp, "Emergency pause active");
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize() external initializer {
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(FEE_MANAGER_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);

        // Add ETH support by default
        _addTokenSupport("ETH", address(0), "Ethereum");
    }

    // ============ FEE COLLECTION FUNCTIONS ============

    /**
     * @notice Collect ETH fees with automatic routing
     * @param source Description of fee source for tracking
     */
    function collectETH(string calldata source) external payable whenNotPaused notInEmergency {
        require(msg.value > 0, "No ETH sent");
        
        supportedTokens["ETH"].totalCollected += msg.value;
        totalEthCollected += msg.value;
        
        emit FeeCollected("ETH", msg.value, msg.sender, source);
        
        // Automatically route fees
        _routeFees("ETH", msg.value);
    }

    /**
     * @notice Collect NFT creation fees (convenience function)
     */
    function collectNftCreationFees() external payable whenNotPaused notInEmergency {
        require(msg.value > 0, "No fees sent");
        this.collectETH{value: msg.value}("NFT_CREATION");
    }

    /**
     * @notice Collect ERC20 token fees
     * @param tokenSymbol Token symbol (e.g., "WETH", "EMARK", "USDC")
     * @param amount Amount to collect
     * @param source Description of fee source
     */
    function collectToken(
        string calldata tokenSymbol,
        uint256 amount,
        string calldata source
    ) external whenNotPaused notInEmergency {
        require(amount > 0, "Amount must be > 0");
        require(supportedTokens[tokenSymbol].supported, "Token not supported");
        require(supportedTokens[tokenSymbol].tokenAddress != address(0), "Use collectETH for ETH");
        
        IERC20 token = IERC20(supportedTokens[tokenSymbol].tokenAddress);
        token.transferFrom(msg.sender, address(this), amount);
        
        supportedTokens[tokenSymbol].totalCollected += amount;
        totalTokensProcessed++;
        
        emit FeeCollected(tokenSymbol, amount, msg.sender, source);
        
        // Automatically route fees
        _routeFees(tokenSymbol, amount);
    }

    /**
     * @notice Collect WETH trading fees from Clanker (main use case)
     * @param amount Amount of WETH to collect
     */
    function collectWethTradingFees(uint256 amount) external whenNotPaused notInEmergency {
        this.collectToken("WETH", amount, "CLANKER_TRADING");
    }

    /**
     * @notice Deposit WETH fees directly  
     * @param amount Amount to deposit
     */
    function depositWethFees(uint256 amount) external whenNotPaused notInEmergency {
        this.collectToken("WETH", amount, "DEPOSIT");
    }

    // ============ INTERNAL FEE ROUTING ============

    /**
     * @notice Internal fee routing logic
     * @param tokenSymbol Token to route
     * @param amount Total amount to distribute
     */
    function _routeFees(string memory tokenSymbol, uint256 amount) internal {
        FeeDestination[] memory destinations = feeDestinations[tokenSymbol];
        require(destinations.length > 0, "No destinations configured");
        
        uint256 remainingAmount = amount;
        uint256 totalBasisPoints = 0;
        
        // Calculate total basis points for active destinations
        for (uint256 i = 0; i < destinations.length; i++) {
            if (destinations[i].active) {
                totalBasisPoints += destinations[i].basisPoints;
            }
        }
        
        require(totalBasisPoints == 10000, "Basis points must sum to 10000");
        
        // Route to each destination
        for (uint256 i = 0; i < destinations.length; i++) {
            if (!destinations[i].active) continue;
            
            uint256 destinationAmount;
            
            // Last active destination gets remainder to avoid rounding issues
            if (i == destinations.length - 1) {
                destinationAmount = remainingAmount;
            } else {
                destinationAmount = (amount * destinations[i].basisPoints) / 10000;
                remainingAmount -= destinationAmount;
            }
            
            if (destinationAmount > 0) {
                _sendToDestination(tokenSymbol, destinations[i].destination, destinationAmount, destinations[i].name);
            }
        }
        
        emit BatchProcessed(tokenSymbol, amount, destinations.length);
    }

    /**
     * @notice Send tokens to specific destination with smart contract integration
     * UPDATED: ETH→WETH conversion for rewards integration
     */
    function _sendToDestination(
        string memory tokenSymbol,
        address destination,
        uint256 amount,
        string memory destinationName
    ) internal {
        if (keccak256(bytes(tokenSymbol)) == keccak256(bytes("ETH"))) {
            // Handle ETH - convert to WETH if going to rewards
            if (destination == address(evermarkRewards)) {
                // Convert ETH to WETH, then fund rewards
                require(supportedTokens["WETH"].supported, "WETH not supported");
                IWETH weth = IWETH(supportedTokens["WETH"].tokenAddress);
                
                weth.deposit{value: amount}();
                weth.approve(address(evermarkRewards), amount);
                
                try evermarkRewards.fundWethRewards(amount) {
                    // Success - ETH was wrapped and sent to rewards
                    emit EthWrappedForRewards(amount);
                } catch {
                    // Fallback: send WETH directly
                    require(weth.transfer(destination, amount), "WETH transfer failed");
                }
            } else {
                // Direct ETH transfer to wallet
                (bool success, ) = payable(destination).call{value: amount}("");
                require(success, string(abi.encodePacked("ETH transfer failed to ", destinationName)));
            }
            
        } else if (keccak256(bytes(tokenSymbol)) == keccak256(bytes("WETH"))) {
            // Handle WETH - direct integration with EvermarkRewards
            IERC20 wethToken = IERC20(supportedTokens[tokenSymbol].tokenAddress);
            
            if (destination == address(evermarkRewards)) {
                // Smart integration: approve and call fundWethRewards
                wethToken.approve(address(evermarkRewards), amount);
                try evermarkRewards.fundWethRewards(amount) {
                    // Success - rewards contract was funded directly
                } catch {
                    // Fallback to direct transfer
                    require(wethToken.transfer(destination, amount), "WETH transfer failed");
                }
            } else {
                // Direct WETH transfer to wallet
                require(wethToken.transfer(destination, amount), "WETH transfer failed");
            }
            
        } else if (keccak256(bytes(tokenSymbol)) == keccak256(bytes("EMARK"))) {
            // Handle EMARK - smart integration with EvermarkRewards
            IERC20 emarkToken = IERC20(supportedTokens[tokenSymbol].tokenAddress);
            
            if (destination == address(evermarkRewards)) {
                // Smart integration: approve and call fundEmarkRewards
                emarkToken.approve(address(evermarkRewards), amount);
                try evermarkRewards.fundEmarkRewards(amount) {
                    // Success - rewards contract was funded directly
                } catch {
                    // Fallback to direct transfer
                    require(emarkToken.transfer(destination, amount), "EMARK transfer failed");
                }
            } else {
                // Direct EMARK transfer to wallet
                require(emarkToken.transfer(destination, amount), "EMARK transfer failed");
            }
            
        } else {
            // Handle any other ERC20 token
            IERC20 token = IERC20(supportedTokens[tokenSymbol].tokenAddress);
            require(token.transfer(destination, amount), "Token transfer failed");
        }
        
        emit FeeRouted(tokenSymbol, destination, amount, destinationName);
    }

    // ============ CONFIGURATION FUNCTIONS ============

    /**
     * @notice Add support for a new token
     * @param symbol Token symbol (e.g., "WETH", "USDC")
     * @param tokenAddress Token contract address
     * @param name Human readable name
     */
    function addTokenSupport(
        string calldata symbol,
        address tokenAddress,
        string calldata name
    ) external onlyRole(ADMIN_ROLE) {
        require(!supportedTokens[symbol].supported, "Token already supported");
        require(tokenAddress != address(0), "Use ETH for zero address");
        
        _addTokenSupport(symbol, tokenAddress, name);
    }

    function _addTokenSupport(string memory symbol, address tokenAddress, string memory name) internal {
        supportedTokens[symbol] = TokenConfig({
            supported: true,
            tokenAddress: tokenAddress,
            name: name,
            totalCollected: 0
        });
        
        tokenSymbols.push(symbol);
        
        emit TokenAdded(symbol, tokenAddress, name);
    }

    /**
     * @notice Configure fee destinations for a token
     * @param tokenSymbol Token to configure
     * @param destinations Array of destination addresses
     * @param basisPoints Array of basis points (must sum to 10000)
     * @param names Array of destination names
     */
    function configureFeeDestinations(
        string calldata tokenSymbol,
        address[] calldata destinations,
        uint256[] calldata basisPoints,
        string[] calldata names
    ) external onlyRole(ADMIN_ROLE) {
        require(supportedTokens[tokenSymbol].supported, "Token not supported");
        require(destinations.length == basisPoints.length, "Array length mismatch");
        require(destinations.length == names.length, "Array length mismatch");
        require(destinations.length > 0, "Must have at least one destination");
        
        // Clear existing destinations
        delete feeDestinations[tokenSymbol];
        
        uint256 totalBasisPoints = 0;
        
        // Add new destinations
        for (uint256 i = 0; i < destinations.length; i++) {
            require(destinations[i] != address(0), "Invalid destination address");
            require(basisPoints[i] > 0, "Basis points must be > 0");
            
            totalBasisPoints += basisPoints[i];
            
            feeDestinations[tokenSymbol].push(FeeDestination({
                destination: destinations[i],
                basisPoints: basisPoints[i],
                name: names[i],
                active: true
            }));
            
            emit DestinationConfigured(tokenSymbol, destinations[i], basisPoints[i], names[i]);
        }
        
        require(totalBasisPoints == 10000, "Basis points must sum to 10000 (100%)");
    }

    /**
     * @notice Quick setup for 50/50 dev/rewards split
     * @param tokenSymbol Token to configure ("ETH", "WETH", or "EMARK")
     * @param devAddress Development wallet address
     * @param rewardsAddress EvermarkRewards contract address
     */
    function setup50_50Split(
        string calldata tokenSymbol,
        address devAddress,
        address rewardsAddress
    ) external onlyRole(ADMIN_ROLE) {
        address[] memory destinations = new address[](2);
        uint256[] memory basisPoints = new uint256[](2);
        string[] memory names = new string[](2);
        
        destinations[0] = devAddress;
        destinations[1] = rewardsAddress;
        
        basisPoints[0] = 5000; // 50%
        basisPoints[1] = 5000; // 50%
        
        names[0] = "Development";
        names[1] = "Staker Rewards";
        
        this.configureFeeDestinations(tokenSymbol, destinations, basisPoints, names);
    }

    /**
     * @notice Bootstrap with WETH + EMARK configuration for 50/50 splits
     * UPDATED: Now supports ETH→WETH conversion for 50/50 split
     * @param wethTokenAddress WETH token address
     * @param emarkTokenAddress EMARK token address
     * @param evermarkRewardsAddress EvermarkRewards contract address
     * @param devAddress Dev wallet
     */
    function bootstrapWethEmarkConfig(
        address wethTokenAddress,
        address emarkTokenAddress,
        address evermarkRewardsAddress,
        address devAddress
    ) external onlyRole(ADMIN_ROLE) {
        // Add token support
        _addTokenSupport("WETH", wethTokenAddress, "Wrapped Ether");
        _addTokenSupport("EMARK", emarkTokenAddress, "Evermark Token");
        
        // Set EvermarkRewards contract
        evermarkRewards = IEvermarkRewards(evermarkRewardsAddress);
        emit EvermarkRewardsUpdated(evermarkRewardsAddress);
        
        // Setup 50/50 splits for all fee types
        this.setup50_50Split("ETH", devAddress, evermarkRewardsAddress);    // NFT fees
        this.setup50_50Split("WETH", devAddress, evermarkRewardsAddress);   // Clanker fees
        this.setup50_50Split("EMARK", devAddress, evermarkRewardsAddress);  // EMARK fees
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Get fee destinations for a token
     */
    function getFeeDestinations(string calldata tokenSymbol) external view returns (FeeDestination[] memory) {
        return feeDestinations[tokenSymbol];
    }

    /**
     * @notice Preview fee split for an amount
     * @param tokenSymbol Token symbol
     * @param amount Amount to split
     * @return destinations Destination addresses
     * @return amounts Split amounts
     * @return names Destination names
     */
    function previewFeeSplit(string calldata tokenSymbol, uint256 amount) external view returns (
        address[] memory destinations,
        uint256[] memory amounts,
        string[] memory names
    ) {
        FeeDestination[] memory dests = feeDestinations[tokenSymbol];
        
        destinations = new address[](dests.length);
        amounts = new uint256[](dests.length);
        names = new string[](dests.length);
        
        for (uint256 i = 0; i < dests.length; i++) {
            destinations[i] = dests[i].destination;
            amounts[i] = (amount * dests[i].basisPoints) / 10000;
            names[i] = dests[i].name;
        }
    }

    // ============ ADMIN FUNCTIONS ============

    function setEvermarkRewards(address _evermarkRewards) external onlyRole(ADMIN_ROLE) {
        evermarkRewards = IEvermarkRewards(_evermarkRewards);
        emit EvermarkRewardsUpdated(_evermarkRewards);
    }

    function setEmergencyPause(uint256 pauseUntilTimestamp) external onlyRole(ADMIN_ROLE) {
        emergencyPauseTimestamp = pauseUntilTimestamp;
        emit EmergencyPauseSet(pauseUntilTimestamp);
    }

    function clearEmergencyPause() external onlyRole(ADMIN_ROLE) {
        emergencyPauseTimestamp = 0;
        emit EmergencyPauseSet(0);
    }

    function emergencyWithdrawETH(address payable recipient, uint256 amount) external onlyRole(ADMIN_ROLE) {
        (bool success, ) = recipient.call{value: amount}("");
        require(success, "Emergency ETH withdrawal failed");
    }

    function emergencyWithdrawToken(
        string calldata tokenSymbol,
        address recipient,
        uint256 amount
    ) external onlyRole(ADMIN_ROLE) {
        require(supportedTokens[tokenSymbol].supported, "Token not supported");
        IERC20 token = IERC20(supportedTokens[tokenSymbol].tokenAddress);
        require(token.transfer(recipient, amount), "Emergency token withdrawal failed");
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function version() external pure returns (string memory) {
        return "2.2.0";
    }

    // Receive ETH directly (e.g., from contract sales)
    receive() external payable {
        if (msg.value > 0) {
            supportedTokens["ETH"].totalCollected += msg.value;
            totalEthCollected += msg.value;
            emit FeeCollected("ETH", msg.value, msg.sender, "Direct");
            _routeFees("ETH", msg.value);
        }
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
