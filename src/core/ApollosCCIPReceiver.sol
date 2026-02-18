// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";

import {IApollosCCIPReceiver} from "../interfaces/IApollosCCIPReceiver.sol";
import {IApollosVault} from "../interfaces/IApollosVault.sol";
import {IApollosFactory} from "../interfaces/IApollosFactory.sol";
import {IMockUniswapPool} from "../interfaces/IMockUniswapPool.sol";

// V4 Core Types (needed for swap)
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/**
 * @title ApollosCCIPReceiver
 * @notice Receives cross-chain deposits via Chainlink CCIP with Auto-Zapping (Store-and-Execute)
 * @dev Deployed on Arbitrum (destination chain) to:
 *      1. Receive CCIP messages from source chain ApollosRouters
 *      2. STORE the message details (Store-and-Execute pattern) to avoid gas limits
 *      3. EXECUTE Zap using "Reserve Swap" mechanism (Use stored USDC, don't mint)
 *      4. Deposit into appropriate Apollos vault
 *
 * Architecture:
 *      - Phase 1 (_ccipReceive): Lightweight. Validates sender & stores PendingDeposit.
 *      - Phase 2 (executeZap): Heavy. Swaps Reserve USDC -> Target Asset -> Deposit Vault.
 */
contract ApollosCCIPReceiver is IApollosCCIPReceiver, CCIPReceiver, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    // ============ Structs ============
    
    struct PendingDeposit {
        bytes32 messageId;
        uint64 sourceChainSelector;
        address sourceSender;
        address receiver;
        uint256 amount;          // Source asset amount (CCIP-BnM)
        address sourceAsset;     // Source asset address
        address targetBaseAsset; // Target vault base asset
        uint256 minShares;       // Slippage protection (Legacy/Stored - ignored in favor of fresh param)
        bool executed;           // Execution status
    }

    // ============ Immutables ============
    
    IApollosFactory public immutable apollosFactory;

    // ============ State Variables ============
    
    /// @notice Quote asset used in mock pools (MockUSDC)
    address public quoteAsset;
    
    /// @notice Reserve asset used for swapping (MockUSDC)
    /// @dev Contract MUST be funded with this token for zapping to work!
    address public reserveAsset; 
    
    IMockUniswapPool public swapPool;
    
    /// @notice sourceChainSelector => senderAddress => authorized
    mapping(uint64 => mapping(address => bool)) public authorizedSources;
    
    /// @notice sourceAsset => localAsset (cross-chain token equivalence)
    mapping(address => address) public assetMapping;
    
    /// @notice baseAsset => vault (direct lookup cache)
    mapping(address => address) public assetToVault;
    
    /// @notice baseAsset => PoolKey (for swap routing)
    mapping(address => PoolKey) public swapPoolKeys;
    
    /// @notice baseAsset => whether PoolKey is configured
    mapping(address => bool) public hasSwapConfig;

    /// @notice Stored pending deposits (Store-and-Execute)
    mapping(bytes32 => PendingDeposit) public pendingDeposits;

    // ============ Events ============
    
    event DepositStored(bytes32 indexed messageId, uint64 indexed sourceChainSelector, address indexed receiver, uint256 amount);
    event ZapExecuted(bytes32 indexed messageId, address indexed vault, uint256 shares);
    event ZapFailed(bytes32 indexed messageId, string reason);
    event ReserveInsufficient(uint256 required, uint256 available);

    // ============ Constructor ============
    
    constructor(
        address _ccipRouter,
        address _factory,
        address _quoteAsset,
        address _reserveAsset,
        address _swapPool
    ) CCIPReceiver(_ccipRouter) Ownable(msg.sender) {
        if (_factory == address(0)) revert ZeroAddress();
        
        apollosFactory = IApollosFactory(_factory);
        quoteAsset = _quoteAsset; // Can be same as reserveAsset
        reserveAsset = _reserveAsset; // MockUSDC
        if (_swapPool != address(0)) {
            swapPool = IMockUniswapPool(_swapPool);
        }
    }

    // ============ CCIP Receive (Phase 1: Store) ============

    /**
     * @notice Internal handler for incoming CCIP messages
     * @dev Only stores the intent. Does NOT execute heavy logic.
     */
    function _ccipReceive(Client.Any2EVMMessage memory message) 
        internal 
        override 
    {
        // 1. Validate source
        address sourceSender = abi.decode(message.sender, (address));
        if (!authorizedSources[message.sourceChainSelector][sourceSender]) {
            revert InvalidSender();
        }
        
        // 2. Decode deposit data
        (
            address sourceAsset,
            uint256 amount,
            uint256 minShares,
            address receiver,
            , // originalSender (unused in store)
            address targetBaseAsset
        ) = abi.decode(message.data, (address, uint256, uint256, address, address, address));
        
        // 3. Store Pending Deposit
        pendingDeposits[message.messageId] = PendingDeposit({
            messageId: message.messageId,
            sourceChainSelector: message.sourceChainSelector,
            sourceSender: sourceSender,
            receiver: receiver,
            amount: amount,
            sourceAsset: sourceAsset,
            targetBaseAsset: targetBaseAsset,
            minShares: minShares,
            executed: false
        });
        
        emit DepositStored(message.messageId, message.sourceChainSelector, receiver, amount);
    }

    // ============ Execute Zap (Phase 2: Execute) ============

    /**
     * @notice Execute the stored deposit intent with FRESH Slippage
     * @param messageId ID of the CCIP message to execute
     * @param minShares Fresh slippage protection provided by user at execution time
     */
    function executeZap(bytes32 messageId, uint256 minShares) external nonReentrant {
        PendingDeposit storage deposit = pendingDeposits[messageId];
        
        if (deposit.amount == 0) revert("Deposit not found");
        if (deposit.executed) revert("Already executed");
        
        // Mark executed optimistically.
        // If anything below fails/reverts, this change will also revert (Native Retry Mechanism).
        deposit.executed = true;

        // 1. Determine local asset
        address localReceivedAsset = _getLocalAsset(deposit.sourceAsset);
        
        // 2. Reserve Swap Logic: 1 CCIP-BnM (18 dec) = 10 USDC (6 dec)
        address swapFromAsset = localReceivedAsset;
        uint256 swapFromAmount = deposit.amount;

        // Check if we need to use Reserve USDC
        if (localReceivedAsset != reserveAsset && reserveAsset != address(0)) {
            uint256 rawAmount = deposit.amount * 10;
            uint256 requiredUsdc = rawAmount / 1e12; // Adjust decimals 18 -> 6

            uint256 reserveBalance = IERC20(reserveAsset).balanceOf(address(this));
            if (reserveBalance < requiredUsdc) {
                // We keep this as a manual revert/emit because insufficient reserve 
                // is a contract state issue, not a user parameter issue.
                // However, reverting here is also fine. Let's revert to keep it simple and safe.
                revert("Insufficient Reserve USDC");
            }

            swapFromAsset = reserveAsset;
            swapFromAmount = requiredUsdc;
        }

        // 3. Auto-Zap: Swap USDC -> Target Base Asset (e.g. WETH)
        address depositAsset = swapFromAsset;
        uint256 depositAmount = swapFromAmount;

        if (swapFromAsset != deposit.targetBaseAsset) {
            (depositAsset, depositAmount) = _autoZap(
                swapFromAsset,
                deposit.targetBaseAsset,
                swapFromAmount
            );
            // If swap failed (returned 0), _autoZap would have emitted log, 
            // but here we probably want to revert to allow retry?
            // Yes, let's strictly require swap success.
            require(depositAsset != address(0), "Swap failed");
        }

        // 4. Deposit to Vault
        // Direct call without try/catch. If this fails (e.g. minShares not met),
        // the whole transaction reverts, resetting 'executed' to false.
        _depositToVault(
            depositAsset,
            depositAmount,
            deposit.receiver,
            minShares, // Use FRESH minShares from parameter
            messageId,
            deposit.sourceChainSelector
        );
    }

    // ============ Internal Functions ============

    function _autoZap(
        address fromToken,
        address toToken,
        uint256 amountIn
    ) internal returns (address swappedAsset, uint256 swappedAmount) {
        if (address(swapPool) == address(0) || !hasSwapConfig[toToken]) {
            return (address(0), 0);
        }
        
        PoolKey memory poolKey = swapPoolKeys[toToken];
        bool zeroForOne = (Currency.unwrap(poolKey.currency0) == fromToken);
        
        IERC20(fromToken).safeIncreaseAllowance(address(swapPool), amountIn);
        
        try swapPool.swap(
            poolKey,
            zeroForOne,
            -int256(amountIn),
            0 
        ) returns (uint256, uint256 amountOut) {
            swappedAsset = toToken;
            swappedAmount = amountOut;
            emit SwapExecuted(fromToken, toToken, amountIn, amountOut);
        } catch {
            return (address(0), 0);
        }
    }

    function _depositToVault(
        address asset,
        uint256 amount,
        address receiver,
        uint256 minShares,
        bytes32 messageId,
        uint64 sourceChainSelector
    ) internal {
        address vault = _getVaultForAsset(asset);
        require(vault != address(0), "Vault not found");
        
        IERC20(asset).safeIncreaseAllowance(vault, amount);
        
        // This call will REVERT if minShares is not met, causing the whole tx to revert.
        // This is DESIRED behavior for safety and retryability.
        uint256 shares = IApollosVault(vault).depositFor(
            amount, receiver, minShares
        );
            
        emit CrossChainDepositReceived(
            messageId, sourceChainSelector, receiver, asset, amount, shares
        );
        emit ZapExecuted(messageId, vault, shares);
    }

    function _getLocalAsset(address sourceAsset) internal view returns (address) {
        if (assetMapping[sourceAsset] != address(0)) {
            return assetMapping[sourceAsset];
        }
        return sourceAsset;
    }
    
    function _getVaultForAsset(address asset) internal view returns (address) {
        if (assetToVault[asset] != address(0)) {
            return assetToVault[asset];
        }
        return apollosFactory.getVault(asset, quoteAsset);
    }

    // ============ Admin Functions ============
    // ... (Keep existing admin functions) ...

    function setAuthorizedSource(
        uint64 sourceChainSelector,
        address senderAddress,
        bool enabled
    ) external override onlyOwner {
        if (senderAddress == address(0)) revert ZeroAddress();
        authorizedSources[sourceChainSelector][senderAddress] = enabled;
        emit SourceChainConfigured(sourceChainSelector, senderAddress, enabled);
    }

    function setAssetMapping(address sourceAsset, address localAsset) external override onlyOwner {
        if (sourceAsset == address(0) || localAsset == address(0)) revert ZeroAddress();
        assetMapping[sourceAsset] = localAsset;
    }

    function setAssetVault(address asset, address vault) external override onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        assetToVault[asset] = vault;
    }

    function setSwapPool(address pool) external override onlyOwner {
        swapPool = IMockUniswapPool(pool);
    }

    function setSwapConfig(address targetBaseAsset, PoolKey memory poolKey) external onlyOwner {
        if (targetBaseAsset == address(0)) revert ZeroAddress();
        swapPoolKeys[targetBaseAsset] = poolKey;
        hasSwapConfig[targetBaseAsset] = true;
    }

    function setQuoteAsset(address _quoteAsset) external onlyOwner {
        quoteAsset = _quoteAsset;
    }

    function setReserveAsset(address _reserveAsset) external onlyOwner {
        reserveAsset = _reserveAsset;
    }
    
    // Legacy support for interface
    function setMockQuoteAsset(address _mockQuoteAsset) external onlyOwner {
        reserveAsset = _mockQuoteAsset;
    }

    function rescueTokens(address token, uint256 amount) external override onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }

    // ============ View Functions ============

    function isAuthorizedSource(uint64 chainSelector, address sender) external view override returns (bool) {
        return authorizedSources[chainSelector][sender];
    }

    function getLocalAsset(address sourceAsset) external view override returns (address) {
        return _getLocalAsset(sourceAsset);
    }
    
    // Helper to check if a zap is actionable
    function isZapPending(bytes32 messageId) external view returns (bool) {
        return pendingDeposits[messageId].amount > 0 && !pendingDeposits[messageId].executed;
    }
}
