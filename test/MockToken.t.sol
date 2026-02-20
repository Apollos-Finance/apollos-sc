// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {MockToken} from "../src/mocks/MockToken.sol";

/**
 * @title MockTokenTest
 * @notice Test suite for verifying basic ERC20 and WETH-style functionality of MockToken.
 * @author Apollos Finance Team
 */
contract MockTokenTest is Test {
    MockToken public weth;
    MockToken public usdc;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    /**
     * @notice Sets up the test environment by deploying WETH and USDC mocks.
     */
    function setUp() public {
        weth = new MockToken("Wrapped Ether", "WETH", 18, true);
        usdc = new MockToken("USD Coin", "USDC", 6, false);
        vm.deal(alice, 100 ether);
    }

    /**
     * @notice Verifies token name, symbol, and decimal precision.
     */
    function test_TokenMetadata() public view {
        assertEq(weth.name(), "Wrapped Ether");
        assertEq(weth.symbol(), "WETH");
        assertEq(weth.decimals(), 18);
        assertTrue(weth.isWETH());

        assertEq(usdc.name(), "USD Coin");
        assertEq(usdc.symbol(), "USDC");
        assertEq(usdc.decimals(), 6);
        assertFalse(usdc.isWETH());
    }

    /**
     * @notice Verifies basic minting functionality.
     */
    function test_MintTo() public {
        weth.mintTo(alice, 100 ether);
        assertEq(weth.balanceOf(alice), 100 ether);

        usdc.mintTo(bob, 1000 * 1e6);
        assertEq(usdc.balanceOf(bob), 1000 * 1e6);
    }

    /**
     * @notice Verifies that the faucet correctly issues tokens.
     */
    function test_Faucet() public {
        vm.prank(alice);
        weth.faucet(100);

        assertEq(weth.balanceOf(alice), 100 ether);
    }

    /**
     * @notice Verifies that the faucet enforces a 24-hour cooldown period.
     */
    function test_FaucetCooldown() public {
        vm.startPrank(alice);

        weth.faucet(100);

        vm.expectRevert();
        weth.faucet(100);

        vm.warp(block.timestamp + 1 days + 1);
        weth.faucet(50);

        assertEq(weth.balanceOf(alice), 150 ether);
        vm.stopPrank();
    }

    /**
     * @notice Ensures that faucet claims cannot exceed the individual limit.
     */
    function test_FaucetMaxAmount() public {
        vm.prank(alice);
        vm.expectRevert();
        weth.faucet(10001);
    }

    /**
     * @notice Verifies that the raw faucet supports precise fractional amounts.
     */
    function test_FaucetRawSupportsFractionalAmount() public {
        vm.prank(alice);
        weth.faucetRaw(1e16);

        assertEq(weth.balanceOf(alice), 1e16);
    }

    /**
     * @notice Ensures raw faucet claims also adhere to maximum limits.
     */
    function test_FaucetRawMaxAmount() public {
        vm.prank(alice);
        vm.expectRevert();
        weth.faucetRaw(10001 ether);
    }

    /**
     * @notice Verifies successful native ETH wrapping via deposit.
     */
    function test_WETHDeposit() public {
        vm.prank(alice);
        weth.deposit{value: 10 ether}();

        assertEq(weth.balanceOf(alice), 10 ether);
        assertEq(address(weth).balance, 10 ether);
    }

    /**
     * @notice Verifies native ETH wrapping via direct transfer.
     */
    function test_WETHDepositViaReceive() public {
        vm.prank(alice);
        (bool success,) = address(weth).call{value: 5 ether}("");
        assertTrue(success);

        assertEq(weth.balanceOf(alice), 5 ether);
    }

    /**
     * @notice Verifies successful native ETH unwrapping via withdrawal.
     */
    function test_WETHWithdraw() public {
        vm.startPrank(alice);
        weth.deposit{value: 10 ether}();

        uint256 balanceBefore = alice.balance;
        weth.withdraw(5 ether);

        assertEq(weth.balanceOf(alice), 5 ether);
        assertEq(alice.balance, balanceBefore + 5 ether);
        vm.stopPrank();
    }

    /**
     * @notice Ensures that non-WETH tokens reject native ETH deposits.
     */
    function test_USDCRejectsDeposit() public {
        vm.prank(alice);
        vm.expectRevert(MockToken.NotWETH.selector);
        usdc.deposit{value: 1 ether}();
    }

    /**
     * @notice Ensures that non-WETH tokens reject unwrap requests.
     */
    function test_USDCRejectsWithdraw() public {
        usdc.mintTo(alice, 1000 * 1e6);

        vm.prank(alice);
        vm.expectRevert(MockToken.NotWETH.selector);
        usdc.withdraw(100 * 1e6);
    }

    /**
     * @notice Ensures that non-WETH tokens reject direct ETH transfers.
     */
    function test_USDCRejectsETHTransfer() public {
        vm.prank(alice);
        vm.expectRevert(MockToken.NotWETH.selector);
        (bool success,) = address(usdc).call{value: 1 ether}("");
    }

    /**
     * @notice Ensures that zero-value WETH deposits revert.
     */
    function test_DepositZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(MockToken.ZeroAmount.selector);
        weth.deposit{value: 0}();
    }

    /**
     * @notice Ensures that zero-value WETH withdrawals revert.
     */
    function test_WithdrawZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(MockToken.ZeroAmount.selector);
        weth.withdraw(0);
    }

    /**
     * @notice Ensures that minting to the zero address reverts.
     */
    function test_MintToZeroAddressReverts() public {
        vm.expectRevert(MockToken.ZeroAddress.selector);
        weth.mint(address(0), 100);
    }
}
