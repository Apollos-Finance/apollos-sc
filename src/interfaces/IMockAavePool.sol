// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IMockAavePool
 * @notice Interface for the Simulated Aave V3 Pool used by Apollos.
 * @author Apollos Team
 * @dev This mock provides a subset of Aave V3 functionality essential for the Apollos leverage strategy,
 *      including supply, borrow (with credit delegation), repay, and liquidation simulation.
 */
interface IMockAavePool {
    /**
     * @notice Comprehensive account data for health and risk monitoring.
     * @param totalCollateralBase Aggregate value of all supplied collateral in USD.
     * @param totalDebtBase Aggregate value of all outstanding debt in USD.
     * @param availableBorrowsBase Remaining borrowing capacity in USD.
     * @param currentLiquidationThreshold Weighted average liquidation threshold.
     * @param ltv Weighted average Loan-to-Value.
     * @param healthFactor Current health factor (multiplied by 1e18).
     */
    struct UserAccountData {
        uint256 totalCollateralBase;
        uint256 totalDebtBase;
        uint256 availableBorrowsBase;
        uint256 currentLiquidationThreshold;
        uint256 ltv;
        uint256 healthFactor;
    }

    /**
     * @notice Data structure representing the state of an individual asset reserve.
     * @param aTokenAddress Mock address of the interest-bearing receipt token.
     * @param variableDebtTokenAddress Mock address of the debt tracking token.
     * @param liquidityRate Annual percentage yield for suppliers.
     * @param variableBorrowRate Annual percentage rate for borrowers.
     * @param liquidityIndex Scaled index for liquidity accrual.
     * @param variableBorrowIndex Scaled index for borrow accrual.
     */
    struct ReserveData {
        address aTokenAddress;
        address variableDebtTokenAddress;
        uint256 liquidityRate;
        uint256 variableBorrowRate;
        uint256 liquidityIndex;
        uint256 variableBorrowIndex;
    }

    /**
     * @notice Emitted when assets are supplied to the pool.
     */
    event Supply(address indexed reserve, address indexed user, address indexed onBehalfOf, uint256 amount);

    /**
     * @notice Emitted when collateral is withdrawn from the pool.
     */
    event Withdraw(address indexed reserve, address indexed user, address indexed to, uint256 amount);

    /**
     * @notice Emitted when a borrow operation is successfully executed.
     */
    event Borrow(
        address indexed reserve,
        address indexed user,
        address indexed onBehalfOf,
        uint256 amount,
        uint256 interestRateMode,
        uint256 borrowRate
    );

    /**
     * @notice Emitted when debt is repaid.
     */
    event Repay(address indexed reserve, address indexed user, address indexed repayer, uint256 amount);

    /**
     * @notice Emitted when a user is liquidated.
     */
    event Liquidation(
        address indexed collateralAsset,
        address indexed debtAsset,
        address indexed user,
        uint256 debtToCover,
        uint256 liquidatedCollateralAmount,
        address liquidator
    );

    /**
     * @notice Emitted when a reserve's parameters are updated by the admin.
     */
    event ReserveConfigured(address indexed asset, uint256 ltv, uint256 liquidationThreshold, uint256 liquidationBonus);

    /// @notice Thrown when a zero or invalid amount is provided.
    error InvalidAmount();

    /// @notice Thrown when an operation is attempted on an inactive reserve.
    error ReserveNotActive();

    /// @notice Thrown when a borrow or withdraw action would breach collateral requirements.
    error InsufficientCollateral();

    /// @notice Thrown when an operation would drop the health factor below the safety threshold.
    error HealthFactorTooLow();

    /// @notice Thrown when trying to repay debt for a user with no active borrows.
    error NothingToRepay();

    /// @notice Thrown when trying to withdraw from an empty collateral balance.
    error NothingToWithdraw();

    /// @notice Thrown when attempting to liquidate a user with a healthy health factor.
    error NotLiquidatable();

    /// @notice Thrown when a non-whitelisted address tries to access credit delegation.
    error NotWhitelistedBorrower();

    /// @notice Thrown when a delegator tries to delegate more credit than they have supplied as collateral.
    error DelegationExceedsSuppliedBalance();

