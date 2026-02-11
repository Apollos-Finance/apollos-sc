// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IApollosCCIPReceiver
 * @notice Interface for receiving cross-chain deposits via Chainlink CCIP
 * @dev Deployed on destination chain (Arbitrum) to process incoming CCIP messages.
 *      Supports Auto-Zapping: swap received USDC → target base asset → deposit to vault.
 * 
 * Data encoding format (must match ApollosRouter):
 *   abi.encode(sourceAsset, amount, minShares, receiver, originalSender, targetBaseAsset)
 *   Types: (address, uint256, uint256, address, address, address)
 */
interface IApollosCCIPReceiver {
    // ============ Events ============
    
    event CrossChainDepositReceived(
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        address indexed receiver,
        address asset,
        uint256 amount,
        uint256 sharesReceived
    );

    event CrossChainDepositFailed(
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        address receiver,
        address asset,
        uint256 amount,
        string reason
    );

    event SourceChainConfigured(
        uint64 indexed chainSelector,
        address indexed senderAddress,
        bool enabled
    );

    event SwapExecuted(
        address indexed fromToken,
        address indexed toToken,
        uint256 amountIn,
        uint256 amountOut
    );

    // ============ Errors ============
    

    error InvalidSourceChain();
    error InvalidSender();
    error InvalidAsset();
    error DepositFailed();
    error SwapFailed();
    error ZeroAddress();

    // ============ Admin Functions ============

    /**
     * @notice Configure authorized source chain and sender
     * @param sourceChainSelector CCIP chain selector
     * @param senderAddress Authorized sender (ApollosRouter) on source chain
     * @param enabled Enable/disable this source
     */
    function setAuthorizedSource(
        uint64 sourceChainSelector,
        address senderAddress,
        bool enabled
    ) external;

    /**
     * @notice Set asset mapping for cross-chain tokens
     * @param sourceAsset Asset address on source chain
     * @param localAsset Equivalent asset on this chain
     */
    function setAssetMapping(address sourceAsset, address localAsset) external;

    /**
     * @notice Set direct asset to vault mapping
     * @param asset Local asset address
     * @param vault Vault address
     */
    function setAssetVault(address asset, address vault) external;

    /**
     * @notice Set MockUniswapPool address for auto-zapping swaps
     * @param pool MockUniswapPool address on this chain
     */
    function setSwapPool(address pool) external;

    /**
     * @notice Rescue stuck tokens (emergency)
     * @param token Token address
     * @param amount Amount to rescue
     */
    function rescueTokens(address token, uint256 amount) external;

    // ============ View Functions ============

    function isAuthorizedSource(
        uint64 chainSelector,
        address sender
    ) external view returns (bool authorized);

    function getLocalAsset(address sourceAsset) external view returns (address localAsset);


}
