// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/**
 * @title IApollosVault
 * @notice Core interface for the Apollos Leveraged Yield Vault.
 * @author Apollos Team
 * @dev This vault implements a 2x leveraged yield strategy using Aave for borrowing and Uniswap V4 for yield generation.
 *      The vault adheres to the ERC4626 standard while providing additional functionality for leverage management
 *      and off-chain NAV (Net Asset Value) updates via Chainlink Workflows.
 */
interface IApollosVault {
    /**
     * @notice Configuration parameters for the vault's leverage strategy.
     * @param baseAsset The underlying asset (e.g., WETH) deposited by users.
     * @param quoteAsset The borrowed asset (e.g., USDC) used to create leverage.
     * @param targetLeverage The ideal leverage ratio desired by the protocol (multiplied by 1e18).
     * @param maxLeverage The safety limit for leverage before emergency deleveraging (multiplied by 1e18).
     * @param rebalanceThreshold The health factor threshold that triggers an automated rebalance.
     */
    struct VaultConfig {
        address baseAsset;
        address quoteAsset;
        uint256 targetLeverage;
        uint256 maxLeverage;
        uint256 rebalanceThreshold;
    }

    /**
     * @notice A comprehensive snapshot of the vault's internal state.
     * @param totalBaseAssets Cumulative amount of base assets held or managed.
     * @param totalBorrowed Total debt outstanding in the Aave protocol.
     * @param lpTokenValue Current market value of the vault's Uniswap V4 liquidity positions.
     * @param totalShares Total supply of afTokens (vault shares).
     * @param healthFactor Current Aave health factor (multiplied by 1e18).
     * @param currentLeverage Calculated effective leverage ratio.
     */
    struct VaultState {
        uint256 totalBaseAssets;
        uint256 totalBorrowed;
        uint256 lpTokenValue;
        uint256 totalShares;
        uint256 healthFactor;
        uint256 currentLeverage;
    }

    /**
     * @notice Emitted when a user successfully deposits assets and receives shares.
     */
    event Deposit(address indexed user, uint256 baseAmount, uint256 sharesReceived, uint256 borrowedAmount);

    /**
     * @notice Emitted when a user burns shares to withdraw their portion of the portfolio.
     */
    event Withdraw(address indexed user, uint256 sharesBurned, uint256 baseAmountReceived, uint256 debtRepaid);

    /**
     * @notice Emitted when the vault undergoes an automated rebalance to restore its target leverage.
     */
    event Rebalance(uint256 oldLeverage, uint256 newLeverage, uint256 debtRepaid, uint256 timestamp);

    /**
     * @notice Emitted when a user performs an emergency withdrawal.
     */
    event EmergencyWithdraw(address indexed user, uint256 sharesBurned, uint256 amountReceived);

    /**
     * @notice Emitted when trading fees are harvested and protocol fees are collected.
     */
    event HarvestFees(uint256 tradingFees, uint256 protocolFee, uint256 timestamp);

    /**
     * @notice Emitted when borrow circuit breaker status changes.
     */
    event BorrowPauseUpdated(bool oldPaused, bool newPaused, address indexed updatedBy);

    /// @notice Thrown when a zero amount is provided for a financial operation.
    error ZeroAmount();

    /// @notice Thrown when a zero address is provided for a mandatory parameter.
    error ZeroAddress();

    /// @notice Thrown when a user attempts to burn more shares than they own.
    error InsufficientShares();

    /// @notice Thrown when the vault lacks sufficient liquidity to fulfill an operation.
    error InsufficientBalance();

    /// @notice Thrown when a vault action would result in a health factor below the safety limit.
    error HealthFactorTooLow();

    /// @notice Thrown when an operation would exceed the protocol's maximum allowed leverage.
    error ExceedsMaxLeverage();

    /// @notice Thrown when an unauthorized account attempts to call a restricted function.
    error NotAuthorized();

    /// @notice Thrown when an operation is attempted while the vault is paused.
    error VaultPaused();

    /// @notice Thrown when borrowing is paused by the circuit breaker.
    error BorrowPaused();

    /// @notice Thrown when the received value is below the user's defined tolerance.
    error SlippageExceeded();

    /// @notice Thrown when a rebalance is triggered but the current state does not warrant one.
    error RebalanceNotNeeded();

    /// @notice Thrown when the vault's idle cash is insufficient for immediate operations.
    error InsufficientIdleLiquidity();

    /// @notice Thrown when the NAV feed from the off-chain workflow is older than the allowed tolerance.
    error StaleNAVFeed();

    /// @notice Thrown when the vault's total liabilities exceed its total assets.
    error InsolventVault();

    /// @notice Thrown when the oracle configuration is incomplete or invalid.
    error InvalidOracleConfig();

