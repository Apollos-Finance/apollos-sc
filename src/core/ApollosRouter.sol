// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// Interfaces
import {IApollosRouter} from "../interfaces/IApollosRouter.sol";
import {IApollosVault} from "../interfaces/IApollosVault.sol";
import {IApollosFactory} from "../interfaces/IApollosFactory.sol";

// WETH Interface
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/**
 * @title ApollosRouter
 * @notice User-facing entry point for Apollos Finance deposits and withdrawals
 * @dev Routes operations to appropriate vaults:
 *      - Finds vault based on deposited asset
 *      - Handles WETH wrapping for ETH deposits
 *      - Integrates with CCIP for cross-chain deposits
 */
contract ApollosRouter is IApollosRouter, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Immutables ============
    IApollosFactory public immutable apollosFactory;
    IWETH public immutable wethContract;
    address public immutable ccipRouterAddress;

    // ============ State Variables ============
    
    /// @notice Mapping: asset => vault
    mapping(address => address) public assetToVault;
    
    /// @notice List of supported assets
    address[] public supportedAssets;
    
    /// @notice Supported CCIP chain selectors
    mapping(uint64 => bool) public supportedChains;
    
    /// @notice Quote asset (e.g., USDC) for all vaults
    address public quoteAsset;

    // ============ Constructor ============
    
    constructor(
        address _factory,
        address _weth,
        address _ccipRouter,
        address _quoteAsset
    ) Ownable(msg.sender) {
        if (_factory == address(0) || _weth == address(0)) revert ZeroAddress();
        
        apollosFactory = IApollosFactory(_factory);
        wethContract = IWETH(_weth);
        ccipRouterAddress = _ccipRouter;
        quoteAsset = _quoteAsset;
    }

    // ============ Receive ETH ============
    receive() external payable {}

    // ============ Deposit Functions ============

    /**
     * @notice Deposit asset into appropriate vault
     */
    function deposit(DepositParams calldata params) 
        external 
        override 
        nonReentrant 
        returns (address vault, uint256 shares) 
    {
        if (params.amount == 0) revert ZeroAmount();
        
        vault = _getVaultForAsset(params.asset);
        if (vault == address(0)) revert VaultNotFound();
        
        // Transfer tokens from user
        IERC20(params.asset).safeTransferFrom(msg.sender, address(this), params.amount);
        
        // Approve vault
        IERC20(params.asset).safeIncreaseAllowance(vault, params.amount);
        
        // Deposit to vault
        address receiver = params.receiver == address(0) ? msg.sender : params.receiver;
        shares = IApollosVault(vault).depositFor(params.amount, receiver, params.minShares);
        
        emit Deposit(msg.sender, vault, params.asset, params.amount, shares);
    }

    /**
     * @notice Deposit ETH - wraps to WETH and deposits
     */
    function depositETH(uint256 minShares) 
        external 
        payable 
        override 
        nonReentrant 
        returns (address vault, uint256 shares) 
    {
        if (msg.value == 0) revert ZeroAmount();
        
        vault = _getVaultForAsset(address(wethContract));
        if (vault == address(0)) revert VaultNotFound();
        
        // Wrap ETH to WETH
        wethContract.deposit{value: msg.value}();
        
        // Approve vault
        wethContract.approve(vault, msg.value);
        
        // Deposit to vault
        shares = IApollosVault(vault).depositFor(msg.value, msg.sender, minShares);
        
        emit Deposit(msg.sender, vault, address(wethContract), msg.value, shares);
    }

    // ============ Withdraw Functions ============

    /**
     * @notice Withdraw from vault
     */
    function withdraw(WithdrawParams calldata params) 
        external 
        override 
        nonReentrant 
        returns (uint256 amount) 
    {
        if (params.shares == 0) revert ZeroAmount();
        if (params.vault == address(0)) revert ZeroAddress();
        
        IApollosVault vault = IApollosVault(params.vault);
        
        // Transfer shares from user to router
        IERC20(params.vault).safeTransferFrom(msg.sender, address(this), params.shares);
        
        // Withdraw from vault
        amount = vault.withdraw(params.shares, params.minAmount);
        
        // Get base asset and transfer to receiver
        IApollosVault.VaultConfig memory config = vault.getVaultConfig();
        address receiver = params.receiver == address(0) ? msg.sender : params.receiver;
        IERC20(config.baseAsset).safeTransfer(receiver, amount);
        
        emit Withdraw(msg.sender, params.vault, params.shares, amount);
    }

    /**
     * @notice Withdraw and unwrap to ETH
     */
    function withdrawETH(
        address vault,
        uint256 shares,
        uint256 minAmount
    ) external override nonReentrant returns (uint256 amount) {
        if (shares == 0) revert ZeroAmount();
        if (vault == address(0)) revert ZeroAddress();
        
        IApollosVault apollosVault = IApollosVault(vault);
        
        // Verify it's a WETH vault
        IApollosVault.VaultConfig memory config = apollosVault.getVaultConfig();
        if (config.baseAsset != address(wethContract)) revert UnsupportedAsset();
        
        // Transfer shares from user to router
        IERC20(vault).safeTransferFrom(msg.sender, address(this), shares);
        
        // Withdraw from vault (receive WETH)
        amount = apollosVault.withdraw(shares, minAmount);
        
        // Unwrap WETH to ETH
        wethContract.withdraw(amount);
        
        // Transfer ETH to user
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "ETH transfer failed");
        
        emit Withdraw(msg.sender, vault, shares, amount);
    }

    // ============ Cross-Chain Functions (CCIP) ============

    /**
     * @notice Initiate cross-chain deposit via CCIP
     * @dev Simplified for hackathon - full implementation requires CCIP Router
     */
    function depositCrossChain(CrossChainDepositParams calldata params) 
        external 
        payable 
        override 
        nonReentrant 
        returns (bytes32 messageId) 
    {
        if (params.amount == 0) revert ZeroAmount();
        if (!supportedChains[params.destinationChainSelector]) revert InvalidChainSelector();
        
        // Transfer tokens from user
        IERC20(params.asset).safeTransferFrom(msg.sender, address(this), params.amount);
        
        // TODO: Implement full CCIP integration
        // For hackathon, emit event for off-chain tracking
        messageId = keccak256(abi.encodePacked(
            params.destinationChainSelector,
            params.receiver,
            params.asset,
            params.amount,
            block.timestamp
        ));
        
        emit CrossChainDepositInitiated(
            messageId,
            params.destinationChainSelector,
            msg.sender,
            params.asset,
            params.amount
        );
    }

    /**
     * @notice Get CCIP fee estimate
     */
    function getCrossChainFee(
        uint64 /* destinationChainSelector */,
        address /* asset */,
        uint256 /* amount */
    ) external pure override returns (uint256 fee) {
        // Simplified: return fixed estimate
        // In production: query CCIP Router for actual fee
        return 0.01 ether;
    }

    // ============ View Functions ============

    function getVaultForAsset(address asset) external view override returns (address) {
        return _getVaultForAsset(asset);
    }

    function _getVaultForAsset(address asset) internal view returns (address) {
        // First check direct mapping
        if (assetToVault[asset] != address(0)) {
            return assetToVault[asset];
        }
        
        // Then check factory
        return apollosFactory.getVault(asset, quoteAsset);
    }

    function getSupportedAssets() external view override returns (address[] memory) {
        return supportedAssets;
    }

    function previewDeposit(address asset, uint256 amount) 
        external 
        view 
        override 
        returns (address vault, uint256 shares) 
    {
        vault = _getVaultForAsset(asset);
        if (vault == address(0)) return (address(0), 0);
        
        shares = IApollosVault(vault).previewDeposit(amount);
    }

    function previewWithdraw(address vault, uint256 shares) 
        external 
        view 
        override 
        returns (uint256 amount) 
    {
        if (vault == address(0)) return 0;
        amount = IApollosVault(vault).previewWithdraw(shares);
    }

    function factory() external view override returns (address) {
        return address(apollosFactory);
    }

    function weth() external view override returns (address) {
        return address(wethContract);
    }

    function ccipRouter() external view override returns (address) {
        return ccipRouterAddress;
    }

    // ============ Admin Functions ============

    function setAssetVault(address asset, address vault) external override onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        
        // Add to supported assets if new
        if (assetToVault[asset] == address(0) && vault != address(0)) {
            supportedAssets.push(asset);
        }
        
        assetToVault[asset] = vault;
    }

    function setSupportedChain(uint64 chainSelector, bool supported) external override onlyOwner {
        supportedChains[chainSelector] = supported;
    }

    function setQuoteAsset(address _quoteAsset) external onlyOwner {
        if (_quoteAsset == address(0)) revert ZeroAddress();
        quoteAsset = _quoteAsset;
    }

    /**
     * @notice Rescue stuck tokens (emergency)
     */
    function rescueTokens(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }

    /**
     * @notice Rescue stuck ETH (emergency)
     */
    function rescueETH() external onlyOwner {
        (bool success, ) = owner().call{value: address(this).balance}("");
        require(success, "ETH rescue failed");
    }
}
