// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IApollosRouter
 * @notice Interface for the user-facing entry point of Apollos.
 * @author Apollos Team
 * @dev This router simplifies user interactions by abstracting vault discovery,
 *      native token wrapping, and cross-chain messaging complexity.
 */
interface IApollosRouter {
    /**
     * @notice Parameters for a standard asset deposit.
     * @param asset The address of the token to deposit (e.g., WETH, WBTC).
     * @param amount The quantity of the asset to deposit.
     * @param minShares Minimum acceptable shares to receive (slippage protection).
     * @param receiver The address that will receive the vault shares.
     */
    struct DepositParams {
        address asset;
        uint256 amount;
        uint256 minShares;
        address receiver;
    }

    /**
     * @notice Parameters for a standard vault withdrawal.
     * @param vault The address of the ApollosVault to withdraw from.
     * @param shares The number of vault shares (afTokens) to burn.
     * @param minAmount Minimum acceptable quantity of base assets to receive.
     * @param receiver The address that will receive the base assets.
     */
    struct WithdrawParams {
        address vault;
        uint256 shares;
        uint256 minAmount;
        address receiver;
    }

    /**
     * @notice Parameters for initiating a cross-chain deposit via CCIP.
     * @param destinationChainSelector The CCIP selector for the target blockchain.
     * @param destinationRouter The address of the CCIPReceiver on the target chain.
     * @param asset The address of the asset to send from the source chain (e.g., USDC).
     * @param amount The quantity of the asset to bridge.
     * @param minShares Minimum acceptable shares to receive on the destination chain.
     * @param receiver The final beneficiary address on the destination chain.
     * @param targetBaseAsset The base asset of the target vault on the destination chain.
     */
    struct CrossChainDepositParams {
        uint64 destinationChainSelector;
        address destinationRouter;
        address asset;
        uint256 amount;
        uint256 minShares;
        address receiver;
        address targetBaseAsset;
    }

    

    /**
     * @notice Emitted when a local deposit operation is completed.
     */
    event Deposit(
        address indexed user, address indexed vault, address indexed asset, uint256 amount, uint256 sharesReceived
    );

    /**
     * @notice Emitted when a local withdrawal operation is completed.
     */
    event Withdraw(address indexed user, address indexed vault, uint256 sharesBurned, uint256 amountReceived);

    /**
     * @notice Emitted when a cross-chain deposit is successfully initiated.
     */
    event CrossChainDepositInitiated(
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        address indexed user,
        address asset,
        uint256 amount
    );

    /**
     * @notice Emitted when an incoming cross-chain deposit message is received.
     */
    event CrossChainDepositReceived(
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        address indexed receiver,
        uint256 amount,
        uint256 sharesReceived
    );

   

    /// @notice Thrown when a zero amount is provided for an operation.
    error ZeroAmount();
    
    /// @notice Thrown when a zero address is provided for a critical parameter.
    error ZeroAddress();
    
    /// @notice Thrown when a vault for the specified asset cannot be found.
    error VaultNotFound();
    
    /// @notice Thrown when the caller has an insufficient token balance.
    error InsufficientBalance();
    
    /// @notice Thrown when the shares or assets received are below the user's minimum tolerance.
    error SlippageExceeded();
    
    /// @notice Thrown when the asset address provided is not supported by the protocol.
    error UnsupportedAsset();
    
    /// @notice Thrown when an invalid CCIP chain selector is provided.
    error InvalidChainSelector();
    
    /// @notice Thrown when the provided native token amount is insufficient to cover bridging fees.
    error InsufficientFee();
    
    /// @notice Thrown when an unauthorized user attempts to perform a restricted admin action.
    error NotAuthorized();

    

    /**
     * @notice Deposits an ERC20 asset into its corresponding vault.
     * @param params Configuration for the deposit.
     * @return vault The address of the vault where the deposit was routed.
     * @return shares The quantity of afTokens issued to the receiver.
     */
    function deposit(DepositParams calldata params) external returns (address vault, uint256 shares);

    /**
     * @notice Deposits native ETH, wraps it into WETH, and routes it to the WETH vault.
     * @param minShares Minimum acceptable shares to receive.
     * @return vault The address of the WETH vault.
     * @return shares The quantity of afTokens issued to the caller.
     */
    function depositETH(uint256 minShares) external payable returns (address vault, uint256 shares);

    

    /**
     * @notice Withdraws assets from a specific vault by burning shares.
     * @param params Configuration for the withdrawal.
     * @return amount The quantity of base assets returned to the receiver.
     */
    function withdraw(WithdrawParams calldata params) external returns (uint256 amount);

    /**
     * @notice Withdraws from a WETH vault, unwraps the WETH, and returns native ETH.
     * @param vault The address of the WETH vault.
     * @param shares The number of shares to burn.
     * @param minAmount Minimum acceptable native ETH to receive.
     * @return amount The quantity of native ETH returned to the caller.
     */
    function withdrawETH(address vault, uint256 shares, uint256 minAmount) external returns (uint256 amount);

    

    /**
     * @notice Initiates a bridge and deposit operation across chains.
     * @param params Configuration for the cross-chain operation.
     * @return messageId The unique identifier generated by Chainlink CCIP.
     */
    function depositCrossChain(CrossChainDepositParams calldata params) external payable returns (bytes32 messageId);

    /**
     * @notice Estimates the native token fee required for a cross-chain deposit.
     * @param destinationChainSelector Target blockchain identifier.
     * @param asset Asset address to bridge.
     * @param amount Quantity of tokens to bridge.
     * @return fee Estimated fee in native currency (e.g., ETH).
     */
    function getCrossChainFee(uint64 destinationChainSelector, address asset, uint256 amount)
        external
        view
        returns (uint256 fee);

    

    /**
     * @notice Returns the ApollosVault address associated with a specific asset.
     */
    function getVaultForAsset(address asset) external view returns (address vault);

    /**
     * @notice Returns an array of all asset addresses currently supported for routing.
     */
    function getSupportedAssets() external view returns (address[] memory assets);

    /**
     * @notice Simulates a deposit to estimate the shares that would be received.
     */
    function previewDeposit(address asset, uint256 amount) external view returns (address vault, uint256 shares);

    /**
     * @notice Simulates a withdrawal to estimate the assets that would be returned.
     */
    function previewWithdraw(address vault, uint256 shares) external view returns (uint256 amount);

    /**
     * @notice Returns the address of the ApollosFactory.
     */
    function factory() external view returns (address);

    /**
     * @notice Returns the address of the WETH token.
     */
    function weth() external view returns (address);

    /**
     * @notice Returns the address of the local Chainlink CCIP Router.
     */
    function ccipRouter() external view returns (address);

    

    /**
     * @notice Updates the routing mapping for a specific asset.
     */
    function setAssetVault(address asset, address vault) external;

    /**
     * @notice Updates the support status for a specific target chain.
     */
    function setSupportedChain(uint64 chainSelector, bool supported) external;
}
