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
import {IApollosVault} from "../src/interfaces/IApollosVault.sol";
import {IApollosFactory} from "../src/interfaces/IApollosFactory.sol";

/**
 * @title ApollosVaultTest
 * @notice Comprehensive test suite for ApollosVault
 */
contract ApollosVaultTest is Test {
    using PoolIdLibrary for PoolKey;

    // ============ Contracts ============
    MockToken public weth;
    MockToken public usdc;
    MockUniswapPool public uniswapPool;
    MockAavePool public aavePool;
    LVRHook public lvrHook;
    ApollosFactory public factory;
    ApollosVault public vault;
    PoolKey public poolKey;

    // ============ Users ============
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public rebalancer = makeAddr("rebalancer");
    address public owner;

    // ============ Constants ============
    uint256 constant INITIAL_WETH = 100 ether;
    uint256 constant INITIAL_USDC = 200_000 * 1e6;
    uint256 constant ETH_PRICE = 2000 * 1e8;  // $2000

    function setUp() public {
        owner = address(this);
        
        // Deploy tokens
        weth = new MockToken("Wrapped Ether", "WETH", 18, true);
        usdc = new MockToken("USD Coin", "USDC", 6, false);
        
        // Deploy pools
        uniswapPool = new MockUniswapPool();
        lvrHook = new LVRHook(address(uniswapPool));
        aavePool = new MockAavePool();
        
        // Configure Aave
        aavePool.configureReserve(address(weth), 7500, 8000, 10500);
        aavePool.configureReserve(address(usdc), 8000, 8500, 10500);
        aavePool.setAssetPrice(address(weth), ETH_PRICE);
        aavePool.setAssetPrice(address(usdc), 1 * 1e8);
        
        // Create PoolKey
        (address token0, address token1) = address(weth) < address(usdc)
            ? (address(weth), address(usdc))
            : (address(usdc), address(weth));
            
        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(lvrHook))
        });
        
        // Initialize pool
        uniswapPool.initialize(poolKey);
        
        // Deploy factory
        factory = new ApollosFactory(
            address(aavePool),
            address(uniswapPool),
            address(lvrHook),
            owner
        );
        
        // Create vault
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
        
        // Configure permissions
        uniswapPool.setWhitelistedVault(address(vault), true);
        lvrHook.setWhitelistedVault(address(vault), true);
        aavePool.setWhitelistedBorrower(address(vault), true);
        aavePool.setCreditLimit(address(vault), address(usdc), 10_000_000 * 1e6);
        vault.setRebalancer(rebalancer, true);
        
        // Seed liquidity
        usdc.mintTo(address(aavePool), 10_000_000 * 1e6);
        
        // Fund users
        weth.mintTo(alice, INITIAL_WETH);
        weth.mintTo(bob, INITIAL_WETH);
        usdc.mintTo(alice, INITIAL_USDC);
        usdc.mintTo(bob, INITIAL_USDC);
        
        // Seed initial LP (needed for proper ratio)
        _seedInitialLiquidity();
    }
    
    function _seedInitialLiquidity() internal {
        // Add initial liquidity to pool so ratios work
        weth.mintTo(address(this), 10 ether);
        usdc.mintTo(address(this), 20_000 * 1e6);
        
        weth.approve(address(uniswapPool), 10 ether);
        usdc.approve(address(uniswapPool), 20_000 * 1e6);
        
        // Temporarily whitelist this contract
        uniswapPool.setWhitelistedVault(address(this), true);
        lvrHook.setWhitelistedVault(address(this), true);
        
        // addLiquidity expects (amount0, amount1) where currency0 < currency1 by address
        // Need to pass amounts in the correct order
        (uint256 amount0, uint256 amount1) = address(weth) < address(usdc)
            ? (uint256(10 ether), uint256(20_000 * 1e6))
            : (uint256(20_000 * 1e6), uint256(10 ether));
        
        uniswapPool.addLiquidity(poolKey, amount0, amount1, 0, 0);
    }

    // ============ Deposit Tests ============

    function test_Deposit_Success() public {
        uint256 depositAmount = 10 ether;
        
        vm.startPrank(alice);
        weth.approve(address(vault), depositAmount);
        
        uint256 sharesBefore = vault.balanceOf(alice);
        uint256 shares = vault.deposit(depositAmount, 0);
        uint256 sharesAfter = vault.balanceOf(alice);
        
        vm.stopPrank();
        
        assertGt(shares, 0, "Should receive shares");
        assertEq(sharesAfter - sharesBefore, shares, "Balance should increase");
        console.log("Shares received:", shares);
    }

    function test_Deposit_FirstDeposit_OneToOne() public {
        // Deploy new tokens for this test to avoid VaultAlreadyExists
        MockToken newWeth = new MockToken("New WETH", "nWETH", 18, true);
        MockToken newUsdc = new MockToken("New USDC", "nUSDC", 6, false);
        
        // Configure Aave for new tokens
        aavePool.configureReserve(address(newWeth), 7500, 8000, 10500);
        aavePool.configureReserve(address(newUsdc), 8000, 8500, 10500);
        aavePool.setAssetPrice(address(newWeth), ETH_PRICE);
        aavePool.setAssetPrice(address(newUsdc), 1 * 1e8);
        
        // Create new pool key
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
        
        // Create fresh vault
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
        
        // Configure permissions
        uniswapPool.setWhitelistedVault(freshVaultAddr, true);
        lvrHook.setWhitelistedVault(freshVaultAddr, true);
        aavePool.setWhitelistedBorrower(freshVaultAddr, true);
        aavePool.setCreditLimit(freshVaultAddr, address(newUsdc), 10_000_000 * 1e6);
        
        // Seed aave with new usdc
        newUsdc.mintTo(address(aavePool), 10_000_000 * 1e6);
        
        // Mint tokens to alice
        newWeth.mintTo(alice, 100 ether);
        
        uint256 depositAmount = 5 ether;
        
        vm.startPrank(alice);
        newWeth.approve(freshVaultAddr, depositAmount);
        uint256 shares = freshVault.deposit(depositAmount, 0);
        vm.stopPrank();
        
        // First deposit should be 1:1
        assertEq(shares, depositAmount, "First deposit should be 1:1");
    }

    function test_Deposit_RevertZeroAmount() public {
        vm.startPrank(alice);
        weth.approve(address(vault), 1 ether);
        
        vm.expectRevert(IApollosVault.ZeroAmount.selector);
        vault.deposit(0, 0);
        
        vm.stopPrank();
    }

    function test_Deposit_SlippageProtection() public {
        uint256 depositAmount = 10 ether;
        uint256 minShares = type(uint256).max; // Impossible to satisfy
        
        vm.startPrank(alice);
        weth.approve(address(vault), depositAmount);
        
        vm.expectRevert(IApollosVault.SlippageExceeded.selector);
        vault.deposit(depositAmount, minShares);
        
        vm.stopPrank();
    }

    // ============ Withdraw Tests ============

    function test_Withdraw_Success() public {
        // First deposit
        uint256 depositAmount = 10 ether;
        
        vm.startPrank(alice);
        weth.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, 0);
        
        // Then withdraw half
        uint256 withdrawShares = shares / 2;
        uint256 wethBefore = weth.balanceOf(alice);
        
        uint256 amount = vault.withdraw(withdrawShares, 0);
        
        uint256 wethAfter = weth.balanceOf(alice);
        vm.stopPrank();
        
        assertGt(amount, 0, "Should receive WETH");
        assertEq(wethAfter - wethBefore, amount, "WETH balance should increase");
        console.log("WETH received:", amount);
    }

    function test_Withdraw_RevertInsufficientShares() public {
        vm.startPrank(alice);
        
        vm.expectRevert(IApollosVault.InsufficientShares.selector);
        vault.withdraw(1 ether, 0);  // Alice has no shares
        
        vm.stopPrank();
    }

    // ============ Share Price Tests ============

    function test_SharePrice_InitialValue() public view {
        uint256 price = vault.getSharePrice();
        console.log("Initial share price:", price);
        // Should be close to 1e18 or reflect actual value
        assertGt(price, 0, "Price should be positive");
    }

    function test_PreviewDeposit_Accuracy() public {
        uint256 depositAmount = 5 ether;
        
        uint256 previewShares = vault.previewDeposit(depositAmount);
        
        vm.startPrank(alice);
        weth.approve(address(vault), depositAmount);
        uint256 actualShares = vault.deposit(depositAmount, 0);
        vm.stopPrank();
        
        // Preview should equal actual (small tolerance for gas)
        assertEq(previewShares, actualShares, "Preview should match actual");
    }

    // ============ Leverage Tests ============

    function test_GetCurrentLeverage() public {
        // Deposit to create leveraged position
        uint256 depositAmount = 10 ether;
        
        vm.startPrank(alice);
        weth.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, 0);
        vm.stopPrank();
        
        uint256 leverage = vault.getCurrentLeverage();
        console.log("Current leverage:", leverage);
        
        // Should be > 1e18 (1x) due to borrowing
        assertGe(leverage, 1e18, "Leverage should be >= 1x");
    }

    // ============ Health Factor Tests ============

    function test_GetHealthFactor() public view {
        uint256 hf = vault.getHealthFactor();
        console.log("Health factor:", hf);
        
        // No debt = max health factor
        assertEq(hf, type(uint256).max, "No debt should mean max HF");
    }

    function test_NeedsRebalance_False_WhenHealthy() public view {
        bool needed = vault.needsRebalance();
        assertFalse(needed, "Should not need rebalance when healthy");
    }

    // ============ Rebalance Tests ============

    function test_Rebalance_RevertWhenNotNeeded() public {
        vm.startPrank(rebalancer);
        
        vm.expectRevert(IApollosVault.RebalanceNotNeeded.selector);
        vault.rebalance();
        
        vm.stopPrank();
    }

    function test_Rebalance_OnlyRebalancer() public {
        vm.startPrank(alice);
        
        vm.expectRevert(IApollosVault.NotAuthorized.selector);
        vault.rebalance();
        
        vm.stopPrank();
    }

    // ============ Admin Tests ============

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

    function test_SetPaused() public {
        vault.setPaused(true);
        
        vm.startPrank(alice);
        weth.approve(address(vault), 1 ether);
        
        vm.expectRevert(IApollosVault.VaultPaused.selector);
        vault.deposit(1 ether, 0);
        
        vm.stopPrank();
    }

    // ============ Emergency Withdraw Tests ============

    function test_EmergencyWithdraw() public {
        // Deposit first
        uint256 depositAmount = 10 ether;
        
        vm.startPrank(alice);
        weth.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, 0);
        
        // Emergency withdraw
        uint256 wethBefore = weth.balanceOf(alice);
        uint256 amount = vault.emergencyWithdraw(shares);
        uint256 wethAfter = weth.balanceOf(alice);
        
        vm.stopPrank();
        
        // Should receive something (may be less than deposit due to LP distribution)
        console.log("Emergency withdraw amount:", amount);
        assertEq(wethAfter - wethBefore, amount, "Should receive WETH");
    }

    // ============ Integration Tests ============

    function test_FullLeverageFlow() public {
        console.log("=== Full 2x Leverage Flow ===");
        
        // 1. Alice deposits 10 WETH
        uint256 depositAmount = 10 ether;
        
        vm.startPrank(alice);
        weth.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, 0);
        vm.stopPrank();
        
        console.log("1. Alice deposited", depositAmount / 1e18, "WETH");
        console.log("   Shares received:", shares);
        
        // 2. Check vault state
        IApollosVault.VaultState memory state = vault.getVaultState();
        console.log("2. Vault State:");
        console.log("   Total Assets:", state.totalBaseAssets);
        console.log("   Total Borrowed:", state.totalBorrowed);
        console.log("   LP Token Value:", state.lpTokenValue);
        console.log("   Current Leverage:", state.currentLeverage);
        
        // 3. Check share price
        uint256 sharePrice = vault.getSharePrice();
        console.log("3. Share Price:", sharePrice);
        
        // 4. Alice withdraws
        vm.startPrank(alice);
        uint256 received = vault.withdraw(shares, 0);
        vm.stopPrank();
        
        console.log("4. Alice withdrew", received / 1e18, "WETH");
        
        // Verify Alice didn't lose too much (some loss expected from fees)
        assertGe(received, depositAmount * 90 / 100, "Should receive at least 90% back");
    }
}
