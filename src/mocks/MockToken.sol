// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockToken
 * @notice Mock ERC20 token implementation for Apollos testing and demonstration.
 * @author Apollos Team
 * @dev Extends standard ERC20 with:
 *      - Configurable decimals.
 *      - Faucet functionality with rate limiting (1-day cooldown).
 *      - Native ETH wrapping (WETH-style) if enabled during deployment.
 *
 * @custom:security-contact security@apollos.finance
 */
contract MockToken is ERC20, ERC20Burnable, Ownable {
    /// @dev Internal storage for custom decimal count
    uint8 private _decimals;

    /// @notice Indicates if this token contract supports WETH-style deposit/withdraw
    bool public immutable isWETH;

    /// @notice Time interval required between faucet claims (24 hours)
    uint256 public constant FAUCET_COOLDOWN = 1 days;

    /// @notice Maximum amount of tokens a user can claim from the faucet per interval
    uint256 public constant MAX_FAUCET_AMOUNT = 10000;

    /// @notice Maps user address to the timestamp of their last successful faucet claim
    mapping(address => uint256) public lastFaucetClaim;

    /// @notice Emitted when a user claims tokens from the faucet
    event FaucetClaimed(address indexed user, uint256 amount);

    /// @notice Emitted when tokens are minted via owner or public minting
    event TokensMinted(address indexed to, uint256 amount);

    /// @notice Emitted when tokens are burned
    event TokensBurned(address indexed from, uint256 amount);

    /// @notice Error thrown when trying to claim from faucet before cooldown expires
    error FaucetCooldownActive(uint256 remainingTime);

    /// @notice Error thrown when requested faucet amount exceeds the defined limit
    error FaucetAmountExceeded(uint256 requested, uint256 maximum);

    /// @notice Error thrown when a zero address is provided as an argument
    error ZeroAddress();

    /// @notice Error thrown when a zero amount is provided as an argument
    error ZeroAmount();

    /// @notice Error thrown when calling WETH functions on a non-WETH token
    error NotWETH();

    /**
     * @notice Initializes the mock token with name, symbol, and configuration
     * @param name Full name of the token (e.g., "Wrapped Ether")
     * @param symbol Short symbol of the token (e.g., "WETH")
     * @param decimals_ Number of decimal places (e.g., 18 for WETH, 6 for USDC)
     * @param _isWETH Set to true to enable WETH-style deposit/withdrawal functionality
     */
    constructor(string memory name, string memory symbol, uint8 decimals_, bool _isWETH)
        ERC20(name, symbol)
        Ownable(msg.sender)
    {
        _decimals = decimals_;
        isWETH = _isWETH;
    }

    /**
     * @notice Returns the number of decimals for this token
     * @return The number of decimal places
     */
    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /**
     * @notice Mints tokens to a specific address (Restrictive version)
     * @dev Restricted to the contract owner
     * @param to Recipient address
     * @param amount Amount to mint (in smallest units)
     */
    function mint(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        _mint(to, amount);
        emit TokensMinted(to, amount);
    }

    /**
     * @notice Mints tokens to any address (Permissive version for testing)
     * @dev Publicly accessible to facilitate easy testnet setup
     * @param to Recipient address
     * @param amount Amount to mint (in smallest units)
     */
    function mintTo(address to, uint256 amount) public {
        if (to == address(0)) revert ZeroAddress();
        _mint(to, amount);
    }

    /**
     * @notice Faucet - Allows users to mint tokens for themselves with rate limiting
     * @dev Amount is specified in token units (automatically adjusted for decimals)
     * @param amount Amount to mint (e.g., 100 for 100 tokens)
     */
    function faucet(uint256 amount) external {
        if (amount > MAX_FAUCET_AMOUNT) {
            revert FaucetAmountExceeded(amount, MAX_FAUCET_AMOUNT);
        }

        _claimFaucet(amount * 10 ** _decimals);
    }

    /**
     * @notice Faucet - Allows users to mint tokens using raw smallest units
     * @param rawAmount Amount in raw units (wei-like)
     */
    function faucetRaw(uint256 rawAmount) external {
        uint256 maxRawAmount = MAX_FAUCET_AMOUNT * 10 ** _decimals;
        if (rawAmount > maxRawAmount) {
            revert FaucetAmountExceeded(rawAmount, maxRawAmount);
        }

        _claimFaucet(rawAmount);
    }

    /**
     * @notice Returns the remaining cooldown time for a specific user
     * @param user The address to check
     * @return remainingTime Time in seconds until the next claim is possible
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
     * @notice Checks if a specific address is currently allowed to claim from the faucet
     * @param user The address to check
     * @return canClaim True if claim is possible, false otherwise
     */
    function canClaimFaucet(address user) external view returns (bool canClaim) {
        if (lastFaucetClaim[user] == 0) {
            return true;
        }

        uint256 timeSinceLastClaim = block.timestamp - lastFaucetClaim[user];
        return timeSinceLastClaim >= FAUCET_COOLDOWN;
    }

    /**
     * @dev Internal helper for faucet claiming logic
     */
    function _claimFaucet(uint256 mintAmount) internal {
        if (mintAmount == 0) revert ZeroAmount();

        uint256 timeSinceLastClaim = block.timestamp - lastFaucetClaim[msg.sender];
        if (lastFaucetClaim[msg.sender] != 0 && timeSinceLastClaim < FAUCET_COOLDOWN) {
            revert FaucetCooldownActive(FAUCET_COOLDOWN - timeSinceLastClaim);
        }

        lastFaucetClaim[msg.sender] = block.timestamp;
        _mint(msg.sender, mintAmount);
        emit FaucetClaimed(msg.sender, mintAmount);
    }

    /**
     * @notice Deposits native ETH and receives an equal amount of mock tokens
     * @dev Only functional if isWETH is set to true
     */
    function deposit() external payable {
        if (!isWETH) revert NotWETH();
        if (msg.value == 0) revert ZeroAmount();
        _mint(msg.sender, msg.value);
    }

    /**
     * @notice Withdraws mock tokens and receives an equal amount of native ETH
     * @dev Only functional if isWETH is set to true
     * @param amount The amount of tokens to burn/withdraw
     */
    function withdraw(uint256 amount) external {
        if (!isWETH) revert NotWETH();
        if (amount == 0) revert ZeroAmount();
        _burn(msg.sender, amount);

        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "ETH transfer failed");
    }

    /**
     * @notice Fallback function to receive native ETH and auto-wrap it
     */
    receive() external payable {
        if (!isWETH) revert NotWETH();
        if (msg.value > 0) {
            _mint(msg.sender, msg.value);
        }
    }
}
