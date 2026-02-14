// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IMockAavePool
 * @notice Interface for MockAavePool - Simplified Aave V3 Pool for Apollos Finance
 * @dev Used by ApollosVault to implement 2x leverage strategy:
 *      1. User deposits WETH into Vault
 *      2. Vault supplies WETH as collateral to AavePool
 *      3. Vault borrows USDC against collateral (2x leverage)
 *      4. Vault provides liquidity to Uniswap with borrowed funds
 */
interface IMockAavePool {
    // ============ Structs ============
    
    /// @notice User account data for health factor calculation
    struct UserAccountData {
        uint256 totalCollateralBase;    // Total collateral in base currency (USD)
        uint256 totalDebtBase;          // Total debt in base currency (USD)
        uint256 availableBorrowsBase;   // Available borrows in base currency
        uint256 currentLiquidationThreshold; // Liquidation threshold (e.g., 8000 = 80%)
        uint256 ltv;                    // Loan-to-value ratio (e.g., 7500 = 75%)
        uint256 healthFactor;           // Health factor (1e18 = 1.0, < 1e18 = liquidatable)
    }

    /// @notice Reserve data for a specific asset
    struct ReserveData {
        address aTokenAddress;          // Address of aToken (receipt token)
        address variableDebtTokenAddress; // Address of variable debt token
        uint256 liquidityRate;          // Current supply APY (in ray, 1e27)
        uint256 variableBorrowRate;     // Current borrow APY (in ray, 1e27)
        uint256 liquidityIndex;         // Cumulative liquidity index
        uint256 variableBorrowIndex;    // Cumulative borrow index
    }

    // ============ Events ============
    
    event Supply(
        address indexed reserve,
        address indexed user,
        address indexed onBehalfOf,
        uint256 amount
    );
    
    event Withdraw(
        address indexed reserve,
        address indexed user,
        address indexed to,
        uint256 amount
    );
    
    event Borrow(
        address indexed reserve,
        address indexed user,
        address indexed onBehalfOf,
        uint256 amount,
        uint256 interestRateMode,
        uint256 borrowRate
    );
    
    event Repay(
        address indexed reserve,
        address indexed user,
        address indexed repayer,
        uint256 amount
    );
    
    event Liquidation(
        address indexed collateralAsset,
        address indexed debtAsset,
        address indexed user,
        uint256 debtToCover,
        uint256 liquidatedCollateralAmount,
        address liquidator
    );
    
    event ReserveConfigured(
        address indexed asset,
        uint256 ltv,
        uint256 liquidationThreshold,
        uint256 liquidationBonus
    );

    // ============ Errors ============
    
    error InvalidAmount();
    error ReserveNotActive();
    error InsufficientCollateral();
    error HealthFactorTooLow();
    error NothingToRepay();
    error NothingToWithdraw();
    error NotLiquidatable();
    error NotWhitelistedBorrower();
    error DelegationExceedsSuppliedBalance();
    error DelegationBelowOutstandingDebt();
    error ZeroAddress();

    // ============ Core Functions ============

    /**
     * @notice Supply assets to the pool as collateral
     * @param asset The address of the underlying asset to supply
     * @param amount The amount to supply
     * @param onBehalfOf The address that will receive the aTokens
     * @param referralCode Referral code (unused, for compatibility)
     */
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;

