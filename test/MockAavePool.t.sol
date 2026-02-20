// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockToken} from "../src/mocks/MockToken.sol";
import {MockAavePool} from "../src/mocks/MockAavePool.sol";
import {IMockAavePool} from "../src/interfaces/IMockAavePool.sol";

/**
 * @title MockAavePoolTest
 * @notice Test suite for verifying the simulated lending functionality of MockAavePool.
 * @author Apollos Finance Team
 */
contract MockAavePoolTest is Test {
    MockToken public weth;
    MockToken public usdc;
    MockAavePool public aavePool;

    address public owner = makeAddr("owner");
    address public vault = makeAddr("vault");
    address public investor = makeAddr("investor");
    address public liquidator = makeAddr("liquidator");

    uint256 constant WETH_PRICE = 2000 * 1e8;
    uint256 constant USDC_PRICE = 1 * 1e8;

    /**
     * @notice Sets up the test environment by deploying tokens and the Aave pool mock.
     */
    function setUp() public {
        vm.startPrank(owner);

        weth = new MockToken("Wrapped Ether", "WETH", 18, true);
        usdc = new MockToken("USD Coin", "USDC", 6, false);

        aavePool = new MockAavePool();

        aavePool.configureReserve(address(weth), 7500, 8000, 10500);
        aavePool.configureReserve(address(usdc), 8000, 8500, 10500);

        aavePool.setAssetPrice(address(weth), WETH_PRICE);
        aavePool.setAssetPrice(address(usdc), USDC_PRICE);

        usdc.mintTo(owner, 1_000_000 * 1e6);
        usdc.approve(address(aavePool), 1_000_000 * 1e6);
        aavePool.seedLiquidity(address(usdc), 1_000_000 * 1e6);

        vm.stopPrank();

        weth.mintTo(vault, 100 ether);
        usdc.mintTo(vault, 100_000 * 1e6);
        usdc.mintTo(investor, 1_000_000 * 1e6);
        usdc.mintTo(liquidator, 100_000 * 1e6);
    }

    /**
     * @notice Verifies successful asset supply to the pool.
     */
    function test_Supply() public {
        vm.startPrank(vault);
        weth.approve(address(aavePool), 10 ether);

        aavePool.supply(address(weth), 10 ether, vault, 0);

        assertEq(aavePool.getUserCollateral(vault, address(weth)), 10 ether);
        vm.stopPrank();
    }

    /**
     * @notice Verifies supplying assets on behalf of another address.
     */
    function test_SupplyOnBehalfOf() public {
        address beneficiary = makeAddr("beneficiary");

        vm.startPrank(vault);
        weth.approve(address(aavePool), 10 ether);

        aavePool.supply(address(weth), 10 ether, beneficiary, 0);

        assertEq(aavePool.getUserCollateral(beneficiary, address(weth)), 10 ether);
        assertEq(aavePool.getUserCollateral(vault, address(weth)), 0);
        vm.stopPrank();
    }

    /**
     * @notice Ensures that supplying zero amount reverts.
     */
    function test_SupplyZeroReverts() public {
        vm.prank(vault);
        vm.expectRevert(IMockAavePool.InvalidAmount.selector);
        aavePool.supply(address(weth), 0, vault, 0);
    }

    /**
     * @notice Verifies successful borrowing against supplied collateral.
     */
    function test_Borrow() public {
        vm.startPrank(vault);
        weth.approve(address(aavePool), 10 ether);
        aavePool.supply(address(weth), 10 ether, vault, 0);

        uint256 borrowAmount = 10_000 * 1e6;
        aavePool.borrow(address(usdc), borrowAmount, 2, 0, vault);

        assertEq(aavePool.getUserDebt(vault, address(usdc)), borrowAmount);
        assertEq(usdc.balanceOf(vault), 100_000 * 1e6 + borrowAmount);

        vm.stopPrank();
    }

    /**
     * @notice Ensures that borrowing above the LTV limit reverts.
     */
    function test_BorrowExceedsLTVReverts() public {
        vm.startPrank(vault);
        weth.approve(address(aavePool), 10 ether);
        aavePool.supply(address(weth), 10 ether, vault, 0);

        uint256 tooMuch = 16_000 * 1e6;

        vm.expectRevert(IMockAavePool.InsufficientCollateral.selector);
        aavePool.borrow(address(usdc), tooMuch, 2, 0, vault);

        vm.stopPrank();
    }

    /**
     * @notice Verifies borrowing using delegated credit from another supplier.
     */
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

    /**
     * @notice Ensures that a supplier cannot delegate more than their collateralized balance.
     */
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

    /**
     * @notice Ensures delegation can be reduced but not below the active debt level.
     */
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

    /**
     * @notice Ensures that delegated collateral cannot be withdrawn without reducing delegation first.
     */
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

    /**
     * @notice Verifies successful debt repayment.
     */
    function test_Repay() public {
        vm.startPrank(vault);
        weth.approve(address(aavePool), 10 ether);
        aavePool.supply(address(weth), 10 ether, vault, 0);

        uint256 borrowAmount = 10_000 * 1e6;
        aavePool.borrow(address(usdc), borrowAmount, 2, 0, vault);

        uint256 repayAmount = 5_000 * 1e6;
        usdc.approve(address(aavePool), repayAmount);
        aavePool.repay(address(usdc), repayAmount, 2, vault);

        assertEq(aavePool.getUserDebt(vault, address(usdc)), borrowAmount - repayAmount);

        vm.stopPrank();
    }

    /**
     * @notice Verifies full debt repayment using the max uint256 constant.
     */
    function test_RepayMax() public {
        vm.startPrank(vault);
        weth.approve(address(aavePool), 10 ether);
        aavePool.supply(address(weth), 10 ether, vault, 0);

        uint256 borrowAmount = 10_000 * 1e6;
        aavePool.borrow(address(usdc), borrowAmount, 2, 0, vault);

        usdc.approve(address(aavePool), type(uint256).max);
        aavePool.repay(address(usdc), type(uint256).max, 2, vault);

        assertEq(aavePool.getUserDebt(vault, address(usdc)), 0);

        vm.stopPrank();
    }

    /**
     * @notice Verifies successful collateral withdrawal.
     */
    function test_Withdraw() public {
        vm.startPrank(vault);
        weth.approve(address(aavePool), 10 ether);
        aavePool.supply(address(weth), 10 ether, vault, 0);

        uint256 balanceBefore = weth.balanceOf(vault);
        aavePool.withdraw(address(weth), 5 ether, vault);

        assertEq(aavePool.getUserCollateral(vault, address(weth)), 5 ether);
        assertEq(weth.balanceOf(vault), balanceBefore + 5 ether);

        vm.stopPrank();
    }

    /**
     * @notice Ensures withdrawal fails if it would drop the health factor below 1.
     */
    function test_WithdrawWouldLowerHealthFactorReverts() public {
        vm.startPrank(vault);
        weth.approve(address(aavePool), 10 ether);
        aavePool.supply(address(weth), 10 ether, vault, 0);

        uint256 borrowAmount = 10_000 * 1e6;
        aavePool.borrow(address(usdc), borrowAmount, 2, 0, vault);

        vm.expectRevert(IMockAavePool.HealthFactorTooLow.selector);
        aavePool.withdraw(address(weth), 8 ether, vault);

        vm.stopPrank();
    }

    /**
     * @notice Verifies accurate health factor calculation.
     */
    function test_HealthFactor() public {
        vm.startPrank(vault);
        weth.approve(address(aavePool), 10 ether);
        aavePool.supply(address(weth), 10 ether, vault, 0);

        (uint256 collateral1, uint256 debt1,,,, uint256 hf1) = aavePool.getUserAccountData(vault);
        console.log("Before borrow - Collateral:", collateral1);
        console.log("Before borrow - Debt:", debt1);
        console.log("Before borrow - Health Factor:", hf1);

        assertEq(hf1, type(uint256).max);

        aavePool.borrow(address(usdc), 10_000 * 1e6, 2, 0, vault);

        (uint256 collateral2, uint256 debt2,,,, uint256 hf2) = aavePool.getUserAccountData(vault);
        console.log("After borrow - Collateral:", collateral2);
        console.log("After borrow - Debt:", debt2);
        console.log("After borrow - Health Factor:", hf2);

        assertTrue(hf2 > 1e18);

        vm.stopPrank();
    }

    /**
     * @notice Verifies the liquidation mechanism after a price drop.
     */
    function test_Liquidation() public {
        vm.startPrank(vault);
        weth.approve(address(aavePool), 10 ether);
        aavePool.supply(address(weth), 10 ether, vault, 0);
        aavePool.borrow(address(usdc), 12_000 * 1e6, 2, 0, vault);
        vm.stopPrank();

        vm.prank(owner);
        aavePool.setAssetPrice(address(weth), 1400 * 1e8);

        (,,,,, uint256 hf) = aavePool.getUserAccountData(vault);
        console.log("Health Factor after price drop:", hf);
        assertTrue(hf < 1e18);

        vm.startPrank(liquidator);
        usdc.approve(address(aavePool), 7_000 * 1e6);

        uint256 collateralBefore = aavePool.getUserCollateral(vault, address(weth));

        aavePool.liquidationCall(address(weth), address(usdc), vault, 7_000 * 1e6, false);

        uint256 collateralAfter = aavePool.getUserCollateral(vault, address(weth));
        uint256 debtAfter = aavePool.getUserDebt(vault, address(usdc));

        console.log("Collateral liquidated:", collateralBefore - collateralAfter);
        console.log("Remaining debt:", debtAfter);

        assertTrue(debtAfter < 14_000 * 1e6);
        assertTrue(weth.balanceOf(liquidator) > 0);

        vm.stopPrank();
    }

    /**
     * @notice Ensures that healthy positions cannot be liquidated.
     */
    function test_LiquidationHealthyReverts() public {
        vm.startPrank(vault);
        weth.approve(address(aavePool), 10 ether);
        aavePool.supply(address(weth), 10 ether, vault, 0);
        aavePool.borrow(address(usdc), 5_000 * 1e6, 2, 0, vault);
        vm.stopPrank();

        vm.startPrank(liquidator);
        usdc.approve(address(aavePool), 2_500 * 1e6);

        vm.expectRevert(IMockAavePool.NotLiquidatable.selector);
        aavePool.liquidationCall(address(weth), address(usdc), vault, 2_500 * 1e6, false);

        vm.stopPrank();
    }

    /**
     * @notice Tests the fundamental 2x leverage borrowing sequence.
     */
    function test_TwoXLeverageFlow() public {
        console.log("=== 2x Leverage Flow Test ===");

        vm.startPrank(vault);
        weth.approve(address(aavePool), 10 ether);
        aavePool.supply(address(weth), 10 ether, vault, 0);
        console.log("Step 1: Supplied 10 WETH as collateral");

        (,, uint256 availableBorrows,,,) = aavePool.getUserAccountData(vault);
        console.log("Available to borrow (USD):", availableBorrows);

        uint256 borrowAmount = 10_000 * 1e6;
        aavePool.borrow(address(usdc), borrowAmount, 2, 0, vault);
        console.log("Step 3: Borrowed 10,000 USDC");

        (uint256 collateral, uint256 debt,,,, uint256 hf) = aavePool.getUserAccountData(vault);
        console.log("Final collateral (USD):", collateral);
        console.log("Final debt (USD):", debt);
        console.log("Health factor:", hf);

        assertTrue(hf > 1e18, "Should be healthy");
        assertEq(aavePool.getUserCollateral(vault, address(weth)), 10 ether);
        assertEq(aavePool.getUserDebt(vault, address(usdc)), borrowAmount);

        vm.stopPrank();
    }
}
