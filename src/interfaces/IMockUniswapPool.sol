// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/**
 * @title IMockUniswapPool
 * @notice Interface for the Simulated Uniswap V4 Pool used by Apollos.
 * @author Apollos Team
 * @dev This mock implements a hybrid V4 architecture:
 *      - Uses official V4 types for full compatibility with existing libraries.
 *      - Implements key Hook callbacks (beforeSwap, beforeAddLiquidity).
 *      - Provides a simplified AMM engine suitable for testing leveraged yield logic.
 */
interface IMockUniswapPool {
    /**
     * @notice State variables for an individual liquidity pool.
     * @param currency0 The address of the first token in the pair (lower address).
     * @param currency1 The address of the second token in the pair.
     * @param reserve0 Current balance of currency0 in the AMM.
     * @param reserve1 Current balance of currency1 in the AMM.
     * @param totalLiquidity Total supply of LP shares for this pool.
     * @param baseFee The standard swap fee in basis points (e.g., 30 = 0.3%).
     * @param tickSpacing Tick spacing for V4 compatibility (unused in this simplified AMM).
     * @param hooks The address of the IHooks contract (e.g., LVRHook).
     * @param isActive True if the pool is accepting trades and liquidity.
     */
    struct PoolState {
        Currency currency0;
        Currency currency1;
        uint256 reserve0;
        uint256 reserve1;
        uint256 totalLiquidity;
        uint24 baseFee;
        int24 tickSpacing;
        IHooks hooks;
        bool isActive;
    }

    /**
     * @notice Tracks an individual provider's stake in a pool.
     * @param liquidity Number of LP shares owned by the provider.
     * @param token0Deposited Aggregate amount of token0 provided.
     * @param token1Deposited Aggregate amount of token1 provided.
     */
    struct LiquidityPosition {
        uint256 liquidity;
        uint256 token0Deposited;
        uint256 token1Deposited;
    }

    /**
     * @notice Emitted when a new liquidity pool is initialized.
     */
    event PoolInitialized(
        PoolId indexed id,
        Currency indexed currency0,
        Currency indexed currency1,
        uint24 fee,
        int24 tickSpacing,
        IHooks hooks
    );

    /**
     * @notice Emitted when liquidity is added or removed from a pool.
     */
    event LiquidityModified(
        PoolId indexed id, address indexed provider, int256 liquidityDelta, uint256 amount0, uint256 amount1
    );

    /**
     * @notice Emitted when a swap is successfully executed.
     */
    event Swap(
        PoolId indexed id,
        address indexed sender,
        bool zeroForOne,
        int256 amountSpecified,
        uint256 amountIn,
        uint256 amountOut,
        uint24 feeApplied
    );

    /**
     * @notice Emitted when a vault's whitelist status for adding liquidity is updated.
     */
    event WhitelistedVaultUpdated(address indexed vault, bool status);

    /// @notice Thrown when attempting to initialize a pool that already exists.
    error PoolAlreadyExists();

    /// @notice Thrown when an operation is performed on a non-existent pool.
    error PoolDoesNotExist();

    /// @notice Thrown when a pool is currently deactivated.
    error PoolNotActive();

    /// @notice Thrown when a withdrawal exceeds available pool or position liquidity.
    error InsufficientLiquidity();

    /// @notice Thrown when the provided swap input is zero or insufficient.
    error InsufficientInputAmount();

    /// @notice Thrown when a swap would result in zero output.
    error InsufficientOutputAmount();

    /// @notice Thrown when an unsupported currency address is provided.
    error InvalidCurrency();

    /// @notice Thrown when a zero amount is provided for a trade or liquidity action.
    error ZeroAmount();

    /// @notice Thrown when a non-whitelisted address attempts to provide liquidity.
    error NotWhitelistedVault();

    /// @notice Thrown when an operation would exceed the user's slippage tolerance.
    error SlippageExceeded();

    /// @notice Thrown when an invalid fee value is provided.
    error InvalidFee();

    /// @notice Thrown when currencies are provided in the wrong address order.
    error CurrenciesOutOfOrder();

    /// @notice Thrown when an external V4 Hook callback fails.
    error HookCallFailed();

    /**
     * @notice Initializes a new pool with V4 parameters.
     * @param key The configuration key for the pool.
     * @return poolId The unique identifier generated from the key.
     */
    function initialize(PoolKey memory key) external returns (PoolId poolId);

    /**
     * @notice Returns the current state of a pool.
     */
    function getPoolState(PoolId id) external view returns (PoolState memory state);

    /**
     * @notice Returns the current state of a pool by its key.
     */
    function getPoolStateByKey(PoolKey memory key) external view returns (PoolState memory state);

    /**
     * @notice Adds liquidity to a pool.
     * @dev Restricted to whitelisted vault addresses.
     * @param key The pool configuration.
     * @param amount0Desired Target amount of token0.
     * @param amount1Desired Target amount of token1.
     * @param amount0Min Minimum token0 to deposit (slippage).
     * @param amount1Min Minimum token1 to deposit (slippage).
     * @return amount0 Actual token0 deposited.
     * @return amount1 Actual token1 deposited.
     * @return liquidity LP shares minted.
     */
    function addLiquidity(
        PoolKey memory key,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) external returns (uint256 amount0, uint256 amount1, uint256 liquidity);

    /**
     * @notice Removes liquidity and burns LP shares.
     * @param key The pool configuration.
     * @param liquidity Number of shares to burn.
     * @return amount0 Amount of token0 returned.
     * @return amount1 Amount of token1 returned.
     */
    function removeLiquidity(PoolKey memory key, uint256 liquidity, uint256 amount0Min, uint256 amount1Min)
        external
        returns (uint256 amount0, uint256 amount1);

    /**
     * @notice Returns the liquidity position details for a specific provider.
     */
    function getPosition(PoolId id, address provider) external view returns (LiquidityPosition memory position);

    /**
     * @notice Executes a token swap, potentially triggering a V4 dynamic fee hook.
     * @param key The pool configuration.
     * @param zeroForOne Direction (true for token0 -> token1).
     * @param amountSpecified Exact input (negative) or exact output (positive) amount.
     * @return amountIn Final amount sold.
     * @return amountOut Final amount purchased.
     */
    function swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        external
        returns (uint256 amountIn, uint256 amountOut);

    /**
     * @notice Returns a quote for a potential swap, including hook-calculated fees.
     */
    function getSwapQuote(PoolKey memory key, bool zeroForOne, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint256 feeAmount);

    /**
     * @notice Grants or revokes liquidity provision authority for a vault.
     */
    function setWhitelistedVault(address vault, bool status) external;

    /**
     * @notice Checks if a vault is authorized to provide liquidity.
     */
    function isWhitelistedVault(address vault) external view returns (bool isWhitelisted);

    /**
     * @notice Returns the current spot price of token0 relative to token1.
     * @dev Precision is 1e18.
     */
    function getPrice(PoolId id) external view returns (uint256 price);

    /**
     * @notice Returns the current liquid reserves of the pool.
     */
    function getReserves(PoolId id) external view returns (uint256 reserve0, uint256 reserve1);

    /**
     * @notice Calculates the underlying token values of a provider's LP position.
     */
    function getPositionValue(PoolId id, address provider) external view returns (uint256 amount0, uint256 amount1);
}
