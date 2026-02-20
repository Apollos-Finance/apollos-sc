// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IApollosFactory} from "../interfaces/IApollosFactory.sol";
import {ApollosVault} from "./ApollosVault.sol";

/**
 * @title ApollosFactory
 * @notice Factory and Registry for creating and managing ApollosVault instances.
 * @author Apollos Team
 * @dev This contract acts as the central hub for the protocol, managing vault deployment,
 *      active vault registration, and global configuration parameters like protocol fees 
 *      and shared pool manager addresses.
 */
contract ApollosFactory is IApollosFactory, Ownable {
    /// @notice Protocol management fee in basis points (e.g., 100 = 1%).
    uint256 public override protocolFee;

    /// @notice The address where protocol fees are collected.
    address public override treasury;

    /// @notice The address of the Aave V3 Pool used by all vaults for borrowing.
    address public override aavePool;

    /// @notice The address of the Uniswap V4 Pool Manager used by all vaults for yield generation.
    address public override uniswapPool;

    /// @notice The address of the LVR Hook shared by all protocol vaults.
    address public override lvrHook;

    /// @dev Internal mapping to resolve vault addresses by asset pair: baseAsset => quoteAsset => vault.
    mapping(address => mapping(address => address)) private vaultsByPair;

    /// @dev Internal array to maintain a list of all deployed vault addresses.
    address[] private allVaults;

    /// @dev Internal mapping to store metadata for each deployed vault.
    mapping(address => VaultInfo) private vaultInfos;


    /**
     * @notice Initializes the ApollosFactory with shared infrastructure addresses.
     * @param _aavePool The address of the MockAavePool.
     * @param _uniswapPool The address of the MockUniswapPool.
     * @param _lvrHook The address of the LVRHook.
     * @param _treasury The address of the protocol treasury.
     */
    constructor(address _aavePool, address _uniswapPool, address _lvrHook, address _treasury) Ownable(msg.sender) {
        if (_aavePool == address(0)) revert ZeroAddress();
        if (_uniswapPool == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();

        aavePool = _aavePool;
        uniswapPool = _uniswapPool;
        lvrHook = _lvrHook;
        treasury = _treasury;
        protocolFee = 100; // 1% default
    }

    

    /**
     * @notice Deploys and registers a new ApollosVault for a specific asset pair.
     * @dev Restricted to the factory owner. Transfers vault ownership to the factory owner upon deployment.
     * @param params Parameters including vault name, symbol, assets, leverage, and pool key.
     * @return vault The address of the newly created vault contract.
     */
    function createVault(VaultParams calldata params) external override onlyOwner returns (address vault) {
        // Validate inputs
        if (params.baseAsset == address(0)) revert InvalidAsset();
        if (params.quoteAsset == address(0)) revert InvalidAsset();
        if (params.baseAsset == params.quoteAsset) revert InvalidAsset();

        // Check if vault already exists for this pair
        if (vaultsByPair[params.baseAsset][params.quoteAsset] != address(0)) {
            revert VaultAlreadyExists();
        }

        // Deploy new vault
        ApollosVault newVault = new ApollosVault(
            params.name,
            params.symbol,
            params.baseAsset,
            params.quoteAsset,
            aavePool,
            uniswapPool,
            params.poolKey,
            params.targetLeverage,
            params.maxLeverage
        );

        vault = address(newVault);

        // Transfer vault ownership to factory owner (so they can configure it)
        newVault.transferOwnership(owner());

        // Register vault
        vaultsByPair[params.baseAsset][params.quoteAsset] = vault;
        allVaults.push(vault);

        vaultInfos[vault] = VaultInfo({
            vault: vault,
            baseAsset: params.baseAsset,
            quoteAsset: params.quoteAsset,
            symbol: params.symbol,
            isActive: true,
            createdAt: block.timestamp
        });

        emit VaultCreated(vault, params.baseAsset, params.quoteAsset, params.name, params.symbol, msg.sender);
    }

    /**
     * @notice Deactivates an existing vault, typically to prevent new deposits.
     * @param vault The address of the vault to deactivate.
     */
    function deactivateVault(address vault) external override onlyOwner {
        if (!isVaultRegistered(vault)) revert VaultNotFound();
        vaultInfos[vault].isActive = false;
        emit VaultDeactivated(vault);
    }

    /**
     * @notice Reactivates a previously deactivated vault.
     * @param vault The address of the vault to reactivate.
     */
    function reactivateVault(address vault) external override onlyOwner {
        if (!isVaultRegistered(vault)) revert VaultNotFound();
        vaultInfos[vault].isActive = true;
        emit VaultReactivated(vault);
    }

    

    /**
     * @notice Returns the vault address for a specific asset pair.
     */
    function getVault(address baseAsset, address quoteAsset) external view override returns (address vault) {
        return vaultsByPair[baseAsset][quoteAsset];
    }

    /**
     * @notice Returns an array containing all registered vault addresses.
     */
    function getAllVaults() external view override returns (address[] memory) {
        return allVaults;
    }

    /**
     * @notice Returns metadata for a specific vault.
     */
    function getVaultInfo(address vault) external view override returns (VaultInfo memory) {
        return vaultInfos[vault];
    }

    /**
     * @notice Checks if a vault address is officially registered in this factory.
     */
    function isVaultRegistered(address vault) public view override returns (bool) {
        return vaultInfos[vault].vault != address(0);
    }

    /**
     * @notice Returns the total count of registered vaults.
     */
    function vaultCount() external view override returns (uint256) {
        return allVaults.length;
    }

    

    /**
     * @notice Updates the protocol fee.
     * @param newFee The new fee in basis points (Max 10%).
     */
    function setProtocolFee(uint256 newFee) external override onlyOwner {
        if (newFee > 1000) revert InvalidParameters(); // Max 10%

        uint256 oldFee = protocolFee;
        protocolFee = newFee;

        emit ProtocolFeeUpdated(oldFee, newFee);
    }

    /**
     * @notice Updates the global treasury address.
     */
    function setTreasury(address newTreasury) external override onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();

        address oldTreasury = treasury;
        treasury = newTreasury;

        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    /**
     * @notice Updates the shared Aave pool address for future vaults.
     */
    function setAavePool(address _aavePool) external onlyOwner {
        if (_aavePool == address(0)) revert ZeroAddress();
        aavePool = _aavePool;
    }

    /**
     * @notice Updates the shared Uniswap pool address for future vaults.
     */
    function setUniswapPool(address _uniswapPool) external onlyOwner {
        if (_uniswapPool == address(0)) revert ZeroAddress();
        uniswapPool = _uniswapPool;
    }

    /**
     * @notice Updates the shared LVR hook address.
     */
    function setLvrHook(address _lvrHook) external onlyOwner {
        lvrHook = _lvrHook;
    }

    /**
     * @notice Returns an array containing only the currently active vault addresses.
     */
    function getActiveVaults() external view returns (address[] memory) {
        uint256 activeCount = 0;

        // Count active vaults
        for (uint256 i = 0; i < allVaults.length; i++) {
            if (vaultInfos[allVaults[i]].isActive) {
                activeCount++;
            }
        }

        // Build array
        address[] memory activeVaults = new address[](activeCount);
        uint256 index = 0;

        for (uint256 i = 0; i < allVaults.length; i++) {
            if (vaultInfos[allVaults[i]].isActive) {
                activeVaults[index] = allVaults[i];
                index++;
            }
        }

        return activeVaults;
    }
}
