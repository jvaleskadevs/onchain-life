// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {GasKillerSDK} from "gas-killer-sdk/GasKillerSDK.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title OnchainLifeNFT
/// @notice Conway's Game of Life as NFTs with Gas Killer integration.
///         Each token has a 64x64 board. Operators evolve off-chain, submit diffs via verifyAndUpdate.
contract OnchainLifeNFT is GasKillerSDK, ERC721, ReentrancyGuard {
    uint256 public constant MINT_PRICE = 0.007 ether;
    address public admin;
    IERC20 public stepToken;

    uint256 public constant WIDTH = 64;
    uint256 public constant HEIGHT = 64;
    uint256 public constant WORDS = 16;
    
    uint256 public nextTokenId;
    
    // Storage: tokenId => board words (slots calculated as keccak256(tokenId, base) + wordIdx)
    mapping(uint256 => uint256[16]) public boards;
    mapping(uint256 => uint256) public generation;
    mapping(address => uint256) public stepBalances;
    
    event BoardMinted(uint256 indexed tokenId, bytes32 boardHash);
    event BoardStepped(uint256 indexed tokenId, uint256 indexed generation, bytes32 boardHash);
    event StepDeposit(address indexed depositor, uint256 amount);
    event StepWithdrawal(address indexed withdrawer, uint256 amount);
    
    constructor(address _avsAddress, address _blsSigChecker, address _stepToken) ERC721("OnchainLife", "LIFE") {
        _setAvsAddress(_avsAddress);
        _setBlsSignatureChecker(_blsSigChecker);
        stepToken = IERC20(_stepToken);
        admin = msg.sender;
    }
    
    /// @notice Mint new NFT with eager board initialization.
    function mint() external payable nonReentrant returns (uint256 tokenId) {
        require(msg.value == MINT_PRICE, "Send exactly 0.007 ETH");
        
        tokenId = nextTokenId++;
        
        // Generate initial board from keccak256(tokenId)
        uint256[16] memory initial;
        for (uint256 i = 0; i < WORDS; i++) {
            initial[i] = uint256(keccak256(abi.encode(tokenId, i, keccak256("OnchainLifeNFT"))));
            boards[tokenId][i] = initial[i];
        }
        
        _safeMint(msg.sender, tokenId);
        emit BoardMinted(tokenId, keccak256(abi.encode(initial)));
    }
    
    function depositStep(uint256 amount) external nonReentrant {
        require(stepToken.transferFrom(msg.sender, address(this), amount), "STEP payment failed");
        stepBalances[msg.sender] += amount;
        emit StepDeposit(msg.sender, amount);
    }
    
    function withdrawStep(uint256 amount) external nonReentrant {
        require(stepToken.transfer(msg.sender, amount), "STEP payment failed");
        stepBalances[msg.sender] -= amount;
        emit StepWithdrawal(msg.sender, amount);
    }
    
    /// @notice Naive on-chain step (gas explosive). For testing/benchmarking only.
    /// @dev In production, use verifyAndUpdate via Gas Killer operator for cheap evolution.
    function step(uint256 tokenId, uint32 generations) external trackState nonReentrant {
        require(ownerOf(tokenId) == msg.sender, "Not owner");
        //require(stepToken.transferFrom(msg.sender, address(this), uint256(generations) * 1e18), "STEP payment failed");
        require(stepBalances[msg.sender] >= generations, "Not enough steps");
        
        stepBalances[msg.sender] -= generations * 1e18;
        
        uint256[16] memory cur = _loadBoard(tokenId);
        
        for (uint32 g = 0; g < generations; g++) {
            uint256[16] memory next;
            for (uint256 y = 0; y < HEIGHT; y++) {
                for (uint256 x = 0; x < WIDTH; x++) {
                    uint256 live = _liveNeighbors(cur, x, y);
                    bool alive = _cellAt(cur, x, y);
                    if (alive ? (live == 2 || live == 3) : (live == 3)) {
                        _setCell(next, x, y);
                    }
                }
            }
            cur = next;
        }
        
        _storeBoard(tokenId, cur);
        generation[tokenId] += generations;
        emit BoardStepped(tokenId, generation[tokenId], keccak256(abi.encode(boards[tokenId])));
    }
    
    /// @notice Generate tokenURI with live BMP image on-the-fly.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(_exists(tokenId), "Nonexistent token");
        
        uint256[16] memory b = boards[tokenId];
        uint256 gen = generation[tokenId];
        
        string memory image = _generateImageDataURI(b);
        
        string memory json = string(abi.encodePacked(
            '{"name":"OnchainLife #', _toString(tokenId),
            '","description":"Conway Game of Life - Generation ', _toString(gen),
            '","image":"', image,
            '","attributes":[',
                '{"trait_type":"Steps","value":', _toString(gen), '},',
                '{"trait_type":"Live Cells","value":', _toString(_countLive(b)), '}',
            ']}'
        ));
        
        return string(abi.encodePacked(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        ));
    }
    
    function getBoard(uint256 tokenId) external view returns (uint256[16] memory out) {
        for (uint256 i = 0; i < WORDS; i++) {
            out[i] = boards[tokenId][i];
        }
    }
    
    function getCell(uint256 tokenId, uint256 x, uint256 y) external view returns (bool) {
        require(x < WIDTH && y < HEIGHT, "out of bounds");
        uint256 idx = y * WIDTH + x;
        return (boards[tokenId][idx >> 8] >> (idx & 255)) & 1 == 1;
    }
    
    function boardHash(uint256 tokenId) external view returns (bytes32) {
        return keccak256(abi.encode(boards[tokenId]));
    }
    
    // withdrawal function for ETH
    function withdrawETH() external {
        require(msg.sender == admin, "Forbidden");
        (bool success, ) = msg.sender.call{value: address(this).balance}("");
        require(success, "ETH transfer failed");
    }
    
    // withdrawal function for STEP tokens
    function withdrawStepAdmin() external {
        require(msg.sender == admin, "Forbidden");
        uint256 balance = stepToken.balanceOf(address(this));
        require(stepToken.transfer(msg.sender, balance), "STEP transfer failed");
    }
    
    /* ----------------------------- Internal Helpers (from original) ----------------------------- */
    
    function _loadBoard(uint256 tokenId) private view returns (uint256[16] memory cur) {
        for (uint256 i = 0; i < WORDS; i++) {
            cur[i] = boards[tokenId][i];
        }
    }
    
    function _storeBoard(uint256 tokenId, uint256[16] memory next) private {
        for (uint256 i = 0; i < WORDS; i++) {
            boards[tokenId][i] = next[i];
        }
    }
    
    function _cellAt(uint256[16] memory b, uint256 x, uint256 y) private pure returns (bool) {
        uint256 idx = y * WIDTH + x;
        return (b[idx >> 8] >> (idx & 255)) & 1 == 1;
    }
    
    function _setCell(uint256[16] memory b, uint256 x, uint256 y) private pure {
        uint256 idx = y * WIDTH + x;
        b[idx >> 8] |= (uint256(1) << (idx & 255));
    }
    
    function _liveNeighbors(uint256[16] memory b, uint256 x, uint256 y) private pure returns (uint256 count) {
        uint256 xm1 = x == 0 ? WIDTH - 1 : x - 1;
        uint256 xp1 = x == WIDTH - 1 ? 0 : x + 1;
        uint256 ym1 = y == 0 ? HEIGHT - 1 : y - 1;
        uint256 yp1 = y == HEIGHT - 1 ? 0 : y + 1;

        count = _b(b, xm1, ym1) + _b(b, x, ym1) + _b(b, xp1, ym1) + 
                _b(b, xm1, y) + _b(b, xp1, y) + 
                _b(b, xm1, yp1) + _b(b, x, yp1) + _b(b, xp1, yp1);
    }
    
    function _b(uint256[16] memory b, uint256 x, uint256 y) private pure returns (uint256) {
        uint256 idx = y * WIDTH + x;
        return (b[idx >> 8] >> (idx & 255)) & 1;
    }
    
    /* ----------------------------- BMP Generation ----------------------------- */

    function _generateImageDataURI(uint256[16] memory b) internal pure returns (string memory) {
        string memory bmpBase64 = Base64.encode(_generateBMP(b));
        
        // SVG wrapper: 64x64 viewBox, display at 512x512 pixels
        string memory svg = string(abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="512" height="512">',
            '<image href="data:image/bmp;base64,', bmpBase64, 
            '" width="64" height="64" image-rendering="pixelated"/>',
            '</svg>'
        ));
        
        return string(abi.encodePacked(
            "data:image/svg+xml;base64,",
            Base64.encode(bytes(svg))
        ));
    }