    /**
     * @notice Standard ERC4626 deposit function.
     * @dev Accepts base asset deposits and issues vault shares.
     * @param assets Amount of base asset to transfer.
     * @param receiver Recipient of the afTokens.
     * @return shares Quantity of shares minted.
     */
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /**
     * @notice Extended deposit function used by the CCIP Receiver.
     * @param amount Quantity of base asset.
     * @param receiver Recipient of the shares.
     * @param minShares Minimum acceptable shares (slippage check).
     * @return shares Final shares minted.
     */
    function depositFor(uint256 amount, address receiver, uint256 minShares) external returns (uint256 shares);

    /**
     * @notice Standard ERC4626 withdraw function.
     * @dev Redeems shares for the underlying base asset.
     * @param shares Number of afTokens to burn.
     * @param minAmount Minimum acceptable base assets to receive.
     * @return amount Final quantity of base assets returned.
     */
    function withdraw(uint256 shares, uint256 minAmount) external returns (uint256 amount);

    /**
     * @notice Readjusts the vault's debt and LP positions to reach the target leverage.
     * @dev Typically called by a Chainlink Keeper or authorized rebalancer.
     * @return newLeverage The leverage ratio achieved after the operation.
     */
    function rebalance() external returns (uint256 newLeverage);

    /**
     * @notice Allows users to exit their positions during extreme protocol emergencies.
     * @dev Skips normal rebalancing and deleveraging logic to prioritize capital preservation.
     */
    function emergencyWithdraw(uint256 shares) external returns (uint256 amount);

    /**
     * @notice Returns the current leverage configuration of the vault.
     */
    function getVaultConfig() external view returns (VaultConfig memory);

    /**
     * @notice Returns a detailed snapshot of the vault's current financial health and positioning.
     */
    function getVaultState() external view returns (VaultState memory);

    /**
     * @notice Simulates a deposit to determine the shares that would be issued.
     */
    function previewDeposit(uint256 amount) external view returns (uint256 shares);

    /**
     * @notice Simulates a withdrawal to determine the assets that would be returned.
     */
    function previewWithdraw(uint256 shares) external view returns (uint256 amount);

    /**
     * @notice Returns the current valuation of a single afToken in terms of the base asset.
     * @dev Multiplied by 1e18 for high precision.
     */
    function getSharePrice() external view returns (uint256 price);

    /**
     * @notice Returns the current health factor of the vault's debt in Aave.
     * @dev Values below 1e18 indicate potential liquidation risk.
     */
    function getHealthFactor() external view returns (uint256 healthFactor);

    /**
     * @notice Returns the effective current leverage of the managed portfolio.
     */
    function getCurrentLeverage() external view returns (uint256 leverage);

    /**
     * @notice Determines if the vault's current state deviates far enough from the target to require a rebalance.
     */
    function needsRebalance() external view returns (bool needed);

    /**
     * @notice Returns the total valuation of the vault's managed assets in base asset terms.
     * @dev This is a "Hybrid" calculation: Idle Balance + (On-chain Math OR Off-chain NAV Feed).
     */
    function totalAssets() external view returns (uint256);

    /**
     * @notice Returns the share balance of a specific user.
     */
    function balanceOf(address user) external view returns (uint256);

    /**
     * @notice Returns the total quantity of afTokens currently in circulation.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @notice Updates the strategy configuration parameters.
     */
    function updateConfig(uint256 targetLeverage, uint256 maxLeverage, uint256 rebalanceThreshold) external;

    /**
     * @notice Updates the Net Asset Value (NAV) using data computed off-chain.
     * @dev This is the primary method for valuation in production mode.
     *      It prevents heavy on-chain calculations and oracle dependencies during every transaction.
     * @param newTotalAssets The valuation of the active (deployed) portion of the portfolio.
     */
    function updateNAV(uint256 newTotalAssets) external;

    /**
     * @notice Enables or disables vault operations.
     */
    function setPaused(bool paused) external;

    /**
     * @notice Enables or disables borrowing while keeping deleverage/repay paths active.
     */
    function setBorrowPaused(bool paused) external;

    /**
     * @notice Grants or revokes rebalancing authority to a specific address.
     */
    function setRebalancer(address rebalancer, bool authorized) external;

    /**
     * @notice Grants or revokes general keeper authority.
     */
    function setKeeper(address keeper, bool authorized) external;

    /**
     * @notice Configures the off-chain data source for automated NAV updates.
     * @param cache The address of the DataFeedsCache contract.
     * @param dataId The unique identifier for the specific NAV feed.
     * @param maxAge The maximum allowed time (in seconds) since the last update.
     */
    function setDataFeedConfig(address cache, bytes32 dataId, uint256 maxAge) external;

    /**
     * @notice Updates the globally allowed stale tolerance for oracle price data.
     */
    function setMaxOracleAge(uint256 maxAge) external;

    /**
     * @notice Configures the percentage of assets kept as idle cash to facilitate fast withdrawals.
     * @param bps Buffer in basis points (e.g., 500 = 5%).
     */
    function setIdleBufferBps(uint256 bps) external;
}
