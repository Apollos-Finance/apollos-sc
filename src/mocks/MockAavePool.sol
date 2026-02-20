// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMockAavePool} from "../interfaces/IMockAavePool.sol";

/**
 * @title MockAavePool
 * @notice Simplified Aave V3 Pool implementation for Apollos testing and simulation.
 * @author Apollos Team
 * @dev Implements core lending and borrowing functionality required for the 2x leverage strategy.
 *      Key features include:
 *      - Collateral supply and withdrawal.
 *      - Undercollateralized borrowing via Credit Delegation for whitelisted vaults.
 *      - Basic health factor calculation and liquidation simulation.
 *
 * @custom:security-contact security@apollos.finance
 */
contract MockAavePool is IMockAavePool, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Basis points denominator (100% = 10000)
    uint256 public constant BPS = 10000;

    /// @notice Health factor precision (1e18 = 1.0)
    uint256 public constant HEALTH_FACTOR_PRECISION = 1e18;

    /// @notice Price precision (8 decimals like Chainlink oracles)
    uint256 public constant PRICE_PRECISION = 1e8;

    /**
     * @notice Configuration parameters for an asset reserve
     * @param isActive Whether the reserve is accepting operations
     * @param ltv Loan-to-Value ratio in basis points
     * @param liquidationThreshold Liquidation threshold in basis points
     * @param liquidationBonus Liquidation bonus/penalty in basis points
     * @param decimals The number of decimals of the underlying asset
     */
    struct ReserveConfig {
        bool isActive;
        uint256 ltv; 
        uint256 liquidationThreshold; 
        uint256 liquidationBonus; 
        uint256 decimals; 
    }

    /// @notice Maps asset address to its reserve configuration
    mapping(address => ReserveConfig) public reserveConfigs;

    /// @notice Maps asset address to its current price in USD (8 decimals)
    mapping(address => uint256) public assetPrices;

    /// @notice Maps user to asset to their supplied collateral amount
    mapping(address => mapping(address => uint256)) public userCollateral;

    /// @notice Maps user to asset to their current borrowed debt amount
    mapping(address => mapping(address => uint256)) public userDebt;

    /// @notice Array of all addresses configured as reserve assets
    address[] public reserveAssets;

    /// @notice Whitelisted borrowers (e.g., ApollosVault) that can access credit delegation
    mapping(address => bool) public whitelistedBorrowers;

    /// @notice Maps borrower to asset to their specific protocol-enforced credit limit
    mapping(address => mapping(address => uint256)) public creditLimits;

    /// @notice Delegation allowance: delegator => borrower => asset => amount
    mapping(address => mapping(address => mapping(address => uint256))) public creditDelegations;

    /// @notice Total amount of an asset delegated by a specific delegator
    mapping(address => mapping(address => uint256)) public totalDelegatedBy;

    /// @notice Total amount of an asset delegated to a specific borrower
    mapping(address => mapping(address => uint256)) public totalDelegatedToBorrower;

    /// @notice Tracks virtual collateral value for whitelisted borrowers
    mapping(address => uint256) public virtualCollateral;

    /// @notice Emitted when a borrower's whitelist status is updated
    event BorrowerWhitelisted(address indexed borrower, bool status);
    
    /// @notice Emitted when a credit limit is set for a borrower
    event CreditLimitSet(address indexed borrower, address indexed asset, uint256 limit);
    
    /// @notice Emitted when a credit delegation is modified
    event CreditDelegationUpdated(
        address indexed delegator, address indexed borrower, address indexed asset, uint256 oldAmount, uint256 newAmount
    );
    
    /// @notice Emitted when virtual collateral for a borrower is updated
    event VirtualCollateralUpdated(address indexed borrower, uint256 amount);

    /**
     * @notice Initializes the MockAavePool
     */
    constructor() Ownable(msg.sender) {}

    /**
     * @notice Supplies assets to the pool to be used as collateral or for lending
     * @dev Transfers tokens from the caller to this contract and updates collateral tracking
     * @param asset The address of the asset to supply
     * @param amount The amount of the asset to supply
     * @param onBehalfOf The address that will receive the collateral credit
     */
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 /* referralCode */
    )
        external
        override
        nonReentrant
    {
        if (amount == 0) revert InvalidAmount();
        if (!reserveConfigs[asset].isActive) revert ReserveNotActive();
        if (onBehalfOf == address(0)) revert ZeroAddress();

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        userCollateral[onBehalfOf][asset] += amount;

        emit Supply(asset, msg.sender, onBehalfOf, amount);
    }

    /**
     * @notice Withdraws supplied assets from the pool
     * @dev Validates that the withdrawal doesn't break health factor requirements if debt exists
     * @param asset The address of the asset to withdraw
     * @param amount The amount to withdraw (use type(uint256).max for full balance)
     * @param to The address that will receive the assets
     * @return The actual amount withdrawn
     */
    function withdraw(address asset, uint256 amount, address to) external override nonReentrant returns (uint256) {
        if (to == address(0)) revert ZeroAddress();

        uint256 userBalance = userCollateral[msg.sender][asset];
        if (userBalance == 0) revert NothingToWithdraw();

        uint256 amountToWithdraw = amount == type(uint256).max ? userBalance : amount;
        if (amountToWithdraw > userBalance) revert InvalidAmount();

        uint256 delegatedAmount = totalDelegatedBy[msg.sender][asset];
        if (userBalance - amountToWithdraw < delegatedAmount) revert DelegationExceedsSuppliedBalance();

        userCollateral[msg.sender][asset] -= amountToWithdraw;

        // Validation check for health factor if the user has active debt
        (, uint256 totalDebt,,,,) = getUserAccountData(msg.sender);
        if (totalDebt > 0) {
            uint256 healthFactor = _calculateHealthFactor(msg.sender);
            if (healthFactor < HEALTH_FACTOR_PRECISION) {
                userCollateral[msg.sender][asset] += amountToWithdraw;
                revert HealthFactorTooLow();
            }
        }

        IERC20(asset).safeTransfer(to, amountToWithdraw);

        emit Withdraw(asset, msg.sender, to, amountToWithdraw);
        return amountToWithdraw;
    }

    /**
     * @notice Borrows assets from the pool against collateral or via credit delegation
     * @dev For whitelisted borrowers, it uses delegated credit limits
     * @param asset The address of the asset to borrow
     * @param amount The amount to borrow
     * @param onBehalfOf The address that will incur the debt
     */
    function borrow(
        address asset,
        uint256 amount,
        uint256,
        /* interestRateMode */
        uint16,
        /* referralCode */
        address onBehalfOf
    )
        external
        override
        nonReentrant
    {
        if (amount == 0) revert InvalidAmount();
        if (!reserveConfigs[asset].isActive) revert ReserveNotActive();
        if (onBehalfOf == address(0)) revert ZeroAddress();

        if (whitelistedBorrowers[onBehalfOf]) {
            uint256 currentDebt = userDebt[onBehalfOf][asset];
            uint256 limit = _getEffectiveCreditLimit(onBehalfOf, asset);
            if (currentDebt + amount > limit) revert InsufficientCollateral();
        } else {
            (,, uint256 availableBorrows,,,) = getUserAccountData(onBehalfOf);
            uint256 borrowValueInBase = _getAssetValueInBase(asset, amount);
            if (borrowValueInBase > availableBorrows) revert InsufficientCollateral();
        }

        uint256 poolBalance = IERC20(asset).balanceOf(address(this));
        if (amount > poolBalance) revert InvalidAmount();

        userDebt[onBehalfOf][asset] += amount;

        IERC20(asset).safeTransfer(msg.sender, amount);

        emit Borrow(asset, msg.sender, onBehalfOf, amount, 2, 0);
    }

    /**
     * @notice Repays borrowed assets
     * @dev Reduces the debt balance of the specified user
     * @param asset The address of the asset to repay
     * @param amount The amount to repay (use type(uint256).max for full debt)
     * @param onBehalfOf The address whose debt is being repaid
     * @return The actual amount repaid
     */
    function repay(
        address asset,
        uint256 amount,
        uint256,
        /* interestRateMode */
        address onBehalfOf
    )
        external
        override
        nonReentrant
        returns (uint256)
    {
        if (onBehalfOf == address(0)) revert ZeroAddress();

        uint256 currentDebt = userDebt[onBehalfOf][asset];
        if (currentDebt == 0) revert NothingToRepay();

        uint256 amountToRepay = amount == type(uint256).max ? currentDebt : amount;
        if (amountToRepay > currentDebt) {
            amountToRepay = currentDebt;
        }

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amountToRepay);

        userDebt[onBehalfOf][asset] -= amountToRepay;

        emit Repay(asset, onBehalfOf, msg.sender, amountToRepay);
        return amountToRepay;
    }

    /**
     * @notice Liquidates an undercollateralized position
     * @dev Transfers debt asset from liquidator and collateral asset to liquidator
     * @param collateralAsset The address of the asset to be seized
     * @param debtAsset The address of the borrowed asset to be repaid
     * @param user The address of the user being liquidated
     * @param debtToCover The amount of debt to repay
     */
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool /* receiveAToken */
    )
        external
        override
        nonReentrant
    {
        (,,,,, uint256 healthFactor) = getUserAccountData(user);
        if (healthFactor >= HEALTH_FACTOR_PRECISION) revert NotLiquidatable();

        uint256 userDebtBalance = userDebt[user][debtAsset];
        if (userDebtBalance == 0) revert NothingToRepay();

        uint256 maxDebtToCover = (userDebtBalance * 50) / 100;
        uint256 actualDebtToCover = debtToCover > maxDebtToCover ? maxDebtToCover : debtToCover;

        ReserveConfig memory config = reserveConfigs[collateralAsset];
        uint256 debtValueInBase = _getAssetValueInBase(debtAsset, actualDebtToCover);
        uint256 collateralToLiquidate = _getAssetAmountFromBase(collateralAsset, debtValueInBase);
        uint256 collateralWithBonus = (collateralToLiquidate * config.liquidationBonus) / BPS;

        uint256 userCollateralBalance = userCollateral[user][collateralAsset];
        if (collateralWithBonus > userCollateralBalance) {
            collateralWithBonus = userCollateralBalance;
        }

        IERC20(debtAsset).safeTransferFrom(msg.sender, address(this), actualDebtToCover);
        userDebt[user][debtAsset] -= actualDebtToCover;

        userCollateral[user][collateralAsset] -= collateralWithBonus;
        IERC20(collateralAsset).safeTransfer(msg.sender, collateralWithBonus);

        emit Liquidation(collateralAsset, debtAsset, user, actualDebtToCover, collateralWithBonus, msg.sender);
    }

    /**
     * @notice Returns account data for a specific user
     * @param user The address of the user
     * @return totalCollateralBase Total collateral value in base currency (USD)
     * @return totalDebtBase Total debt value in base currency (USD)
     * @return availableBorrowsBase Remaining borrowing power in base currency (USD)
     * @return currentLiquidationThreshold Weighted liquidation threshold
     * @return ltv Weighted Loan-to-Value
     * @return healthFactor The current health factor of the user
     */
    function getUserAccountData(address user)
        public
        view
        override
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        uint256 weightedLtv;
        uint256 weightedLiqThreshold;

        for (uint256 i = 0; i < reserveAssets.length; i++) {
            address asset = reserveAssets[i];
            uint256 collateral = userCollateral[user][asset];

            if (collateral > 0) {
                uint256 valueInBase = _getAssetValueInBase(asset, collateral);
                totalCollateralBase += valueInBase;

                ReserveConfig memory config = reserveConfigs[asset];
                weightedLtv += valueInBase * config.ltv;
                weightedLiqThreshold += valueInBase * config.liquidationThreshold;
            }

            uint256 debt = userDebt[user][asset];
            if (debt > 0) {
                totalDebtBase += _getAssetValueInBase(asset, debt);
            }
        }

        if (totalCollateralBase > 0) {
            ltv = weightedLtv / totalCollateralBase;
            currentLiquidationThreshold = weightedLiqThreshold / totalCollateralBase;

            uint256 maxBorrowPower = (totalCollateralBase * ltv) / BPS;

            if (totalDebtBase > maxBorrowPower) {
                availableBorrowsBase = 0; 
            } else {
                availableBorrowsBase = maxBorrowPower - totalDebtBase;
            }
        }

        healthFactor = _calculateHealthFactor(user);
    }

    /**
     * @notice Returns reserve data for a specific asset (Mock implementation)
     * @param asset The address of the asset
     * @return Data structure containing reserve state
     */
    function getReserveData(address asset) external view override returns (ReserveData memory) {
        return ReserveData({
            aTokenAddress: address(0),
            variableDebtTokenAddress: address(0),
            liquidityRate: 0, 
            variableBorrowRate: 0,
            liquidityIndex: 1e27,
            variableBorrowIndex: 1e27
        });
    }

    /**
     * @notice Returns user's collateral balance for a specific asset
     */
    function getUserCollateral(address user, address asset) external view override returns (uint256) {
        return userCollateral[user][asset];
    }

    /**
     * @notice Returns user's debt balance for a specific asset
     */
    function getUserDebt(address user, address asset) external view override returns (uint256) {
        return userDebt[user][asset];
    }

    /**
     * @notice Configures parameters for a reserve asset
     * @param asset The address of the asset
     * @param _ltv Loan-to-Value in basis points
     * @param _liquidationThreshold Liquidation threshold in basis points
     * @param _liquidationBonus Liquidation bonus in basis points
     */
    function configureReserve(address asset, uint256 _ltv, uint256 _liquidationThreshold, uint256 _liquidationBonus)
        external
        override
        onlyOwner
    {
        if (asset == address(0)) revert ZeroAddress();

        if (!reserveConfigs[asset].isActive) {
            reserveAssets.push(asset);
        }

        reserveConfigs[asset] = ReserveConfig({
            isActive: true,
            ltv: _ltv,
            liquidationThreshold: _liquidationThreshold,
            liquidationBonus: _liquidationBonus,
            decimals: _getDecimals(asset)
        });

        emit ReserveConfigured(asset, _ltv, _liquidationThreshold, _liquidationBonus);
    }

    /**
     * @notice Manually sets the price of an asset (for simulation purposes)
     * @param asset The address of the asset
     * @param priceInUsd The price in USD (8 decimals)
     */
    function setAssetPrice(address asset, uint256 priceInUsd) external override onlyOwner {
        assetPrices[asset] = priceInUsd;
    }

    /**
     * @notice Sets prices for multiple assets in a single transaction
     * @param assets Array of asset addresses
     * @param prices Array of corresponding prices in USD (8 decimals)
     */
    function batchSetAssetPrices(address[] calldata assets, uint256[] calldata prices) external onlyOwner {
        require(assets.length == prices.length, "Length mismatch");
        for (uint256 i = 0; i < assets.length; i++) {
            assetPrices[assets[i]] = prices[i];
        }
    }

    /**
     * @notice Seeds the pool with liquidity for lending
     * @param asset The address of the asset to seed
     * @param amount The amount of the asset to transfer to the pool
     */
    function seedLiquidity(address asset, uint256 amount) external onlyOwner {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Updates the whitelist status of a borrower
     * @param borrower The address of the borrower
     * @param status True to whitelist, false to remove
     */
    function setWhitelistedBorrower(address borrower, bool status) external onlyOwner {
        if (borrower == address(0)) revert ZeroAddress();
        whitelistedBorrowers[borrower] = status;
        emit BorrowerWhitelisted(borrower, status);
    }

    /**
     * @notice Sets a credit limit for a whitelisted borrower
     * @param borrower The address of the whitelisted borrower
     * @param asset The address of the asset
     * @param limit The maximum amount the borrower can borrow
     */
    function setCreditLimit(address borrower, address asset, uint256 limit) external onlyOwner {
        if (borrower == address(0) || asset == address(0)) revert ZeroAddress();
        creditLimits[borrower][asset] = limit;
        emit CreditLimitSet(borrower, asset, limit);
    }

    /**
     * @notice Delegates borrowing power from msg.sender to a whitelisted borrower
     * @param borrower The address allowed to borrow on behalf of msg.sender
     * @param asset The address of the asset to delegate
     * @param amount The maximum amount of delegation
     */
    function setCreditDelegation(address borrower, address asset, uint256 amount) external override nonReentrant {
        if (borrower == address(0) || asset == address(0)) revert ZeroAddress();
        if (!whitelistedBorrowers[borrower]) revert NotWhitelistedBorrower();
        if (!reserveConfigs[asset].isActive) revert ReserveNotActive();

        uint256 currentAmount = creditDelegations[msg.sender][borrower][asset];
        if (currentAmount == amount) return;

        if (amount > currentAmount) {
            uint256 increase = amount - currentAmount;
            uint256 suppliedBalance = userCollateral[msg.sender][asset];
            uint256 delegatedByUser = totalDelegatedBy[msg.sender][asset];

            if (delegatedByUser + increase > suppliedBalance) {
                revert DelegationExceedsSuppliedBalance();
            }

            totalDelegatedBy[msg.sender][asset] = delegatedByUser + increase;
            totalDelegatedToBorrower[borrower][asset] += increase;
        } else {
            uint256 decrease = currentAmount - amount;
            uint256 newBorrowerDelegation = totalDelegatedToBorrower[borrower][asset] - decrease;

            if (userDebt[borrower][asset] > newBorrowerDelegation) {
                revert DelegationBelowOutstandingDebt();
            }

            totalDelegatedBy[msg.sender][asset] -= decrease;
            totalDelegatedToBorrower[borrower][asset] = newBorrowerDelegation;
        }

        creditDelegations[msg.sender][borrower][asset] = amount;
        emit CreditDelegationUpdated(msg.sender, borrower, asset, currentAmount, amount);
    }

    /**
     * @notice Updates virtual collateral value for a borrower
     * @dev Used to simulate the value of LP tokens locked in a vault
     * @param borrower The address of the borrower
     * @param amount The value in base currency
     */
    function updateVirtualCollateral(address borrower, uint256 amount) external onlyOwner {
        virtualCollateral[borrower] = amount;
        emit VirtualCollateralUpdated(borrower, amount);
    }

    /**
     * @notice Checks if an address is a whitelisted borrower
     */
    function isWhitelistedBorrower(address borrower) external view returns (bool) {
        return whitelistedBorrowers[borrower];
    }

    /**
     * @notice Returns the credit limit for a borrower and asset
     */
    function getCreditLimit(address borrower, address asset) external view returns (uint256) {
        return creditLimits[borrower][asset];
    }

    /**
     * @notice Returns the delegation amount from a delegator to a borrower for an asset
     */
    function getCreditDelegation(address delegator, address borrower, address asset)
        external
        view
        override
        returns (uint256)
    {
        return creditDelegations[delegator][borrower][asset];
    }

    /**
     * @notice Returns the total delegated credit available to a borrower for an asset
     */
    function getTotalDelegatedToBorrower(address borrower, address asset) external view override returns (uint256) {
        return totalDelegatedToBorrower[borrower][asset];
    }

    /**
     * @notice Returns the total delegated amount set by a delegator for an asset
     */
    function getTotalDelegatedBy(address delegator, address asset) external view override returns (uint256) {
        return totalDelegatedBy[delegator][asset];
    }

    /**
     * @dev Internal helper to get effective credit limit (taking protocol hard cap into account)
     */
    function _getEffectiveCreditLimit(address borrower, address asset) internal view returns (uint256) {
        uint256 delegatedLimit = totalDelegatedToBorrower[borrower][asset];
        uint256 hardCap = creditLimits[borrower][asset];

        if (hardCap == 0) return delegatedLimit;
        return delegatedLimit < hardCap ? delegatedLimit : hardCap;
    }

    /**
     * @dev Internal helper to calculate health factor
     */
    function _calculateHealthFactor(address user) internal view returns (uint256) {
        uint256 totalDebtBase;
        uint256 liquidationThresholdValue;

        for (uint256 i = 0; i < reserveAssets.length; i++) {
            address asset = reserveAssets[i];

            uint256 collateral = userCollateral[user][asset];
            if (collateral > 0) {
                uint256 valueInBase = _getAssetValueInBase(asset, collateral);
                ReserveConfig memory config = reserveConfigs[asset];
                liquidationThresholdValue += (valueInBase * config.liquidationThreshold) / BPS;
            }

            uint256 debt = userDebt[user][asset];
            if (debt > 0) {
                totalDebtBase += _getAssetValueInBase(asset, debt);
            }
        }

        if (totalDebtBase == 0) {
            return type(uint256).max;
        }

        if (liquidationThresholdValue > type(uint256).max / HEALTH_FACTOR_PRECISION) {
            return (liquidationThresholdValue / totalDebtBase) * HEALTH_FACTOR_PRECISION;
        }
        return (liquidationThresholdValue * HEALTH_FACTOR_PRECISION) / totalDebtBase;
    }

    /**
     * @dev Internal helper to get asset value in base currency (USD, 8 decimals)
     */
    function _getAssetValueInBase(address asset, uint256 amount) internal view returns (uint256) {
        uint256 price = assetPrices[asset];
        uint256 decimals = reserveConfigs[asset].decimals;
        uint256 divisor = 10 ** decimals;

        if (amount > type(uint256).max / price) {
            return (amount / divisor) * price;
        }
        return (amount * price) / divisor;
    }

    /**
     * @dev Internal helper to get asset amount from base currency value
     */
    function _getAssetAmountFromBase(address asset, uint256 valueInBase) internal view returns (uint256) {
        uint256 price = assetPrices[asset];
        uint256 decimals = reserveConfigs[asset].decimals;
        uint256 multiplier = 10 ** decimals;

        if (price == 0) return 0;

        if (valueInBase > type(uint256).max / multiplier) {
            return (valueInBase / price) * multiplier;
        }
        return (valueInBase * multiplier) / price;
    }

    /**
     * @dev Internal helper to get token decimals
     */
    function _getDecimals(address asset) internal view returns (uint256) {
        try IERC20Metadata(asset).decimals() returns (uint8 decimals) {
            return decimals;
        } catch {
            return 18;
        }
    }
}

/**
 * @dev Minimal interface for retrieving token metadata decimals
 */
interface IERC20Metadata {
    function decimals() external view returns (uint8);
}
