// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

// V4 Core Types
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

// Contracts
import {MockToken} from "../src/mocks/MockToken.sol";
import {MockUniswapPool} from "../src/mocks/MockUniswapPool.sol";
import {IMockUniswapPool} from "../src/interfaces/IMockUniswapPool.sol";
import {LVRHook} from "../src/core/LVRHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockUniswapPoolTest
 * @notice Tests for MockUniswapPool V4 Hybrid implementation
 */
contract MockUniswapPoolTest is Test {
    using PoolIdLibrary for PoolKey;

    MockToken public weth;
    MockToken public usdc;
    MockUniswapPool public pool;
    LVRHook public lvrHook;

    PoolKey public poolKey;
    PoolId public poolId;

    address public owner = makeAddr("owner");
    address public vault = makeAddr("vault");
    address public user = makeAddr("user");

    function setUp() public {
        vm.startPrank(owner);

        // Deploy tokens
        weth = new MockToken("Wrapped Ether", "WETH", 18, true);
        usdc = new MockToken("USD Coin", "USDC", 6, false);

        // Deploy pool
        pool = new MockUniswapPool();

        // Deploy LVRHook
        lvrHook = new LVRHook(address(pool));

        // Create PoolKey (currency0 must be < currency1)
        (address token0, address token1) =
            address(weth) < address(usdc) ? (address(weth), address(usdc)) : (address(usdc), address(weth));

        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000, // 0.3% = 3000 in V4 format
            tickSpacing: 60,
            hooks: IHooks(address(lvrHook))
        });

        poolId = poolKey.toId();

        // Initialize pool
        pool.initialize(poolKey);

        // Whitelist vault
        pool.setWhitelistedVault(vault, true);
        lvrHook.setWhitelistedVault(vault, true);

        vm.stopPrank();

        // Mint tokens to vault for testing
        weth.mintTo(vault, 1000 ether);
        usdc.mintTo(vault, 1_000_000 * 1e6);

        // Mint tokens to user for swap testing
        weth.mintTo(user, 100 ether);
        usdc.mintTo(user, 100_000 * 1e6);
    }

    // ============ Pool Initialization Tests ============

    function test_PoolInitialized() public view {
        IMockUniswapPool.PoolState memory state = pool.getPoolState(poolId);

        assertTrue(state.isActive);
        assertEq(state.baseFee, 3000);
        assertEq(address(state.hooks), address(lvrHook));
    }

    function test_DoubleInitializeReverts() public {
        vm.prank(owner);
        vm.expectRevert(IMockUniswapPool.PoolAlreadyExists.selector);
        pool.initialize(poolKey);
    }

    // ============ Liquidity Tests ============

    function test_AddLiquidity() public {
        vm.startPrank(vault);

        // Approve tokens
        weth.approve(address(pool), 100 ether);
        usdc.approve(address(pool), 100_000 * 1e6);

        // Add liquidity
        (uint256 amount0, uint256 amount1, uint256 liquidity) =
            pool.addLiquidity(poolKey, 100 ether, 100_000 * 1e6, 0, 0);

        assertTrue(liquidity > 0);
        console.log("Liquidity minted:", liquidity);

        vm.stopPrank();
    }

    function test_AddLiquidityNonWhitelistedReverts() public {
        vm.startPrank(user);

        weth.approve(address(pool), 10 ether);
        usdc.approve(address(pool), 10_000 * 1e6);

        vm.expectRevert();
        pool.addLiquidity(poolKey, 10 ether, 10_000 * 1e6, 0, 0);

        vm.stopPrank();
    }

    function test_RemoveLiquidity() public {
        // First add liquidity
        vm.startPrank(vault);
        weth.approve(address(pool), 100 ether);
        usdc.approve(address(pool), 100_000 * 1e6);

        (,, uint256 liquidity) = pool.addLiquidity(poolKey, 100 ether, 100_000 * 1e6, 0, 0);

        // Remove half
        (uint256 amount0, uint256 amount1) = pool.removeLiquidity(poolKey, liquidity / 2, 0, 0);

        assertTrue(amount0 > 0);
        assertTrue(amount1 > 0);
        console.log("Received token0:", amount0);
        console.log("Received token1:", amount1);

        vm.stopPrank();
    }

    // ============ Swap Tests ============

    function test_Swap() public {
        // Add liquidity first
        vm.startPrank(vault);
        weth.approve(address(pool), 100 ether);
        usdc.approve(address(pool), 100_000 * 1e6);
        pool.addLiquidity(poolKey, 100 ether, 100_000 * 1e6, 0, 0);
        vm.stopPrank();

        // User swaps
        vm.startPrank(user);

        address token0 = Currency.unwrap(poolKey.currency0);
        address token1 = Currency.unwrap(poolKey.currency1);

        // Use IERC20 to avoid payable conversion issue
        IERC20(token0).approve(address(pool), 10 ether);

        uint256 balanceBefore = IERC20(token1).balanceOf(user);

        // Swap token0 -> token1 (zeroForOne = true, negative = exactIn)
        (uint256 amountIn, uint256 amountOut) =
            pool.swap(
                poolKey,
                true, // zeroForOne
                -10 ether, // exactIn (negative)
                0 // sqrtPriceLimitX96 (ignored)
            );

        uint256 balanceAfter = IERC20(token1).balanceOf(user);

        assertEq(amountIn, 10 ether);
        assertTrue(amountOut > 0);
        assertEq(balanceAfter - balanceBefore, amountOut);

        console.log("Swapped in:", amountIn);
        console.log("Received out:", amountOut);

        vm.stopPrank();
    }

    // ============ Dynamic Fee Tests (LVR Hook) ============

    function test_DynamicFeeApplied() public {
        // Add liquidity
        vm.startPrank(vault);
        weth.approve(address(pool), 100 ether);
        usdc.approve(address(pool), 100_000 * 1e6);
        pool.addLiquidity(poolKey, 100 ether, 100_000 * 1e6, 0, 0);
        vm.stopPrank();

        // Owner sets high dynamic fee (simulating high volatility)
        vm.prank(owner);
        lvrHook.setDynamicFee(poolId, 100000); // 10% fee

        // Swap with high fee
        vm.startPrank(user);
        address token0 = Currency.unwrap(poolKey.currency0);
        IERC20(token0).approve(address(pool), 10 ether);

        (uint256 amountIn, uint256 amountOut) = pool.swap(poolKey, true, -10 ether, 0);

        // With 10% fee, output should be significantly less
        console.log("With 10% fee - In:", amountIn, "Out:", amountOut);

        vm.stopPrank();
    }

    function test_MinFeeDefault() public view {
        uint24 fee = lvrHook.getDynamicFee(poolId);
        assertEq(fee, 500); // MIN_FEE = 0.05%
    }

    // ============ Whitelist Tests ============

    function test_WhitelistVault() public {
        assertTrue(pool.isWhitelistedVault(vault));
        assertFalse(pool.isWhitelistedVault(user));

        vm.prank(owner);
        pool.setWhitelistedVault(user, true);
        assertTrue(pool.isWhitelistedVault(user));
    }

    // ============ Price Tests ============

    function test_GetPrice() public {
        // Add liquidity
        vm.startPrank(vault);
        weth.approve(address(pool), 100 ether);
        usdc.approve(address(pool), 100_000 * 1e6);
        pool.addLiquidity(poolKey, 100 ether, 100_000 * 1e6, 0, 0);
        vm.stopPrank();

        uint256 price = pool.getPrice(poolId);
        assertTrue(price > 0);
        console.log("Price:", price);
    }

    function test_GetReserves() public {
        // Add liquidity
        vm.startPrank(vault);
        weth.approve(address(pool), 100 ether);
        usdc.approve(address(pool), 100_000 * 1e6);
        pool.addLiquidity(poolKey, 100 ether, 100_000 * 1e6, 0, 0);
        vm.stopPrank();

        (uint256 reserve0, uint256 reserve1) = pool.getReserves(poolId);
        assertTrue(reserve0 > 0);
        assertTrue(reserve1 > 0);
        console.log("Reserve0:", reserve0);
        console.log("Reserve1:", reserve1);
    }
}
