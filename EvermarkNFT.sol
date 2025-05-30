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
    uint256 public constant REFERRAL_PERCENTAGE = 10;
    uint256 public constant MAX_BATCH_SIZE = 10;

    struct EvermarkMetadata {
        string title;
        string creator;
        string metadataURI;
        uint256 creationTime;
        address minter;
        address referrer;
    }

    uint256 private _nextTokenId;
    address public feeCollector;
    
    mapping(uint256 => EvermarkMetadata) public evermarkData;
    
    mapping(address => uint256) public referralCounts;
    mapping(address => uint256) public referralEarnings;
    mapping(uint256 => address) public evermarkReferrers;
    
    mapping(address => uint256) public pendingReferralPayments;
    
    uint256 public emergencyPauseTimestamp;
    
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
    event ReferralPaymentFailed(
        address indexed referrer,
        address indexed referred,
        uint256 amount
    );
    event ReferralPaymentClaimed(
        address indexed referrer,
        uint256 amount
    );
    event FeeCollectorUpdated(address indexed oldCollector, address indexed newCollector);
    event EmergencyPauseSet(uint256 timestamp);

    modifier notInEmergency() {
        require(block.timestamp > emergencyPauseTimestamp, "Emergency pause active");
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize() external initializer {
        __ERC721_init("Evermark", "EVERMARK");
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);
        
        _nextTokenId = 1;
        emergencyPauseTimestamp = 0;
    }

    function mintEvermark(
        string calldata metadataURI,
        string calldata title, 
        string calldata creator
    ) external payable whenNotPaused notInEmergency nonReentrant returns (uint256) {
        return mintEvermarkWithReferral(metadataURI, title, creator, address(0));
    }

    function mintEvermarkWithReferral(
        string calldata metadataURI,
        string calldata title, 
        string calldata creator,
        address referrer
    ) public payable whenNotPaused notInEmergency nonReentrant returns (uint256) {
        require(msg.value >= MINTING_FEE, "Insufficient minting fee");
        require(referrer != msg.sender, "Cannot refer yourself");
        require(bytes(title).length > 0, "Title required");
        require(bytes(title).length <= 200, "Title too long");
        require(bytes(metadataURI).length > 0, "Metadata URI required");
        require(bytes(metadataURI).length <= 500, "Metadata URI too long");

        uint256 tokenId = _nextTokenId++;
        
        evermarkData[tokenId] = EvermarkMetadata({
            title: title,
            creator: creator,
            metadataURI: metadataURI,
            creationTime: block.timestamp,
            minter: msg.sender,
            referrer: referrer
        });

        _safeMint(msg.sender, tokenId);

        uint256 referralFee = 0;
        if (referrer != address(0)) {
            referralFee = (msg.value * REFERRAL_PERCENTAGE) / 100;
            
            (bool success, ) = payable(referrer).call{value: referralFee}("");
            if (success) {
                referralCounts[referrer]++;
                referralEarnings[referrer] += referralFee;
                emit ReferralEarned(referrer, msg.sender, referralFee);
            } else {
                pendingReferralPayments[referrer] += referralFee;
                referralCounts[referrer]++;
                emit ReferralPaymentFailed(referrer, msg.sender, referralFee);
            }
            
            evermarkReferrers[tokenId] = referrer;
        }

        uint256 remainingFee = msg.value - referralFee;
        if (remainingFee > 0 && feeCollector != address(0)) {
            try IFeeCollector(feeCollector).collectNftCreationFees{value: remainingFee}() {
            } catch {
            }
        }

        emit EvermarkMinted(tokenId, msg.sender, referrer, title);
        return tokenId;
    }

    function claimPendingReferralPayment() external nonReentrant whenNotPaused {
        uint256 amount = pendingReferralPayments[msg.sender];
        require(amount > 0, "No pending referral payments");
        
        pendingReferralPayments[msg.sender] = 0;
        referralEarnings[msg.sender] += amount;
        
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Referral payment claim failed");
        
        emit ReferralPaymentClaimed(msg.sender, amount);
    }

    function mintEvermarkBatch(
        string[] calldata metadataURIs,
        string[] calldata titles,
        string[] calldata creators,
        address referrer
    ) external payable whenNotPaused notInEmergency nonReentrant returns (uint256[] memory) {
        uint256 count = metadataURIs.length;
        require(count > 0 && count <= MAX_BATCH_SIZE, "Invalid batch size");
        require(count == titles.length && count == creators.length, "Array length mismatch");
        require(msg.value >= MINTING_FEE * count, "Insufficient batch fee");
        require(referrer != msg.sender, "Cannot refer yourself");

        uint256[] memory tokenIds = new uint256[](count);
        
        for (uint256 i = 0; i < count; i++) {
            require(bytes(titles[i]).length > 0, "Title required");
            require(bytes(titles[i]).length <= 200, "Title too long");
            require(bytes(metadataURIs[i]).length > 0, "Metadata URI required");
            require(bytes(metadataURIs[i]).length <= 500, "Metadata URI too long");
            
            uint256 tokenId = _nextTokenId++;
            tokenIds[i] = tokenId;
            
            evermarkData[tokenId] = EvermarkMetadata({
                title: titles[i],
                creator: creators[i],
                metadataURI: metadataURIs[i],
                creationTime: block.timestamp,
                minter: msg.sender,
                referrer: referrer
            });
            
            _safeMint(msg.sender, tokenId);
            
            if (referrer != address(0)) {
                evermarkReferrers[tokenId] = referrer;
            }
            
            emit EvermarkMinted(tokenId, msg.sender, referrer, titles[i]);
        }

        if (referrer != address(0)) {
            uint256 totalReferralFee = (msg.value * REFERRAL_PERCENTAGE) / 100;
            
            (bool success, ) = payable(referrer).call{value: totalReferralFee}("");
            if (success) {
                referralCounts[referrer] += count;
                referralEarnings[referrer] += totalReferralFee;
                emit ReferralEarned(referrer, msg.sender, totalReferralFee);
            } else {
                pendingReferralPayments[referrer] += totalReferralFee;
                referralCounts[referrer] += count;
                emit ReferralPaymentFailed(referrer, msg.sender, totalReferralFee);
            }
            
            uint256 remainingFee = msg.value - totalReferralFee;
            if (remainingFee > 0 && feeCollector != address(0)) {
                try IFeeCollector(feeCollector).collectNftCreationFees{value: remainingFee}() {
                } catch {
                }
            }
        } else {
            if (msg.value > 0 && feeCollector != address(0)) {
                try IFeeCollector(feeCollector).collectNftCreationFees{value: msg.value}() {
                } catch {
                }
            }
        }

        return tokenIds;
    }

    function mintEvermarkFor(
        address to,
        string calldata metadataURI,
        string calldata title,
        string calldata creator
    ) external onlyRole(MINTER_ROLE) whenNotPaused notInEmergency returns (uint256) {
        require(to != address(0), "Invalid recipient");
        require(bytes(title).length > 0, "Title required");
        require(bytes(title).length <= 200, "Title too long");
        require(bytes(metadataURI).length > 0, "Metadata URI required");
        require(bytes(metadataURI).length <= 500, "Metadata URI too long");

        uint256 tokenId = _nextTokenId++;
        
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

    function getReferralStats(address user) external view returns (
        uint256 totalReferred,
        uint256 totalEarned,
        uint256 pendingPayment,
        uint256 averageEarningPerReferral
    ) {
        totalReferred = referralCounts[user];
        totalEarned = referralEarnings[user];
        pendingPayment = pendingReferralPayments[user];
        averageEarningPerReferral = totalReferred > 0 ? totalEarned / totalReferred : 0;
    }

    function getEvermarkMetadata(uint256 tokenId) external view returns (
        string memory title,
        string memory creator,
        string memory metadataURI
    ) {

        require(_ownerOf(tokenId) != address(0), "Token does not exist");
        EvermarkMetadata memory data = evermarkData[tokenId];
        return (data.title, data.creator, data.metadataURI);
    }

    function getEvermarkCreator(uint256 tokenId) external view returns (address) {

        require(_ownerOf(tokenId) != address(0), "Token does not exist");
        return evermarkData[tokenId].minter;
    }

    function getEvermarkCreationTime(uint256 tokenId) external view returns (uint256) {

        require(_ownerOf(tokenId) != address(0), "Token does not exist");
        return evermarkData[tokenId].creationTime;
    }

    function exists(uint256 tokenId) external view returns (bool) {

        return _ownerOf(tokenId) != address(0);
    }

    function totalSupply() external view returns (uint256) {
        return _nextTokenId - 1;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {

        require(_ownerOf(tokenId) != address(0), "Token does not exist");
        return evermarkData[tokenId].metadataURI;
    }

    function getTotalPendingReferralPayments() external view returns (uint256) {
        return address(this).balance;
    }

    function setEmergencyPause(uint256 pauseUntilTimestamp) external onlyRole(ADMIN_ROLE) {
        emergencyPauseTimestamp = pauseUntilTimestamp;
        emit EmergencyPauseSet(pauseUntilTimestamp);
    }

    function clearEmergencyPause() external onlyRole(ADMIN_ROLE) {
        emergencyPauseTimestamp = 0;
        emit EmergencyPauseSet(0);
    }

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

    function emergencyWithdraw() external onlyRole(ADMIN_ROLE) {
        uint256 balance = address(this).balance;
        require(balance > 0, "No funds to withdraw");
        
        (bool success, ) = payable(msg.sender).call{value: balance}("");
        require(success, "Withdrawal failed");
    }

    function adminProcessReferralPayment(address referrer, uint256 amount) external onlyRole(ADMIN_ROLE) {
        require(pendingReferralPayments[referrer] >= amount, "Amount exceeds pending payment");
        require(amount > 0, "Amount must be greater than 0");
        
        pendingReferralPayments[referrer] -= amount;
        referralEarnings[referrer] += amount;
        
        (bool success, ) = payable(referrer).call{value: amount}("");
        require(success, "Admin referral payment failed");
        
        emit ReferralPaymentClaimed(referrer, amount);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    function supportsInterface(bytes4 interfaceId) public view override(ERC721Upgradeable, AccessControlUpgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function getBatchEvermarkMetadata(uint256[] calldata tokenIds) external view returns (EvermarkMetadata[] memory) {
        require(tokenIds.length <= 100, "Batch size too large");
        
        EvermarkMetadata[] memory results = new EvermarkMetadata[](tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(_ownerOf(tokenIds[i]) != address(0), "Token does not exist");
            results[i] = evermarkData[tokenIds[i]];
        }
        return results;
    }
}