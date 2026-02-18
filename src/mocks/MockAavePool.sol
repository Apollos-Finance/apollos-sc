// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMockAavePool} from "../interfaces/IMockAavePool.sol";

/**
 * @title MockAavePool
 * @notice Simplified Aave V3 Pool for Apollos Finance testing
 * @dev Implements core lending functions for 2x leverage strategy:
 *      1. ApollosVault supplies WETH as collateral
 *      2. ApollosVault borrows USDC against collateral
 *      3. Borrowed USDC + original WETH = 2x liquidity for UniswapPool
 *
 * Simplifications:
 *      - No aTokens/debtTokens (balances tracked internally)
 *      - Fixed interest rates (no interest accrual for hackathon)
 *      - Manual price setting (no Chainlink oracle integration)
 *      - Single interest rate mode (variable only)
 */
contract MockAavePool is IMockAavePool, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice Basis points denominator (100% = 10000)
    uint256 public constant BPS = 10000;

    /// @notice Health factor precision (1e18 = 1.0)
    uint256 public constant HEALTH_FACTOR_PRECISION = 1e18;

    /// @notice Price precision (8 decimals like Chainlink)
    uint256 public constant PRICE_PRECISION = 1e8;

    // ============ Structs ============

    /// @notice Reserve configuration
    struct ReserveConfig {
        bool isActive;
        uint256 ltv; // e.g., 7500 = 75%
        uint256 liquidationThreshold; // e.g., 8000 = 80%
        uint256 liquidationBonus; // e.g., 10500 = 5% bonus
        uint256 decimals; // Token decimals
    }

    // ============ State Variables ============

    /// @notice Reserve configurations per asset
    mapping(address => ReserveConfig) public reserveConfigs;

    /// @notice Asset prices in USD (8 decimals)
    mapping(address => uint256) public assetPrices;

    /// @notice User collateral balances: user => asset => amount
    mapping(address => mapping(address => uint256)) public userCollateral;

    /// @notice User debt balances: user => asset => amount
    mapping(address => mapping(address => uint256)) public userDebt;

    /// @notice List of configured assets
    address[] public reserveAssets;

    // ============ Credit Delegation (For Apollos Vault) ============

    /// @notice Whitelisted borrowers (ApollosVault) that can borrow without collateral
    mapping(address => bool) public whitelistedBorrowers;

    /// @notice Credit limit per whitelisted borrower per asset
    mapping(address => mapping(address => uint256)) public creditLimits;

    /// @notice Delegation allowance: delegator => borrower => asset => amount
    mapping(address => mapping(address => mapping(address => uint256))) public creditDelegations;

    /// @notice Total delegated amount by delegator per asset
    mapping(address => mapping(address => uint256)) public totalDelegatedBy;

    /// @notice Total delegated amount to borrower per asset
    mapping(address => mapping(address => uint256)) public totalDelegatedToBorrower;

    /// @notice Virtual collateral for whitelisted borrowers (LP tokens locked in vault)
    mapping(address => uint256) public virtualCollateral;

    // ============ Events for Credit Delegation ============
    event BorrowerWhitelisted(address indexed borrower, bool status);
    event CreditLimitSet(address indexed borrower, address indexed asset, uint256 limit);
    event CreditDelegationUpdated(
        address indexed delegator, address indexed borrower, address indexed asset, uint256 oldAmount, uint256 newAmount
    );
    event VirtualCollateralUpdated(address indexed borrower, uint256 amount);

    // ============ Constructor ============

    constructor() Ownable(msg.sender) {}

    // ============ Core Functions ============

    /**
     * @notice Supply assets as collateral
     * @dev Transfers tokens from user and tracks collateral balance
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

        // Transfer tokens from caller
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        // Update collateral balance
        userCollateral[onBehalfOf][asset] += amount;

        emit Supply(asset, msg.sender, onBehalfOf, amount);
    }

    /**
     * @notice Withdraw collateral from the pool
     * @dev Checks health factor after withdrawal
     */
    function withdraw(address asset, uint256 amount, address to) external override nonReentrant returns (uint256) {
        if (to == address(0)) revert ZeroAddress();

        uint256 userBalance = userCollateral[msg.sender][asset];
        if (userBalance == 0) revert NothingToWithdraw();

        // Handle max withdrawal
        uint256 amountToWithdraw = amount == type(uint256).max ? userBalance : amount;
        if (amountToWithdraw > userBalance) revert InvalidAmount();

        // Keep delegator's pledged backing locked unless delegation is reduced first
        uint256 delegatedAmount = totalDelegatedBy[msg.sender][asset];
        if (userBalance - amountToWithdraw < delegatedAmount) revert DelegationExceedsSuppliedBalance();

        // Update balance first (checks-effects-interactions)
        userCollateral[msg.sender][asset] -= amountToWithdraw;

        // Check health factor after withdrawal (only if user has ANY debt)
        (, uint256 totalDebt,,,,) = getUserAccountData(msg.sender);
        if (totalDebt > 0) {
            uint256 healthFactor = _calculateHealthFactor(msg.sender);
            if (healthFactor < HEALTH_FACTOR_PRECISION) {
                // Revert the balance change
                userCollateral[msg.sender][asset] += amountToWithdraw;
                revert HealthFactorTooLow();
            }
        }

        // Transfer tokens
        IERC20(asset).safeTransfer(to, amountToWithdraw);

        emit Withdraw(asset, msg.sender, to, amountToWithdraw);
        return amountToWithdraw;
    }

    /**
     * @notice Borrow assets against collateral
     * @dev Checks that borrow doesn't exceed available borrows
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

        // Credit Delegation: Whitelisted vaults can borrow without collateral
        if (whitelistedBorrowers[onBehalfOf]) {
            // Check against credit limit instead of collateral
            uint256 currentDebt = userDebt[onBehalfOf][asset];
            uint256 limit = _getEffectiveCreditLimit(onBehalfOf, asset);
            if (currentDebt + amount > limit) revert InsufficientCollateral();
        } else {
            // Standard collateralized borrow
            (,, uint256 availableBorrows,,,) = getUserAccountData(onBehalfOf);
            uint256 borrowValueInBase = _getAssetValueInBase(asset, amount);
            if (borrowValueInBase > availableBorrows) revert InsufficientCollateral();
        }

        // Check pool liquidity
        uint256 poolBalance = IERC20(asset).balanceOf(address(this));
        if (amount > poolBalance) revert InvalidAmount();

        // Update debt balance
        userDebt[onBehalfOf][asset] += amount;

        // Transfer borrowed tokens
        IERC20(asset).safeTransfer(msg.sender, amount);

        emit Borrow(asset, msg.sender, onBehalfOf, amount, 2, 0);
    }

    /**
     * @notice Repay borrowed assets
     * @dev Transfers tokens from caller and reduces debt
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

        // Handle max repay
        uint256 amountToRepay = amount == type(uint256).max ? currentDebt : amount;
        if (amountToRepay > currentDebt) {
            amountToRepay = currentDebt;
        }

        // Transfer tokens from caller
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amountToRepay);

        // Update debt balance
        userDebt[onBehalfOf][asset] -= amountToRepay;

        emit Repay(asset, onBehalfOf, msg.sender, amountToRepay);
        return amountToRepay;
    }

    /**
     * @notice Liquidate an undercollateralized position
     * @dev Liquidator repays debt and receives collateral + bonus
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
        // Check if position is liquidatable
        (,,,,, uint256 healthFactor) = getUserAccountData(user);
        if (healthFactor >= HEALTH_FACTOR_PRECISION) revert NotLiquidatable();

        uint256 userDebtBalance = userDebt[user][debtAsset];
        if (userDebtBalance == 0) revert NothingToRepay();

        // Cap debt to cover at 50% of total debt (standard Aave rule)
        uint256 maxDebtToCover = (userDebtBalance * 50) / 100;
        uint256 actualDebtToCover = debtToCover > maxDebtToCover ? maxDebtToCover : debtToCover;

        // Calculate collateral to receive (with bonus)
        ReserveConfig memory config = reserveConfigs[collateralAsset];
        uint256 debtValueInBase = _getAssetValueInBase(debtAsset, actualDebtToCover);
        uint256 collateralToLiquidate = _getAssetAmountFromBase(collateralAsset, debtValueInBase);
        uint256 collateralWithBonus = (collateralToLiquidate * config.liquidationBonus) / BPS;

        // Check user has enough collateral
        uint256 userCollateralBalance = userCollateral[user][collateralAsset];
        if (collateralWithBonus > userCollateralBalance) {
            collateralWithBonus = userCollateralBalance;
        }

        // Execute liquidation
        // 1. Liquidator repays debt
        IERC20(debtAsset).safeTransferFrom(msg.sender, address(this), actualDebtToCover);
        userDebt[user][debtAsset] -= actualDebtToCover;

        // 2. Liquidator receives collateral
        userCollateral[user][collateralAsset] -= collateralWithBonus;
        IERC20(collateralAsset).safeTransfer(msg.sender, collateralWithBonus);

        emit Liquidation(collateralAsset, debtAsset, user, actualDebtToCover, collateralWithBonus, msg.sender);
    }

    // ============ View Functions ============

    /**
     * @notice Get user account data with health factor
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
        // Calculate total collateral and weighted LTV
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

            // Calculate total debt
            uint256 debt = userDebt[user][asset];
            if (debt > 0) {
                totalDebtBase += _getAssetValueInBase(asset, debt);
            }
        }

        // Calculate weighted averages
        if (totalCollateralBase > 0) {
            ltv = weightedLtv / totalCollateralBase;
            currentLiquidationThreshold = weightedLiqThreshold / totalCollateralBase;

            // Calculate max borrow power
            uint256 maxBorrowPower = (totalCollateralBase * ltv) / BPS;

            // Prevent underflow: check if debt exceeds limit
            if (totalDebtBase > maxBorrowPower) {
                availableBorrowsBase = 0; // Debt exceeds limit
            } else {
                availableBorrowsBase = maxBorrowPower - totalDebtBase;
            }
        }

        // Calculate health factor
        healthFactor = _calculateHealthFactor(user);
    }

    /**
     * @notice Get reserve data (simplified)
     */
    function getReserveData(address asset) external view override returns (ReserveData memory) {
        return ReserveData({
            aTokenAddress: address(0), // Not using aTokens
            variableDebtTokenAddress: address(0),
            liquidityRate: 0, // No interest for hackathon
            variableBorrowRate: 0,
            liquidityIndex: 1e27,
            variableBorrowIndex: 1e27
        });
    }

    /**
     * @notice Get user's collateral balance
     */
    function getUserCollateral(address user, address asset) external view override returns (uint256) {
        return userCollateral[user][asset];
    }

    /**
     * @notice Get user's debt balance
     */
    function getUserDebt(address user, address asset) external view override returns (uint256) {
        return userDebt[user][asset];
    }

    // ============ Admin Functions ============

    /**
     * @notice Configure a reserve asset
     */
    function configureReserve(address asset, uint256 _ltv, uint256 _liquidationThreshold, uint256 _liquidationBonus)
        external
        override
        onlyOwner
    {
        if (asset == address(0)) revert ZeroAddress();

        // Add to reserve list if new
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
     * @notice Set asset price (for testing without oracle)
     */
    function setAssetPrice(address asset, uint256 priceInUsd) external override onlyOwner {
        assetPrices[asset] = priceInUsd;
    }

    /**
     * @notice Batch set asset prices
     */
    function batchSetAssetPrices(address[] calldata assets, uint256[] calldata prices) external onlyOwner {
        require(assets.length == prices.length, "Length mismatch");
        for (uint256 i = 0; i < assets.length; i++) {
            assetPrices[assets[i]] = prices[i];
        }
    }

    /**
     * @notice Seed pool with liquidity for borrowing
     */
    function seedLiquidity(address asset, uint256 amount) external onlyOwner {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
    }

    // ============ Credit Delegation Admin Functions ============

    /**
     * @notice Whitelist a borrower (ApollosVault) for undercollateralized borrowing
     * @param borrower The address to whitelist
     * @param status True to whitelist, false to remove
     */
    function setWhitelistedBorrower(address borrower, bool status) external onlyOwner {
        if (borrower == address(0)) revert ZeroAddress();
        whitelistedBorrowers[borrower] = status;
        emit BorrowerWhitelisted(borrower, status);
    }

    /**
     * @notice Set optional protocol hard cap for borrower credit
     * @dev Effective borrow limit for whitelisted borrowers is:
     *      min(total delegated credit, protocol hard cap) when hard cap > 0
     *      total delegated credit when hard cap == 0
     * @param borrower The whitelisted borrower address
     * @param asset The asset they can borrow
     * @param limit Maximum amount they can borrow
     */
    function setCreditLimit(address borrower, address asset, uint256 limit) external onlyOwner {
        if (borrower == address(0) || asset == address(0)) revert ZeroAddress();
        creditLimits[borrower][asset] = limit;
        emit CreditLimitSet(borrower, asset, limit);
    }

    /**
     * @notice Set delegated borrow allowance from msg.sender to whitelisted borrower
     * @dev Delegation can be increased up to supplier's deposited balance of the asset.
     *      Delegation can be reduced as long as it does not go below borrower's current debt.
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
     * @notice Update virtual collateral (called when vault deposits LP tokens)
     * @param borrower The vault address
     * @param amount The virtual collateral value in base currency
     */
    function updateVirtualCollateral(address borrower, uint256 amount) external onlyOwner {
        virtualCollateral[borrower] = amount;
        emit VirtualCollateralUpdated(borrower, amount);
    }

    /**
     * @notice Check if an address is a whitelisted borrower
     */
    function isWhitelistedBorrower(address borrower) external view returns (bool) {
        return whitelistedBorrowers[borrower];
    }

    /**
     * @notice Get credit limit for a borrower and asset
     */
    function getCreditLimit(address borrower, address asset) external view returns (uint256) {
        return creditLimits[borrower][asset];
    }

    /**
     * @notice Get delegation from a specific delegator to borrower
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
     * @notice Get aggregate delegated credit available to borrower
     */
    function getTotalDelegatedToBorrower(address borrower, address asset) external view override returns (uint256) {
        return totalDelegatedToBorrower[borrower][asset];
    }

    /**
     * @notice Get aggregate delegated credit set by delegator
     */
    function getTotalDelegatedBy(address delegator, address asset) external view override returns (uint256) {
        return totalDelegatedBy[delegator][asset];
    }

    // ============ Internal Functions ============

    /**
     * @notice Get effective credit limit for whitelisted borrower
     * @dev Delegated credit is the primary limit. Protocol hard cap is optional.
     */
    function _getEffectiveCreditLimit(address borrower, address asset) internal view returns (uint256) {
        uint256 delegatedLimit = totalDelegatedToBorrower[borrower][asset];
        uint256 hardCap = creditLimits[borrower][asset];

        if (hardCap == 0) return delegatedLimit;
        return delegatedLimit < hardCap ? delegatedLimit : hardCap;
    }

    /**
     * @notice Calculate health factor for a user
     */
    function _calculateHealthFactor(address user) internal view returns (uint256) {
        uint256 totalDebtBase;
        uint256 liquidationThresholdValue;

        for (uint256 i = 0; i < reserveAssets.length; i++) {
            address asset = reserveAssets[i];

            // Collateral contribution to liquidation threshold
            uint256 collateral = userCollateral[user][asset];
            if (collateral > 0) {
                uint256 valueInBase = _getAssetValueInBase(asset, collateral);
                ReserveConfig memory config = reserveConfigs[asset];
                liquidationThresholdValue += (valueInBase * config.liquidationThreshold) / BPS;
            }

            // Total debt
            uint256 debt = userDebt[user][asset];
            if (debt > 0) {
                totalDebtBase += _getAssetValueInBase(asset, debt);
            }
        }

        if (totalDebtBase == 0) {
            return type(uint256).max; // No debt = infinite health
        }

        // Avoid overflow: divide first, then multiply
        // HF = (liquidationThresholdValue / totalDebtBase) * HEALTH_FACTOR_PRECISION
        // But this loses precision, so we use:
        // HF = (liquidationThresholdValue * HEALTH_FACTOR_PRECISION) / totalDebtBase
        // Safely: check for potential overflow first
        if (liquidationThresholdValue > type(uint256).max / HEALTH_FACTOR_PRECISION) {
            // Large values: do division first to avoid overflow
            return (liquidationThresholdValue / totalDebtBase) * HEALTH_FACTOR_PRECISION;
        }
        return (liquidationThresholdValue * HEALTH_FACTOR_PRECISION) / totalDebtBase;
    }

    /**
     * @notice Get asset value in base currency (USD, 8 decimals)
     */
    function _getAssetValueInBase(address asset, uint256 amount) internal view returns (uint256) {
        uint256 price = assetPrices[asset];
        uint256 decimals = reserveConfigs[asset].decimals;
        uint256 divisor = 10 ** decimals;

        // value = amount * price / 10^decimals
        // To avoid overflow: divide first if amount is large
        if (amount > type(uint256).max / price) {
            return (amount / divisor) * price;
        }
        return (amount * price) / divisor;
    }

    /**
     * @notice Get asset amount from base currency value
     */
    function _getAssetAmountFromBase(address asset, uint256 valueInBase) internal view returns (uint256) {
        uint256 price = assetPrices[asset];
        uint256 decimals = reserveConfigs[asset].decimals;
        uint256 multiplier = 10 ** decimals;

        if (price == 0) return 0;

        // amount = valueInBase * 10^decimals / price
        // To avoid overflow: divide first if valueInBase is large
        if (valueInBase > type(uint256).max / multiplier) {
            return (valueInBase / price) * multiplier;
        }
        return (valueInBase * multiplier) / price;
    }

    /**
     * @notice Get token decimals
     */
    function _getDecimals(address asset) internal view returns (uint256) {
        // Try to get decimals, default to 18
        try IERC20Metadata(asset).decimals() returns (uint8 decimals) {
            return decimals;
        } catch {
            return 18;
        }
    }
}

// Interface for getting token decimals
interface IERC20Metadata {
    function decimals() external view returns (uint8);
}
