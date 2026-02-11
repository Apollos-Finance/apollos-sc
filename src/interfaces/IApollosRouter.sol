// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IApollosRouter
 * @notice Interface for ApollosRouter - User-facing entry point for Apollos Finance
 * @dev Routes user operations to appropriate vaults:
 *      - Deposit: Routes to correct vault based on asset
 *      - Withdraw: Handles withdrawal from any vault
 *      - Cross-chain: Integrates with CCIP for multi-chain deposits
 */
interface IApollosRouter {
    // ============ Structs ============
    
    /// @notice Parameters for deposit operation
    struct DepositParams {
        address asset;          // Asset to deposit (WETH, WBTC, etc.)
        uint256 amount;         // Amount to deposit
        uint256 minShares;      // Minimum shares to receive (slippage)
        address receiver;       // Address to receive shares
    }

    /// @notice Parameters for withdraw operation
    struct WithdrawParams {
        address vault;          // Vault to withdraw from
        uint256 shares;         // Shares to burn
        uint256 minAmount;      // Minimum asset to receive
        address receiver;       // Address to receive assets
    }

    /// @notice Parameters for cross-chain deposit
    struct CrossChainDepositParams {
        uint64 destinationChainSelector;  // CCIP chain selector
        address destinationRouter;        // CCIPReceiver on destination chain
        address asset;                    // Asset to send via CCIP (e.g., USDC)
        uint256 amount;                   // Amount to deposit
        uint256 minShares;                // Minimum shares
        address receiver;                 // Receiver on destination chain
        address targetBaseAsset;          // Target vault base asset on dest chain (WETH/WBTC/LINK)
    }

    // ============ Events ============
    
    event Deposit(
        address indexed user,
        address indexed vault,
        address indexed asset,
        uint256 amount,
        uint256 sharesReceived
    );
    
    event Withdraw(
        address indexed user,
        address indexed vault,
        uint256 sharesBurned,
        uint256 amountReceived
    );
    
    event CrossChainDepositInitiated(
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        address indexed user,
        address asset,
        uint256 amount
    );
    
    event CrossChainDepositReceived(
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        address indexed receiver,
        uint256 amount,
        uint256 sharesReceived
    );

    // ============ Errors ============
    
    error ZeroAmount();
    error ZeroAddress();
    error VaultNotFound();
    error InsufficientBalance();
    error SlippageExceeded();
    error UnsupportedAsset();
    error InvalidChainSelector();
    error InsufficientFee();
    error NotAuthorized();

    // ============ Deposit Functions ============

    /**
     * @notice Deposit asset into appropriate vault
     * @param params Deposit parameters
     * @return vault Address of vault deposited to
     * @return shares Amount of shares received
     */
    function deposit(DepositParams calldata params) 
        external 
        returns (address vault, uint256 shares);

    /**
     * @notice Deposit ETH into WETH vault
     * @param minShares Minimum shares to receive
     * @return vault Vault address
     * @return shares Shares received
     */
    function depositETH(uint256 minShares) 
        external 
        payable 
        returns (address vault, uint256 shares);


    // ============ Withdraw Functions ============

    /**
     * @notice Withdraw from vault
     * @param params Withdraw parameters
     * @return amount Amount of assets received
     */
    function withdraw(WithdrawParams calldata params) 
        external 
        returns (uint256 amount);

    /**
     * @notice Withdraw from vault and receive ETH (for WETH vault)
     * @param vault Vault address
     * @param shares Shares to burn
     * @param minAmount Minimum ETH to receive
     * @return amount ETH received
     */
    function withdrawETH(
        address vault,
        uint256 shares,
        uint256 minAmount
    ) external returns (uint256 amount);

    // ============ Cross-Chain Functions (CCIP) ============

    /**
     * @notice Initiate cross-chain deposit
     * @param params Cross-chain deposit parameters
     * @return messageId CCIP message ID
     */
    function depositCrossChain(CrossChainDepositParams calldata params) 
        external 
        payable 
        returns (bytes32 messageId);

    /**
     * @notice Get fee for cross-chain deposit
     * @param destinationChainSelector Target chain selector
     * @param asset Asset to deposit
     * @param amount Amount to deposit
     * @return fee Required CCIP fee in native token
     */
    function getCrossChainFee(
        uint64 destinationChainSelector,
        address asset,
        uint256 amount
    ) external view returns (uint256 fee);

    // ============ View Functions ============

    /**
     * @notice Get vault for an asset
     * @param asset Asset address
     * @return vault Vault address (address(0) if not found)
     */
    function getVaultForAsset(address asset) external view returns (address vault);

    /**
     * @notice Get all supported assets
     * @return assets Array of supported asset addresses
     */
    function getSupportedAssets() external view returns (address[] memory assets);

    /**
     * @notice Preview deposit - get expected shares
     * @param asset Asset to deposit
     * @param amount Amount to deposit
     * @return vault Vault that would be used
     * @return shares Expected shares
     */
    function previewDeposit(address asset, uint256 amount) 
        external 
        view 
        returns (address vault, uint256 shares);

    /**
     * @notice Preview withdraw - get expected amount
     * @param vault Vault address
     * @param shares Shares to burn
     * @return amount Expected asset amount
     */
    function previewWithdraw(address vault, uint256 shares) 
        external 
        view 
        returns (uint256 amount);

    /**
     * @notice Get factory address
     */
    function factory() external view returns (address);

    /**
     * @notice Get WETH address
     */
    function weth() external view returns (address);

    /**
     * @notice Get CCIP Router address
     */
    function ccipRouter() external view returns (address);

    // ============ Admin Functions ============

    /**
     * @notice Set mapping from asset to vault
     * @param asset Asset address
     * @param vault Vault address
     */
    function setAssetVault(address asset, address vault) external;

    /**
     * @notice Set supported chain selector
     * @param chainSelector CCIP chain selector
     * @param supported True to support, false to remove
     */
    function setSupportedChain(uint64 chainSelector, bool supported) external;
}
