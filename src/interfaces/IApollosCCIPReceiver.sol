// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IApollosCCIPReceiver
 * @notice Interface for receiving and processing cross-chain deposits via Chainlink CCIP.
 * @author Apollos Team
 * @dev This interface defines the behavior for the destination chain (Arbitrum) receiver.
 *      It supports the "Store-and-Execute" pattern to handle heavy DeFi logic outside the
 *      strict gas limits of CCIP message delivery.
 */
interface IApollosCCIPReceiver {
    /**
     * @notice Emitted when a cross-chain deposit is successfully zapped into a vault.
     * @param messageId The unique identifier of the CCIP message.
     * @param sourceChainSelector The selector of the chain the message originated from.
     * @param receiver The beneficiary address on the destination chain.
     * @param asset The address of the asset deposited into the vault.
     * @param amount The amount of the asset deposited.
     * @param sharesReceived The number of vault shares (afTokens) minted to the receiver.
     */
    event CrossChainDepositReceived(
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        address indexed receiver,
        address asset,
        uint256 amount,
        uint256 sharesReceived
    );

    /**
     * @notice Emitted when a cross-chain deposit fails during the zap process.
     * @param messageId The unique identifier of the CCIP message.
     * @param sourceChainSelector The selector of the source chain.
     * @param receiver The intended beneficiary address.
     * @param asset The address of the asset that failed to deposit.
     * @param amount The amount of the asset.
     * @param reason The reason for the failure.
     */
    event CrossChainDepositFailed(
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        address receiver,
        address asset,
        uint256 amount,
        string reason
    );

    /**
     * @notice Emitted when a source chain/sender authorization status is updated.
     * @param chainSelector The CCIP chain selector.
     * @param senderAddress The address of the authorized sender on the source chain.
     * @param enabled True if the source is authorized, false otherwise.
     */
    event SourceChainConfigured(uint64 indexed chainSelector, address indexed senderAddress, bool enabled);

    /**
     * @notice Emitted when an internal swap is executed during the Auto-Zap process.
     * @param fromToken The address of the token being swapped from.
     * @param toToken The address of the token being swapped to.
     * @param amountIn The amount of fromToken sold.
     * @param amountOut The amount of toToken received.
     */
    event SwapExecuted(address indexed fromToken, address indexed toToken, uint256 amountIn, uint256 amountOut);

    /// @notice Thrown when receiving a message from an unauthorized chain.
    error InvalidSourceChain();

    /// @notice Thrown when receiving a message from an unauthorized sender.
    error InvalidSender();

    /// @notice Thrown when the provided asset is not supported.
    error InvalidAsset();

    /// @notice Thrown when the vault deposit fails.
    error DepositFailed();

    /// @notice Thrown when the internal token swap fails.
    error SwapFailed();

    /// @notice Thrown when a zero address is provided where a valid address is required.
    error ZeroAddress();

    /**
     * @notice Configures authorized source chains and senders for CCIP messages.
     * @param sourceChainSelector The CCIP chain selector of the source chain.
     * @param senderAddress The address of the ApollosRouter on the source chain.
     * @param enabled True to authorize, false to revoke authorization.
     */
    function setAuthorizedSource(uint64 sourceChainSelector, address senderAddress, bool enabled) external;

    /**
     * @notice Maps a source chain asset address to its local equivalent.
     * @dev Used to handle token address differences across various chains.
     * @param sourceAsset The address of the token on the source chain.
     * @param localAsset The address of the equivalent token on the destination chain.
     */
    function setAssetMapping(address sourceAsset, address localAsset) external;

    /**
     * @notice Manually sets a direct mapping between a local asset and its corresponding Apollos vault.
     * @param asset The local token address.
     * @param vault The address of the ApollosVault.
     */
    function setAssetVault(address asset, address vault) external;

    /**
     * @notice Configures the MockUniswapPool address used for Auto-Zap swaps.
     * @param pool The address of the MockUniswapPool contract.
     */
    function setSwapPool(address pool) external;

    /**
     * @notice Emergency function to rescue tokens stuck in the contract.
     * @param token The address of the token to rescue.
     * @param amount The amount of tokens to transfer to the owner.
     */
    function rescueTokens(address token, uint256 amount) external;

    /**
     * @notice Checks if a specific source chain and sender are authorized.
     * @param chainSelector The source CCIP chain selector.
     * @param sender The sender address on the source chain.
     * @return authorized True if the source is authorized.
     */
    function isAuthorizedSource(uint64 chainSelector, address sender) external view returns (bool authorized);

    /**
     * @notice Resolves the local address for a given source chain asset.
     * @param sourceAsset The asset address on the source chain.
     * @return localAsset The corresponding local asset address.
     */
    function getLocalAsset(address sourceAsset) external view returns (address localAsset);
}
