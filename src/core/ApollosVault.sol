// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
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
 * @notice Core vault contract implementing 2x leverage strategy with LVR protection
 * @dev The "heart" of Apollos Finance:
 *      1. Receives user deposits (WETH)
 *      2. Borrows quote asset (USDC) from MockAavePool via Credit Delegation
 *      3. Provides liquidity to MockUniswapPool (protected by LVRHook)
 *      4. Mints afTOKEN shares to users
 * 
 * Integration:
 *      - MockAavePool: Undercollateralized borrowing (vault is whitelisted)
 *      - MockUniswapPool: LP deposits (only this vault can add liquidity)
 *      - LVRHook: Dynamic fee protection during high volatility
 *      - Chainlink Workflow: Triggers rebalance() when health factor is low
 */
contract ApollosVault is IApollosVault, ERC20, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    // ============ Constants ============
    uint256 public constant PRECISION = 1e18;
    uint256 public constant BPS = 10000;
    uint256 public constant MIN_DEPOSIT = 1e15; // 0.001 base asset
    
    // ============ Immutables ============
    IERC20 public immutable baseAsset;      // e.g., WETH
    IERC20 public immutable quoteAsset;     // e.g., USDC
    IMockAavePool public immutable aavePool;
    IMockUniswapPool public immutable uniswapPool;
    PoolKey public poolKey;
    
    // ============ State Variables ============
    VaultConfig public config;
    bool public paused;
    
    /// @notice Authorized rebalancers (Chainlink Workflow)
    mapping(address => bool) public authorizedRebalancers;
    
    /// @notice LP token amount held by vault
    uint256 public lpTokenBalance;
    
    /// @notice Protocol fee in basis points (e.g., 100 = 1%)
    uint256 public protocolFee;
    address public treasury;
    
    /// @notice Accumulated fees pending harvest
    uint256 public pendingFees;

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
    ) ERC20(_name, _symbol) Ownable(msg.sender) {
        if (_baseAsset == address(0) || _quoteAsset == address(0)) revert ZeroAddress();
        if (_aavePool == address(0) || _uniswapPool == address(0)) revert ZeroAddress();
        
        baseAsset = IERC20(_baseAsset);
        quoteAsset = IERC20(_quoteAsset);
        aavePool = IMockAavePool(_aavePool);
        uniswapPool = IMockUniswapPool(_uniswapPool);
        poolKey = _poolKey;
        
        config = VaultConfig({
            baseAsset: _baseAsset,
            quoteAsset: _quoteAsset,
            targetLeverage: _targetLeverage,  // e.g., 2e18 = 2x
            maxLeverage: _maxLeverage,        // e.g., 2.5e18
            rebalanceThreshold: 1.1e18        // Rebalance if HF < 1.1
        });
        
        protocolFee = 100; // 1% default
    }

    // ============ Core Functions ============

    /**
     * @notice Deposit base asset and receive vault shares
     * @dev Flow: Transfer WETH → Borrow USDC → Add LP → Mint shares
     */
    function deposit(uint256 amount, uint256 minShares) 
        external 
        override 
        nonReentrant 
        whenNotPaused 
        returns (uint256 shares) 
    {
        return _deposit(amount, msg.sender, minShares);
    }

    /**
     * @notice Deposit on behalf of another user (for CCIP receiver)
     */
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

    /**
     * @notice Internal deposit logic
     */
    function _deposit(uint256 amount, address receiver, uint256 minShares) 
        internal 
        returns (uint256 shares) 
    {
        if (amount < MIN_DEPOSIT) revert ZeroAmount();
        
        // Calculate shares before any state changes
        shares = previewDeposit(amount);
        if (shares < minShares) revert SlippageExceeded();
        
        // Transfer base asset from user
        baseAsset.safeTransferFrom(msg.sender, address(this), amount);
        
        // Calculate borrow amount for 2x leverage
        // For 2x: borrow equivalent value in quote asset
        uint256 borrowAmount = _calculateBorrowAmount(amount);
        
        // Borrow quote asset from Aave (Credit Delegation)
        if (borrowAmount > 0) {
            quoteAsset.safeIncreaseAllowance(address(aavePool), borrowAmount);
            aavePool.borrow(
                address(quoteAsset),
                borrowAmount,
                2,  // Variable rate
                0,  // No referral
                address(this)
            );
        }
        
        // Add liquidity to Uniswap Pool
        uint256 lpReceived = _addLiquidity(amount, borrowAmount);
        lpTokenBalance += lpReceived;
        
        // Mint shares to receiver
        _mint(receiver, shares);
        
        emit Deposit(receiver, amount, shares, borrowAmount);
    }

    /**
     * @notice Withdraw by burning shares
     * @dev Flow: Burn shares → Remove LP → Repay debt → Transfer WETH
     */
    function withdraw(uint256 shares, uint256 minAmount)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 amount)
    {
        if (shares == 0) revert ZeroAmount();
        if (balanceOf(msg.sender) < shares) revert InsufficientShares();
        
        // Calculate base asset to receive
        amount = previewWithdraw(shares);
        if (amount < minAmount) revert SlippageExceeded();
        
        // Calculate proportional LP to remove
        uint256 lpToRemove = (lpTokenBalance * shares) / totalSupply();
        
        // Remove liquidity from Uniswap
        (uint256 baseReceived, uint256 quoteReceived) = _removeLiquidity(lpToRemove);
        lpTokenBalance -= lpToRemove;
        
        // Repay proportional debt to Aave
        uint256 debtToRepay = _calculateProportionalDebt(shares);
        if (debtToRepay > 0 && debtToRepay <= quoteReceived) {
            quoteAsset.safeIncreaseAllowance(address(aavePool), debtToRepay);
            aavePool.repay(address(quoteAsset), debtToRepay, 2, address(this));
        }
        
        // Burn shares
        _burn(msg.sender, shares);
        
        // Transfer base asset to user
        baseAsset.safeTransfer(msg.sender, amount);
        
        // Transfer excess quote asset if any
        uint256 excessQuote = quoteReceived > debtToRepay ? quoteReceived - debtToRepay : 0;
        if (excessQuote > 0) {
            // Convert to base asset value and add to amount (simplified)
            quoteAsset.safeTransfer(msg.sender, excessQuote);
        }
        
        emit Withdraw(msg.sender, shares, amount, debtToRepay);
    }

    /**
     * @notice Rebalance vault to maintain target leverage
     * @dev Called by Chainlink Workflow when health factor drops
     */
    function rebalance() 
        external 
        override 
        onlyRebalancer 
        nonReentrant 
        returns (uint256 newLeverage) 
    {
        uint256 currentLeverage = getCurrentLeverage();
        
        // Only rebalance if needed
        if (!needsRebalance()) revert RebalanceNotNeeded();
        
        uint256 oldLeverage = currentLeverage;
        
        // Calculate how much LP to remove to reduce leverage
        uint256 lpToRemove = _calculateRebalanceAmount();
        
        if (lpToRemove > 0 && lpToRemove <= lpTokenBalance) {
            // Remove some liquidity
            (uint256 baseReceived, uint256 quoteReceived) = _removeLiquidity(lpToRemove);
            lpTokenBalance -= lpToRemove;
            
            // Use quote to repay debt
            if (quoteReceived > 0) {
                quoteAsset.safeIncreaseAllowance(address(aavePool), quoteReceived);
                aavePool.repay(address(quoteAsset), quoteReceived, 2, address(this));
            }
            
            // Keep base asset in vault for buffer
        }
        
        newLeverage = getCurrentLeverage();
        
        emit Rebalance(oldLeverage, newLeverage, lpToRemove, block.timestamp);
    }

    /**
     * @notice Emergency withdraw without full unwinding
     */
    function emergencyWithdraw(uint256 shares) 
        external 
        override 
        nonReentrant 
        returns (uint256 amount) 
    {
        if (shares == 0) revert ZeroAmount();
        if (balanceOf(msg.sender) < shares) revert InsufficientShares();
        
        // Simplified: return proportional base asset from vault balance
        uint256 vaultBalance = baseAsset.balanceOf(address(this));
        amount = (vaultBalance * shares) / totalSupply();
        
        _burn(msg.sender, shares);
        baseAsset.safeTransfer(msg.sender, amount);
        
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

    function previewDeposit(uint256 amount) public view override returns (uint256 shares) {
        uint256 supply = totalSupply();
        uint256 assets = totalAssets();
        
        if (supply == 0 || assets == 0) {
            // First deposit: 1:1 ratio
            shares = amount;
        } else {
            // Proportional to existing shares
            shares = (amount * supply) / assets;
        }
    }

    function previewWithdraw(uint256 shares) public view override returns (uint256 amount) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        
        // Proportional to total assets
        amount = (shares * totalAssets()) / supply;
    }

    function getSharePrice() external view override returns (uint256 price) {
        uint256 supply = totalSupply();
        if (supply == 0) return PRECISION;
        
        return (totalAssets() * PRECISION) / supply;
    }

    function getHealthFactor() public view override returns (uint256 healthFactor) {
        (,,,,, healthFactor) = aavePool.getUserAccountData(address(this));
        
        // If no debt, return max
        if (healthFactor == 0) {
            healthFactor = type(uint256).max;
        }
    }

    function getCurrentLeverage() public view override returns (uint256 leverage) {
        uint256 totalDebt = _getTotalDebt();
        uint256 assets = totalAssets();
        
        if (assets == 0) return PRECISION; // 1x if no assets
        
        // Leverage = (Assets + Debt) / Assets
        leverage = ((assets + totalDebt) * PRECISION) / assets;
    }

    function needsRebalance() public view override returns (bool needed) {
        uint256 hf = getHealthFactor();
        return hf < config.rebalanceThreshold && hf != type(uint256).max;
    }

    function totalAssets() public view override returns (uint256) {
        // Base asset in vault + value of LP position - debt
        uint256 vaultBalance = baseAsset.balanceOf(address(this));
        uint256 lpValue = _getLPValueInBase();
        uint256 debt = _getTotalDebt();
        
        // Net assets = vault + LP value - debt (converted to base)
        uint256 debtInBase = _convertQuoteToBase(debt);
        
        if (vaultBalance + lpValue > debtInBase) {
            return vaultBalance + lpValue - debtInBase;
        }
        return 0;
    }

    function balanceOf(address user) public view override(ERC20, IApollosVault) returns (uint256) {
        return super.balanceOf(user);
    }

    function totalSupply() public view override(ERC20, IApollosVault) returns (uint256) {
        return super.totalSupply();
    }

    // ============ Admin Functions ============

    function updateConfig(
        uint256 _targetLeverage,
        uint256 _maxLeverage,
        uint256 _rebalanceThreshold
    ) external override onlyOwner {
        config.targetLeverage = _targetLeverage;
        config.maxLeverage = _maxLeverage;
        config.rebalanceThreshold = _rebalanceThreshold;
    }

    function setPaused(bool _paused) external override onlyOwner {
        paused = _paused;
    }

    function setRebalancer(address rebalancer, bool authorized) external override onlyOwner {
        if (rebalancer == address(0)) revert ZeroAddress();
        authorizedRebalancers[rebalancer] = authorized;
    }

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
    }

    function setProtocolFee(uint256 _fee) external onlyOwner {
        if (_fee > 1000) revert(); // Max 10%
        protocolFee = _fee;
    }

    // ============ Internal Functions ============

    function _calculateBorrowAmount(uint256 baseAmount) internal view returns (uint256) {
        // For 2x leverage: borrow value equal to deposit
        // Convert base to quote using price oracle (simplified: use Aave prices)
        uint256 basePrice = aavePool.assetPrices(address(baseAsset));
        uint256 quotePrice = aavePool.assetPrices(address(quoteAsset));
        
        if (basePrice == 0 || quotePrice == 0) return 0;
        
        // Get decimals
        uint8 baseDecimals = _getDecimals(address(baseAsset));
        uint8 quoteDecimals = _getDecimals(address(quoteAsset));
        
        // borrowAmount = baseAmount * basePrice / quotePrice (adjusted for decimals)
        uint256 borrowValue = (baseAmount * basePrice) / (10 ** baseDecimals);
        uint256 borrowAmount = (borrowValue * (10 ** quoteDecimals)) / quotePrice;
        
        return borrowAmount;
    }

    function _addLiquidity(uint256 baseAmount, uint256 quoteAmount) 
        internal 
        returns (uint256 lpReceived) 
    {
        // Approve tokens to pool
        baseAsset.safeIncreaseAllowance(address(uniswapPool), baseAmount);
        quoteAsset.safeIncreaseAllowance(address(uniswapPool), quoteAmount);
        
        // Add liquidity - returns (amount0, amount1, liquidity)
        (,, lpReceived) = uniswapPool.addLiquidity(
            poolKey,
            baseAmount,
            quoteAmount,
            0, // minAmount0
            0  // minAmount1
        );
    }

    function _removeLiquidity(uint256 lpAmount) 
        internal 
        returns (uint256 baseReceived, uint256 quoteReceived) 
    {
        (baseReceived, quoteReceived) = uniswapPool.removeLiquidity(
            poolKey,
            lpAmount,
            0, // minAmount0
            0  // minAmount1
        );
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
        // Calculate LP to remove to bring leverage back to target
        uint256 currentLev = getCurrentLeverage();
        uint256 targetLev = config.targetLeverage;
        
        if (currentLev <= targetLev) return 0;
        
        // Remove proportional LP to reduce leverage
        uint256 excessLeverage = currentLev - targetLev;
        return (lpTokenBalance * excessLeverage) / currentLev;
    }

    function _getLPValueInBase() internal view returns (uint256) {
        // Query actual position value from Uniswap Pool
        PoolId poolId = poolKey.toId();
        
        (uint256 amount0, uint256 amount1) = uniswapPool.getPositionValue(
            poolId,
            address(this)
        );
        
        // amount0 = base asset (WETH), amount1 = quote asset (USDC)
        // Convert quote to base and add together for total value in base terms
        uint256 quoteValueInBase = _convertQuoteToBase(amount1);
        
        return amount0 + quoteValueInBase;
    }

    function _convertQuoteToBase(uint256 quoteAmount) internal view returns (uint256) {
        uint256 basePrice = aavePool.assetPrices(address(baseAsset));
        uint256 quotePrice = aavePool.assetPrices(address(quoteAsset));
        
        if (basePrice == 0) return 0;
        
        uint8 baseDecimals = _getDecimals(address(baseAsset));
        uint8 quoteDecimals = _getDecimals(address(quoteAsset));
        
        // Convert quote to base: quoteAmount * quotePrice / basePrice
        uint256 quoteValue = (quoteAmount * quotePrice) / (10 ** quoteDecimals);
        return (quoteValue * (10 ** baseDecimals)) / basePrice;
    }

    function _getDecimals(address token) internal view returns (uint8) {
        try IERC20Metadata(token).decimals() returns (uint8 decimals) {
            return decimals;
        } catch {
            return 18;
        }
    }
}

// Interface for ERC20 decimals
interface IERC20Metadata {
    function decimals() external view returns (uint8);
}
