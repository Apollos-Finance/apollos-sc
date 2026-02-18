// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// V4 Core Types
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

// Interfaces
import {IApollosVault} from "../interfaces/IApollosVault.sol";
import {IMockAavePool} from "../interfaces/IMockAavePool.sol";
import {IMockUniswapPool} from "../interfaces/IMockUniswapPool.sol";

/**
 * @title ApollosVault
 * @notice Hybrid ERC4626 Vault: Supports both On-Chain Math (Testing) and Off-Chain Accountant (Production)
 */
contract ApollosVault is IApollosVault, ERC4626, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    // ============ Constants ============
    uint256 public constant PRECISION = 1e18;
    uint256 public constant BPS = 10000;
    uint256 public constant MIN_DEPOSIT = 1e15;

    // ============ Immutables ============
    IERC20 public immutable quoteAsset;
    IMockAavePool public immutable aavePool;
    IMockUniswapPool public immutable uniswapPool;
    PoolKey public poolKey;

    // ============ State Variables ============
    VaultConfig public config;
    bool public paused;

    mapping(address => bool) public authorizedRebalancers;

    uint256 public lpTokenBalance;
    uint256 public protocolFee;
    address public treasury;
    uint256 public pendingFees;

    /// @notice Stored NAV updated by Chainlink Workflow (For Production)
    uint256 public storedTotalAssets;

    // ============ Events ============
    event NAVUpdated(uint256 newValue, uint256 timestamp);

    // ============ Modifiers ============
    modifier whenNotPaused() {
        if (paused) revert VaultPaused();
        _;
    }

    modifier onlyRebalancer() {
        if (!authorizedRebalancers[msg.sender] && msg.sender != owner()) {
            revert NotAuthorized();
        }
        _;
    }

    // ============ Constructor ============
    constructor(
        string memory _name,
        string memory _symbol,
        address _baseAsset,
        address _quoteAsset,
        address _aavePool,
        address _uniswapPool,
        PoolKey memory _poolKey,
        uint256 _targetLeverage,
        uint256 _maxLeverage
    ) ERC4626(IERC20(_baseAsset)) ERC20(_name, _symbol) Ownable(msg.sender) {
        if (_quoteAsset == address(0)) revert ZeroAddress();
        if (_aavePool == address(0) || _uniswapPool == address(0)) revert ZeroAddress();

        quoteAsset = IERC20(_quoteAsset);
        aavePool = IMockAavePool(_aavePool);
        uniswapPool = IMockUniswapPool(_uniswapPool);
        poolKey = _poolKey;

        config = VaultConfig({
            baseAsset: _baseAsset,
            quoteAsset: _quoteAsset,
            targetLeverage: _targetLeverage,
            maxLeverage: _maxLeverage,
            rebalanceThreshold: 1.1e18
        });

        protocolFee = 100; // 1% default
    }

    // ============ Accountant / NAV Functions ============

    function updateNAV(uint256 _newTotalAssets) external onlyRebalancer {
        storedTotalAssets = _newTotalAssets;
        emit NAVUpdated(_newTotalAssets, block.timestamp);
    }

    /**
     * @notice Hybrid Total Assets Logic
     * @dev If storedTotalAssets is set (Production/Workflow), use it.
     *      Otherwise, fallback to On-Chain Math (Testing).
     */
    function totalAssets() public view override(ERC4626, IApollosVault) returns (uint256) {
        // Mode Production: Use Off-Chain Accountant + Idle Cash
        if (storedTotalAssets > 0) {
            return storedTotalAssets + IERC20(asset()).balanceOf(address(this));
        }

        // Mode Testing: Use On-Chain Calculation
        uint256 vaultBalance = IERC20(asset()).balanceOf(address(this));
        uint256 lpValue = _getLPValueInBase();
        uint256 debt = _getTotalDebt();

        uint256 debtInBase = _convertQuoteToBase(debt);

        if (vaultBalance + lpValue > debtInBase) {
            return vaultBalance + lpValue - debtInBase;
        }
        return 0;
    }

    // ============ Core Functions ============

    // Override Deposit to maintain Leverage Strategy behavior
    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626, IApollosVault)
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        return _deposit(assets, receiver, 0);
    }

    function depositFor(uint256 amount, address receiver, uint256 minShares)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (receiver == address(0)) revert ZeroAddress();
        return _deposit(amount, receiver, minShares);
    }

    function _deposit(uint256 amount, address receiver, uint256 minShares) internal returns (uint256 shares) {
        if (amount < MIN_DEPOSIT) revert ZeroAmount();

        // Use ERC4626 standard preview
        shares = previewDeposit(amount);
        if (shares < minShares) revert SlippageExceeded();

        // Transfer base asset from user
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);

        // Execute Strategy (Borrow + LP)
        uint256 borrowAmount = _calculateBorrowAmount(amount);

        if (borrowAmount > 0) {
            quoteAsset.safeIncreaseAllowance(address(aavePool), borrowAmount);
            aavePool.borrow(address(quoteAsset), borrowAmount, 2, 0, address(this));
        }

        uint256 lpReceived = _addLiquidity(amount, borrowAmount);
        lpTokenBalance += lpReceived;

        if (storedTotalAssets > 0) {
            storedTotalAssets += amount;
        }

        // Mint shares
        _mint(receiver, shares);

        emit Deposit(receiver, amount, shares, borrowAmount);
    }

    function withdraw(uint256 shares, uint256 minAmount)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 amount)
    {
        if (shares == 0) revert ZeroAmount();
        if (balanceOf(msg.sender) < shares) revert InsufficientShares();

        amount = previewRedeem(shares);
        if (amount < minAmount) revert SlippageExceeded();

        uint256 lpToRemove = (lpTokenBalance * shares) / totalSupply();

        (uint256 amount0Received, uint256 amount1Received) = _removeLiquidity(lpToRemove);
        address currency0 = Currency.unwrap(poolKey.currency0);
        uint256 baseReceived = currency0 == address(asset()) ? amount0Received : amount1Received;
        uint256 quoteReceived = currency0 == address(asset()) ? amount1Received : amount0Received;
        lpTokenBalance -= lpToRemove;

        uint256 debtToRepay = _calculateProportionalDebt(shares);
        if (debtToRepay > 0 && debtToRepay <= quoteReceived) {
            quoteAsset.safeIncreaseAllowance(address(aavePool), debtToRepay);
            aavePool.repay(address(quoteAsset), debtToRepay, 2, address(this));
        }

        _burn(msg.sender, shares);

        uint256 availableBase = IERC20(asset()).balanceOf(address(this));
        if (baseReceived < availableBase) {
            availableBase = baseReceived;
        }
        if (amount > availableBase) {
            amount = availableBase;
        }
        if (amount < minAmount) revert SlippageExceeded();

        IERC20(asset()).safeTransfer(msg.sender, amount);

        uint256 excessQuote = quoteReceived > debtToRepay ? quoteReceived - debtToRepay : 0;
        if (excessQuote > 0) {
            quoteAsset.safeTransfer(msg.sender, excessQuote);
        }

        if (storedTotalAssets >= amount) {
            storedTotalAssets -= amount;
        } else {
            storedTotalAssets = 0;
        }

        emit Withdraw(msg.sender, shares, amount, debtToRepay);
    }

    function rebalance() external override onlyRebalancer nonReentrant returns (uint256 newLeverage) {
        uint256 currentLeverage = getCurrentLeverage();

        if (!needsRebalance()) revert RebalanceNotNeeded();

        uint256 oldLeverage = currentLeverage;
        uint256 lpToRemove = _calculateRebalanceAmount();

        if (lpToRemove > 0 && lpToRemove <= lpTokenBalance) {
            (uint256 amount0Received, uint256 amount1Received) = _removeLiquidity(lpToRemove);
            address currency0 = Currency.unwrap(poolKey.currency0);
            uint256 quoteReceived = currency0 == address(asset()) ? amount1Received : amount0Received;
            lpTokenBalance -= lpToRemove;

            if (quoteReceived > 0) {
                quoteAsset.safeIncreaseAllowance(address(aavePool), quoteReceived);
                aavePool.repay(address(quoteAsset), quoteReceived, 2, address(this));
            }
        }

        newLeverage = getCurrentLeverage();
        emit Rebalance(oldLeverage, newLeverage, lpToRemove, block.timestamp);
    }

    function emergencyWithdraw(uint256 shares) external override returns (uint256 amount) {
        amount = withdraw(shares, 0);
        emit EmergencyWithdraw(msg.sender, shares, amount);
    }

    // ============ View Functions ============

    function getVaultConfig() external view override returns (VaultConfig memory) {
        return config;
    }

    function getVaultState() external view override returns (VaultState memory) {
        return VaultState({
            totalBaseAssets: totalAssets(),
            totalBorrowed: _getTotalDebt(),
            lpTokenValue: lpTokenBalance,
            totalShares: totalSupply(),
            healthFactor: getHealthFactor(),
            currentLeverage: getCurrentLeverage()
        });
    }

    function previewDeposit(uint256 amount) public view override(ERC4626, IApollosVault) returns (uint256) {
        return super.previewDeposit(amount);
    }

    function previewWithdraw(uint256 shares) public view override(ERC4626, IApollosVault) returns (uint256) {
        return super.previewRedeem(shares);
    }

    function getSharePrice() external view override returns (uint256 price) {
        return convertToAssets(PRECISION);
    }

    function getHealthFactor() public view override returns (uint256 healthFactor) {
        (,,,,, healthFactor) = aavePool.getUserAccountData(address(this));
        if (healthFactor == 0) healthFactor = type(uint256).max;
    }

    function getCurrentLeverage() public view override returns (uint256 leverage) {
        uint256 totalDebt = _getTotalDebt();
        uint256 assets = totalAssets();

        if (assets == 0) return PRECISION;
        leverage = ((assets + totalDebt) * PRECISION) / assets;
    }

    function needsRebalance() public view override returns (bool needed) {
        uint256 hf = getHealthFactor();
        return hf < config.rebalanceThreshold && hf != type(uint256).max;
    }

    // ============ ERC4626 Conflict Resolution ============

    function decimals() public view override(ERC4626) returns (uint8) {
        return super.decimals();
    }

    function totalSupply() public view override(ERC20, IERC20, IApollosVault) returns (uint256) {
        return super.totalSupply();
    }

    function balanceOf(address account) public view override(ERC20, IERC20, IApollosVault) returns (uint256) {
        return super.balanceOf(account);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override(ERC4626) returns (uint256) {
        revert("Use withdraw(shares, minAmount)");
    }

    // ============ Admin Functions ============

    function updateConfig(uint256 _targetLeverage, uint256 _maxLeverage, uint256 _rebalanceThreshold)
        external
        override
        onlyOwner
    {
        config.targetLeverage = _targetLeverage;
        config.maxLeverage = _maxLeverage;
        config.rebalanceThreshold = _rebalanceThreshold;
    }

    function setPaused(bool _paused) external override onlyOwner {
        paused = _paused;
    }

    function setRebalancer(address rebalancer, bool authorized) external override onlyOwner {
        authorizedRebalancers[rebalancer] = authorized;
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }

    function setProtocolFee(uint256 _fee) external onlyOwner {
        protocolFee = _fee;
    }

    // ============ Internal Functions (On-Chain Math Kept for Testing) ============

    function _calculateBorrowAmount(uint256 baseAmount) internal view returns (uint256) {
        uint256 basePrice = aavePool.assetPrices(address(asset()));
        uint256 quotePrice = aavePool.assetPrices(address(quoteAsset));

        if (basePrice == 0 || quotePrice == 0) return 0;

        uint8 baseDecimals = _getDecimals(address(asset()));
        uint8 quoteDecimals = _getDecimals(address(quoteAsset));

        uint256 borrowValue = (baseAmount * basePrice) / (10 ** baseDecimals);
        uint256 borrowAmount = (borrowValue * (10 ** quoteDecimals)) / quotePrice;

        return borrowAmount;
    }

    function _addLiquidity(uint256 baseAmount, uint256 quoteAmount) internal returns (uint256 lpReceived) {
        address currency0 = Currency.unwrap(poolKey.currency0);
        address currency1 = Currency.unwrap(poolKey.currency1);

        uint256 amount0;
        uint256 amount1;

        if (currency0 == address(asset()) && currency1 == address(quoteAsset)) {
            amount0 = baseAmount;
            amount1 = quoteAmount;
        } else if (currency0 == address(quoteAsset) && currency1 == address(asset())) {
            amount0 = quoteAmount;
            amount1 = baseAmount;
        } else {
            revert ZeroAddress();
        }

        if (amount0 == 0 || amount1 == 0) revert SlippageExceeded();

        IERC20(currency0).safeIncreaseAllowance(address(uniswapPool), amount0);
        IERC20(currency1).safeIncreaseAllowance(address(uniswapPool), amount1);

        (,, lpReceived) = uniswapPool.addLiquidity(poolKey, amount0, amount1, 1, 1);

        if (lpReceived == 0) revert SlippageExceeded();
    }

    function _removeLiquidity(uint256 lpAmount) internal returns (uint256 baseReceived, uint256 quoteReceived) {
        (baseReceived, quoteReceived) = uniswapPool.removeLiquidity(poolKey, lpAmount, 0, 0);
    }

    function _getTotalDebt() internal view returns (uint256) {
        return aavePool.getUserDebt(address(this), address(quoteAsset));
    }

    function _calculateProportionalDebt(uint256 shares) internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        return (_getTotalDebt() * shares) / supply;
    }

    function _calculateRebalanceAmount() internal view returns (uint256) {
        uint256 currentLev = getCurrentLeverage();
        uint256 targetLev = config.targetLeverage;

        if (currentLev <= targetLev) return 0;

        uint256 excessLeverage = currentLev - targetLev;
        return (lpTokenBalance * excessLeverage) / currentLev;
    }

    function _getLPValueInBase() internal view returns (uint256) {
        PoolId poolId = poolKey.toId();

        (uint256 amount0, uint256 amount1) = uniswapPool.getPositionValue(poolId, address(this));

        address currency0 = Currency.unwrap(poolKey.currency0);
        uint256 baseAmount;
        uint256 quoteAmount;

        if (currency0 == address(asset())) {
            baseAmount = amount0;
            quoteAmount = amount1;
        } else {
            baseAmount = amount1;
            quoteAmount = amount0;
        }

        uint256 quoteValueInBase = _convertQuoteToBase(quoteAmount);
        return baseAmount + quoteValueInBase;
    }

    function _convertQuoteToBase(uint256 quoteAmount) internal view returns (uint256) {
        uint256 basePrice = aavePool.assetPrices(address(asset()));
        uint256 quotePrice = aavePool.assetPrices(address(quoteAsset));

        if (basePrice == 0) return 0;

        uint8 baseDecimals = _getDecimals(address(asset()));
        uint8 quoteDecimals = _getDecimals(address(quoteAsset));

        uint256 quoteValue = (quoteAmount * quotePrice) / (10 ** quoteDecimals);
        return (quoteValue * (10 ** baseDecimals)) / basePrice;
    }

    // Fixed shadowing by renaming return var
    function _getDecimals(address token) internal view returns (uint8) {
        try IERC20Metadata(token).decimals() returns (uint8 tokenDecimals) {
            return tokenDecimals;
        } catch {
            return 18;
        }
    }
}

interface IERC20Metadata {
    function decimals() external view returns (uint8);
}
