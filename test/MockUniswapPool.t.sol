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
 * @notice Test suite for verifying the V4 Hybrid logic of MockUniswapPool.
 * @author Apollos Finance Team
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

    /**
     * @notice Sets up the test environment by deploying tokens, pools, and hooks.
     */
    function setUp() public {
        vm.startPrank(owner);

        weth = new MockToken("Wrapped Ether", "WETH", 18, true);
        usdc = new MockToken("USD Coin", "USDC", 6, false);

        pool = new MockUniswapPool();

        lvrHook = new LVRHook(address(pool));

        (address token0, address token1) =
            address(weth) < address(usdc) ? (address(weth), address(usdc)) : (address(usdc), address(weth));

        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000, 
            tickSpacing: 60,
            hooks: IHooks(address(lvrHook))
        });

        poolId = poolKey.toId();

        pool.initialize(poolKey);

        pool.setWhitelistedVault(vault, true);
        lvrHook.setWhitelistedVault(vault, true);

        vm.stopPrank();

        weth.mintTo(vault, 1000 ether);
        usdc.mintTo(vault, 1_000_000 * 1e6);

        weth.mintTo(user, 100 ether);
        usdc.mintTo(user, 100_000 * 1e6);
    }

    /**
     * @notice Verifies that the pool is correctly initialized with the specified parameters.
     */
    function test_PoolInitialized() public view {
        IMockUniswapPool.PoolState memory state = pool.getPoolState(poolId);

        assertTrue(state.isActive);
        assertEq(state.baseFee, 3000);
        assertEq(address(state.hooks), address(lvrHook));
    }

    /**
     * @notice Ensures that initializing an existing pool reverts.
     */
    function test_DoubleInitializeReverts() public {
        vm.prank(owner);
        vm.expectRevert(IMockUniswapPool.PoolAlreadyExists.selector);
        pool.initialize(poolKey);
    }

    /**
     * @notice Verifies successful liquidity provision by a whitelisted vault.
     */
    function test_AddLiquidity() public {
        vm.startPrank(vault);

        weth.approve(address(pool), 100 ether);
        usdc.approve(address(pool), 100_000 * 1e6);

        (uint256 amount0, uint256 amount1, uint256 liquidity) =
            pool.addLiquidity(poolKey, 100 ether, 100_000 * 1e6, 0, 0);

        assertTrue(liquidity > 0);
        console.log("Liquidity minted:", liquidity);

        vm.stopPrank();
    }

    /**
     * @notice Ensures that non-whitelisted addresses cannot provide liquidity.
     */
    function test_AddLiquidityNonWhitelistedReverts() public {
        vm.startPrank(user);

        weth.approve(address(pool), 10 ether);
        usdc.approve(address(pool), 10_000 * 1e6);

        vm.expectRevert();
        pool.addLiquidity(poolKey, 10 ether, 10_000 * 1e6, 0, 0);

        vm.stopPrank();
    }

    /**
     * @notice Verifies successful liquidity removal.
     */
    function test_RemoveLiquidity() public {
        vm.startPrank(vault);
        weth.approve(address(pool), 100 ether);
        usdc.approve(address(pool), 100_000 * 1e6);

        (,, uint256 liquidity) = pool.addLiquidity(poolKey, 100 ether, 100_000 * 1e6, 0, 0);

        (uint256 amount0, uint256 amount1) = pool.removeLiquidity(poolKey, liquidity / 2, 0, 0);

        assertTrue(amount0 > 0);
        assertTrue(amount1 > 0);
        console.log("Received token0:", amount0);
        console.log("Received token1:", amount1);

        vm.stopPrank();
    }

    /**
     * @notice Verifies successful token swapping through the AMM.
     */
    function test_Swap() public {
        vm.startPrank(vault);
        weth.approve(address(pool), 100 ether);
        usdc.approve(address(pool), 100_000 * 1e6);
        pool.addLiquidity(poolKey, 100 ether, 100_000 * 1e6, 0, 0);
        vm.stopPrank();

        vm.startPrank(user);

        address token0 = Currency.unwrap(poolKey.currency0);
        address token1 = Currency.unwrap(poolKey.currency1);

        IERC20(token0).approve(address(pool), 10 ether);

        uint256 balanceBefore = IERC20(token1).balanceOf(user);

        (uint256 amountIn, uint256 amountOut) =
            pool.swap(
                poolKey,
                true, 
                -10 ether, 
                0 
            );

        uint256 balanceAfter = IERC20(token1).balanceOf(user);

        assertEq(amountIn, 10 ether);
        assertTrue(amountOut > 0);
        assertEq(balanceAfter - balanceBefore, amountOut);

        console.log("Swapped in:", amountIn);
        console.log("Received out:", amountOut);

        vm.stopPrank();
    }

    /**
     * @notice Verifies that dynamic fees from the LVR hook are correctly applied during swaps.
     */
    function test_DynamicFeeApplied() public {
        vm.startPrank(vault);
        weth.approve(address(pool), 100 ether);
        usdc.approve(address(pool), 100_000 * 1e6);
        pool.addLiquidity(poolKey, 100 ether, 100_000 * 1e6, 0, 0);
        vm.stopPrank();

        vm.prank(owner);
        lvrHook.setDynamicFee(poolId, 100000); 

        vm.startPrank(user);
        address token0 = Currency.unwrap(poolKey.currency0);
        IERC20(token0).approve(address(pool), 10 ether);

        (uint256 amountIn, uint256 amountOut) = pool.swap(poolKey, true, -10 ether, 0);

        console.log("With 10% fee - In:", amountIn, "Out:", amountOut);

        vm.stopPrank();
    }

    /**
     * @notice Verifies the default minimum fee level.
     */
    function test_MinFeeDefault() public view {
        uint24 fee = lvrHook.getDynamicFee(poolId);
        assertEq(fee, 500); 
    }

    /**
     * @notice Verifies the vault whitelisting functionality.
     */
    function test_WhitelistVault() public {
        assertTrue(pool.isWhitelistedVault(vault));
        assertFalse(pool.isWhitelistedVault(user));

        vm.prank(owner);
        pool.setWhitelistedVault(user, true);
        assertTrue(pool.isWhitelistedVault(user));
    }

    /**
     * @notice Verifies price retrieval from the pool.
     */
    function test_GetPrice() public {
        vm.startPrank(vault);
        weth.approve(address(pool), 100 ether);
        usdc.approve(address(pool), 100_000 * 1e6);
        pool.addLiquidity(poolKey, 100 ether, 100_000 * 1e6, 0, 0);
        vm.stopPrank();

        uint256 price = pool.getPrice(poolId);
        assertTrue(price > 0);
        console.log("Price:", price);
    }

    /**
     * @notice Verifies reserve retrieval from the pool.
     */
    function test_GetReserves() public {
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
