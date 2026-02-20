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

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/**
 * @title ApollosCCIPReceiver
 * @notice Destination chain receiver for Apollos cross-chain deposits.
 * @author Apollos Finance Team
 * @dev Implements the Store-and-Execute pattern to handle complex DeFi operations triggered via Chainlink CCIP.
 *      The contract stores the incoming deposit intent and allows a secondary transaction to execute the heavy
 *      logic (swapping and vault depositing) to bypass CCIP gas limits.
 */
contract ApollosCCIPReceiver is IApollosCCIPReceiver, CCIPReceiver, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    /**
     * @notice Data structure for a stored cross-chain deposit intent.
     * @param messageId The unique identifier from Chainlink CCIP.
     * @param sourceChainSelector The CCIP selector of the originating chain.
     * @param sourceSender The address of the ApollosRouter on the source chain.
     * @param receiver The final beneficiary of the vault shares.
     * @param amount The quantity of the bridged asset (e.g., CCIP-BnM).
     * @param sourceAsset The address of the asset on the source chain.
     * @param targetBaseAsset The desired base asset for the vault on this chain.
     * @param minShares Minimum acceptable shares (Stored for reference, usually overridden in execution).
     * @param executed True if the zap has been successfully completed.
     */
    struct PendingDeposit {
        bytes32 messageId;
        uint64 sourceChainSelector;
        address sourceSender;
        address receiver;
        uint256 amount;
        address sourceAsset;
        address targetBaseAsset;
        uint256 minShares;
        bool executed;
    }

    /// @notice The factory contract used to resolve vault addresses.
    IApollosFactory public immutable apollosFactory;

    /// @notice The stable asset used as the pairing token in most liquidity pools (e.g., USDC).
    address public quoteAsset;

    /// @notice The local stable asset used to fund the Auto-Zap "Reserve Swap" mechanism.
    address public reserveAsset;

    /// @notice The MockUniswapPool used for performing Auto-Zap swaps.
    IMockUniswapPool public swapPool;

    /// @notice Maps source chain selector to sender address to authorization status.
    mapping(uint64 => mapping(address => bool)) public authorizedSources;

    /// @notice Maps source chain asset addresses to their local equivalents on this chain.
    mapping(address => address) public assetMapping;

    /// @notice Maps a base asset address directly to an ApollosVault address (Cache).
    mapping(address => address) public assetToVault;

    /// @notice Maps a target base asset to the PoolKey required to swap into it.
    mapping(address => PoolKey) public swapPoolKeys;

    /// @notice Indicates if a swap configuration exists for a given target base asset.
    mapping(address => bool) public hasSwapConfig;

    /// @notice Access point for all stored pending deposits by their message ID.
    mapping(bytes32 => PendingDeposit) public pendingDeposits;

    /**
     * @notice Emitted when a CCIP message is received and its intent is stored.
     */
    event DepositStored(
        bytes32 indexed messageId, uint64 indexed sourceChainSelector, address indexed receiver, uint256 amount
    );

    /**
     * @notice Emitted when a stored zap is successfully executed.
     */
    event ZapExecuted(bytes32 indexed messageId, address indexed vault, uint256 shares);

    /**
     * @notice Emitted when a zap execution fails (captured within try/catch blocks).
     */
    event ZapFailed(bytes32 indexed messageId, string reason);

    /**
     * @notice Emitted when the contract's reserve balance is too low to facilitate a swap.
     */
    event ReserveInsufficient(uint256 required, uint256 available);

    /**
     * @notice Initializes the ApollosCCIPReceiver.
     * @param _ccipRouter The address of the official Chainlink CCIP Router on this chain.
     * @param _factory The address of the ApollosFactory.
     * @param _quoteAsset The address of the system's quote asset (USDC).
     * @param _reserveAsset The address of the local asset used for reserve swaps.
     * @param _swapPool The address of the MockUniswapPool.
     */
    constructor(address _ccipRouter, address _factory, address _quoteAsset, address _reserveAsset, address _swapPool)
        CCIPReceiver(_ccipRouter)
        Ownable(msg.sender)
    {
        if (_factory == address(0)) revert ZeroAddress();

        apollosFactory = IApollosFactory(_factory);
        quoteAsset = _quoteAsset;
        reserveAsset = _reserveAsset;
        if (_swapPool != address(0)) {
            swapPool = IMockUniswapPool(_swapPool);
        }
    }

    /**
     * @notice Internal handler called by the CCIP Router when a message is delivered.
     * @dev Validates the source and stores the deposit parameters. Heavy logic is deferred.
     * @param message The incoming CCIP message structure.
     */
    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        // Validate source
        address sourceSender = abi.decode(message.sender, (address));
        if (!authorizedSources[message.sourceChainSelector][sourceSender]) {
            revert InvalidSender();
        }

        // Decode deposit data
        (
            address sourceAsset,
            uint256 amount,
            uint256 minShares,
            address receiver,, // originalSender (unused in store)
            address targetBaseAsset
        ) = abi.decode(message.data, (address, uint256, uint256, address, address, address));

        // Store Pending Deposit
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

    /**
     * @notice Executes a previously stored cross-chain deposit intent.
     * @dev Swaps the local USDC reserve into the target asset and deposits into the vault.
     * @param messageId The unique identifier of the stored deposit.
     * @param minShares Fresh slippage protection (overrides the stored minShares).
     */
    function executeZap(bytes32 messageId, uint256 minShares) external nonReentrant {
        PendingDeposit storage deposit = pendingDeposits[messageId];

        if (deposit.amount == 0) revert("Deposit not found");
        if (deposit.executed) revert("Already executed");

        // If anything below fails/reverts, this change will also revert (Native Retry Mechanism).
        deposit.executed = true;

        // Determine local asset
        address localReceivedAsset = _getLocalAsset(deposit.sourceAsset);

        // Reserve Swap Logic: 1 CCIP-BnM (18 dec) = 10 USDC (6 dec)
        address swapFromAsset = localReceivedAsset;
        uint256 swapFromAmount = deposit.amount;

        // Check if we need to use Reserve USDC
        if (localReceivedAsset != reserveAsset && reserveAsset != address(0)) {
            uint256 rawAmount = deposit.amount * 10;
            uint256 requiredUsdc = rawAmount / 1e12; // Adjust decimals 18 -> 6

            uint256 reserveBalance = IERC20(reserveAsset).balanceOf(address(this));
            if (reserveBalance < requiredUsdc) {
                revert("Insufficient Reserve USDC");
            }

            swapFromAsset = reserveAsset;
            swapFromAmount = requiredUsdc;
        }

        // Auto-Zap: Swap USDC -> Target Base Asset
        address depositAsset = swapFromAsset;
        uint256 depositAmount = swapFromAmount;

        if (swapFromAsset != deposit.targetBaseAsset) {
            (depositAsset, depositAmount) = _autoZap(swapFromAsset, deposit.targetBaseAsset, swapFromAmount);
            require(depositAsset != address(0), "Swap failed");
        }

        // Deposit to Vault
        _depositToVault(
            depositAsset,
            depositAmount,
            deposit.receiver,
            minShares, // Use FRESH minShares from parameter
            messageId,
            deposit.sourceChainSelector
        );
    }

    /**
     * @dev Internal helper to perform a token swap via the MockUniswapPool.
     */
    function _autoZap(address fromToken, address toToken, uint256 amountIn)
        internal
        returns (address swappedAsset, uint256 swappedAmount)
    {
        if (address(swapPool) == address(0) || !hasSwapConfig[toToken]) {
            return (address(0), 0);
        }

        PoolKey memory poolKey = swapPoolKeys[toToken];
        bool zeroForOne = (Currency.unwrap(poolKey.currency0) == fromToken);

        IERC20(fromToken).safeIncreaseAllowance(address(swapPool), amountIn);

        try swapPool.swap(poolKey, zeroForOne, -int256(amountIn), 0) returns (uint256, uint256 amountOut) {
            swappedAsset = toToken;
            swappedAmount = amountOut;
            emit SwapExecuted(fromToken, toToken, amountIn, amountOut);
        } catch {
            return (address(0), 0);
        }
    }

    /**
     * @dev Internal helper to deposit assets into the resolved ApollosVault.
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
        require(vault != address(0), "Vault not found");

        IERC20(asset).safeIncreaseAllowance(vault, amount);

        // This call will REVERT if minShares is not met, causing the whole tx to revert.
        uint256 shares = IApollosVault(vault).depositFor(amount, receiver, minShares);

        emit CrossChainDepositReceived(messageId, sourceChainSelector, receiver, asset, amount, shares);
        emit ZapExecuted(messageId, vault, shares);
    }

    /**
     * @dev Internal helper to resolve source asset to local asset address.
     */
    function _getLocalAsset(address sourceAsset) internal view returns (address) {
        if (assetMapping[sourceAsset] != address(0)) {
            return assetMapping[sourceAsset];
        }
        return sourceAsset;
    }

    /**
     * @dev Internal helper to resolve base asset to its corresponding vault.
     */
    function _getVaultForAsset(address asset) internal view returns (address) {
        if (assetToVault[asset] != address(0)) {
            return assetToVault[asset];
        }
        return apollosFactory.getVault(asset, quoteAsset);
    }

    /**
     * @notice Authorizes a source chain and sender for incoming messages.
     */
    function setAuthorizedSource(uint64 sourceChainSelector, address senderAddress, bool enabled)
        external
        override
        onlyOwner
    {
        if (senderAddress == address(0)) revert ZeroAddress();
        authorizedSources[sourceChainSelector][senderAddress] = enabled;
        emit SourceChainConfigured(sourceChainSelector, senderAddress, enabled);
    }

    /**
     * @notice Maps a source chain asset address to its local equivalent.
     */
    function setAssetMapping(address sourceAsset, address localAsset) external override onlyOwner {
        if (sourceAsset == address(0) || localAsset == address(0)) revert ZeroAddress();
        assetMapping[sourceAsset] = localAsset;
    }

    /**
     * @notice Directly maps an asset to a specific vault address.
     */
    function setAssetVault(address asset, address vault) external override onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        assetToVault[asset] = vault;
    }

    /**
     * @notice Updates the swap pool address.
     */
    function setSwapPool(address pool) external override onlyOwner {
        swapPool = IMockUniswapPool(pool);
    }

    /**
     * @notice Configures the PoolKey required to swap quote asset into target base asset.
     */
    function setSwapConfig(address targetBaseAsset, PoolKey memory poolKey) external onlyOwner {
        if (targetBaseAsset == address(0)) revert ZeroAddress();
        swapPoolKeys[targetBaseAsset] = poolKey;
        hasSwapConfig[targetBaseAsset] = true;
    }

    /**
     * @notice Updates the global quote asset address.
     */
    function setQuoteAsset(address _quoteAsset) external onlyOwner {
        quoteAsset = _quoteAsset;
    }

    /**
     * @notice Updates the reserve asset used for Auto-Zaps.
     */
    function setReserveAsset(address _reserveAsset) external onlyOwner {
        reserveAsset = _reserveAsset;
    }

    /**
     * @notice Legacy alias for setReserveAsset.
     */
    function setMockQuoteAsset(address _mockQuoteAsset) external onlyOwner {
        reserveAsset = _mockQuoteAsset;
    }

    /**
     * @notice Emergency rescue function for tokens stuck in the contract.
     */
    function rescueTokens(address token, uint256 amount) external override onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }

    /**
     * @notice Checks if a source is authorized.
     */
    function isAuthorizedSource(uint64 chainSelector, address sender) external view override returns (bool) {
        return authorizedSources[chainSelector][sender];
    }

    /**
     * @notice Resolves local asset from source asset.
     */
    function getLocalAsset(address sourceAsset) external view override returns (address) {
        return _getLocalAsset(sourceAsset);
    }

    /**
     * @notice Checks if a zap execution is pending for a specific message ID.
     */
    function isZapPending(bytes32 messageId) external view returns (bool) {
        return pendingDeposits[messageId].amount > 0 && !pendingDeposits[messageId].executed;
    }
}
