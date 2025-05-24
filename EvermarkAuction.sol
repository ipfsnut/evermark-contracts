// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721ReceiverUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/*
 █████╗ ██╗   ██╗ ██████╗████████╗██╗ ██████╗ ███╗   ██╗
██╔══██╗██║   ██║██╔════╝╚══██╔══╝██║██╔═══██╗████╗  ██║
███████║██║   ██║██║        ██║   ██║██║   ██║██╔██╗ ██║
██╔══██║██║   ██║██║        ██║   ██║██║   ██║██║╚██╗██║
██║  ██║╚██████╔╝╚██████╗   ██║   ██║╚██████╔╝██║ ╚████║
╚═╝  ╚═╝ ╚═════╝  ╚═════╝   ╚═╝   ╚═╝ ╚═════╝ ╚═╝  ╚═══╝
*/

interface IEvermarkRewards {
    function distributeCreatorRewards(address[] calldata creators, uint256[] calldata amounts) external;
}

interface IFeeCollector {
    function collectAuctionFees() external payable;
}

contract EvermarkAuction is 
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    IERC721ReceiverUpgradeable
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant AUCTION_MANAGER_ROLE = keccak256("AUCTION_MANAGER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    struct Auction {
        uint256 tokenId;
        address nftContract;
        address seller;
        uint256 startingPrice;
        uint256 reservePrice;
        uint256 currentBid;
        address highestBidder;
        uint256 startTime;
        uint256 endTime;
        bool finalized;
        bool cancelled;
        uint256 bidCount;
        mapping(address => uint256) bidderAmounts; // Track all bids for refunds
    }

    struct AuctionView {
        uint256 tokenId;
        address nftContract;
        address seller;
        uint256 startingPrice;
        uint256 reservePrice;
        uint256 currentBid;
        address highestBidder;
        uint256 startTime;
        uint256 endTime;
        bool finalized;
        bool cancelled;
        uint256 bidCount;
    }

    // Storage
    IEvermarkRewards public evermarkRewards;
    IFeeCollector public feeCollector;
    
    uint256 public nextAuctionId;
    mapping(uint256 => Auction) public auctions;
    uint256[] public activeAuctions;
    
    // Fee configuration
    uint256 public creatorFeePercentage; // Basis points (100 = 1%)
    uint256 public protocolFeePercentage; // Basis points
    
    // Auction configuration
    uint256 public minimumAuctionDuration; // Minimum auction duration
    uint256 public maximumAuctionDuration; // Maximum auction duration
    uint256 public bidExtensionTime; // Time added when bid placed near end
    uint256 public minimumBidIncrement; // Minimum bid increment (basis points)
    
    // Tracking
    mapping(address => uint256[]) public userAuctions; // seller => auction IDs
    mapping(address => uint256[]) public userBids; // bidder => auction IDs
    mapping(address => uint256) public totalSales; // seller => total ETH earned
    mapping(address => uint256) public totalPurchases; // buyer => total ETH spent
    
    // Events
    event AuctionCreated(
        uint256 indexed auctionId,
        uint256 indexed tokenId,
        address indexed nftContract,
        address seller,
        uint256 startingPrice,
        uint256 reservePrice,
        uint256 startTime,
        uint256 endTime
    );
    event BidPlaced(uint256 indexed auctionId, address indexed bidder, uint256 amount, uint256 timestamp);
    event BidRefunded(uint256 indexed auctionId, address indexed bidder, uint256 amount);
    event AuctionFinalized(uint256 indexed auctionId, address indexed winner, uint256 amount);
    event AuctionCancelled(uint256 indexed auctionId, string reason);
    event FeesUpdated(uint256 creatorFee, uint256 protocolFee);
    event AuctionExtended(uint256 indexed auctionId, uint256 newEndTime);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _evermarkRewards,
        address _feeCollector
    ) external initializer {
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(AUCTION_MANAGER_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);

        evermarkRewards = IEvermarkRewards(_evermarkRewards);
        feeCollector = IFeeCollector(_feeCollector);
        
        nextAuctionId = 1;
        
        // Default configuration
        creatorFeePercentage = 250; // 2.5%
        protocolFeePercentage = 250; // 2.5%
        minimumAuctionDuration = 1 hours;
        maximumAuctionDuration = 30 days;
        bidExtensionTime = 10 minutes;
        minimumBidIncrement = 500; // 5%
    }

    // Create an auction
    function createAuction(
        address nftContract,
        uint256 tokenId,
        uint256 startingPrice,
        uint256 reservePrice,
        uint256 duration
    ) external whenNotPaused nonReentrant returns (uint256) {
        require(startingPrice > 0, "Starting price must be > 0");
        require(reservePrice >= startingPrice, "Reserve price must be >= starting price");
        require(duration >= minimumAuctionDuration, "Duration too short");
        require(duration <= maximumAuctionDuration, "Duration too long");
        
        // Transfer NFT to this contract
        IERC721(nftContract).transferFrom(msg.sender, address(this), tokenId);
        
        uint256 auctionId = nextAuctionId++;
        Auction storage auction = auctions[auctionId];
        
        auction.tokenId = tokenId;
        auction.nftContract = nftContract;
        auction.seller = msg.sender;
        auction.startingPrice = startingPrice;
        auction.reservePrice = reservePrice;
        auction.startTime = block.timestamp;
        auction.endTime = block.timestamp + duration;
        auction.finalized = false;
        auction.cancelled = false;
        auction.bidCount = 0;
        
        activeAuctions.push(auctionId);
        userAuctions[msg.sender].push(auctionId);
        
        emit AuctionCreated(
            auctionId,
            tokenId,
            nftContract,
            msg.sender,
            startingPrice,
            reservePrice,
            auction.startTime,
            auction.endTime
        );
        
        return auctionId;
    }

    // Place a bid
    function placeBid(uint256 auctionId) external payable whenNotPaused nonReentrant {
        Auction storage auction = auctions[auctionId];
        
        require(auction.seller != address(0), "Auction does not exist");
        require(!auction.finalized, "Auction already finalized");
        require(!auction.cancelled, "Auction cancelled");
        require(block.timestamp >= auction.startTime, "Auction not started");
        require(block.timestamp < auction.endTime, "Auction ended");
        require(msg.sender != auction.seller, "Cannot bid on own auction");
        require(msg.value > 0, "Bid must be > 0");
        
        uint256 minBid = auction.currentBid == 0 ? 
            auction.startingPrice : 
            auction.currentBid + ((auction.currentBid * minimumBidIncrement) / 10000);
        
        require(msg.value >= minBid, "Bid too low");
        
        // Refund previous highest bidder
        if (auction.highestBidder != address(0)) {
            uint256 refundAmount = auction.currentBid;
            auction.bidderAmounts[auction.highestBidder] -= refundAmount;
            
            (bool success, ) = auction.highestBidder.call{value: refundAmount}("");
            require(success, "Refund failed");
            
            emit BidRefunded(auctionId, auction.highestBidder, refundAmount);
        }
        
        // Update auction state
        auction.currentBid = msg.value;
        auction.highestBidder = msg.sender;
        auction.bidCount++;
        auction.bidderAmounts[msg.sender] += msg.value;
        
        // Add to user's bid tracking
        userBids[msg.sender].push(auctionId);
        
        // Extend auction if bid placed near end
        if (block.timestamp + bidExtensionTime > auction.endTime) {
            auction.endTime = block.timestamp + bidExtensionTime;
            emit AuctionExtended(auctionId, auction.endTime);
        }
        
        emit BidPlaced(auctionId, msg.sender, msg.value, block.timestamp);
    }

    // Finalize auction
    function finalizeAuction(uint256 auctionId) external nonReentrant {
        Auction storage auction = auctions[auctionId];
        
        require(auction.seller != address(0), "Auction does not exist");
        require(!auction.finalized, "Already finalized");
        require(!auction.cancelled, "Auction cancelled");
        require(block.timestamp >= auction.endTime, "Auction not ended");
        
        auction.finalized = true;
        _removeFromActiveAuctions(auctionId);
        
        if (auction.currentBid >= auction.reservePrice && auction.highestBidder != address(0)) {
            // Successful auction
            _processSale(auctionId);
        } else {
            // Failed auction - return NFT to seller, refund highest bidder
            IERC721(auction.nftContract).transferFrom(address(this), auction.seller, auction.tokenId);
            
            if (auction.highestBidder != address(0)) {
                uint256 refundAmount = auction.currentBid;
                auction.bidderAmounts[auction.highestBidder] -= refundAmount;
                
                (bool success, ) = auction.highestBidder.call{value: refundAmount}("");
                require(success, "Refund failed");
                
                emit BidRefunded(auctionId, auction.highestBidder, refundAmount);
            }
        }
        
        emit AuctionFinalized(auctionId, auction.highestBidder, auction.currentBid);
    }

    // Process successful sale
    function _processSale(uint256 auctionId) internal {
        Auction storage auction = auctions[auctionId];
        
        uint256 salePrice = auction.currentBid;
        uint256 creatorFee = (salePrice * creatorFeePercentage) / 10000;
        uint256 protocolFee = (salePrice * protocolFeePercentage) / 10000;
        uint256 sellerAmount = salePrice - creatorFee - protocolFee;
        
        // Transfer NFT to winner
        IERC721(auction.nftContract).transferFrom(address(this), auction.highestBidder, auction.tokenId);
        
        // Pay seller
        (bool sellerSuccess, ) = auction.seller.call{value: sellerAmount}("");
        require(sellerSuccess, "Seller payment failed");
        
        // Send fees to fee collector
        if (creatorFee + protocolFee > 0) {
            feeCollector.collectAuctionFees{value: creatorFee + protocolFee}();
        }
        
        // Update tracking
        totalSales[auction.seller] += sellerAmount;
        totalPurchases[auction.highestBidder] += salePrice;
        auction.bidderAmounts[auction.highestBidder] -= salePrice;
    }

    // Cancel auction (only seller or admin)
    function cancelAuction(uint256 auctionId, string calldata reason) external nonReentrant {
        Auction storage auction = auctions[auctionId];
        
        require(auction.seller != address(0), "Auction does not exist");
        require(!auction.finalized, "Already finalized");
        require(!auction.cancelled, "Already cancelled");
        require(
            msg.sender == auction.seller || hasRole(ADMIN_ROLE, msg.sender),
            "Not authorized"
        );
        
        // Can only cancel if no bids, or in emergency by admin
        if (auction.currentBid > 0) {
            require(hasRole(ADMIN_ROLE, msg.sender), "Cannot cancel auction with bids");
        }
        
        auction.cancelled = true;
        _removeFromActiveAuctions(auctionId);
        
        // Return NFT to seller
        IERC721(auction.nftContract).transferFrom(address(this), auction.seller, auction.tokenId);
        
        // Refund highest bidder if exists
        if (auction.highestBidder != address(0)) {
            uint256 refundAmount = auction.currentBid;
            auction.bidderAmounts[auction.highestBidder] -= refundAmount;
            
            (bool success, ) = auction.highestBidder.call{value: refundAmount}("");
            require(success, "Refund failed");
            
            emit BidRefunded(auctionId, auction.highestBidder, refundAmount);
        }
        
        emit AuctionCancelled(auctionId, reason);
    }

    // Batch finalize multiple auctions
    function finalizeAuctionsBatch(uint256[] calldata auctionIds) external {
        for (uint256 i = 0; i < auctionIds.length; i++) {
            if (auctionIds[i] != 0 && !auctions[auctionIds[i]].finalized) {
                finalizeAuction(auctionIds[i]);
            }
        }
    }

    // Remove auction from active list
    function _removeFromActiveAuctions(uint256 auctionId) internal {
        for (uint256 i = 0; i < activeAuctions.length; i++) {
            if (activeAuctions[i] == auctionId) {
                activeAuctions[i] = activeAuctions[activeAuctions.length - 1];
                activeAuctions.pop();
                break;
            }
        }
    }

    // View functions
    function getActiveAuctions() external view returns (uint256[] memory) {
        return activeAuctions;
    }

    function getAuctionDetails(uint256 auctionId) external view returns (AuctionView memory) {
        Auction storage auction = auctions[auctionId];
        
        return AuctionView({
            tokenId: auction.tokenId,
            nftContract: auction.nftContract,
            seller: auction.seller,
            startingPrice: auction.startingPrice,
            reservePrice: auction.reservePrice,
            currentBid: auction.currentBid,
            highestBidder: auction.highestBidder,
            startTime: auction.startTime,
            endTime: auction.endTime,
            finalized: auction.finalized,
            cancelled: auction.cancelled,
            bidCount: auction.bidCount
        });
    }

    function getUserAuctions(address user) external view returns (uint256[] memory) {
        return userAuctions[user];
    }

    function getUserBids(address user) external view returns (uint256[] memory) {
        return userBids[user];
    }

    function getUserStats(address user) external view returns (
        uint256 totalSalesAmount,
        uint256 totalPurchasesAmount,
        uint256 auctionsCreated,
        uint256 bidsPlaced
    ) {
        return (
            totalSales[user],
            totalPurchases[user],
            userAuctions[user].length,
            userBids[user].length
        );
    }

    function getAuctionsEndingSoon(uint256 timeThreshold) external view returns (uint256[] memory) {
        uint256[] memory endingSoon = new uint256[](activeAuctions.length);
        uint256 count = 0;
        
        for (uint256 i = 0; i < activeAuctions.length; i++) {
            uint256 auctionId = activeAuctions[i];
            Auction storage auction = auctions[auctionId];
            
            if (!auction.finalized && !auction.cancelled && 
                auction.endTime <= block.timestamp + timeThreshold) {
                endingSoon[count] = auctionId;
                count++;
            }
        }
        
        // Resize array
        uint256[] memory result = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = endingSoon[i];
        }
        
        return result;
    }

    // Admin functions
    function updateFeeConfiguration(
        uint256 _creatorFeePercentage,
        uint256 _protocolFeePercentage
    ) external onlyRole(ADMIN_ROLE) {
        require(_creatorFeePercentage + _protocolFeePercentage <= 1000, "Total fees too high"); // Max 10%
        
        creatorFeePercentage = _creatorFeePercentage;
        protocolFeePercentage = _protocolFeePercentage;
        
        emit FeesUpdated(_creatorFeePercentage, _protocolFeePercentage);
    }

    function updateAuctionConfiguration(
        uint256 _minimumDuration,
        uint256 _maximumDuration,
        uint256 _bidExtensionTime,
        uint256 _minimumBidIncrement
    ) external onlyRole(ADMIN_ROLE) {
        require(_minimumDuration >= 1 hours, "Minimum duration too short");
        require(_maximumDuration <= 365 days, "Maximum duration too long");
        require(_minimumDuration <= _maximumDuration, "Invalid duration range");
        
        minimumAuctionDuration = _minimumDuration;
        maximumAuctionDuration = _maximumDuration;
        bidExtensionTime = _bidExtensionTime;
        minimumBidIncrement = _minimumBidIncrement;
    }

    function updateEvermarkRewards(address _evermarkRewards) external onlyRole(ADMIN_ROLE) {
        require(_evermarkRewards != address(0), "Invalid address");
        evermarkRewards = IEvermarkRewards(_evermarkRewards);
    }

    function updateFeeCollector(address _feeCollector) external onlyRole(ADMIN_ROLE) {
        require(_feeCollector != address(0), "Invalid address");
        feeCollector = IFeeCollector(_feeCollector);
    }

    function grantAuctionManagerRole(address manager) external onlyRole(ADMIN_ROLE) {
        grantRole(AUCTION_MANAGER_ROLE, manager);
    }

    function revokeAuctionManagerRole(address manager) external onlyRole(ADMIN_ROLE) {
        revokeRole(AUCTION_MANAGER_ROLE, manager);
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // Emergency functions
    function emergencyFinalizeAuction(uint256 auctionId) external onlyRole(ADMIN_ROLE) {
        finalizeAuction(auctionId);
    }

    function withdrawProtocolFees(uint256 amount, address recipient) external onlyRole(ADMIN_ROLE) {
        require(recipient != address(0), "Invalid recipient");
        require(amount <= address(this).balance, "Insufficient balance");
        
        (bool success, ) = recipient.call{value: amount}("");
        require(success, "Withdrawal failed");
    }

    // Required overrides
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IERC721ReceiverUpgradeable.onERC721Received.selector;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    // Fallback to receive ETH
    receive() external payable {}
}