/*    
    function _generateBMPDataURI(uint256[16] memory b) private pure returns (string memory) {
        bytes memory bmp = _generateBMP(b);
        return string(abi.encodePacked(
            "data:image/bmp;base64,",
            Base64.encode(bmp)
        ));
    }
*/    
    function _generateBMP(uint256[16] memory b) private pure returns (bytes memory) {
        // BMP Header (62 bytes) - properly formatted hex
        bytes memory header = hex"424D" // Signature "BM"
            hex"66020000" // File size: 574 bytes (0x0266 little endian)
            hex"0000"     // Reserved
            hex"0000"     // Reserved
            hex"3E000000" // Data offset: 62 bytes
            hex"28000000" // Header size: 40 bytes
            hex"40000000" // Width: 64
            hex"40000000" // Height: 64
            hex"0100"     // Planes: 1
            hex"0100"     // Bits per pixel: 1
            hex"00000000" // Compression: none
            hex"00020000" // Image size: 512 bytes
            hex"00000000" // X pixels per meter
            hex"00000000" // Y pixels per meter
            hex"02000000" // Colors used: 2
            hex"02000000" // Important colors: 2
            hex"00000000" // Color 0: Black (BGRA)
            hex"00FF0000"; // Color 1: Green (BGRA)
        
        bytes memory pixels = new bytes(512);
        
        for (uint256 y = 0; y < 64; y++) {
            uint256 row = 63 - y;
            for (uint256 x = 0; x < 64; x += 8) {
                uint8 packed;
                for (uint256 bit = 0; bit < 8; bit++) {
                    uint256 cellIdx = row * 64 + x + bit;
                    if ((b[cellIdx >> 8] >> (cellIdx & 255)) & 1 == 1) {
                        packed |= uint8(1 << (7 - bit));
                    }
                }
                pixels[(y * 8) + (x >> 3)] = bytes1(packed);
            }
        }
        return bytes.concat(header, pixels);
    }
    
    function _countLive(uint256[16] memory b) private pure returns (uint256) {
        uint256 count;
        for (uint256 i = 0; i < WORDS; i++) {
            uint256 word = b[i];
            while (word != 0) {
                word &= word - 1;
                count++;
            }
        }
        return count;
    }
    
    function _toString(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
    
    function supportsInterface(bytes4 interfaceId) public view override(ERC721, GasKillerSDK) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
