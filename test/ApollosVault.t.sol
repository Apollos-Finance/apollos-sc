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
import {MockAavePool} from "../src/mocks/MockAavePool.sol";
import {LVRHook} from "../src/core/LVRHook.sol";
import {ApollosFactory} from "../src/core/ApollosFactory.sol";
import {ApollosVault} from "../src/core/ApollosVault.sol";
import {DataFeedsCache} from "../src/core/DataFeedsCache.sol";
import {IApollosVault} from "../src/interfaces/IApollosVault.sol";
import {IApollosFactory} from "../src/interfaces/IApollosFactory.sol";

/**
 * @title ApollosVaultTest
 * @notice Comprehensive test suite for verifying the ApollosVault leverage strategy and NAV logic.
 * @author Apollos Finance Team
 */
contract ApollosVaultTest is Test {
    using PoolIdLibrary for PoolKey;

    MockToken public weth;
    MockToken public usdc;
    MockUniswapPool public uniswapPool;
    MockAavePool public aavePool;
    LVRHook public lvrHook;
    ApollosFactory public factory;
    ApollosVault public vault;
    PoolKey public poolKey;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public rebalancer = makeAddr("rebalancer");
    address public owner;
    DataFeedsCache public dataFeedsCache;

    uint256 constant INITIAL_WETH = 100 ether;
    uint256 constant INITIAL_USDC = 200_000 * 1e6;
    uint256 constant ETH_PRICE = 2000 * 1e8;
    bytes32 constant WETH_NAV = keccak256("WETH_NAV");

    /**
     * @notice Sets up the test environment by deploying mocks, pools, and initializing the vault.
     */
    function setUp() public {
        owner = address(this);

        weth = new MockToken("Wrapped Ether", "WETH", 18, true);
        usdc = new MockToken("USD Coin", "USDC", 6, false);

        uniswapPool = new MockUniswapPool();
        lvrHook = new LVRHook(address(uniswapPool));
        aavePool = new MockAavePool();

        aavePool.configureReserve(address(weth), 7500, 8000, 10500);
        aavePool.configureReserve(address(usdc), 8000, 8500, 10500);
        aavePool.setAssetPrice(address(weth), ETH_PRICE);
        aavePool.setAssetPrice(address(usdc), 1 * 1e8);

        (address token0, address token1) =
            address(weth) < address(usdc) ? (address(weth), address(usdc)) : (address(usdc), address(weth));

        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(lvrHook))
        });

        uniswapPool.initialize(poolKey);

        factory = new ApollosFactory(address(aavePool), address(uniswapPool), address(lvrHook), owner);

        IApollosFactory.VaultParams memory params = IApollosFactory.VaultParams({
            name: "Apollos WETH Vault",
            symbol: "afWETH",
            baseAsset: address(weth),
            quoteAsset: address(usdc),
            poolKey: poolKey,
            targetLeverage: 2e18,
            maxLeverage: 2.5e18
        });

        address vaultAddr = factory.createVault(params);
        vault = ApollosVault(vaultAddr);

        uniswapPool.setWhitelistedVault(address(vault), true);
        lvrHook.setWhitelistedVault(address(vault), true);
        aavePool.setWhitelistedBorrower(address(vault), true);
        aavePool.setCreditLimit(address(vault), address(usdc), 10_000_000 * 1e6);
        vault.setRebalancer(rebalancer, true);

        usdc.mintTo(owner, 10_000_000 * 1e6);
        usdc.approve(address(aavePool), 10_000_000 * 1e6);
        aavePool.supply(address(usdc), 10_000_000 * 1e6, owner, 0);
        aavePool.setCreditDelegation(address(vault), address(usdc), 10_000_000 * 1e6);

        weth.mintTo(alice, INITIAL_WETH);
        weth.mintTo(bob, INITIAL_WETH);
        usdc.mintTo(alice, INITIAL_USDC);
        usdc.mintTo(bob, INITIAL_USDC);

        _seedInitialLiquidity();
    }

    /**
     * @notice Seeds the Uniswap pool with initial base and quote assets.
     */
    function _seedInitialLiquidity() internal {
        weth.mintTo(address(this), 10 ether);
        usdc.mintTo(address(this), 20_000 * 1e6);

        weth.approve(address(uniswapPool), 10 ether);
        usdc.approve(address(uniswapPool), 20_000 * 1e6);

        uniswapPool.setWhitelistedVault(address(this), true);
        lvrHook.setWhitelistedVault(address(this), true);

        (uint256 amount0, uint256 amount1) = address(weth) < address(usdc)
            ? (uint256(10 ether), uint256(20_000 * 1e6))
            : (uint256(20_000 * 1e6), uint256(10 ether));

        uniswapPool.addLiquidity(poolKey, amount0, amount1, 0, 0);
    }

    /**
     * @notice Verifies successful asset deposit and leveraged share issuance.
     */
    function test_Deposit_Success() public {
        uint256 depositAmount = 10 ether;

        vm.startPrank(alice);
        weth.approve(address(vault), depositAmount);

        uint256 sharesBefore = vault.balanceOf(alice);
        uint256 shares = vault.deposit(depositAmount, alice);
        uint256 sharesAfter = vault.balanceOf(alice);

        vm.stopPrank();

        assertGt(shares, 0, "Should receive shares");
        assertEq(sharesAfter - sharesBefore, shares, "Balance should increase");
        console.log("Shares received:", shares);
    }

    /**
     * @notice Verifies that the first deposit results in 1:1 share issuance.
     */
    function test_Deposit_FirstDeposit_OneToOne() public {
        MockToken newWeth = new MockToken("New WETH", "nWETH", 18, true);
        MockToken newUsdc = new MockToken("New USDC", "nUSDC", 6, false);

        aavePool.configureReserve(address(newWeth), 7500, 8000, 10500);
        aavePool.configureReserve(address(newUsdc), 8000, 8500, 10500);
        aavePool.setAssetPrice(address(newWeth), ETH_PRICE);
        aavePool.setAssetPrice(address(newUsdc), 1 * 1e8);

        (address t0, address t1) = address(newWeth) < address(newUsdc)
            ? (address(newWeth), address(newUsdc))
            : (address(newUsdc), address(newWeth));
        PoolKey memory newPoolKey = PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(lvrHook))
        });
        uniswapPool.initialize(newPoolKey);

        IApollosFactory.VaultParams memory params = IApollosFactory.VaultParams({
            name: "Fresh Vault",
            symbol: "afFRESH",
            baseAsset: address(newWeth),
            quoteAsset: address(newUsdc),
            poolKey: newPoolKey,
            targetLeverage: 2e18,
            maxLeverage: 2.5e18
        });

        address freshVaultAddr = factory.createVault(params);
        ApollosVault freshVault = ApollosVault(freshVaultAddr);

        uniswapPool.setWhitelistedVault(freshVaultAddr, true);
        lvrHook.setWhitelistedVault(freshVaultAddr, true);
        aavePool.setWhitelistedBorrower(freshVaultAddr, true);
        aavePool.setCreditLimit(freshVaultAddr, address(newUsdc), 10_000_000 * 1e6);

        newUsdc.mintTo(owner, 10_000_000 * 1e6);
        newUsdc.approve(address(aavePool), 10_000_000 * 1e6);
        aavePool.supply(address(newUsdc), 10_000_000 * 1e6, owner, 0);
        aavePool.setCreditDelegation(freshVaultAddr, address(newUsdc), 10_000_000 * 1e6);

        newWeth.mintTo(alice, 100 ether);

        uint256 depositAmount = 5 ether;

        vm.startPrank(alice);
        newWeth.approve(freshVaultAddr, depositAmount);
        uint256 shares = freshVault.deposit(depositAmount, alice);
        vm.stopPrank();

        assertEq(shares, depositAmount, "First deposit should be 1:1");
    }

    /**
     * @notice Ensures that zero-amount deposits revert.
     */
    function test_Deposit_RevertZeroAmount() public {
        vm.startPrank(alice);
        weth.approve(address(vault), 1 ether);

        vm.expectRevert(IApollosVault.ZeroAmount.selector);
        vault.deposit(0, alice);

        vm.stopPrank();
    }

    /**
     * @notice Verifies slippage protection for vault deposits.
     */
    function test_Deposit_SlippageProtection() public {
        uint256 depositAmount = 10 ether;
        uint256 minShares = type(uint256).max;

        vm.startPrank(alice);
        weth.approve(address(vault), depositAmount);

        vm.expectRevert(IApollosVault.SlippageExceeded.selector);
        vault.depositFor(depositAmount, alice, minShares);

        vm.stopPrank();
    }

    /**
     * @notice Verifies successful share redemption and position unwinding.
     */
    function test_Withdraw_Success() public {
        uint256 depositAmount = 10 ether;

        vm.startPrank(alice);
        weth.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, alice);

        uint256 withdrawShares = shares / 2;
        uint256 wethBefore = weth.balanceOf(alice);

        uint256 amount = vault.withdraw(withdrawShares, 0);

        uint256 wethAfter = weth.balanceOf(alice);
        vm.stopPrank();

        assertGt(amount, 0, "Should receive WETH");
        assertEq(wethAfter - wethBefore, amount, "WETH balance should increase");
        console.log("WETH received:", amount);
    }

    /**
     * @notice Ensures withdrawal fails if shares are insufficient.
     */
    function test_Withdraw_RevertInsufficientShares() public {
        vm.startPrank(alice);

        vm.expectRevert(IApollosVault.InsufficientShares.selector);
        vault.withdraw(1 ether, 0);

        vm.stopPrank();
    }

    /**
     * @notice Verifies the initial share price valuation.
     */
    function test_SharePrice_InitialValue() public view {
        uint256 price = vault.getSharePrice();
        console.log("Initial share price:", price);
        assertGt(price, 0, "Price should be positive");
    }

    /**
     * @notice Ensures previewDeposit matches actual deposit results.
     */
    function test_PreviewDeposit_Accuracy() public {
        uint256 depositAmount = 5 ether;

        uint256 previewShares = vault.previewDeposit(depositAmount);

        vm.startPrank(alice);
        weth.approve(address(vault), depositAmount);
        uint256 actualShares = vault.deposit(depositAmount, alice);
        vm.stopPrank();

        assertEq(previewShares, actualShares, "Preview should match actual");
    }

    /**
     * @notice Verifies the leverage calculation after a deposit.
     */
    function test_GetCurrentLeverage() public {
        uint256 depositAmount = 10 ether;

        vm.startPrank(alice);
        weth.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        uint256 leverage = vault.getCurrentLeverage();
        console.log("Current leverage:", leverage);

        assertGe(leverage, 1e18, "Leverage should be >= 1x");
    }

    /**
     * @notice Verifies health factor tracking.
     */
    function test_GetHealthFactor() public view {
        uint256 hf = vault.getHealthFactor();
        console.log("Health factor:", hf);

        assertEq(hf, type(uint256).max, "No debt should mean max HF");
    }

    /**
     * @notice Ensures rebalance is not required for a healthy position.
     */
    function test_NeedsRebalance_False_WhenHealthy() public view {
        bool needed = vault.needsRebalance();
        assertFalse(needed, "Should not need rebalance when healthy");
    }

    /**
     * @notice Ensures manual rebalance fails if not authorized or not needed.
     */
    function test_Rebalance_RevertWhenNotNeeded() public {
        vm.startPrank(rebalancer);

        vm.expectRevert(IApollosVault.RebalanceNotNeeded.selector);
        vault.rebalance();

        vm.stopPrank();
    }

    /**
     * @notice Ensures rebalance is restricted to authorized roles.
     */
    function test_Rebalance_OnlyRebalancer() public {
        vm.startPrank(alice);

        vm.expectRevert(IApollosVault.NotAuthorized.selector);
        vault.rebalance();

        vm.stopPrank();
    }

    /**
     * @notice Verifies the ability to update leverage parameters.
     */
    function test_UpdateConfig() public {
        uint256 newTarget = 1.8e18;
        uint256 newMax = 2.2e18;
        uint256 newThreshold = 1.2e18;

        vault.updateConfig(newTarget, newMax, newThreshold);

        IApollosVault.VaultConfig memory config = vault.getVaultConfig();
        assertEq(config.targetLeverage, newTarget);
        assertEq(config.maxLeverage, newMax);
        assertEq(config.rebalanceThreshold, newThreshold);
    }

    /**
     * @notice Verifies that operations are blocked when the vault is paused.
     */
    function test_SetPaused() public {
        vault.setPaused(true);

        vm.startPrank(alice);
        weth.approve(address(vault), 1 ether);

        vm.expectRevert(IApollosVault.VaultPaused.selector);
        vault.deposit(1 ether, alice);

        vm.stopPrank();
    }

    /**
     * @notice Verifies only rebalancer/owner can toggle borrow pause.
     */
    function test_SetBorrowPaused_OnlyRebalancer() public {
        vm.startPrank(alice);
        vm.expectRevert(IApollosVault.NotAuthorized.selector);
        vault.setBorrowPaused(true);
        vm.stopPrank();

        vm.startPrank(rebalancer);
        vault.setBorrowPaused(true);
        vm.stopPrank();

        assertTrue(vault.borrowPaused(), "borrow pause should be enabled by rebalancer");
    }

    /**
     * @notice Verifies deposits still work while borrow is paused, without increasing debt.
     */
    function test_SetBorrowPaused_DepositWithoutBorrow() public {
        vault.setBorrowPaused(true);

        uint256 debtBefore = aavePool.getUserDebt(address(vault), address(usdc));
        uint256 depositAmount = 10 ether;

        vm.startPrank(alice);
        weth.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, alice);
        vm.stopPrank();

        uint256 debtAfter = aavePool.getUserDebt(address(vault), address(usdc));

        assertGt(shares, 0, "deposit should still mint shares");
        assertEq(debtAfter, debtBefore, "debt must not increase when borrow is paused");
    }

    /**
     * @notice Verifies basic emergency withdrawal functionality.
     */
    function test_EmergencyWithdraw() public {
        uint256 depositAmount = 10 ether;

        vm.startPrank(alice);
        weth.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, alice);

        uint256 wethBefore = weth.balanceOf(alice);
        uint256 amount = vault.emergencyWithdraw(shares);
        uint256 wethAfter = weth.balanceOf(alice);

        vm.stopPrank();

        console.log("Emergency withdraw amount:", amount);
        assertEq(wethAfter - wethBefore, amount, "Should receive WETH");
    }

    /**
     * @notice Tests the complete lifecycle of a leveraged position.
     */
    function test_FullLeverageFlow() public {
        console.log("=== Full 2x Leverage Flow ===");

        uint256 depositAmount = 10 ether;

        vm.startPrank(alice);
        weth.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, alice);
        vm.stopPrank();

        console.log("1. Alice deposited", depositAmount / 1e18, "WETH");
        console.log("   Shares received:", shares);

        IApollosVault.VaultState memory state = vault.getVaultState();
        console.log("2. Vault State:");
        console.log("   Total Assets:", state.totalBaseAssets);
        console.log("   Total Borrowed:", state.totalBorrowed);
        console.log("   LP Token Value:", state.lpTokenValue);
        console.log("   Current Leverage:", state.currentLeverage);

        uint256 sharePrice = vault.getSharePrice();
        console.log("3. Share Price:", sharePrice);

        vm.startPrank(alice);
        uint256 received = vault.withdraw(shares, 0);
        vm.stopPrank();

        console.log("4. Alice withdrew", received / 1e18, "WETH");

        assertGe(received, depositAmount * 90 / 100, "Should receive at least 90% back");
    }

    /**
     * @notice Helper to initialize a mock data feed.
     */
    function _setupDataFeed(uint256 answer, uint256 updatedAt) internal {
        dataFeedsCache = new DataFeedsCache(owner);
        dataFeedsCache.configureFeed(WETH_NAV, 18);
        dataFeedsCache.updateRoundData(WETH_NAV, int256(answer), updatedAt);
        vault.setDataFeedConfig(address(dataFeedsCache), WETH_NAV, 1800);
    }

    /**
     * @notice Verifies totalAssets calculation using feed plus flow deltas.
     */
    function test_TotalAssets_FeedPlusIdle() public {
        _setupDataFeed(50 ether, block.timestamp);

        vm.startPrank(alice);
        weth.approve(address(vault), 10 ether);
        vault.deposit(10 ether, alice);
        vm.stopPrank();

        assertEq(vault.totalAssets(), 60 ether, "totalAssets should use fresh feed + net flow delta");
    }

    /**
     * @notice Verifies fallback to on-chain math when the NAV feed is stale.
     */
    function test_TotalAssets_FallbackToOnchain_WhenFeedStale() public {
        vm.startPrank(alice);
        weth.approve(address(vault), 10 ether);
        vault.deposit(10 ether, alice);
        vm.stopPrank();

        _setupDataFeed(20 ether, block.timestamp);

        vm.warp(block.timestamp + 2 days);

        uint256 assets = vault.totalAssets();
        assertGt(assets, 0, "fallback NAV should be positive");
        assertLt(assets, 20 ether, "stale feed should not be used as primary source");
    }

    /**
     * @notice Verifies successful withdrawal even when capital is deployed in LP.
     */
    function test_Withdraw_Success_WhenCapitalDeployed() public {
        vm.startPrank(alice);
        weth.approve(address(vault), 10 ether);
        vault.deposit(10 ether, alice);
        vm.stopPrank();

        vm.startPrank(alice);
        uint256 received = vault.withdraw(5 ether, 0);
        vm.stopPrank();

        assertGt(received, 0, "withdraw should unwind position and return base asset");
    }
}
