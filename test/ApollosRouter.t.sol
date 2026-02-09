// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

// V4 Core Types
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

// Contracts
import {MockToken} from "../src/mocks/MockToken.sol";
import {MockUniswapPool} from "../src/mocks/MockUniswapPool.sol";
import {MockAavePool} from "../src/mocks/MockAavePool.sol";
import {LVRHook} from "../src/core/LVRHook.sol";
import {ApollosFactory} from "../src/core/ApollosFactory.sol";
import {ApollosVault} from "../src/core/ApollosVault.sol";
import {ApollosRouter} from "../src/core/ApollosRouter.sol";
import {IApollosRouter} from "../src/interfaces/IApollosRouter.sol";
import {IApollosFactory} from "../src/interfaces/IApollosFactory.sol";

/**
 * @title ApollosRouterTest
 * @notice Test suite for ApollosRouter
 */
contract ApollosRouterTest is Test {
    MockToken public weth;
    MockToken public usdc;
    MockUniswapPool public uniswapPool;
    MockAavePool public aavePool;
    LVRHook public lvrHook;
    ApollosFactory public factory;
    ApollosVault public vault;
    ApollosRouter public router;
    PoolKey public poolKey;
    
    address public owner;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    
    uint256 constant INITIAL_WETH = 100 ether;
    uint256 constant INITIAL_USDC = 200_000 * 1e6;

    // Allow test contract to receive ETH
    receive() external payable {}

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
        aavePool.setAssetPrice(address(weth), 2000 * 1e8);
        aavePool.setAssetPrice(address(usdc), 1 * 1e8);
        
        // Create PoolKey
        (address t0, address t1) = address(weth) < address(usdc)
            ? (address(weth), address(usdc))
            : (address(usdc), address(weth));
        poolKey = PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
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
        
        // Deploy router
        router = new ApollosRouter(
            address(factory),
            address(weth),
            address(0),  // No CCIP
            address(usdc)
        );
        
        // Configure permissions
        uniswapPool.setWhitelistedVault(address(vault), true);
        lvrHook.setWhitelistedVault(address(vault), true);
        aavePool.setWhitelistedBorrower(address(vault), true);
        aavePool.setCreditLimit(address(vault), address(usdc), 10_000_000 * 1e6);
        
        // Set router asset mapping
        router.setAssetVault(address(weth), address(vault));
        
        // Seed liquidity
        usdc.mintTo(address(aavePool), 10_000_000 * 1e6);
        _seedInitialLiquidity();
        
        // Fund users
        weth.mintTo(alice, INITIAL_WETH);
        weth.mintTo(bob, INITIAL_WETH);
        
        // Give alice some ETH for depositETH tests
        vm.deal(alice, INITIAL_WETH);
    }
    
    function _seedInitialLiquidity() internal {
        weth.mintTo(address(this), 10 ether);
        usdc.mintTo(address(this), 20_000 * 1e6);
        
        weth.approve(address(uniswapPool), 10 ether);
        usdc.approve(address(uniswapPool), 20_000 * 1e6);
        
        uniswapPool.setWhitelistedVault(address(this), true);
        lvrHook.setWhitelistedVault(address(this), true);
        
        // addLiquidity expects (amount0, amount1) where currency0 < currency1 by address
        (uint256 amount0, uint256 amount1) = address(weth) < address(usdc)
            ? (uint256(10 ether), uint256(20_000 * 1e6))
            : (uint256(20_000 * 1e6), uint256(10 ether));
        
        uniswapPool.addLiquidity(poolKey, amount0, amount1, 0, 0);
    }

    // ============ Deposit Tests ============

    function test_Deposit_Success() public {
        uint256 depositAmount = 10 ether;
        
        vm.startPrank(alice);
        weth.approve(address(router), depositAmount);
        
        IApollosRouter.DepositParams memory params = IApollosRouter.DepositParams({
            asset: address(weth),
            amount: depositAmount,
            minShares: 0,
            receiver: alice
        });
        
        (address usedVault, uint256 shares) = router.deposit(params);
        vm.stopPrank();
        
        assertEq(usedVault, address(vault), "Should use WETH vault");
        assertGt(shares, 0, "Should receive shares");
        assertGt(vault.balanceOf(alice), 0, "Alice should have shares");
        
        console.log("Deposited via Router, shares:", shares);
    }

    function test_DepositETH_Success() public {
        uint256 depositAmount = 5 ether;
        
        vm.startPrank(alice);
        
        (address usedVault, uint256 shares) = router.depositETH{value: depositAmount}(0);
        
        vm.stopPrank();
        
        assertEq(usedVault, address(vault), "Should use WETH vault");
        assertGt(shares, 0, "Should receive shares");
        
        console.log("Deposited ETH, shares:", shares);
    }

    function test_Deposit_RevertVaultNotFound() public {
        vm.startPrank(alice);
        usdc.mintTo(alice, 1000 * 1e6);
        usdc.approve(address(router), 1000 * 1e6);
        
        // USDC vault doesn't exist
        IApollosRouter.DepositParams memory params = IApollosRouter.DepositParams({
            asset: address(usdc),
            amount: 1000 * 1e6,
            minShares: 0,
            receiver: alice
        });
        
        vm.expectRevert(IApollosRouter.VaultNotFound.selector);
        router.deposit(params);
        
        vm.stopPrank();
    }

    function test_Deposit_RevertZeroAmount() public {
        vm.startPrank(alice);
        
        IApollosRouter.DepositParams memory params = IApollosRouter.DepositParams({
            asset: address(weth),
            amount: 0,
            minShares: 0,
            receiver: alice
        });
        
        vm.expectRevert(IApollosRouter.ZeroAmount.selector);
        router.deposit(params);
        
        vm.stopPrank();
    }

    // ============ Withdraw Tests ============

    function test_Withdraw_Success() public {
        // First deposit
        uint256 depositAmount = 10 ether;
        
        vm.startPrank(alice);
        weth.approve(address(router), depositAmount);
        
        IApollosRouter.DepositParams memory depositParams = IApollosRouter.DepositParams({
            asset: address(weth),
            amount: depositAmount,
            minShares: 0,
            receiver: alice
        });
        (, uint256 shares) = router.deposit(depositParams);
        
        // Approve router to transfer shares
        vault.approve(address(router), shares);
        
        // Now withdraw
        uint256 wethBefore = weth.balanceOf(alice);
        
        IApollosRouter.WithdrawParams memory withdrawParams = IApollosRouter.WithdrawParams({
            vault: address(vault),
            shares: shares,
            minAmount: 0,
            receiver: alice
        });
        uint256 received = router.withdraw(withdrawParams);
        
        uint256 wethAfter = weth.balanceOf(alice);
        vm.stopPrank();
        
        assertGt(received, 0, "Should receive WETH");
        assertEq(wethAfter - wethBefore, received, "Balance should increase");
        
        console.log("Withdrew via Router:", received);
    }

    function test_WithdrawETH_Success() public {
        // First deposit ETH
        uint256 depositAmount = 5 ether;
        
        vm.startPrank(alice);
        (, uint256 shares) = router.depositETH{value: depositAmount}(0);
        
        // Approve router
        vault.approve(address(router), shares);
        
        // Withdraw as ETH
        uint256 ethBefore = alice.balance;
        uint256 received = router.withdrawETH(address(vault), shares, 0);
        uint256 ethAfter = alice.balance;
        
        vm.stopPrank();
        
        assertGt(received, 0, "Should receive ETH");
        assertEq(ethAfter - ethBefore, received, "ETH balance should increase");
        
        console.log("Withdrew ETH:", received);
    }

    // ============ View Functions Tests ============

    function test_GetVaultForAsset() public view {
        address v = router.getVaultForAsset(address(weth));
        assertEq(v, address(vault), "Should return WETH vault");
    }

    function test_PreviewDeposit() public view {
        (address v, uint256 shares) = router.previewDeposit(address(weth), 10 ether);
        
        assertEq(v, address(vault), "Should return WETH vault");
        assertGt(shares, 0, "Should return expected shares");
    }

    function test_PreviewWithdraw() public {
        // First deposit
        vm.startPrank(alice);
        weth.approve(address(router), 10 ether);
        
        IApollosRouter.DepositParams memory params = IApollosRouter.DepositParams({
            asset: address(weth),
            amount: 10 ether,
            minShares: 0,
            receiver: alice
        });
        (, uint256 shares) = router.deposit(params);
        vm.stopPrank();
        
        uint256 expected = router.previewWithdraw(address(vault), shares);
        assertGt(expected, 0, "Should return expected amount");
    }

    // ============ Admin Tests ============

    function test_SetAssetVault() public {
        address newVault = makeAddr("newVault");
        
        router.setAssetVault(address(usdc), newVault);
        
        assertEq(router.getVaultForAsset(address(usdc)), newVault);
    }

    function test_SetSupportedChain() public {
        uint64 chainSelector = 16015286601757825753; // Ethereum sepolia
        
        router.setSupportedChain(chainSelector, true);
        
        assertTrue(router.supportedChains(chainSelector));
    }

    function test_SetQuoteAsset() public {
        MockToken dai = new MockToken("DAI", "DAI", 18, false);
        
        router.setQuoteAsset(address(dai));
        
        assertEq(router.quoteAsset(), address(dai));
    }

    // ============ Cross-Chain Tests ============

    function test_GetCrossChainFee() public view {
        uint256 fee = router.getCrossChainFee(1, address(weth), 10 ether);
        assertEq(fee, 0.01 ether, "Should return fixed fee");
    }

    function test_DepositCrossChain_RevertInvalidChain() public {
        vm.startPrank(alice);
        weth.approve(address(router), 10 ether);
        
        IApollosRouter.CrossChainDepositParams memory params = IApollosRouter.CrossChainDepositParams({
            destinationChainSelector: 12345,  // Not supported
            destinationRouter: address(0),
            asset: address(weth),
            amount: 10 ether,
            minShares: 0,
            receiver: alice
        });
        
        vm.expectRevert(IApollosRouter.InvalidChainSelector.selector);
        router.depositCrossChain(params);
        
        vm.stopPrank();
    }

    // ============ Rescue Tests ============

    function test_RescueTokens() public {
        // Send some tokens to router accidentally
        weth.mintTo(address(router), 1 ether);
        
        uint256 ownerBefore = weth.balanceOf(owner);
        router.rescueTokens(address(weth), 1 ether);
        uint256 ownerAfter = weth.balanceOf(owner);
        
        assertEq(ownerAfter - ownerBefore, 1 ether, "Should rescue tokens");
    }

    function test_RescueETH() public {
        // Send some ETH to router
        vm.deal(address(router), 1 ether);
        
        uint256 ownerBefore = owner.balance;
        router.rescueETH();
        uint256 ownerAfter = owner.balance;
        
        assertEq(ownerAfter - ownerBefore, 1 ether, "Should rescue ETH");
    }
}
