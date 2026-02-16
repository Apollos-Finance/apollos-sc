// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

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

/// @notice Minimal interface for MockToken.mintTo()
interface IMintableToken {
    function mintTo(address to, uint256 amount) external;
}

/**
 * @title ApollosCCIPReceiver
 * @notice Receives cross-chain deposits via Chainlink CCIP with Auto-Zapping
 * @dev Deployed on Arbitrum (destination chain) to:
 *      1. Receive CCIP messages from source chain ApollosRouters
 *      2. Receive real USDC via CCIP → Mint MockUSDC 1:1
 *      3. Auto-Zap: Swap MockUSDC → target base asset (MockWETH/MockWBTC/MockLINK)
 *      4. Deposit into appropriate Apollos vault
 *      5. Credit vault shares to the original receiver
 *
 * Bridge Logic:
 *      Real USDC arrives via CCIP → mint MockUSDC 1:1 → swap in existing mock pools
 *      Real USDC stays in contract as "backing reserve"
 *
 * Data encoding (must match ApollosRouter):
 *      abi.encode(sourceAsset, amount, minShares, receiver, originalSender, targetBaseAsset)
 */
contract ApollosCCIPReceiver is IApollosCCIPReceiver, CCIPReceiver, Ownable {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    // ============ Immutables ============
    
    /// @notice Apollos Factory for vault lookups
    IApollosFactory public immutable apollosFactory;

    // ============ State Variables ============
    
    /// @notice Quote asset used in mock pools (MockUSDC)
    address public quoteAsset;
    
    /// @notice MockUSDC token for 1:1 minting (bridge from real USDC)
    /// @dev Real USDC from CCIP → mint MockUSDC 1:1 → swap in mock pools
    address public mockQuoteAsset;
    
    /// @notice MockUniswapPool for auto-zapping swaps
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

    // ============ Constructor ============
    
    constructor(
        address _ccipRouter,
        address _factory,
        address _quoteAsset,
        address _mockQuoteAsset,
        address _swapPool
    ) CCIPReceiver(_ccipRouter) Ownable(msg.sender) {
        if (_factory == address(0)) revert ZeroAddress();
        
        apollosFactory = IApollosFactory(_factory);
        quoteAsset = _quoteAsset;
        mockQuoteAsset = _mockQuoteAsset;
        if (_swapPool != address(0)) {
            swapPool = IMockUniswapPool(_swapPool);
        }
    }

    // ============ CCIP Receive (Override) ============

    /**
     * @notice Internal handler for incoming CCIP messages
     * @dev Called by CCIPReceiver.ccipReceive() after router validation
     *
     * Flow:
     *   1. Validate source chain + sender
     *   2. Decode deposit data (6 fields)
     *   3. Determine received token amount
     *   4. If received token != targetBaseAsset → Auto-Zap (swap via MockUniswapPool)
     *   5. Deposit base asset to vault on behalf of receiver
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
        
        // 2. Decode deposit data (must match ApollosRouter encoding)
        (
            address sourceAsset,
            uint256 amount,
            uint256 minShares,
            address receiver,
            address originalSender,
            address targetBaseAsset
        ) = abi.decode(message.data, (address, uint256, uint256, address, address, address));
        
        // 3. Determine received token and amount
        address localReceivedAsset = _getLocalAsset(sourceAsset);
        if (localReceivedAsset == address(0)) revert InvalidAsset();
        
        uint256 receivedAmount = _getReceivedAmount(message, localReceivedAsset, amount);
        if (receivedAmount == 0) {
            emit CrossChainDepositFailed(
                message.messageId,
                message.sourceChainSelector,
                receiver,
                localReceivedAsset,
                amount,
                "No tokens received"
            );
            return;
        }
        
        // 4. Bridge: Mint MockUSDC from CCIP-BnM with 10x conversion
        //    CCIP-BnM stays in this contract as "backing reserve"
        //    MockUSDC is used for swaps in mock ecosystem at 10:1 ratio
        address swapFromAsset = localReceivedAsset;
        uint256 swapFromAmount = receivedAmount;
        
        if (mockQuoteAsset != address(0) && localReceivedAsset != mockQuoteAsset) {
            // CCIP-BnM received (18 decimals) → mint MockUSDC (6 decimals)
            // Logic: 1 CCIP-BnM = 10 USDC equivalent
            
            // Langkah 1: Hitung angka dasar (1 CCIP-BnM * 10)
            // Hasil: 10e18
            uint256 rawAmount = receivedAmount * 10;

            // Langkah 2: Sesuaikan Decimals (18 -> 6)
            // Kita bagi dengan 1e12 (12 nol) untuk membuang kelebihan desimal
            uint256 mockUsdcAmount = rawAmount / 1e12; 

            // SAFETY CHECK: Pastikan tidak 0 (kalo user kirim debu/dust amount)
            if (mockUsdcAmount == 0) {
                 emit CrossChainDepositFailed(
                    message.messageId, 
                    message.sourceChainSelector, 
                    receiver, 
                    localReceivedAsset, 
                    receivedAmount, 
                    "Amount too small for USDC conversion"
                );
                return;
            }

            IMintableToken(mockQuoteAsset).mintTo(address(this), mockUsdcAmount);
            swapFromAsset = mockQuoteAsset;
            swapFromAmount = mockUsdcAmount;
        }
        
        // 5. Auto-Zap: Swap MockUSDC → target base asset (MockWETH/etc)
        address depositAsset = swapFromAsset;
        uint256 depositAmount = swapFromAmount;
        
        if (swapFromAsset != targetBaseAsset) {
            (depositAsset, depositAmount) = _autoZap(
                swapFromAsset,     // MockUSDC (not real USDC)
                targetBaseAsset,   // MockWETH/MockWBTC/MockLINK
                swapFromAmount,
                message.messageId,
                message.sourceChainSelector,
                receiver
            );
            
            if (depositAsset == address(0)) return;
        }
        
        // 5. Deposit to vault
        _depositToVault(
            depositAsset,
            depositAmount,
            receiver,
            minShares,
            message.messageId,
            message.sourceChainSelector
        );
    }

    // ============ Internal: Auto-Zap ============

    /**
     * @notice Swap received token to target base asset via MockUniswapPool
     * @return swappedAsset The token received from swap
     * @return swappedAmount The amount received from swap
     */
    function _autoZap(
        address fromToken,
        address toToken,
        uint256 amountIn,
        bytes32 messageId,
        uint64 sourceChainSelector,
        address receiver
    ) internal returns (address swappedAsset, uint256 swappedAmount) {
        // Validate swap pool is configured
        if (address(swapPool) == address(0)) {
            emit CrossChainDepositFailed(
                messageId, sourceChainSelector, receiver, fromToken, amountIn,
                "Swap pool not configured"
            );
            return (address(0), 0);
        }
        
        // Get PoolKey for this target asset
        if (!hasSwapConfig[toToken]) {
            emit CrossChainDepositFailed(
                messageId, sourceChainSelector, receiver, fromToken, amountIn,
                "No swap config for target asset"
            );
            return (address(0), 0);
        }
        
        PoolKey memory poolKey = swapPoolKeys[toToken];
        
        // Determine swap direction
        // If fromToken is currency0, zeroForOne = true (sell currency0, buy currency1)
        // If fromToken is currency1, zeroForOne = false (sell currency1, buy currency0)
        bool zeroForOne = (Currency.unwrap(poolKey.currency0) == fromToken);
        
        // Approve swap pool to spend tokens
        IERC20(fromToken).safeIncreaseAllowance(address(swapPool), amountIn);
        
        // Execute swap (negative amountSpecified = exactIn in V4 convention)
        try swapPool.swap(
            poolKey,
            zeroForOne,
            -int256(amountIn),
            0 // no price limit
        ) returns (uint256 /* actualIn */, uint256 amountOut) {
            swappedAsset = toToken;
            swappedAmount = amountOut;
            
            emit SwapExecuted(fromToken, toToken, amountIn, amountOut);
        } catch Error(string memory reason) {
            emit CrossChainDepositFailed(
                messageId, sourceChainSelector, receiver, fromToken, amountIn,
                string.concat("Swap failed: ", reason)
            );
            return (address(0), 0);
        } catch {
            emit CrossChainDepositFailed(
                messageId, sourceChainSelector, receiver, fromToken, amountIn,
                "Swap failed: unknown error"
            );
            return (address(0), 0);
        }
    }

    // ============ Internal: Deposit ============

    /**
     * @notice Deposit asset to vault on behalf of receiver
     */
    function _depositToVault(
        address asset,
        uint256 amount,
        address receiver,
        uint256 minShares,
        bytes32 messageId,
        uint64 sourceChainSelector
    ) internal {
        address vault = _getVaultForAsset(asset);
        if (vault == address(0)) {
            emit CrossChainDepositFailed(
                messageId, sourceChainSelector, receiver, asset, amount,
                "Vault not found for asset"
            );
            return;
        }
        
        // Approve vault to spend tokens
        IERC20(asset).safeIncreaseAllowance(vault, amount);
        
        // Deposit to vault
        try IApollosVault(vault).depositFor(
            amount, receiver, minShares
        ) returns (uint256 shares) {
            emit CrossChainDepositReceived(
                messageId, sourceChainSelector, receiver, asset, amount, shares
            );
        } catch Error(string memory reason) {
            emit CrossChainDepositFailed(
                messageId, sourceChainSelector, receiver, asset, amount, reason
            );
        }
    }

    // ============ Internal: Helpers ============

    /**
     * @notice Get amount of tokens received from CCIP transfer
     */
    function _getReceivedAmount(
        Client.Any2EVMMessage memory message,
        address localAsset,
        uint256 expectedAmount
    ) internal view returns (uint256 receivedAmount) {
        // Check CCIP token amounts first
        for (uint256 i = 0; i < message.destTokenAmounts.length; i++) {
            if (message.destTokenAmounts[i].token == localAsset) {
                return message.destTokenAmounts[i].amount;
            }
        }
        
        // Fallback: check contract balance (for testing/mock)
        uint256 balance = IERC20(localAsset).balanceOf(address(this));
        if (balance >= expectedAmount) {
            return expectedAmount;
        }
        
        return 0;
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

    function setAuthorizedSource(
        uint64 sourceChainSelector,
        address senderAddress,
        bool enabled
    ) external override onlyOwner {
        if (senderAddress == address(0)) revert ZeroAddress();
        authorizedSources[sourceChainSelector][senderAddress] = enabled;
        emit SourceChainConfigured(sourceChainSelector, senderAddress, enabled);
    }

    function setAssetMapping(
        address sourceAsset, 
        address localAsset
    ) external override onlyOwner {
        if (sourceAsset == address(0) || localAsset == address(0)) revert ZeroAddress();
        assetMapping[sourceAsset] = localAsset;
    }

    function setAssetVault(address asset, address vault) external override onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        assetToVault[asset] = vault;
    }

    /**
     * @notice Set MockUniswapPool for auto-zapping
     */
    function setSwapPool(address pool) external override onlyOwner {
        swapPool = IMockUniswapPool(pool);
    }

    /**
     * @notice Configure swap route for a target base asset
     * @dev Admin sets the PoolKey so CCIPReceiver knows how to swap USDC → baseAsset
     * @param targetBaseAsset The base asset (WETH/WBTC/LINK)
     * @param poolKey The PoolKey for the USDC/baseAsset pool on MockUniswapPool
     */
    function setSwapConfig(
        address targetBaseAsset,
        PoolKey memory poolKey
    ) external onlyOwner {
        if (targetBaseAsset == address(0)) revert ZeroAddress();
        swapPoolKeys[targetBaseAsset] = poolKey;
        hasSwapConfig[targetBaseAsset] = true;
    }

    function setQuoteAsset(address _quoteAsset) external onlyOwner {
        if (_quoteAsset == address(0)) revert ZeroAddress();
        quoteAsset = _quoteAsset;
    }

    /**
     * @notice Set MockUSDC address for 1:1 bridge minting
     * @dev Real USDC from CCIP → mint this MockUSDC 1:1 → swap in mock pools
     */
    function setMockQuoteAsset(address _mockQuoteAsset) external onlyOwner {
        mockQuoteAsset = _mockQuoteAsset;
    }

    function rescueTokens(address token, uint256 amount) external override onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }

    // ============ View Functions ============

    function isAuthorizedSource(
        uint64 chainSelector,
        address sender
    ) external view override returns (bool) {
        return authorizedSources[chainSelector][sender];
    }

    function getLocalAsset(address sourceAsset) external view override returns (address) {
        return _getLocalAsset(sourceAsset);
    }
}
