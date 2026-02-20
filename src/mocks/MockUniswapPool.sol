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
 * @notice Simplified Uniswap V4 Pool simulation for Apollos.
 * @author Apollos Team
 * @dev Employs a Hybrid V4 Architecture:
 *      - Uses official V4 types (PoolKey, Currency, PoolId) for compatibility.
 *      - Implements Hook callbacks (beforeSwap, beforeAddLiquidity) to test LVRHook logic.
 *      - Uses a simplified constant product AMM formula (x * y = k) instead of full tick-based logic.
 */
contract MockUniswapPool is IMockUniswapPool, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    /// @notice Maximum allowed fee in basis points (100% = 1,000,000)
    uint24 public constant MAX_FEE = 1_000_000;

    /// @notice Minimum liquidity to be locked on first deposit
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    /// @notice Bitmask flag to identify dynamic fee overrides from hooks
    /// @dev Corresponds to OVERRIDE_FEE_FLAG in LVRHook.sol
    uint24 public constant DYNAMIC_FEE_FLAG = 0x800000;

    /// @notice Maps pool identifier to its current state
    mapping(PoolId => PoolState) private pools;

    /// @notice Maps pool identifier to provider to their liquidity position
    mapping(PoolId => mapping(address => LiquidityPosition)) private positions;

    /// @notice Maps address to its whitelisted status for liquidity provision
    mapping(address => bool) public whitelistedVaults;

    /**
     * @notice Initializes the MockUniswapPool
     */
    constructor() Ownable(msg.sender) {}

    /// @dev Ensures the pool has been initialized
    modifier poolExists(PoolId id) {
        if (Currency.unwrap(pools[id].currency0) == address(0)) revert PoolDoesNotExist();
        _;
    }

    /// @dev Ensures the pool is currently active
    modifier poolActive(PoolId id) {
        if (!pools[id].isActive) revert PoolNotActive();
        _;
    }

    /// @dev Restricts access to whitelisted vault addresses
    modifier onlyWhitelistedVault() {
        if (!whitelistedVaults[msg.sender]) revert NotWhitelistedVault();
        _;
    }

    /**
     * @notice Initializes a new pool with the specified parameters
     * @param key The V4 PoolKey defining the pair, fee, spacing, and hooks
     * @return poolId The generated unique identifier for the pool
     */
    function initialize(PoolKey memory key) external onlyOwner returns (PoolId poolId) {
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

    /**
     * @notice Returns the current state of a pool by ID
     */
    function getPoolState(PoolId id) external view returns (PoolState memory) {
        return pools[id];
    }

    /**
     * @notice Returns the current state of a pool by Key
     */
    function getPoolStateByKey(PoolKey memory key) external view returns (PoolState memory) {
        return pools[key.toId()];
    }

    /**
     * @notice Adds liquidity to an existing pool
     * @dev Triggers the beforeAddLiquidity hook if configured
     * @param key Pool definition
     * @param amount0Desired Target amount for token0
     * @param amount1Desired Target amount for token1
     * @param amount0Min Minimum amount for token0 (slippage)
     * @param amount1Min Minimum amount for token1 (slippage)
     * @return amount0 Actual amount of token0 deposited
     * @return amount1 Actual amount of token1 deposited
     * @return liquidity Amount of liquidity shares minted
     */
    function addLiquidity(
        PoolKey memory key,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) external nonReentrant returns (uint256 amount0, uint256 amount1, uint256 liquidity) {
        PoolId id = key.toId();
        if (Currency.unwrap(pools[id].currency0) == address(0)) revert PoolDoesNotExist();
        if (!pools[id].isActive) revert PoolNotActive();
        if (amount0Desired == 0 || amount1Desired == 0) revert ZeroAmount();

        PoolState storage pool = pools[id];

        // Trigger V4 Hook if present
        if (address(pool.hooks) != address(0)) {
            IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
                tickLower: -887220, tickUpper: 887220, liquidityDelta: int256(amount0Desired), salt: bytes32(0)
            });

            try pool.hooks.beforeAddLiquidity(msg.sender, key, params, "") returns (bytes4 selector) {
                if (selector != IHooks.beforeAddLiquidity.selector) revert NotWhitelistedVault();
            } catch {
                revert NotWhitelistedVault();
            }
        } else {
            if (!whitelistedVaults[msg.sender]) revert NotWhitelistedVault();
        }

        // AMM Logic
        if (pool.reserve0 == 0 && pool.reserve1 == 0) {
            amount0 = amount0Desired;
            amount1 = amount1Desired;
            liquidity = _sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            pool.totalLiquidity += MINIMUM_LIQUIDITY;
        } else {
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

            uint256 liquidity0 = (amount0 * pool.totalLiquidity) / pool.reserve0;
            uint256 liquidity1 = (amount1 * pool.totalLiquidity) / pool.reserve1;
            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        }

        IERC20(Currency.unwrap(pool.currency0)).safeTransferFrom(msg.sender, address(this), amount0);
        IERC20(Currency.unwrap(pool.currency1)).safeTransferFrom(msg.sender, address(this), amount1);

        pool.reserve0 += amount0;
        pool.reserve1 += amount1;
        pool.totalLiquidity += liquidity;

        LiquidityPosition storage pos = positions[id][msg.sender];
        pos.liquidity += liquidity;
        pos.token0Deposited += amount0;
        pos.token1Deposited += amount1;

        emit LiquidityModified(id, msg.sender, int256(liquidity), amount0, amount1);
    }

    /**
     * @notice Removes liquidity from a pool
     * @param key Pool definition
     * @param liquidity Amount of shares to burn
     * @param amount0Min Minimum amount of token0 to receive
     * @param amount1Min Minimum amount of token1 to receive
     * @return amount0 Actual amount of token0 received
     * @return amount1 Actual amount of token1 received
     */
    function removeLiquidity(PoolKey memory key, uint256 liquidity, uint256 amount0Min, uint256 amount1Min)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        PoolId id = key.toId();
        if (Currency.unwrap(pools[id].currency0) == address(0)) revert PoolDoesNotExist();
        if (liquidity == 0) revert ZeroAmount();

        PoolState storage pool = pools[id];
        LiquidityPosition storage pos = positions[id][msg.sender];

        if (pos.liquidity < liquidity) revert InsufficientLiquidity();

        amount0 = (liquidity * pool.reserve0) / pool.totalLiquidity;
        amount1 = (liquidity * pool.reserve1) / pool.totalLiquidity;

        if (amount0 < amount0Min || amount1 < amount1Min) revert SlippageExceeded();

        pool.reserve0 -= amount0;
        pool.reserve1 -= amount1;
        pool.totalLiquidity -= liquidity;

        pos.liquidity -= liquidity;

        IERC20(Currency.unwrap(pool.currency0)).safeTransfer(msg.sender, amount0);
        IERC20(Currency.unwrap(pool.currency1)).safeTransfer(msg.sender, amount1);

        emit LiquidityModified(id, msg.sender, -int256(liquidity), amount0, amount1);
    }

    /**
     * @notice Returns the liquidity position of a specific provider
     */
    function getPosition(PoolId id, address provider) external view returns (LiquidityPosition memory) {
        return positions[id][provider];
    }

    /**
     * @notice Executes a token swap
     * @dev Triggers the beforeSwap hook to determine the dynamic fee
     * @param key Pool definition
     * @param zeroForOne Swap direction (true: sell token0, false: sell token1)
     * @param amountSpecified Amount to swap (negative for exact-in, positive for exact-out)
     * @return amountIn Actual amount transferred in
     * @return amountOut Actual amount transferred out
     */
    function swap(
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 /* sqrtPriceLimitX96 */
    )
        external
        nonReentrant
        returns (uint256 amountIn, uint256 amountOut)
    {
        PoolId id = key.toId();
        if (Currency.unwrap(pools[id].currency0) == address(0)) revert PoolDoesNotExist();
        if (!pools[id].isActive) revert PoolNotActive();
        if (amountSpecified == 0) revert ZeroAmount();

        PoolState storage pool = pools[id];

        uint24 effectiveFee = pool.baseFee;

        // Trigger V4 Hook if present
        if (address(pool.hooks) != address(0)) {
            IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
                zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: 0
            });

            try pool.hooks.beforeSwap(msg.sender, key, params, "") returns (
                bytes4 selector, BeforeSwapDelta, uint24 hookFee
            ) {
                if (selector == IHooks.beforeSwap.selector) {
                    if ((hookFee & DYNAMIC_FEE_FLAG) != 0) {
                        // Extract the actual fee (lower 23 bits)
                        effectiveFee = hookFee & 0x7FFFFF;
                    } else if (hookFee > 0) {
                        effectiveFee = hookFee;
                    }
                }
            } catch {
                // Silently fallback to baseFee on hook error for testing
            }
        }

        if (effectiveFee > MAX_FEE) effectiveFee = uint24(MAX_FEE);

        bool exactIn = amountSpecified < 0;
        uint256 absAmount = exactIn ? uint256(-amountSpecified) : uint256(amountSpecified);

        if (exactIn) {
            amountIn = absAmount;
            (amountOut,) = _calculateSwapOutput(pool, zeroForOne, amountIn, effectiveFee);
        } else {
            amountOut = absAmount;
            amountIn = _calculateSwapInput(pool, zeroForOne, amountOut, effectiveFee);
        }

        if (amountOut == 0) revert InsufficientOutputAmount();

        Currency currencyIn = zeroForOne ? pool.currency0 : pool.currency1;
        Currency currencyOut = zeroForOne ? pool.currency1 : pool.currency0;

        IERC20(Currency.unwrap(currencyIn)).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(Currency.unwrap(currencyOut)).safeTransfer(msg.sender, amountOut);

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

    /**
     * @notice Returns a quote for a swap without executing it
     * @return amountOut Expected amount out
     * @return feeAmount Expected fee to be paid
     */
    function getSwapQuote(PoolKey memory key, bool zeroForOne, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint256 feeAmount)
    {
        PoolId id = key.toId();
        if (Currency.unwrap(pools[id].currency0) == address(0)) revert PoolDoesNotExist();

        PoolState storage pool = pools[id];
        uint24 fee = pool.baseFee;

        (amountOut, feeAmount) = _calculateSwapOutput(pool, zeroForOne, amountIn, fee);
    }

    /**
     * @dev Internal helper to calculate swap output using constant product
     */
    function _calculateSwapOutput(PoolState storage pool, bool zeroForOne, uint256 amountIn, uint24 fee)
        internal
        view
        returns (uint256 amountOut, uint256 feeAmount)
    {
        uint256 reserveIn = zeroForOne ? pool.reserve0 : pool.reserve1;
        uint256 reserveOut = zeroForOne ? pool.reserve1 : pool.reserve0;

        feeAmount = (amountIn * fee) / MAX_FEE;
        uint256 amountInAfterFee = amountIn - feeAmount;

        amountOut = (reserveOut * amountInAfterFee) / (reserveIn + amountInAfterFee);
    }

    /**
     * @dev Internal helper to calculate required input for exact output
     */
    function _calculateSwapInput(PoolState storage pool, bool zeroForOne, uint256 amountOut, uint24 fee)
        internal
        view
        returns (uint256 amountIn)
    {
        uint256 reserveIn = zeroForOne ? pool.reserve0 : pool.reserve1;
        uint256 reserveOut = zeroForOne ? pool.reserve1 : pool.reserve0;

        if (amountOut >= reserveOut) revert InsufficientLiquidity();

        uint256 amountInBeforeFee = (reserveIn * amountOut) / (reserveOut - amountOut);
        amountIn = (amountInBeforeFee * MAX_FEE) / (MAX_FEE - fee);
    }

    /**
     * @notice Whitelists a vault address for adding liquidity
     */
    function setWhitelistedVault(address vault, bool status) external onlyOwner {
        whitelistedVaults[vault] = status;
        emit WhitelistedVaultUpdated(vault, status);
    }

    /**
     * @notice Checks if a vault address is whitelisted
     */
    function isWhitelistedVault(address vault) external view returns (bool) {
        return whitelistedVaults[vault];
    }

    /**
     * @notice Returns the current spot price of token0 in terms of token1
     * @dev Multiplied by 1e18 for precision
     */
    function getPrice(PoolId id) external view poolExists(id) returns (uint256) {
        PoolState storage pool = pools[id];
        if (pool.reserve0 == 0) return 0;
        return (pool.reserve1 * 1e18) / pool.reserve0;
    }

    /**
     * @notice Returns the current reserves of token0 and token1
     */
    function getReserves(PoolId id) external view poolExists(id) returns (uint256, uint256) {
        PoolState storage pool = pools[id];
        return (pool.reserve0, pool.reserve1);
    }

    /**
     * @notice Returns the underlying token values of a liquidity position
     */
    function getPositionValue(PoolId id, address provider)
        external
        view
        poolExists(id)
        returns (uint256 amount0, uint256 amount1)
    {
        PoolState storage pool = pools[id];
        LiquidityPosition storage position = positions[id][provider];

        if (pool.totalLiquidity == 0 || position.liquidity == 0) {
            return (0, 0);
        }

        amount0 = (position.liquidity * pool.reserve0) / pool.totalLiquidity;
        amount1 = (position.liquidity * pool.reserve1) / pool.totalLiquidity;
    }

    /**
     * @dev Babylonian method for square root calculation
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

    /**
     * @notice Toggles the active status of a pool
     */
    function setPoolActive(PoolId id, bool active) external onlyOwner poolExists(id) {
        pools[id].isActive = active;
    }
}
