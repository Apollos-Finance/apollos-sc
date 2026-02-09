// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/**
 * @title IApollosVault
 * @notice Interface for ApollosVault - The heart of Apollos Finance
 * @dev Core vault that implements 2x leverage strategy:
 *      1. User deposits WETH → Vault supplies to Aave as collateral
 *      2. Vault borrows USDC from Aave (Credit Delegation)
 *      3. Vault provides WETH+USDC liquidity to Uniswap V4 Pool
 *      4. User receives afTOKEN shares representing their position
 */
interface IApollosVault {
    // ============ Structs ============
    
    /// @notice Vault configuration
    struct VaultConfig {
        address baseAsset;          // e.g., WETH
        address quoteAsset;         // e.g., USDC
        uint256 targetLeverage;     // e.g., 2e18 = 2x leverage
        uint256 maxLeverage;        // e.g., 2.5e18 = 2.5x max
        uint256 rebalanceThreshold; // e.g., 1.1e18 = rebalance if HF < 1.1
    }

    /// @notice Vault state snapshot
    struct VaultState {
        uint256 totalBaseAssets;    // Total WETH in vault
        uint256 totalBorrowed;      // Total USDC borrowed from Aave
        uint256 lpTokenValue;       // Value of LP position in Uniswap
        uint256 totalShares;        // Total afTOKEN supply
        uint256 healthFactor;       // Current health factor
        uint256 currentLeverage;    // Current leverage ratio
    }

    // ============ Events ============
    
    event Deposit(
        address indexed user,
        uint256 baseAmount,
        uint256 sharesReceived,
        uint256 borrowedAmount
    );
    
    event Withdraw(
        address indexed user,
        uint256 sharesBurned,
        uint256 baseAmountReceived,
        uint256 debtRepaid
    );
    
    event Rebalance(
        uint256 oldLeverage,
        uint256 newLeverage,
        uint256 debtRepaid,
        uint256 timestamp
    );
    
    event EmergencyWithdraw(
        address indexed user,
        uint256 sharesBurned,
        uint256 amountReceived
    );
    
    event HarvestFees(
        uint256 tradingFees,
        uint256 protocolFee,
        uint256 timestamp
    );

    // ============ Errors ============
    
    error ZeroAmount();
    error ZeroAddress();
    error InsufficientShares();
    error InsufficientBalance();
    error HealthFactorTooLow();
    error ExceedsMaxLeverage();
    error NotAuthorized();
    error VaultPaused();
    error SlippageExceeded();
    error RebalanceNotNeeded();

    // ============ Core Functions ============

    /**
     * @notice Deposit base asset and receive vault shares
     * @param amount Amount of base asset to deposit
     * @param minShares Minimum shares to receive (slippage protection)
     * @return shares Amount of afTOKEN shares received
     */
    function deposit(uint256 amount, uint256 minShares) external returns (uint256 shares);

    /**
     * @notice Deposit base asset on behalf of another user
     * @param amount Amount of base asset to deposit
     * @param receiver Address to receive the shares
     * @param minShares Minimum shares to receive
     * @return shares Amount of shares received
     */
    function depositFor(
        uint256 amount,
        address receiver,
        uint256 minShares
    ) external returns (uint256 shares);

    /**
     * @notice Withdraw by burning shares
     * @param shares Amount of shares to burn
     * @param minAmount Minimum base asset to receive (slippage protection)
     * @return amount Amount of base asset received
     */
    function withdraw(uint256 shares, uint256 minAmount) external returns (uint256 amount);

    /**
     * @notice Rebalance vault to maintain target leverage
     * @dev Called by Chainlink Workflow when health factor is low
     * @return newLeverage The new leverage ratio after rebalancing
     */
    function rebalance() external returns (uint256 newLeverage);

    /**
     * @notice Emergency withdraw without going through normal flow
     * @dev Only available when vault is in emergency mode
     * @param shares Amount of shares to burn
     * @return amount Amount of base asset received
     */
    function emergencyWithdraw(uint256 shares) external returns (uint256 amount);

    // ============ View Functions ============

    /**
     * @notice Get vault configuration
     */
    function getVaultConfig() external view returns (VaultConfig memory);

    /**
     * @notice Get current vault state
     */
    function getVaultState() external view returns (VaultState memory);

    /**
     * @notice Calculate shares for deposit amount
     * @param amount Base asset amount to deposit
     * @return shares Expected shares to receive
     */
    function previewDeposit(uint256 amount) external view returns (uint256 shares);

    /**
     * @notice Calculate base asset for share amount
     * @param shares Shares to withdraw
     * @return amount Expected base asset to receive
     */
    function previewWithdraw(uint256 shares) external view returns (uint256 amount);

    /**
     * @notice Get share price in base asset terms
     * @return price Price of 1 share in base asset (18 decimals)
     */
    function getSharePrice() external view returns (uint256 price);

    /**
     * @notice Get current health factor
     * @return healthFactor Current health factor (1e18 = 1.0)
     */
    function getHealthFactor() external view returns (uint256 healthFactor);

    /**
     * @notice Get current leverage ratio
     * @return leverage Current leverage (1e18 = 1.0x)
     */
    function getCurrentLeverage() external view returns (uint256 leverage);

    /**
     * @notice Check if rebalance is needed
     * @return needed True if health factor is below threshold
     */
    function needsRebalance() external view returns (bool needed);

    /**
     * @notice Get total assets managed by vault (in base asset terms)
     */
    function totalAssets() external view returns (uint256);

    /**
     * @notice Get user's share balance
     */
    function balanceOf(address user) external view returns (uint256);

    /**
     * @notice Get total supply of shares
     */
    function totalSupply() external view returns (uint256);

    // ============ Admin Functions ============

    /**
     * @notice Update vault parameters
     * @param targetLeverage New target leverage
     * @param maxLeverage New max leverage
     * @param rebalanceThreshold New rebalance threshold
     */
    function updateConfig(
        uint256 targetLeverage,
        uint256 maxLeverage,
        uint256 rebalanceThreshold
    ) external;

    /**
     * @notice Pause/unpause vault
     * @param paused True to pause, false to unpause
     */
    function setPaused(bool paused) external;

    /**
     * @notice Set authorized rebalancer (Chainlink Workflow)
     * @param rebalancer Address of the rebalancer
     * @param authorized True to authorize, false to remove
     */
    function setRebalancer(address rebalancer, bool authorized) external;
}
