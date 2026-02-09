// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/**
 * @title IApollosFactory
 * @notice Interface for ApollosFactory - Vault creation and registry
 * @dev Factory pattern for deploying new ApollosVault instances:
 *      - Creates vaults for different asset pairs (WETH/USDC, WBTC/USDC, etc.)
 *      - Maintains registry of all valid vaults
 *      - Configures initial vault parameters
 */
interface IApollosFactory {
    // ============ Structs ============
    
    /// @notice Parameters for creating a new vault
    struct VaultParams {
        string name;                // e.g., "Apollos WETH Vault"
        string symbol;              // e.g., "afWETH"
        address baseAsset;          // e.g., WETH
        address quoteAsset;         // e.g., USDC
        PoolKey poolKey;            // Uniswap V4 pool key
        uint256 targetLeverage;     // e.g., 2e18 = 2x
        uint256 maxLeverage;        // e.g., 2.5e18 = 2.5x
    }

    /// @notice Vault info in registry
    struct VaultInfo {
        address vault;              // Vault contract address
        address baseAsset;          // Base asset address
        address quoteAsset;         // Quote asset address
        string symbol;              // Vault share symbol
        bool isActive;              // Whether vault is active
        uint256 createdAt;          // Creation timestamp
    }

    // ============ Events ============
    
    event VaultCreated(
        address indexed vault,
        address indexed baseAsset,
        address indexed quoteAsset,
        string name,
        string symbol,
        address creator
    );
    
    event VaultDeactivated(address indexed vault);
    event VaultReactivated(address indexed vault);
    event ProtocolFeeUpdated(uint256 oldFee, uint256 newFee);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    // ============ Errors ============
    
    error VaultAlreadyExists();
    error VaultNotFound();
    error InvalidAsset();
    error InvalidParameters();
    error ZeroAddress();
    error Unauthorized();

    // ============ Core Functions ============

    /**
     * @notice Create a new vault for an asset pair
     * @param params Vault creation parameters
     * @return vault Address of the newly created vault
     */
    function createVault(VaultParams calldata params) external returns (address vault);

    /**
     * @notice Deactivate a vault (pause operations)
     * @param vault Vault address to deactivate
     */
    function deactivateVault(address vault) external;

    /**
     * @notice Reactivate a vault
     * @param vault Vault address to reactivate
     */
    function reactivateVault(address vault) external;

    // ============ View Functions ============

    /**
     * @notice Get vault by base and quote asset
     * @param baseAsset Base asset address
     * @param quoteAsset Quote asset address
     * @return vault Vault address (address(0) if not exists)
     */
    function getVault(address baseAsset, address quoteAsset) external view returns (address vault);

    /**
     * @notice Get all registered vaults
     * @return vaults Array of vault addresses
     */
    function getAllVaults() external view returns (address[] memory vaults);

    /**
     * @notice Get vault info
     * @param vault Vault address
     * @return info Vault information
     */
    function getVaultInfo(address vault) external view returns (VaultInfo memory info);

    /**
     * @notice Check if vault is registered
     * @param vault Vault address
     * @return registered True if vault is in registry
     */
    function isVaultRegistered(address vault) external view returns (bool registered);

    /**
     * @notice Get number of registered vaults
     */
    function vaultCount() external view returns (uint256);

    /**
     * @notice Get protocol fee (in basis points)
     */
    function protocolFee() external view returns (uint256);

    /**
     * @notice Get treasury address
     */
    function treasury() external view returns (address);

    /**
     * @notice Get Aave pool address used by vaults
     */
    function aavePool() external view returns (address);

    /**
     * @notice Get Uniswap pool address used by vaults
     */
    function uniswapPool() external view returns (address);

    /**
     * @notice Get LVR Hook address
     */
    function lvrHook() external view returns (address);

    // ============ Admin Functions ============

    /**
     * @notice Set protocol fee
     * @param newFee New fee in basis points (e.g., 100 = 1%)
     */
    function setProtocolFee(uint256 newFee) external;

    /**
     * @notice Set treasury address
     * @param newTreasury New treasury address
     */
    function setTreasury(address newTreasury) external;
}
