// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/**
 * @title IMockUniswapPool
 * @notice Interface for MockUniswapPool - V4 Hybrid Architecture
 * @dev Uses V4 types (PoolKey, Currency) but simplified AMM logic (x*y=k)
 *      Integrates with LVRHook for dynamic fee via beforeSwap callback
 */
interface IMockUniswapPool {
    // ============ Structs ============
    struct PoolState {
        Currency currency0;
        Currency currency1;
        uint256 reserve0;
        uint256 reserve1;
        uint256 totalLiquidity;
        uint24 baseFee;         // Base swap fee in bps (e.g., 30 = 0.3%)
        int24 tickSpacing;      // V4 compatibility
        IHooks hooks;           // LVRHook address
        bool isActive;
    }

    struct LiquidityPosition {
        uint256 liquidity;
        uint256 token0Deposited;
        uint256 token1Deposited;
    }

    // ============ Events ============
    event PoolInitialized(
        PoolId indexed id,
        Currency indexed currency0,
        Currency indexed currency1,
        uint24 fee,
        int24 tickSpacing,
        IHooks hooks
    );

    event LiquidityModified(
        PoolId indexed id,
        address indexed provider,
        int256 liquidityDelta,
        uint256 amount0,
        uint256 amount1
    );

    event Swap(
        PoolId indexed id,
        address indexed sender,
        bool zeroForOne,
        int256 amountSpecified,
        uint256 amountIn,
        uint256 amountOut,
        uint24 feeApplied
    );

    event WhitelistedVaultUpdated(address indexed vault, bool status);

    // ============ Errors ============
    error PoolAlreadyExists();
    error PoolDoesNotExist();
    error PoolNotActive();
    error InsufficientLiquidity();
    error InsufficientInputAmount();
    error InsufficientOutputAmount();
    error InvalidCurrency();
    error ZeroAmount();
    error NotWhitelistedVault();
    error SlippageExceeded();
    error InvalidFee();
    error CurrenciesOutOfOrder();
    error HookCallFailed();

    // ============ Pool Management (V4 Style) ============
    
    /**
     * @notice Initialize a new pool (V4 style)
     * @param key The PoolKey containing currencies, fee, tickSpacing, and hooks
     * @return poolId The unique identifier for the pool
     */
    function initialize(PoolKey memory key) external returns (PoolId poolId);

    /**
     * @notice Get pool state by PoolId
     * @param id The pool identifier
     * @return state Pool state struct
     */
    function getPoolState(PoolId id) external view returns (PoolState memory state);

    /**
     * @notice Get pool state by PoolKey
     * @param key The pool key
     * @return state Pool state struct
     */
    function getPoolStateByKey(PoolKey memory key) external view returns (PoolState memory state);

    // ============ Liquidity Functions ============

    /**
     * @notice Add liquidity to pool (restricted to whitelisted vaults)
     * @param key The pool key
     * @param amount0Desired Desired amount of currency0
     * @param amount1Desired Desired amount of currency1
     * @param amount0Min Minimum amount of currency0 (slippage protection)
     * @param amount1Min Minimum amount of currency1 (slippage protection)
     * @return amount0 Actual amount of currency0 deposited
     * @return amount1 Actual amount of currency1 deposited
     * @return liquidity LP tokens minted
     */
    function addLiquidity(
        PoolKey memory key,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) external returns (uint256 amount0, uint256 amount1, uint256 liquidity);

    /**
     * @notice Remove liquidity from pool
     * @param key The pool key
     * @param liquidity Amount of LP tokens to burn
     * @param amount0Min Minimum amount of currency0 to receive
     * @param amount1Min Minimum amount of currency1 to receive
     * @return amount0 Amount of currency0 received
     * @return amount1 Amount of currency1 received
     */
    function removeLiquidity(
        PoolKey memory key,
        uint256 liquidity,
        uint256 amount0Min,
        uint256 amount1Min
    ) external returns (uint256 amount0, uint256 amount1);

    /**
     * @notice Get liquidity position for a provider
     * @param id The pool identifier
     * @param provider Address of the liquidity provider
     * @return position The liquidity position
     */
    function getPosition(
        PoolId id,
        address provider
    ) external view returns (LiquidityPosition memory position);

    // ============ Swap Functions (V4 Style with Hook) ============

    /**
     * @notice Execute a swap - calls Hook.beforeSwap for dynamic fee
     * @param key The pool key
     * @param zeroForOne Direction: true = currency0 -> currency1
     * @param amountSpecified Amount (negative = exactIn, positive = exactOut)
     * @param sqrtPriceLimitX96 Price limit (ignored in simplified AMM, for V4 compat)
     * @return amountIn Amount of input tokens
     * @return amountOut Amount of output tokens
     */
    function swap(
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 amountIn, uint256 amountOut);

    /**
     * @notice Get quote for swap (includes hook fee calculation)
     * @param key The pool key
     * @param zeroForOne Direction of swap
     * @param amountIn Amount of input tokens
     * @return amountOut Expected output amount
     * @return feeAmount Fee amount deducted
     */
    function getSwapQuote(
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn
    ) external view returns (uint256 amountOut, uint256 feeAmount);

    // ============ Vault Whitelist (Restricted Deposit) ============

    /**
     * @notice Add or remove vault from whitelist
     * @param vault Address of the ApollosVault
     * @param status True to whitelist, false to remove
     */
    function setWhitelistedVault(address vault, bool status) external;

    /**
     * @notice Check if vault is whitelisted
     * @param vault Address to check
     * @return isWhitelisted True if whitelisted
     */
    function isWhitelistedVault(address vault) external view returns (bool isWhitelisted);

    // ============ Price Functions ============

    /**
     * @notice Get current price of currency0 in terms of currency1
     * @param id The pool identifier
     * @return price Price with 18 decimals precision
     */
    function getPrice(PoolId id) external view returns (uint256 price);

    /**
     * @notice Get reserves for a pool
     * @param id The pool identifier
     * @return reserve0 Reserve of currency0
     * @return reserve1 Reserve of currency1
     */
    function getReserves(PoolId id) external view returns (uint256 reserve0, uint256 reserve1);
}
