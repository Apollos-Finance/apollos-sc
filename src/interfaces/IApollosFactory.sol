// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/**
 * @title IApollosFactory
 * @notice Interface for the Apollos Vault Factory and Registry.
 * @author Apollos Team
 * @dev This interface defines the management functions for deploying and registering Apollos vaults.
 */
interface IApollosFactory {
    /**
     * @notice Parameters required to initialize a new Apollos vault.
     * @param name The descriptive name of the vault (e.g., "Apollos WETH Vault").
     * @param symbol The ticker symbol for vault shares (e.g., "afWETH").
     * @param baseAsset The underlying asset deposited by users.
     * @param quoteAsset The stable asset borrowed against the base asset.
     * @param poolKey The configuration key for the corresponding Uniswap V4 pool.
     * @param targetLeverage The desired leverage ratio (multiplied by 1e18).
     * @param maxLeverage The maximum allowed leverage before emergency deleveraging (multiplied by 1e18).
     */
    struct VaultParams {
        string name;
        string symbol;
        address baseAsset;
        address quoteAsset;
        PoolKey poolKey;
        uint256 targetLeverage;
        uint256 maxLeverage;
    }

    /**
     * @notice Data structure containing high-level information about a registered vault.
     * @param vault The deployed vault contract address.
     * @param baseAsset The address of the vault's base asset.
     * @param quoteAsset The address of the vault's quote asset.
     * @param symbol The vault share ticker symbol.
     * @param isActive True if the vault is currently active and accepting deposits.
     * @param createdAt The timestamp of the vault's creation.
     */
    struct VaultInfo {
        address vault;
        address baseAsset;
        address quoteAsset;
        string symbol;
        bool isActive;
        uint256 createdAt;
    }

    

    /**
     * @notice Emitted when a new ApollosVault is deployed and registered.
     */
    event VaultCreated(
        address indexed vault,
        address indexed baseAsset,
        address indexed quoteAsset,
        string name,
        string symbol,
        address creator
    );

    /**
     * @notice Emitted when a vault is deactivated.
     */
    event VaultDeactivated(address indexed vault);
    
    /**
     * @notice Emitted when a previously deactivated vault is reactivated.
     */
    event VaultReactivated(address indexed vault);
    
    /**
     * @notice Emitted when the global protocol fee is updated.
     */
    event ProtocolFeeUpdated(uint256 oldFee, uint256 newFee);
    
    /**
     * @notice Emitted when the protocol treasury address is updated.
     */
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    

    /// @notice Thrown when attempting to create a vault for a pair that already exists.
    error VaultAlreadyExists();
    
    /// @notice Thrown when looking up a vault address that is not in the registry.
    error VaultNotFound();
    
    /// @notice Thrown when an invalid asset address is provided.
    error InvalidAsset();
    
    /// @notice Thrown when provided vault parameters are inconsistent or out of bounds.
    error InvalidParameters();
    
    /// @notice Thrown when a zero address is provided.
    error ZeroAddress();
    
    /// @notice Thrown when an unauthorized user attempts to call a restricted function.
    error Unauthorized();

    

    /**
     * @notice Deploys a new ApollosVault instance and registers it in the system.
     * @param params Initial configuration parameters for the vault.
     * @return vault The address of the newly deployed vault contract.
     */
    function createVault(VaultParams calldata params) external returns (address vault);

    /**
     * @notice Deactivates a vault, typically disabling new deposits while allowing withdrawals.
     * @param vault The address of the vault to deactivate.
     */
    function deactivateVault(address vault) external;

    /**
     * @notice Reactivates a previously deactivated vault.
     * @param vault The address of the vault to reactivate.
     */
    function reactivateVault(address vault) external;

    

    /**
     * @notice Returns the vault address for a specific asset pair.
     * @param baseAsset The address of the base asset.
     * @param quoteAsset The address of the quote asset.
     * @return vault The address of the corresponding ApollosVault.
     */
    function getVault(address baseAsset, address quoteAsset) external view returns (address vault);

    /**
     * @notice Returns a list of all deployed vault addresses.
     * @return vaults Array of registered vault addresses.
     */
    function getAllVaults() external view returns (address[] memory vaults);

    /**
     * @notice Retrieves detailed information about a specific vault.
     * @param vault The address of the vault to query.
     * @return info The VaultInfo structure for the specified vault.
     */
    function getVaultInfo(address vault) external view returns (VaultInfo memory info);

    /**
     * @notice Checks if a given vault address is part of the official Apollos registry.
     * @param vault The address to check.
     * @return registered True if the vault is officially registered.
     */
    function isVaultRegistered(address vault) external view returns (bool registered);

    /**
     * @notice Returns the total number of registered vaults.
     */
    function vaultCount() external view returns (uint256);

    /**
     * @notice Returns the current protocol-level management fee in basis points.
     */
    function protocolFee() external view returns (uint256);

    /**
     * @notice Returns the current address of the protocol treasury.
     */
    function treasury() external view returns (address);

    /**
     * @notice Returns the address of the Aave pool shared by all vaults.
     */
    function aavePool() external view returns (address);

    /**
     * @notice Returns the address of the Uniswap V4 pool manager shared by all vaults.
     */
    function uniswapPool() external view returns (address);

    /**
     * @notice Returns the address of the LVR Hook shared by all vaults.
     */
    function lvrHook() external view returns (address);

    

    /**
     * @notice Updates the protocol-level fee.
     * @param newFee The new fee in basis points (e.g., 100 = 1%).
     */
    function setProtocolFee(uint256 newFee) external;

    /**
     * @notice Updates the treasury address for fee collection.
     * @param newTreasury The address of the new treasury.
     */
    function setTreasury(address newTreasury) external;
}
