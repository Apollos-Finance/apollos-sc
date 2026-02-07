// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {MockToken} from "../src/mocks/MockToken.sol";

/**
 * @title MockTokenTest
 * @notice Tests for MockToken including WETH-specific functions
 */
contract MockTokenTest is Test {
    MockToken public weth;
    MockToken public usdc;
    
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public {
        // Deploy WETH (isWETH = true)
        weth = new MockToken("Wrapped Ether", "WETH", 18, true);
        
        // Deploy USDC (isWETH = false)
        usdc = new MockToken("USD Coin", "USDC", 6, false);
        
        // Fund Alice with ETH for testing
        vm.deal(alice, 100 ether);
    }

    // ============ Basic ERC20 Tests ============

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

    function test_MintTo() public {
        weth.mintTo(alice, 100 ether);
        assertEq(weth.balanceOf(alice), 100 ether);
        
        usdc.mintTo(bob, 1000 * 1e6);
        assertEq(usdc.balanceOf(bob), 1000 * 1e6);
    }

    // ============ Faucet Tests ============

    function test_Faucet() public {
        vm.prank(alice);
        weth.faucet(100);
        
        assertEq(weth.balanceOf(alice), 100 ether);
    }

    function test_FaucetCooldown() public {
        vm.startPrank(alice);
        
        // First claim
        weth.faucet(100);
        
        // Second claim should fail
        vm.expectRevert();
        weth.faucet(100);
        
        // After cooldown, should work
        vm.warp(block.timestamp + 1 days + 1);
        weth.faucet(50);
        
        assertEq(weth.balanceOf(alice), 150 ether);
        vm.stopPrank();
    }

    function test_FaucetMaxAmount() public {
        vm.prank(alice);
        vm.expectRevert();
        weth.faucet(10001); // Exceeds MAX_FAUCET_AMOUNT
    }

    // ============ WETH Deposit/Withdraw Tests ============

    function test_WETHDeposit() public {
        vm.prank(alice);
        weth.deposit{value: 10 ether}();
        
        assertEq(weth.balanceOf(alice), 10 ether);
        assertEq(address(weth).balance, 10 ether);
    }

    function test_WETHDepositViaReceive() public {
        vm.prank(alice);
        (bool success,) = address(weth).call{value: 5 ether}("");
        assertTrue(success);
        
        assertEq(weth.balanceOf(alice), 5 ether);
    }

    function test_WETHWithdraw() public {
        // First deposit
        vm.startPrank(alice);
        weth.deposit{value: 10 ether}();
        
        uint256 balanceBefore = alice.balance;
        weth.withdraw(5 ether);
        
        assertEq(weth.balanceOf(alice), 5 ether);
        assertEq(alice.balance, balanceBefore + 5 ether);
        vm.stopPrank();
    }

    // ============ Non-WETH Protection Tests ============

    function test_USDCRejectsDeposit() public {
        vm.prank(alice);
        vm.expectRevert(MockToken.NotWETH.selector);
        usdc.deposit{value: 1 ether}();
    }

    function test_USDCRejectsWithdraw() public {
        // Mint some USDC first
        usdc.mintTo(alice, 1000 * 1e6);
        
        vm.prank(alice);
        vm.expectRevert(MockToken.NotWETH.selector);
        usdc.withdraw(100 * 1e6);
    }

    function test_USDCRejectsETHTransfer() public {
        vm.prank(alice);
        vm.expectRevert(MockToken.NotWETH.selector);
        (bool success,) = address(usdc).call{value: 1 ether}("");
        // Note: The call itself will succeed but revert inside receive()
    }

    // ============ Edge Cases ============

    function test_DepositZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(MockToken.ZeroAmount.selector);
        weth.deposit{value: 0}();
    }

    function test_WithdrawZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(MockToken.ZeroAmount.selector);
        weth.withdraw(0);
    }

    function test_MintToZeroAddressReverts() public {
        vm.expectRevert(MockToken.ZeroAddress.selector);
        weth.mint(address(0), 100);
    }
}
