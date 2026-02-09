// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// V4 Core Types
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

// Interfaces
import {IApollosFactory} from "../interfaces/IApollosFactory.sol";
import {ApollosVault} from "./ApollosVault.sol";

/**
 * @title ApollosFactory
 * @notice Factory for creating and managing ApollosVault instances
 * @dev Registry of all vaults with protocol-level configuration:
 *      - Creates new vaults for different asset pairs
 *      - Maintains vault registry for discovery
 *      - Manages protocol fee and treasury
 */
contract ApollosFactory is IApollosFactory, Ownable {
    // ============ State Variables ============
    
    /// @notice Protocol fee in basis points (e.g., 100 = 1%)
    uint256 public override protocolFee;
    
    /// @notice Treasury address for protocol fees
    address public override treasury;
    
    /// @notice Aave Pool used by all vaults
    address public override aavePool;
    
    /// @notice Uniswap Pool used by all vaults
    address public override uniswapPool;
    
    /// @notice LVR Hook address
    address public override lvrHook;
    
    /// @notice Mapping: baseAsset => quoteAsset => vault
    mapping(address => mapping(address => address)) private vaultsByPair;
    
    /// @notice Array of all vault addresses
    address[] private allVaults;
    
    /// @notice Vault info by address
    mapping(address => VaultInfo) private vaultInfos;

    // ============ Constructor ============
    
    constructor(
        address _aavePool,
        address _uniswapPool,
        address _lvrHook,
        address _treasury
    ) Ownable(msg.sender) {
        if (_aavePool == address(0)) revert ZeroAddress();
        if (_uniswapPool == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();
        
        aavePool = _aavePool;
        uniswapPool = _uniswapPool;
        lvrHook = _lvrHook;
        treasury = _treasury;
        protocolFee = 100; // 1% default
    }

    // ============ Core Functions ============

    /**
     * @notice Create a new vault for an asset pair
     * @param params Vault creation parameters
     * @return vault Address of the newly created vault
     */
    function createVault(VaultParams calldata params) 
        external 
        override 
        onlyOwner 
        returns (address vault) 
    {
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
        
        emit VaultCreated(
            vault,
            params.baseAsset,
            params.quoteAsset,
            params.name,
            params.symbol,
            msg.sender
        );
    }

    /**
     * @notice Deactivate a vault
     */
    function deactivateVault(address vault) external override onlyOwner {
        if (!isVaultRegistered(vault)) revert VaultNotFound();
        vaultInfos[vault].isActive = false;
        emit VaultDeactivated(vault);
    }

    /**
     * @notice Reactivate a vault
     */
    function reactivateVault(address vault) external override onlyOwner {
        if (!isVaultRegistered(vault)) revert VaultNotFound();
        vaultInfos[vault].isActive = true;
        emit VaultReactivated(vault);
    }

    // ============ View Functions ============

    function getVault(address baseAsset, address quoteAsset) 
        external 
        view 
        override 
        returns (address vault) 
    {
        return vaultsByPair[baseAsset][quoteAsset];
    }

    function getAllVaults() external view override returns (address[] memory) {
        return allVaults;
    }

    function getVaultInfo(address vault) 
        external 
        view 
        override 
        returns (VaultInfo memory) 
    {
        return vaultInfos[vault];
    }

    function isVaultRegistered(address vault) public view override returns (bool) {
        return vaultInfos[vault].vault != address(0);
    }

    function vaultCount() external view override returns (uint256) {
        return allVaults.length;
    }

    // ============ Admin Functions ============

    function setProtocolFee(uint256 newFee) external override onlyOwner {
        if (newFee > 1000) revert InvalidParameters(); // Max 10%
        
        uint256 oldFee = protocolFee;
        protocolFee = newFee;
        
        emit ProtocolFeeUpdated(oldFee, newFee);
    }

    function setTreasury(address newTreasury) external override onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        
        address oldTreasury = treasury;
        treasury = newTreasury;
        
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    /**
     * @notice Update Aave pool address
     */
    function setAavePool(address _aavePool) external onlyOwner {
        if (_aavePool == address(0)) revert ZeroAddress();
        aavePool = _aavePool;
    }

    /**
     * @notice Update Uniswap pool address
     */
    function setUniswapPool(address _uniswapPool) external onlyOwner {
        if (_uniswapPool == address(0)) revert ZeroAddress();
        uniswapPool = _uniswapPool;
    }

    /**
     * @notice Update LVR Hook address
     */
    function setLvrHook(address _lvrHook) external onlyOwner {
        lvrHook = _lvrHook;
    }

    /**
     * @notice Get active vaults only
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
