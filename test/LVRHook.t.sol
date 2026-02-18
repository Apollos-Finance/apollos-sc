// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

// V4 Core Types
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

// Contracts
import {MockToken} from "../src/mocks/MockToken.sol";
import {MockUniswapPool} from "../src/mocks/MockUniswapPool.sol";
import {LVRHook} from "../src/core/LVRHook.sol";

/**
 * @title LVRHookTest
 * @notice Tests for LVRHook - Dynamic Fee & Whitelist functionality
 */
contract LVRHookTest is Test {
    using PoolIdLibrary for PoolKey;

    MockToken public weth;
    MockToken public usdc;
    MockUniswapPool public pool;
    LVRHook public lvrHook;

    PoolKey public poolKey;
    PoolId public poolId;

    address public owner = makeAddr("owner");
    address public workflow = makeAddr("workflow");
    address public vault = makeAddr("vault");
    address public attacker = makeAddr("attacker");

    function setUp() public {
        vm.startPrank(owner);

        // Deploy tokens
        weth = new MockToken("Wrapped Ether", "WETH", 18, true);
        usdc = new MockToken("USD Coin", "USDC", 6, false);

        // Deploy pool
        pool = new MockUniswapPool();

        // Deploy LVRHook
        lvrHook = new LVRHook(address(pool));

        // Set workflow authorizer
        lvrHook.setWorkflowAuthorizer(workflow);

        // Create PoolKey
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

        // Initialize pool
        pool.initialize(poolKey);

        // Whitelist vault
        lvrHook.setWhitelistedVault(vault, true);

        vm.stopPrank();
    }

    // ============ Dynamic Fee Tests ============

    function test_SetDynamicFeeByOwner() public {
        vm.prank(owner);
        lvrHook.setDynamicFee(poolId, 50000); // 5%

        assertEq(lvrHook.getDynamicFee(poolId), 50000);
    }

    function test_SetDynamicFeeByWorkflow() public {
        vm.prank(workflow);
        lvrHook.setDynamicFee(poolId, 100000); // 10%

        assertEq(lvrHook.getDynamicFee(poolId), 100000);
    }

    function test_SetDynamicFeeByAttackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(LVRHook.NotAuthorized.selector);
        lvrHook.setDynamicFee(poolId, 50000);
    }

    function test_SetDynamicFeeExceedsMaxReverts() public {
        vm.prank(owner);
        vm.expectRevert(LVRHook.InvalidFee.selector);
        lvrHook.setDynamicFee(poolId, 600000); // 60% > MAX_DYNAMIC_FEE (50%)
    }

    function test_SetDynamicFeeWithReason() public {
        vm.prank(workflow);
        lvrHook.setDynamicFeeWithReason(poolId, 200000, "High CEX-DEX spread detected");

        assertEq(lvrHook.getDynamicFee(poolId), 200000);
    }

    function test_BatchSetDynamicFees() public {
        // Create another pool
        MockToken link = new MockToken("Chainlink", "LINK", 18, false);

        (address t0, address t1) =
            address(link) < address(usdc) ? (address(link), address(usdc)) : (address(usdc), address(link));

        PoolKey memory linkUsdcKey = PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(lvrHook))
        });

        PoolId linkPoolId = linkUsdcKey.toId();

        // Batch update
        PoolId[] memory poolIds = new PoolId[](2);
        poolIds[0] = poolId;
        poolIds[1] = linkPoolId;

        uint24[] memory fees = new uint24[](2);
        fees[0] = 50000;
        fees[1] = 75000;

        vm.prank(owner);
        lvrHook.batchSetDynamicFees(poolIds, fees);

        assertEq(lvrHook.getDynamicFee(poolId), 50000);
        assertEq(lvrHook.getDynamicFee(linkPoolId), 75000);
    }

    function test_ResetFee() public {
        // Set high fee
        vm.prank(owner);
        lvrHook.setDynamicFee(poolId, 200000);
        assertEq(lvrHook.getDynamicFee(poolId), 200000);

        // Reset to minimum
        vm.prank(workflow);
        lvrHook.resetFee(poolId);
        assertEq(lvrHook.getDynamicFee(poolId), 500); // MIN_FEE
    }

    // ============ BeforeSwap Hook Tests ============

    function test_BeforeSwapReturnsDynamicFee() public {
        // Set fee
        vm.prank(owner);
        lvrHook.setDynamicFee(poolId, 100000); // 10%

        // Call beforeSwap
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});

        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = lvrHook.beforeSwap(address(this), poolKey, params, "");

        assertEq(selector, IHooks.beforeSwap.selector);
        // Fee should have override flag set (bit 24)
        assertTrue((fee & 0x800000) != 0);
        // Extract raw fee
        uint24 rawFee = fee & 0x7FFFFF;
        assertEq(rawFee, 100000);
    }

    function test_BeforeSwapReturnsMinFeeWhenNotSet() public {
        // Don't set any fee, should return MIN_FEE
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});

        (,, uint24 fee) = lvrHook.beforeSwap(address(this), poolKey, params, "");

        uint24 rawFee = fee & 0x7FFFFF;
        assertEq(rawFee, 500); // MIN_FEE
    }

    // ============ Whitelist Tests ============

    function test_WhitelistVault() public {
        assertTrue(lvrHook.isVaultWhitelisted(vault));
        assertFalse(lvrHook.isVaultWhitelisted(attacker));
    }

    function test_BeforeAddLiquidityWhitelistedPasses() public {
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: -887220, tickUpper: 887220, liquidityDelta: 1000, salt: bytes32(0)
        });

        bytes4 selector = lvrHook.beforeAddLiquidity(vault, poolKey, params, "");
        assertEq(selector, IHooks.beforeAddLiquidity.selector);
    }

    function test_BeforeAddLiquidityNonWhitelistedReverts() public {
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: -887220, tickUpper: 887220, liquidityDelta: 1000, salt: bytes32(0)
        });

        vm.expectRevert(LVRHook.NotWhitelistedVault.selector);
        lvrHook.beforeAddLiquidity(attacker, poolKey, params, "");
    }

    function test_BatchSetWhitelistedVaults() public {
        address[] memory vaults = new address[](3);
        vaults[0] = makeAddr("vault1");
        vaults[1] = makeAddr("vault2");
        vaults[2] = makeAddr("vault3");

        bool[] memory statuses = new bool[](3);
        statuses[0] = true;
        statuses[1] = true;
        statuses[2] = false;

        vm.prank(owner);
        lvrHook.batchSetWhitelistedVaults(vaults, statuses);

        assertTrue(lvrHook.isVaultWhitelisted(vaults[0]));
        assertTrue(lvrHook.isVaultWhitelisted(vaults[1]));
        assertFalse(lvrHook.isVaultWhitelisted(vaults[2]));
    }

    // ============ Admin Tests ============

    function test_SetWorkflowAuthorizer() public {
        address newWorkflow = makeAddr("newWorkflow");

        vm.prank(owner);
        lvrHook.setWorkflowAuthorizer(newWorkflow);

        assertEq(lvrHook.workflowAuthorizer(), newWorkflow);

        // New workflow can now set fees
        vm.prank(newWorkflow);
        lvrHook.setDynamicFee(poolId, 50000);
        assertEq(lvrHook.getDynamicFee(poolId), 50000);
    }

    function test_GetFeeInfo() public {
        vm.prank(owner);
        lvrHook.setDynamicFee(poolId, 50000);

        (uint24 fee, uint256 lastUpdate, bool isHighVolatility) = lvrHook.getFeeInfo(poolId);

        assertEq(fee, 50000);
        assertEq(lastUpdate, block.timestamp);
        assertTrue(isHighVolatility); // 5% > 1%
    }
}
