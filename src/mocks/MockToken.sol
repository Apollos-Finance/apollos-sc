// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockToken
 * @notice Mock ERC20 token for Apollos Finance testing (WETH, USDC, LINK, WBTC)
 * @dev Includes faucet functionality with rate limiting for testnet usage
 */
contract MockToken is ERC20, ERC20Burnable, Ownable {
    uint8 private _decimals;
    bool public immutable isWETH; // True only for WETH, false for USDC/LINK/WBTC
    
    uint256 public constant FAUCET_COOLDOWN = 1 days;
    uint256 public constant MAX_FAUCET_AMOUNT = 10000;
    
    mapping(address => uint256) public lastFaucetClaim;

    event FaucetClaimed(address indexed user, uint256 amount);
    event TokensMinted(address indexed to, uint256 amount);
    event TokensBurned(address indexed from, uint256 amount);

    error FaucetCooldownActive(uint256 remainingTime);
    error FaucetAmountExceeded(uint256 requested, uint256 maximum);
    error ZeroAddress();
    error ZeroAmount();
    error NotWETH(); // Tried to use WETH functions on non-WETH token

    /**
     * @notice Constructor
     * @param name Token name (e.g., "Wrapped Ether", "USD Coin")
     * @param symbol Token symbol (e.g., "WETH", "USDC")
     * @param decimals_ Token decimals (18 for WETH, 6 for USDC)
     * @param _isWETH True if this is WETH (enables deposit/withdraw), false otherwise
     */
    constructor(
        string memory name, 
        string memory symbol, 
        uint8 decimals_,
        bool _isWETH
    )
        ERC20(name, symbol)
        Ownable(msg.sender)
    {
        _decimals = decimals_;
        isWETH = _isWETH;
    }

    /**
     * @notice Get token decimals
     * @return Token decimals
     */
    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /**
     * @notice Mint tokens (owner only for controlled supply)
     * @param to Recipient address
     * @param amount Amount to mint (in smallest unit)
     */
    function mint(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        
        _mint(to, amount);
        emit TokensMinted(to, amount);
    }

    /**
     * @notice Mint tokens to any address (for testing convenience)
     * @dev This is public for easy testnet setup - would be restricted in production
     * @param to Recipient address
     * @param amount Amount to mint (in smallest unit)
     */
    function mintTo(address to, uint256 amount) public {
        if (to == address(0)) revert ZeroAddress();
        _mint(to, amount);
    }

    /**
     * @notice Faucet - mint tokens to sender with rate limiting
     * @param amount Amount to mint (in token units, will be multiplied by decimals)
     */
    function faucet(uint256 amount) external {
        uint256 timeSinceLastClaim = block.timestamp - lastFaucetClaim[msg.sender];
        
        if (lastFaucetClaim[msg.sender] != 0 && timeSinceLastClaim < FAUCET_COOLDOWN) {
            revert FaucetCooldownActive(FAUCET_COOLDOWN - timeSinceLastClaim);
        }

        if (amount > MAX_FAUCET_AMOUNT) {
            revert FaucetAmountExceeded(amount, MAX_FAUCET_AMOUNT);
        }

        lastFaucetClaim[msg.sender] = block.timestamp;

        uint256 mintAmount = amount * 10 ** _decimals;
        _mint(msg.sender, mintAmount);

        emit FaucetClaimed(msg.sender, mintAmount);
    }

    /**
     * @notice Get remaining cooldown time for an address
     * @param user Address to check
     * @return remainingTime Time remaining until next faucet claim (0 if can claim now)
     */
    function getFaucetCooldown(address user) external view returns (uint256 remainingTime) {
        if (lastFaucetClaim[user] == 0) {
            return 0;
        }

        uint256 timeSinceLastClaim = block.timestamp - lastFaucetClaim[user];
        if (timeSinceLastClaim >= FAUCET_COOLDOWN) {
            return 0;
        }

        return FAUCET_COOLDOWN - timeSinceLastClaim;
    }

    /**
     * @notice Check if an address can claim from faucet
     * @param user Address to check
     * @return canClaim True if user can claim, false otherwise
     */
    function canClaimFaucet(address user) external view returns (bool canClaim) {
        if (lastFaucetClaim[user] == 0) {
            return true;
        }

        uint256 timeSinceLastClaim = block.timestamp - lastFaucetClaim[user];
        return timeSinceLastClaim >= FAUCET_COOLDOWN;
    }

    /**
     * @notice Deposit ETH and receive wrapped tokens (WETH functionality)
     * @dev Only works if token was deployed with isWETH = true
     */
    function deposit() external payable {
        if (!isWETH) revert NotWETH();
        if (msg.value == 0) revert ZeroAmount();
        _mint(msg.sender, msg.value);
    }

    /**
     * @notice Withdraw ETH by burning wrapped tokens (WETH functionality)
     * @dev Only works if token was deployed with isWETH = true
     * @param amount Amount to withdraw
     */
    function withdraw(uint256 amount) external {
        if (!isWETH) revert NotWETH();
        if (amount == 0) revert ZeroAmount();
        _burn(msg.sender, amount);
        
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "ETH transfer failed");
    }

    /**
     * @notice Receive ETH and auto-wrap (WETH functionality)
     * @dev Only accepts ETH if token was deployed with isWETH = true
     *      Reverts if someone sends ETH to USDC/LINK/WBTC contracts
     */
    receive() external payable {
        if (!isWETH) revert NotWETH();
        if (msg.value > 0) {
            _mint(msg.sender, msg.value);
        }
    }
}