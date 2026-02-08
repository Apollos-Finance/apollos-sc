// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// V4 Core Types
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {IMockUniswapPool} from "../interfaces/IMockUniswapPool.sol";

/**
 * @title MockUniswapPool
 * @notice V4 Hybrid Architecture - Uses V4 types/hooks but simplified AMM (x*y=k)
 * @dev Features:
 *      - V4 PoolKey/Currency/PoolId types for compatibility
 *      - Calls IHooks.beforeSwap() for dynamic fee from LVRHook
 *      - Calls IHooks.beforeAddLiquidity() for whitelist check
 *      - Simplified constant product AMM (no ticks/sqrtPrice)
 */
contract MockUniswapPool is IMockUniswapPool, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    // ============ Constants ============
    uint24 public constant MAX_FEE = 1_000_000; // 100% in V4 format (1e6)
    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    
    // Flag to indicate dynamic fee override from hook (bit 24 = 0x800000)
    // MUST match OVERRIDE_FEE_FLAG in LVRHook.sol
    uint24 public constant DYNAMIC_FEE_FLAG = 0x800000;

    // ============ State Variables ============
    mapping(PoolId => PoolState) private pools;
    mapping(PoolId => mapping(address => LiquidityPosition)) private positions;
    mapping(address => bool) public whitelistedVaults;

    // ============ Constructor ============
    constructor() Ownable(msg.sender) {}

    // ============ Modifiers ============
    modifier poolExists(PoolId id) {
        if (Currency.unwrap(pools[id].currency0) == address(0)) revert PoolDoesNotExist();
        _;
    }

    modifier poolActive(PoolId id) {
        if (!pools[id].isActive) revert PoolNotActive();
        _;
    }

    modifier onlyWhitelistedVault() {
        if (!whitelistedVaults[msg.sender]) revert NotWhitelistedVault();
        _;
    }

    // ============ Pool Management (V4 Style) ============

    /// @inheritdoc IMockUniswapPool
    function initialize(PoolKey memory key) external onlyOwner returns (PoolId poolId) {
        // Validate currencies are in order (V4 requirement)
        if (key.currency0 >= key.currency1) revert CurrenciesOutOfOrder();
        if (key.fee > MAX_FEE) revert InvalidFee();

        poolId = key.toId();
        if (Currency.unwrap(pools[poolId].currency0) != address(0)) revert PoolAlreadyExists();

        pools[poolId] = PoolState({
            currency0: key.currency0,
            currency1: key.currency1,
            reserve0: 0,
            reserve1: 0,
            totalLiquidity: 0,
            baseFee: key.fee,
            tickSpacing: key.tickSpacing,
            hooks: key.hooks,
            isActive: true
        });

        emit PoolInitialized(poolId, key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks);
    }

    /// @inheritdoc IMockUniswapPool
    function getPoolState(PoolId id) external view returns (PoolState memory) {
        return pools[id];
    }

    /// @inheritdoc IMockUniswapPool
    function getPoolStateByKey(PoolKey memory key) external view returns (PoolState memory) {
        return pools[key.toId()];
    }

    // ============ Liquidity Functions ============

    /// @inheritdoc IMockUniswapPool
    function addLiquidity(
        PoolKey memory key,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) external 
      nonReentrant 
      returns (uint256 amount0, uint256 amount1, uint256 liquidity) 
    {
        PoolId id = key.toId();
        if (Currency.unwrap(pools[id].currency0) == address(0)) revert PoolDoesNotExist();
        if (!pools[id].isActive) revert PoolNotActive();
        if (amount0Desired == 0 || amount1Desired == 0) revert ZeroAmount();

        PoolState storage pool = pools[id];

        // Call beforeAddLiquidity hook for whitelist verification
        if (address(pool.hooks) != address(0)) {
            IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
                tickLower: -887220,  // Full range for simplified AMM
                tickUpper: 887220,
                liquidityDelta: int256(amount0Desired), // Placeholder
                salt: bytes32(0)
            });

            try pool.hooks.beforeAddLiquidity(msg.sender, key, params, "") returns (bytes4 selector) {
                if (selector != IHooks.beforeAddLiquidity.selector) revert NotWhitelistedVault();
            } catch {
                revert NotWhitelistedVault();
            }
        } else {
            // Fallback: check whitelist directly if no hook
            if (!whitelistedVaults[msg.sender]) revert NotWhitelistedVault();
        }

        // Calculate optimal amounts based on current reserves
        if (pool.reserve0 == 0 && pool.reserve1 == 0) {
            // First liquidity provision
            amount0 = amount0Desired;
            amount1 = amount1Desired;
            liquidity = _sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            pool.totalLiquidity += MINIMUM_LIQUIDITY;
        } else {
            // Calculate optimal ratio
            uint256 amount1Optimal = (amount0Desired * pool.reserve1) / pool.reserve0;
            
            if (amount1Optimal <= amount1Desired) {
                if (amount1Optimal < amount1Min) revert SlippageExceeded();
                amount0 = amount0Desired;
                amount1 = amount1Optimal;
            } else {
                uint256 amount0Optimal = (amount1Desired * pool.reserve0) / pool.reserve1;
                if (amount0Optimal < amount0Min) revert SlippageExceeded();
                amount0 = amount0Optimal;
                amount1 = amount1Desired;
            }

            // Calculate liquidity based on the smaller ratio
            uint256 liquidity0 = (amount0 * pool.totalLiquidity) / pool.reserve0;
            uint256 liquidity1 = (amount1 * pool.totalLiquidity) / pool.reserve1;
            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        }

        // Transfer tokens from provider
        IERC20(Currency.unwrap(pool.currency0)).safeTransferFrom(msg.sender, address(this), amount0);
        IERC20(Currency.unwrap(pool.currency1)).safeTransferFrom(msg.sender, address(this), amount1);

        // Update state
        pool.reserve0 += amount0;
        pool.reserve1 += amount1;
        pool.totalLiquidity += liquidity;

        // Update position
        LiquidityPosition storage pos = positions[id][msg.sender];
        pos.liquidity += liquidity;
        pos.token0Deposited += amount0;
        pos.token1Deposited += amount1;

        emit LiquidityModified(id, msg.sender, int256(liquidity), amount0, amount1);
    }

    /// @inheritdoc IMockUniswapPool
    function removeLiquidity(
        PoolKey memory key,
        uint256 liquidity,
        uint256 amount0Min,
        uint256 amount1Min
    ) external 
      nonReentrant 
      returns (uint256 amount0, uint256 amount1) 
    {
        PoolId id = key.toId();
        if (Currency.unwrap(pools[id].currency0) == address(0)) revert PoolDoesNotExist();
        if (liquidity == 0) revert ZeroAmount();

        PoolState storage pool = pools[id];
        LiquidityPosition storage pos = positions[id][msg.sender];

        if (pos.liquidity < liquidity) revert InsufficientLiquidity();

        // Calculate amounts to return
        amount0 = (liquidity * pool.reserve0) / pool.totalLiquidity;
        amount1 = (liquidity * pool.reserve1) / pool.totalLiquidity;

        if (amount0 < amount0Min || amount1 < amount1Min) revert SlippageExceeded();

        // Update state
        pool.reserve0 -= amount0;
        pool.reserve1 -= amount1;
        pool.totalLiquidity -= liquidity;

        // Update position
        pos.liquidity -= liquidity;
        
        // Transfer tokens back
        IERC20(Currency.unwrap(pool.currency0)).safeTransfer(msg.sender, amount0);
        IERC20(Currency.unwrap(pool.currency1)).safeTransfer(msg.sender, amount1);

        emit LiquidityModified(id, msg.sender, -int256(liquidity), amount0, amount1);
    }

    /// @inheritdoc IMockUniswapPool
    function getPosition(
        PoolId id,
        address provider
    ) external view returns (LiquidityPosition memory) {
        return positions[id][provider];
    }

    // ============ Swap Functions (V4 Style with Hook) ============

    /// @inheritdoc IMockUniswapPool
    function swap(
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 /* sqrtPriceLimitX96 */
    ) external 
      nonReentrant 
      returns (uint256 amountIn, uint256 amountOut) 
    {
        PoolId id = key.toId();
        if (Currency.unwrap(pools[id].currency0) == address(0)) revert PoolDoesNotExist();
        if (!pools[id].isActive) revert PoolNotActive();
        if (amountSpecified == 0) revert ZeroAmount();

        PoolState storage pool = pools[id];
        
        // Determine actual fee by calling beforeSwap hook
        uint24 effectiveFee = pool.baseFee;
        
        if (address(pool.hooks) != address(0)) {
            IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: 0
            });

            try pool.hooks.beforeSwap(msg.sender, key, params, "") 
                returns (bytes4 selector, BeforeSwapDelta, uint24 hookFee) 
            {
                if (selector == IHooks.beforeSwap.selector) {
                    // Check if hook returned a fee override (bit 23 set)
                    if ((hookFee & DYNAMIC_FEE_FLAG) != 0) {
                        // Extract the actual fee (lower 23 bits)
                        effectiveFee = hookFee & 0x7FFFFF;
                    } else if (hookFee > 0) {
                        effectiveFee = hookFee;
                    }
                }
            } catch {
                // Hook call failed, use base fee
            }
        }

        // Cap effective fee
        if (effectiveFee > MAX_FEE) effectiveFee = uint24(MAX_FEE);

        // For simplified AMM, only support exactIn (negative amountSpecified means exactIn in V4)
        bool exactIn = amountSpecified < 0;
        uint256 absAmount = exactIn ? uint256(-amountSpecified) : uint256(amountSpecified);

        // Calculate swap using constant product formula
        if (exactIn) {
            amountIn = absAmount;
            (amountOut,) = _calculateSwapOutput(pool, zeroForOne, amountIn, effectiveFee);
        } else {
            // exactOut: calculate required input
            amountOut = absAmount;
            amountIn = _calculateSwapInput(pool, zeroForOne, amountOut, effectiveFee);
        }

        if (amountOut == 0) revert InsufficientOutputAmount();

        // Execute transfers
        Currency currencyIn = zeroForOne ? pool.currency0 : pool.currency1;
        Currency currencyOut = zeroForOne ? pool.currency1 : pool.currency0;

        IERC20(Currency.unwrap(currencyIn)).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(Currency.unwrap(currencyOut)).safeTransfer(msg.sender, amountOut);

        // Update reserves (fee stays in pool)
        uint256 feeAmount = (amountIn * effectiveFee) / MAX_FEE;
        uint256 amountInAfterFee = amountIn - feeAmount;

        if (zeroForOne) {
            pool.reserve0 += amountInAfterFee;
            pool.reserve1 -= amountOut;
        } else {
            pool.reserve1 += amountInAfterFee;
            pool.reserve0 -= amountOut;
        }

        emit Swap(id, msg.sender, zeroForOne, amountSpecified, amountIn, amountOut, effectiveFee);
    }

    /// @inheritdoc IMockUniswapPool
    function getSwapQuote(
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn
    ) external view returns (uint256 amountOut, uint256 feeAmount) {
        PoolId id = key.toId();
        if (Currency.unwrap(pools[id].currency0) == address(0)) revert PoolDoesNotExist();

        PoolState storage pool = pools[id];
        
        // Use base fee for quote (hook fee is dynamic)
        uint24 fee = pool.baseFee;
        
        (amountOut, feeAmount) = _calculateSwapOutput(pool, zeroForOne, amountIn, fee);
    }

    /**
     * @dev Calculate swap output using constant product formula (x * y = k)
     */
    function _calculateSwapOutput(
        PoolState storage pool,
        bool zeroForOne,
        uint256 amountIn,
        uint24 fee
    ) internal view returns (uint256 amountOut, uint256 feeAmount) {
        uint256 reserveIn = zeroForOne ? pool.reserve0 : pool.reserve1;
        uint256 reserveOut = zeroForOne ? pool.reserve1 : pool.reserve0;

        // Calculate fee
        feeAmount = (amountIn * fee) / MAX_FEE;
        uint256 amountInAfterFee = amountIn - feeAmount;

        // Constant product formula: (x + dx) * (y - dy) = x * y
        // dy = y * dx / (x + dx)
        amountOut = (reserveOut * amountInAfterFee) / (reserveIn + amountInAfterFee);
    }

    /**
     * @dev Calculate required input for exact output swap
     */
    function _calculateSwapInput(
        PoolState storage pool,
        bool zeroForOne,
        uint256 amountOut,
        uint24 fee
    ) internal view returns (uint256 amountIn) {
        uint256 reserveIn = zeroForOne ? pool.reserve0 : pool.reserve1;
        uint256 reserveOut = zeroForOne ? pool.reserve1 : pool.reserve0;

        if (amountOut >= reserveOut) revert InsufficientLiquidity();

        // Inverse of constant product: dx = x * dy / (y - dy)
        uint256 amountInBeforeFee = (reserveIn * amountOut) / (reserveOut - amountOut);
        
        // Add fee: amountIn = amountInBeforeFee / (1 - fee)
        amountIn = (amountInBeforeFee * MAX_FEE) / (MAX_FEE - fee);
    }

    // ============ Vault Whitelist ============

    /// @inheritdoc IMockUniswapPool
    function setWhitelistedVault(address vault, bool status) external onlyOwner {
        whitelistedVaults[vault] = status;
        emit WhitelistedVaultUpdated(vault, status);
    }

    /// @inheritdoc IMockUniswapPool
    function isWhitelistedVault(address vault) external view returns (bool) {
        return whitelistedVaults[vault];
    }

    // ============ Price Functions ============

    /// @inheritdoc IMockUniswapPool
    function getPrice(PoolId id) external view poolExists(id) returns (uint256) {
        PoolState storage pool = pools[id];
        if (pool.reserve0 == 0) return 0;
        // Price of currency0 in terms of currency1 (with 18 decimals precision)
        return (pool.reserve1 * 1e18) / pool.reserve0;
    }

    /// @inheritdoc IMockUniswapPool
    function getReserves(PoolId id) external view poolExists(id) returns (uint256, uint256) {
        PoolState storage pool = pools[id];
        return (pool.reserve0, pool.reserve1);
    }

    // ============ Internal Helpers ============

    /**
     * @dev Babylonian method for square root
     */
    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    // ============ Emergency Functions ============

    /**
     * @notice Toggle pool active status
     * @param id The pool identifier
     * @param active New active status
     */
    function setPoolActive(PoolId id, bool active) external onlyOwner poolExists(id) {
        pools[id].isActive = active;
    }
}