    /// @notice Thrown when a delegator tries to reduce delegation below the borrower's active debt.
    error DelegationBelowOutstandingDebt();

    /// @notice Thrown when a zero address is provided.
    error ZeroAddress();

    /**
     * @notice Supplies assets to be used as collateral.
     * @param asset The underlying token address.
     * @param amount The quantity to supply.
     * @param onBehalfOf The address that will own the collateral.
     */
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    /**
     * @notice Withdraws collateral assets from the pool.
     * @param asset The token address to withdraw.
     * @param amount The quantity to withdraw (use max uint256 for full balance).
     * @return The actual amount withdrawn.
     */
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    /**
     * @notice Borrows tokens from the pool using collateral or delegation.
     * @param asset The token address to borrow.
     * @param amount The quantity to borrow.
     * @param interestRateMode 1 for stable, 2 for variable.
     * @param onBehalfOf The address that will incur the debt.
     */
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;

    /**
     * @notice Repays an active borrow.
     * @param asset The borrowed token address.
     * @param amount The quantity to repay.
     * @param interestRateMode Must match the mode used for borrowing.
     * @return The final amount repaid.
     */
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external
        returns (uint256);

    /**
     * @notice Liquidates an undercollateralized user position.
     * @param collateralAsset The collateral to seize.
     * @param debtAsset The debt to repay.
     * @param user The address of the borrower being liquidated.
     * @param debtToCover The amount of debt the liquidator is paying off.
     */
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;

    /**
     * @notice Returns comprehensive risk and positioning data for a specific user.
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
     * @notice Returns metadata and state for a specific asset reserve.
     */
    function getReserveData(address asset) external view returns (ReserveData memory);

    /**
     * @notice Returns the collateral balance of a user for a specific asset.
     */
    function getUserCollateral(address user, address asset) external view returns (uint256);

    /**
     * @notice Returns the debt balance of a user for a specific asset.
     */
    function getUserDebt(address user, address asset) external view returns (uint256);

    /**
     * @notice Sets the risk parameters for an asset.
     */
    function configureReserve(address asset, uint256 ltv, uint256 liquidationThreshold, uint256 liquidationBonus)
        external;

    /**
     * @notice Manually sets the simulated price of an asset.
     * @param priceInUsd Price in USD with 8 decimals precision.
     */
    function setAssetPrice(address asset, uint256 priceInUsd) external;

    /**
     * @notice Returns the current simulated price of an asset.
     */
    function assetPrices(address asset) external view returns (uint256 priceInUsd);

    /**
     * @notice Whitelists a borrower to access undercollateralized borrowing via delegation.
     */
    function setWhitelistedBorrower(address borrower, bool status) external;

    /**
     * @notice Sets a maximum protocol-enforced credit limit for a whitelisted borrower.
     */
    function setCreditLimit(address borrower, address asset, uint256 limit) external;

    /**
     * @notice Sets a direct credit delegation from msg.sender to a whitelisted borrower.
     * @dev Allows the borrower to take on debt that is backed by msg.sender's collateral.
     * @param borrower The authorized borrower address.
     * @param asset The token address being delegated.
     * @param amount The maximum delegation capacity.
     */
    function setCreditDelegation(address borrower, address asset, uint256 amount) external;

    /**
     * @notice Checks if an address is authorized for credit delegation.
     */
    function isWhitelistedBorrower(address borrower) external view returns (bool);

    /**
     * @notice Returns the protocol-enforced credit limit for a borrower.
     */
    function getCreditLimit(address borrower, address asset) external view returns (uint256 limit);

    /**
     * @notice Returns the specific delegation amount from a delegator to a borrower.
     */
    function getCreditDelegation(address delegator, address borrower, address asset)
        external
        view
        returns (uint256 delegatedAmount);

    /**
     * @notice Returns the total aggregated credit delegated to a specific borrower across all suppliers.
     */
    function getTotalDelegatedToBorrower(address borrower, address asset)
        external
        view
        returns (uint256 delegatedAmount);

    /**
     * @notice Returns the total quantity of assets a supplier has delegated across all borrowers.
     */
    function getTotalDelegatedBy(address delegator, address asset) external view returns (uint256 delegatedAmount);
}
