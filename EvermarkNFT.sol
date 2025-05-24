// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

/*
 ███████╗██╗   ██╗███████╗██████╗ ███╗   ███╗ █████╗ ██████╗ ██╗  ██╗
 ██╔════╝██║   ██║██╔════╝██╔══██╗████╗ ████║██╔══██╗██╔══██╗██║ ██╔╝
 █████╗  ██║   ██║█████╗  ██████╔╝██╔████╔██║███████║██████╔╝█████╔╝ 
 ██╔══╝  ╚██╗ ██╔╝██╔══╝  ██╔══██╗██║╚██╔╝██║██╔══██║██╔══██╗██╔═██╗ 
 ███████╗ ╚████╔╝ ███████╗██║  ██║██║ ╚═╝ ██║██║  ██║██║  ██║██║  ██╗
 ╚══════╝  ╚═══╝  ╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝
 
 Content Preservation NFTs with Viral Growth
*/

interface IFeeCollector {
    function collectNftCreationFees() external payable;
}

contract EvermarkNFT is 
    Initializable,
    ERC721Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    uint256 public constant MINTING_FEE = 0.0007 ether;
    uint256 public constant REFERRAL_PERCENTAGE = 10; // 10% of fee goes to referrer

    struct EvermarkMetadata {
        string title;
        string creator;
        string metadataURI;
        uint256 creationTime;
        address minter;
        address referrer;
    }

    // Storage
    uint256 private _nextTokenId;
    address public feeCollector;
    
    // Enhanced metadata storage
    mapping(uint256 => EvermarkMetadata) public evermarkData;
    
    // Referral tracking
    mapping(address => uint256) public referralCounts;
    mapping(address => uint256) public referralEarnings;
    mapping(uint256 => address) public evermarkReferrers; // tokenId => referrer
    
    // Events
    event EvermarkMinted(
        uint256 indexed tokenId, 
        address indexed minter, 
        address indexed referrer, 
        string title
    );
    event ReferralEarned(
        address indexed referrer, 
        address indexed referred, 
        uint256 amount
    );
    event FeeCollectorUpdated(address indexed oldCollector, address indexed newCollector);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() external initializer {
        __ERC721_init("Evermark", "EMARK");
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);
        
        _nextTokenId = 1;
    }

    // Standard minting (no referrer)
    function mintEvermark(
        string calldata metadataURI,
        string calldata title, 
        string calldata creator
    ) external payable whenNotPaused nonReentrant returns (uint256) {
        return mintEvermarkWithReferral(metadataURI, title, creator, address(0));
    }

    // Enhanced minting with referral system
    function mintEvermarkWithReferral(
        string calldata metadataURI,
        string calldata title, 
        string calldata creator,
        address referrer
    ) public payable whenNotPaused nonReentrant returns (uint256) {
        require(msg.value >= MINTING_FEE, "Insufficient minting fee");
        require(referrer != msg.sender, "Cannot refer yourself");
        require(bytes(title).length > 0, "Title required");
        require(bytes(metadataURI).length > 0, "Metadata URI required");

        uint256 tokenId = _nextTokenId++;
        
        // Store metadata
        evermarkData[tokenId] = EvermarkMetadata({
            title: title,
            creator: creator,
            metadataURI: metadataURI,
            creationTime: block.timestamp,
            minter: msg.sender,
            referrer: referrer
        });

        // Mint NFT
        _safeMint(msg.sender, tokenId);

        // Handle referral fee split
        uint256 referralFee = 0;
        if (referrer != address(0)) {
            referralFee = (msg.value * REFERRAL_PERCENTAGE) / 100;
            
            // Pay referrer immediately
            (bool success, ) = payable(referrer).call{value: referralFee}("");
            require(success, "Referral payment failed");
            
            // Track referral stats
            referralCounts[referrer]++;
            referralEarnings[referrer] += referralFee;
            evermarkReferrers[tokenId] = referrer;
            
            emit ReferralEarned(referrer, msg.sender, referralFee);
        }

        // Send remaining fee to collector
        uint256 remainingFee = msg.value - referralFee;
        if (remainingFee > 0 && feeCollector != address(0)) {
            IFeeCollector(feeCollector).collectNftCreationFees{value: remainingFee}();
        }

        emit EvermarkMinted(tokenId, msg.sender, referrer, title);
        return tokenId;
    }

    // Batch minting with referrals
    function mintEvermarkBatch(
        string[] calldata metadataURIs,
        string[] calldata titles,
        string[] calldata creators,
        address referrer
    ) external payable whenNotPaused nonReentrant returns (uint256[] memory) {
        uint256 count = metadataURIs.length;
        require(count > 0 && count <= 10, "Invalid batch size");
        require(count == titles.length && count == creators.length, "Array length mismatch");
        require(msg.value >= MINTING_FEE * count, "Insufficient batch fee");
        require(referrer != msg.sender, "Cannot refer yourself");

        uint256[] memory tokenIds = new uint256[](count);
        
        for (uint256 i = 0; i < count; i++) {
            require(bytes(titles[i]).length > 0, "Title required");
            require(bytes(metadataURIs[i]).length > 0, "Metadata URI required");
            
            uint256 tokenId = _nextTokenId++;
            tokenIds[i] = tokenId;
            
            // Store metadata
            evermarkData[tokenId] = EvermarkMetadata({
                title: titles[i],
                creator: creators[i],
                metadataURI: metadataURIs[i],
                creationTime: block.timestamp,
                minter: msg.sender,
                referrer: referrer
            });
            
            // Mint NFT
            _safeMint(msg.sender, tokenId);
            
            if (referrer != address(0)) {
                evermarkReferrers[tokenId] = referrer;
            }
            
            emit EvermarkMinted(tokenId, msg.sender, referrer, titles[i]);
        }

        // Handle batch referral payment
        if (referrer != address(0)) {
            uint256 totalReferralFee = (msg.value * REFERRAL_PERCENTAGE) / 100;
            (bool success, ) = payable(referrer).call{value: totalReferralFee}("");
            require(success, "Batch referral payment failed");
            
            referralCounts[referrer] += count;
            referralEarnings[referrer] += totalReferralFee;
            
            emit ReferralEarned(referrer, msg.sender, totalReferralFee);
        }

        // Send remaining to fee collector
        uint256 totalReferralFee = referrer != address(0) ? (msg.value * REFERRAL_PERCENTAGE) / 100 : 0;
        uint256 remainingFee = msg.value - totalReferralFee;
        if (remainingFee > 0 && feeCollector != address(0)) {
            IFeeCollector(feeCollector).collectNftCreationFees{value: remainingFee}();
        }

        return tokenIds;
    }

    // Admin minting for special cases
    function mintEvermarkFor(
        address to,
        string calldata metadataURI,
        string calldata title,
        string calldata creator
    ) external onlyRole(MINTER_ROLE) whenNotPaused returns (uint256) {
        require(to != address(0), "Invalid recipient");
        require(bytes(title).length > 0, "Title required");
        require(bytes(metadataURI).length > 0, "Metadata URI required");

        uint256 tokenId = _nextTokenId++;
        
        // Store metadata
        evermarkData[tokenId] = EvermarkMetadata({
            title: title,
            creator: creator,
            metadataURI: metadataURI,
            creationTime: block.timestamp,
            minter: to,
            referrer: address(0)
        });

        _safeMint(to, tokenId);
        emit EvermarkMinted(tokenId, to, address(0), title);
        return tokenId;
    }

    // View functions for referral analytics
    function getReferralStats(address user) external view returns (
        uint256 totalReferred,
        uint256 totalEarned,
        uint256 averageEarningPerReferral
    ) {
        totalReferred = referralCounts[user];
        totalEarned = referralEarnings[user];
        averageEarningPerReferral = totalReferred > 0 ? totalEarned / totalReferred : 0;
    }

    // Get evermark metadata
    function getEvermarkMetadata(uint256 tokenId) external view returns (
        string memory title,
        string memory creator,
        string memory metadataURI
    ) {
        require(_exists(tokenId), "Token does not exist");
        EvermarkMetadata memory data = evermarkData[tokenId];
        return (data.title, data.creator, data.metadataURI);
    }

    function getEvermarkCreator(uint256 tokenId) external view returns (address) {
        require(_exists(tokenId), "Token does not exist");
        return evermarkData[tokenId].minter;
    }

    function getEvermarkCreationTime(uint256 tokenId) external view returns (uint256) {
        require(_exists(tokenId), "Token does not exist");
        return evermarkData[tokenId].creationTime;
    }

    function exists(uint256 tokenId) external view returns (bool) {
        return _exists(tokenId);
    }

    function totalSupply() external view returns (uint256) {
        return _nextTokenId - 1;
    }

    // Token URI override
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(_exists(tokenId), "Token does not exist");
        return evermarkData[tokenId].metadataURI;
    }

    // Admin functions
    function setFeeCollector(address _feeCollector) external onlyRole(ADMIN_ROLE) {
        address oldCollector = feeCollector;
        feeCollector = _feeCollector;
        emit FeeCollectorUpdated(oldCollector, _feeCollector);
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function grantMinterRole(address minter) external onlyRole(ADMIN_ROLE) {
        grantRole(MINTER_ROLE, minter);
    }

    function revokeMinterRole(address minter) external onlyRole(ADMIN_ROLE) {
        revokeRole(MINTER_ROLE, minter);
    }

    // Emergency withdrawal
    function emergencyWithdraw() external onlyRole(ADMIN_ROLE) {
        uint256 balance = address(this).balance;
        require(balance > 0, "No funds to withdraw");
        (bool success, ) = payable(msg.sender).call{value: balance}("");
        require(success, "Withdrawal failed");
    }

    // Required overrides
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    function supportsInterface(bytes4 interfaceId) public view override(ERC721Upgradeable, AccessControlUpgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    // Batch token metadata query for efficiency
    function getBatchEvermarkMetadata(uint256[] calldata tokenIds) external view returns (EvermarkMetadata[] memory) {
        EvermarkMetadata[] memory results = new EvermarkMetadata[](tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(_exists(tokenIds[i]), "Token does not exist");
            results[i] = evermarkData[tokenIds[i]];
        }
        return results;
    }
}