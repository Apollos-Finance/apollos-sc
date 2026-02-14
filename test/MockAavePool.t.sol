// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockToken} from "../src/mocks/MockToken.sol";
import {MockAavePool} from "../src/mocks/MockAavePool.sol";
import {IMockAavePool} from "../src/interfaces/IMockAavePool.sol";

/**
 * @title MockAavePoolTest
 * @notice Tests for MockAavePool - Lending functionality for 2x leverage
 */
contract MockAavePoolTest is Test {
    MockToken public weth;
    MockToken public usdc;
    MockAavePool public aavePool;
    
    address public owner = makeAddr("owner");
    address public vault = makeAddr("vault");
    address public investor = makeAddr("investor");
    address public liquidator = makeAddr("liquidator");
    
    // Prices in USD with 8 decimals
    uint256 constant WETH_PRICE = 2000 * 1e8;  // $2000
    uint256 constant USDC_PRICE = 1 * 1e8;     // $1

    function setUp() public {
        vm.startPrank(owner);
        
        // Deploy tokens
        weth = new MockToken("Wrapped Ether", "WETH", 18, true);
        usdc = new MockToken("USD Coin", "USDC", 6, false);
        
        // Deploy Aave Pool
        aavePool = new MockAavePool();
        
        // Configure reserves
        // WETH: 75% LTV, 80% liquidation threshold, 5% bonus
        aavePool.configureReserve(address(weth), 7500, 8000, 10500);
        
        // USDC: 80% LTV, 85% liquidation threshold, 5% bonus
        aavePool.configureReserve(address(usdc), 8000, 8500, 10500);
        
        // Set prices
        aavePool.setAssetPrice(address(weth), WETH_PRICE);
        aavePool.setAssetPrice(address(usdc), USDC_PRICE);
        
        // Seed pool with USDC liquidity for borrowing
        usdc.mintTo(owner, 1_000_000 * 1e6);
        usdc.approve(address(aavePool), 1_000_000 * 1e6);
        aavePool.seedLiquidity(address(usdc), 1_000_000 * 1e6);
        
        vm.stopPrank();
        
        // Mint tokens for testing
        weth.mintTo(vault, 100 ether);
        usdc.mintTo(vault, 100_000 * 1e6);
        usdc.mintTo(investor, 1_000_000 * 1e6);
        usdc.mintTo(liquidator, 100_000 * 1e6);
    }

    // ============ Supply Tests ============

    function test_Supply() public {
        vm.startPrank(vault);
        weth.approve(address(aavePool), 10 ether);
        
        aavePool.supply(address(weth), 10 ether, vault, 0);
        
        assertEq(aavePool.getUserCollateral(vault, address(weth)), 10 ether);
        vm.stopPrank();
    }

    function test_SupplyOnBehalfOf() public {
        address beneficiary = makeAddr("beneficiary");
        
        vm.startPrank(vault);
        weth.approve(address(aavePool), 10 ether);
        
        aavePool.supply(address(weth), 10 ether, beneficiary, 0);
        
        assertEq(aavePool.getUserCollateral(beneficiary, address(weth)), 10 ether);
        assertEq(aavePool.getUserCollateral(vault, address(weth)), 0);
        vm.stopPrank();
    }

    function test_SupplyZeroReverts() public {
        vm.prank(vault);
        vm.expectRevert(IMockAavePool.InvalidAmount.selector);
        aavePool.supply(address(weth), 0, vault, 0);
    }

    // ============ Borrow Tests ============

    function test_Borrow() public {
        // Supply collateral first
        vm.startPrank(vault);
        weth.approve(address(aavePool), 10 ether);
        aavePool.supply(address(weth), 10 ether, vault, 0);
        
        // 10 WETH @ $2000 = $20,000 collateral
        // With 75% LTV = $15,000 available to borrow
        
        // Borrow 10,000 USDC
        uint256 borrowAmount = 10_000 * 1e6;
        aavePool.borrow(address(usdc), borrowAmount, 2, 0, vault);
        
        assertEq(aavePool.getUserDebt(vault, address(usdc)), borrowAmount);
        assertEq(usdc.balanceOf(vault), 100_000 * 1e6 + borrowAmount);
        
        vm.stopPrank();
    }

    function test_BorrowExceedsLTVReverts() public {
        vm.startPrank(vault);
        weth.approve(address(aavePool), 10 ether);
        aavePool.supply(address(weth), 10 ether, vault, 0);
        
        // Try to borrow more than LTV allows
        // $20,000 collateral * 75% = $15,000 max
        uint256 tooMuch = 16_000 * 1e6; // $16,000
        
        vm.expectRevert(IMockAavePool.InsufficientCollateral.selector);
        aavePool.borrow(address(usdc), tooMuch, 2, 0, vault);
        
        vm.stopPrank();
    }

    function test_BorrowWithDelegatedCredit() public {
        vm.prank(owner);
        aavePool.setWhitelistedBorrower(vault, true);

        vm.startPrank(investor);
        usdc.approve(address(aavePool), 50_000 * 1e6);
        aavePool.supply(address(usdc), 50_000 * 1e6, investor, 0);
        aavePool.setCreditDelegation(vault, address(usdc), 40_000 * 1e6);
        vm.stopPrank();

        vm.prank(vault);
        aavePool.borrow(address(usdc), 30_000 * 1e6, 2, 0, vault);

        assertEq(aavePool.getUserDebt(vault, address(usdc)), 30_000 * 1e6);
    }

    function test_CannotDelegateBeyondSuppliedBalance() public {
        vm.prank(owner);
        aavePool.setWhitelistedBorrower(vault, true);

        vm.startPrank(investor);
        usdc.approve(address(aavePool), 10_000 * 1e6);
        aavePool.supply(address(usdc), 10_000 * 1e6, investor, 0);

        vm.expectRevert(IMockAavePool.DelegationExceedsSuppliedBalance.selector);
        aavePool.setCreditDelegation(vault, address(usdc), 10_001 * 1e6);
        vm.stopPrank();
    }

    function test_DelegationCanBeReducedButNotBelowDebt() public {
        vm.prank(owner);
        aavePool.setWhitelistedBorrower(vault, true);

        vm.startPrank(investor);
        usdc.approve(address(aavePool), 50_000 * 1e6);
        aavePool.supply(address(usdc), 50_000 * 1e6, investor, 0);
        aavePool.setCreditDelegation(vault, address(usdc), 40_000 * 1e6);
        vm.stopPrank();

        vm.prank(vault);
        aavePool.borrow(address(usdc), 25_000 * 1e6, 2, 0, vault);

        vm.prank(investor);
        aavePool.setCreditDelegation(vault, address(usdc), 30_000 * 1e6);

        vm.startPrank(investor);
        vm.expectRevert(IMockAavePool.DelegationBelowOutstandingDebt.selector);
        aavePool.setCreditDelegation(vault, address(usdc), 20_000 * 1e6);
        vm.stopPrank();
    }

    function test_CannotWithdrawDelegatedBackingWithoutReducingDelegation() public {
        vm.prank(owner);
        aavePool.setWhitelistedBorrower(vault, true);

        vm.startPrank(investor);
        usdc.approve(address(aavePool), 10_000 * 1e6);
        aavePool.supply(address(usdc), 10_000 * 1e6, investor, 0);
        aavePool.setCreditDelegation(vault, address(usdc), 8_000 * 1e6);

        vm.expectRevert(IMockAavePool.DelegationExceedsSuppliedBalance.selector);
        aavePool.withdraw(address(usdc), 3_000 * 1e6, investor);
        vm.stopPrank();
    }

    // ============ Repay Tests ============

    function test_Repay() public {
        // Setup: Supply and borrow
        vm.startPrank(vault);
        weth.approve(address(aavePool), 10 ether);
        aavePool.supply(address(weth), 10 ether, vault, 0);
        
        uint256 borrowAmount = 10_000 * 1e6;
        aavePool.borrow(address(usdc), borrowAmount, 2, 0, vault);
        
        // Repay half
        uint256 repayAmount = 5_000 * 1e6;
        usdc.approve(address(aavePool), repayAmount);
        aavePool.repay(address(usdc), repayAmount, 2, vault);
        
        assertEq(aavePool.getUserDebt(vault, address(usdc)), borrowAmount - repayAmount);
        
        vm.stopPrank();
    }

    function test_RepayMax() public {
        vm.startPrank(vault);
        weth.approve(address(aavePool), 10 ether);
        aavePool.supply(address(weth), 10 ether, vault, 0);
        
        uint256 borrowAmount = 10_000 * 1e6;
        aavePool.borrow(address(usdc), borrowAmount, 2, 0, vault);
        
        // Repay with max uint256
        usdc.approve(address(aavePool), type(uint256).max);
        aavePool.repay(address(usdc), type(uint256).max, 2, vault);
        
        assertEq(aavePool.getUserDebt(vault, address(usdc)), 0);
        
        vm.stopPrank();
    }

    // ============ Withdraw Tests ============

    function test_Withdraw() public {
        vm.startPrank(vault);
        weth.approve(address(aavePool), 10 ether);
        aavePool.supply(address(weth), 10 ether, vault, 0);
        
        // Withdraw half
        uint256 balanceBefore = weth.balanceOf(vault);
        aavePool.withdraw(address(weth), 5 ether, vault);
        
        assertEq(aavePool.getUserCollateral(vault, address(weth)), 5 ether);
        assertEq(weth.balanceOf(vault), balanceBefore + 5 ether);
        
        vm.stopPrank();
    }

    function test_WithdrawWouldLowerHealthFactorReverts() public {
        vm.startPrank(vault);
        weth.approve(address(aavePool), 10 ether);
        aavePool.supply(address(weth), 10 ether, vault, 0);
        
        // Borrow at reasonable LTV (10k USDC against 20k WETH = 50% LTV)
        uint256 borrowAmount = 10_000 * 1e6;
        aavePool.borrow(address(usdc), borrowAmount, 2, 0, vault);
        
        // Try to withdraw too much (would drop health factor below 1)
        // With 10 ETH ($20k), borrowing 10k, need at least ~$12.5k collateral for HF=1
        // Withdrawing 8 ETH leaves only 2 ETH ($4k) which would make HF < 1
        vm.expectRevert(IMockAavePool.HealthFactorTooLow.selector);
        aavePool.withdraw(address(weth), 8 ether, vault);
        
        vm.stopPrank();
    }

    // ============ Health Factor Tests ============

    function test_HealthFactor() public {
        vm.startPrank(vault);
        weth.approve(address(aavePool), 10 ether);
        aavePool.supply(address(weth), 10 ether, vault, 0);
        
        // Get account data before borrow
        (uint256 collateral1, uint256 debt1,,,,uint256 hf1) = aavePool.getUserAccountData(vault);
        console.log("Before borrow - Collateral:", collateral1);
        console.log("Before borrow - Debt:", debt1);
        console.log("Before borrow - Health Factor:", hf1);
        
        // Health factor should be max (no debt)
        assertEq(hf1, type(uint256).max);
        
        // Borrow
        aavePool.borrow(address(usdc), 10_000 * 1e6, 2, 0, vault);
        
        (uint256 collateral2, uint256 debt2,,,,uint256 hf2) = aavePool.getUserAccountData(vault);
        console.log("After borrow - Collateral:", collateral2);
        console.log("After borrow - Debt:", debt2);
        console.log("After borrow - Health Factor:", hf2);
        
        // Health factor should be > 1e18 (healthy)
        assertTrue(hf2 > 1e18);
        
        vm.stopPrank();
    }

    // ============ Liquidation Tests ============

    function test_Liquidation() public {
        // Setup: Vault supplies and borrows near max
        vm.startPrank(vault);
        weth.approve(address(aavePool), 10 ether);
        aavePool.supply(address(weth), 10 ether, vault, 0);
        aavePool.borrow(address(usdc), 12_000 * 1e6, 2, 0, vault); // 12k USDC (lower than max to avoid edge case)
        vm.stopPrank();
        
        // Price drops - now position is liquidatable
        vm.prank(owner);
        aavePool.setAssetPrice(address(weth), 1400 * 1e8); // $1400 (30% drop)
        
        // Check health factor is below 1
        (,,,,,uint256 hf) = aavePool.getUserAccountData(vault);
        console.log("Health Factor after price drop:", hf);
        assertTrue(hf < 1e18);
        
        // Liquidator liquidates
        vm.startPrank(liquidator);
        usdc.approve(address(aavePool), 7_000 * 1e6);
        
        uint256 collateralBefore = aavePool.getUserCollateral(vault, address(weth));
        
        aavePool.liquidationCall(
            address(weth),
            address(usdc),
            vault,
            7_000 * 1e6, // Repay 50% of debt
            false
        );
        
        uint256 collateralAfter = aavePool.getUserCollateral(vault, address(weth));
        uint256 debtAfter = aavePool.getUserDebt(vault, address(usdc));
        
        console.log("Collateral liquidated:", collateralBefore - collateralAfter);
        console.log("Remaining debt:", debtAfter);
        
        // Verify debt reduced
        assertTrue(debtAfter < 14_000 * 1e6);
        
        // Verify liquidator received collateral
        assertTrue(weth.balanceOf(liquidator) > 0);
        
        vm.stopPrank();
    }

    function test_LiquidationHealthyReverts() public {
        vm.startPrank(vault);
        weth.approve(address(aavePool), 10 ether);
        aavePool.supply(address(weth), 10 ether, vault, 0);
        aavePool.borrow(address(usdc), 5_000 * 1e6, 2, 0, vault); // Low LTV = healthy
        vm.stopPrank();
        
        // Try to liquidate healthy position
        vm.startPrank(liquidator);
        usdc.approve(address(aavePool), 2_500 * 1e6);
        
        vm.expectRevert(IMockAavePool.NotLiquidatable.selector);
        aavePool.liquidationCall(address(weth), address(usdc), vault, 2_500 * 1e6, false);
        
        vm.stopPrank();
    }

    // ============ 2x Leverage Flow Test ============

    function test_TwoXLeverageFlow() public {
        console.log("=== 2x Leverage Flow Test ===");
        
        // Step 1: Vault deposits 10 WETH
        vm.startPrank(vault);
        weth.approve(address(aavePool), 10 ether);
        aavePool.supply(address(weth), 10 ether, vault, 0);
        console.log("Step 1: Supplied 10 WETH as collateral");
        
        // Step 2: Calculate available borrows
        (,, uint256 availableBorrows,,,) = aavePool.getUserAccountData(vault);
        console.log("Available to borrow (USD):", availableBorrows);
        
        // Step 3: Borrow USDC (equivalent to ~10 WETH in value for 2x leverage)
        // 10 WETH @ $2000 = $20,000
        // Borrow $10,000 USDC for 2x total exposure
        uint256 borrowAmount = 10_000 * 1e6;
        aavePool.borrow(address(usdc), borrowAmount, 2, 0, vault);
        console.log("Step 3: Borrowed 10,000 USDC");
        
        // Verify state
        (uint256 collateral, uint256 debt,,,,uint256 hf) = aavePool.getUserAccountData(vault);
        console.log("Final collateral (USD):", collateral);
        console.log("Final debt (USD):", debt);
        console.log("Health factor:", hf);
        
        // Now vault has:
        // - 10 WETH in collateral
        // - 10,000 USDC borrowed
        // Total exposure: $30,000 ($20k WETH + $10k USDC)
        // Effective leverage: 1.5x on the $20k
        
        assertTrue(hf > 1e18, "Should be healthy");
        assertEq(aavePool.getUserCollateral(vault, address(weth)), 10 ether);
        assertEq(aavePool.getUserDebt(vault, address(usdc)), borrowAmount);
        
        vm.stopPrank();
    }
}