    /**
     * @notice Withdraw assets from the pool
     * @param asset The address of the underlying asset to withdraw
     * @param amount The amount to withdraw (use type(uint256).max for full balance)
     * @param to The address that will receive the underlying
     * @return The final amount withdrawn
     */
    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256);

    /**
     * @notice Borrow assets from the pool
     * @param asset The address of the underlying asset to borrow
     * @param amount The amount to borrow
     * @param interestRateMode The interest rate mode (1 = stable, 2 = variable)
     * @param referralCode Referral code (unused)
     * @param onBehalfOf The address that will receive the debt
     */
    function borrow(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        uint16 referralCode,
        address onBehalfOf
    ) external;

    /**
     * @notice Repay borrowed assets
     * @param asset The address of the borrowed asset
     * @param amount The amount to repay (use type(uint256).max for full debt)
     * @param interestRateMode The interest rate mode (1 = stable, 2 = variable)
     * @param onBehalfOf The address of the user who will get debt reduced
     * @return The final amount repaid
     */
    function repay(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        address onBehalfOf
    ) external returns (uint256);

    /**
     * @notice Liquidate an undercollateralized position
     * @param collateralAsset The address of the collateral asset to liquidate
     * @param debtAsset The address of the debt asset to repay
     * @param user The address of the borrower to liquidate
     * @param debtToCover The amount of debt to cover
     * @param receiveAToken True to receive aTokens, false to receive underlying
     */
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;

    // ============ View Functions ============

    /**
     * @notice Get user account data
     * @param user The address of the user
     * @return totalCollateralBase Total collateral in base currency
     * @return totalDebtBase Total debt in base currency
     * @return availableBorrowsBase Available borrows in base currency
     * @return currentLiquidationThreshold Liquidation threshold
     * @return ltv Loan-to-value ratio
     * @return healthFactor Health factor (< 1e18 = liquidatable)
     */
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );

    /**
     * @notice Get reserve data for an asset
     * @param asset The address of the reserve asset
     * @return The reserve data
     */
    function getReserveData(address asset) external view returns (ReserveData memory);

    /**
     * @notice Get the user's collateral balance for an asset
     * @param user The address of the user
     * @param asset The address of the collateral asset
     * @return The collateral balance
     */
    function getUserCollateral(address user, address asset) external view returns (uint256);

    /**
     * @notice Get the user's debt balance for an asset
     * @param user The address of the user
     * @param asset The address of the debt asset
     * @return The debt balance
     */
    function getUserDebt(address user, address asset) external view returns (uint256);

    // ============ Admin Functions ============

    /**
     * @notice Configure a reserve asset
     * @param asset The address of the asset
     * @param ltv Loan-to-value ratio (e.g., 7500 = 75%)
     * @param liquidationThreshold Liquidation threshold (e.g., 8000 = 80%)
     * @param liquidationBonus Liquidation bonus (e.g., 10500 = 5% bonus)
     */
    function configureReserve(
        address asset,
        uint256 ltv,
        uint256 liquidationThreshold,
        uint256 liquidationBonus
    ) external;

    /**
     * @notice Set the price oracle for an asset
     * @param asset The address of the asset
     * @param priceInUsd The price in USD with 8 decimals
     */
    function setAssetPrice(address asset, uint256 priceInUsd) external;

    /**
     * @notice Get the price of an asset
     * @param asset The address of the asset
     * @return priceInUsd The price in USD with 8 decimals
     */
    function assetPrices(address asset) external view returns (uint256 priceInUsd);

    // ============ Credit Delegation (For Apollos Vault) ============

    /**
     * @notice Whitelist a borrower for undercollateralized borrowing
     * @param borrower The address to whitelist
     * @param status True to whitelist, false to remove
     */
    function setWhitelistedBorrower(address borrower, bool status) external;

    /**
     * @notice Set credit limit for a whitelisted borrower
     * @param borrower The whitelisted borrower address
     * @param asset The asset they can borrow
     * @param limit Maximum amount they can borrow
     */
    function setCreditLimit(address borrower, address asset, uint256 limit) external;

    /**
     * @notice Set credit delegation allowance for a whitelisted borrower
     * @dev Delegation is capped by delegator's supplied balance for the same asset.
     *      Calling again with a different amount increases or decreases allowance.
     * @param borrower The whitelisted borrower (e.g. ApollosVault)
     * @param asset The delegated borrow asset
     * @param amount Total delegated allowance amount
     */
    function setCreditDelegation(address borrower, address asset, uint256 amount) external;

    /**
     * @notice Check if an address is a whitelisted borrower
     * @param borrower The address to check
     * @return True if whitelisted
     */
    function isWhitelistedBorrower(address borrower) external view returns (bool);

    /**
     * @notice Get credit limit for a borrower and asset
     * @param borrower The borrower address
     * @param asset The asset address
     * @return limit Credit limit amount
     */
    function getCreditLimit(address borrower, address asset) external view returns (uint256 limit);

    /**
     * @notice Get delegation amount from a specific delegator to borrower
     */
    function getCreditDelegation(
        address delegator,
        address borrower,
        address asset
    ) external view returns (uint256 delegatedAmount);

    /**
     * @notice Get total delegated credit to a borrower for an asset
     */
    function getTotalDelegatedToBorrower(
        address borrower,
        address asset
    ) external view returns (uint256 delegatedAmount);

    /**
     * @notice Get total delegated amount by a delegator for an asset
     */
    function getTotalDelegatedBy(
        address delegator,
        address asset
    ) external view returns (uint256 delegatedAmount);
}
