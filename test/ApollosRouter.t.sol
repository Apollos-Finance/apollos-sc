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
 * @notice Test suite for verifying the functionality of the Apollos Router.
 * @author Apollos Finance Team
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

    /**
     * @notice Allows the test contract to receive native ETH.
     */
    receive() external payable {}

    /**
     * @notice Sets up the test environment by deploying tokens, pools, and the router.
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
        aavePool.setAssetPrice(address(weth), 2000 * 1e8);
        aavePool.setAssetPrice(address(usdc), 1 * 1e8);

        (address t0, address t1) =
            address(weth) < address(usdc) ? (address(weth), address(usdc)) : (address(usdc), address(weth));
        poolKey = PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
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

        router = new ApollosRouter(address(factory), address(weth), address(0), address(usdc));

        uniswapPool.setWhitelistedVault(address(vault), true);
        lvrHook.setWhitelistedVault(address(vault), true);
        aavePool.setWhitelistedBorrower(address(vault), true);
        aavePool.setCreditLimit(address(vault), address(usdc), 10_000_000 * 1e6);
        usdc.mintTo(owner, 10_000_000 * 1e6);
        usdc.approve(address(aavePool), 10_000_000 * 1e6);
        aavePool.supply(address(usdc), 10_000_000 * 1e6, owner, 0);
        aavePool.setCreditDelegation(address(vault), address(usdc), 10_000_000 * 1e6);

        router.setAssetVault(address(weth), address(vault));

        _seedInitialLiquidity();

        weth.mintTo(alice, INITIAL_WETH);
        weth.mintTo(bob, INITIAL_WETH);

        vm.deal(alice, INITIAL_WETH);
    }

    /**
     * @notice Bootstraps initial liquidity in the Uniswap pool.
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
     * @notice Verifies successful ERC20 asset deposit through the router.
     */
    function test_Deposit_Success() public {
        uint256 depositAmount = 10 ether;

        vm.startPrank(alice);
        weth.approve(address(router), depositAmount);

        IApollosRouter.DepositParams memory params =
            IApollosRouter.DepositParams({asset: address(weth), amount: depositAmount, minShares: 0, receiver: alice});

        (address usedVault, uint256 shares) = router.deposit(params);
        vm.stopPrank();

        assertEq(usedVault, address(vault), "Should use WETH vault");
        assertGt(shares, 0, "Should receive shares");
        assertGt(vault.balanceOf(alice), 0, "Alice should have shares");

        console.log("Deposited via Router, shares:", shares);
    }

    /**
     * @notice Verifies successful native ETH deposit through the router.
     */
    function test_DepositETH_Success() public {
        uint256 depositAmount = 5 ether;

        vm.startPrank(alice);

        (address usedVault, uint256 shares) = router.depositETH{value: depositAmount}(0);

        vm.stopPrank();

        assertEq(usedVault, address(vault), "Should use WETH vault");
        assertGt(shares, 0, "Should receive shares");

        console.log("Deposited ETH, shares:", shares);
    }

    /**
     * @notice Ensures deposit reverts if no vault is found for the asset.
     */
    function test_Deposit_RevertVaultNotFound() public {
        vm.startPrank(alice);
        usdc.mintTo(alice, 1000 * 1e6);
        usdc.approve(address(router), 1000 * 1e6);

        IApollosRouter.DepositParams memory params =
            IApollosRouter.DepositParams({asset: address(usdc), amount: 1000 * 1e6, minShares: 0, receiver: alice});

        vm.expectRevert(IApollosRouter.VaultNotFound.selector);
        router.deposit(params);

        vm.stopPrank();
    }

    /**
     * @notice Ensures deposit reverts if amount is zero.
     */
    function test_Deposit_RevertZeroAmount() public {
        vm.startPrank(alice);

        IApollosRouter.DepositParams memory params =
            IApollosRouter.DepositParams({asset: address(weth), amount: 0, minShares: 0, receiver: alice});

        vm.expectRevert(IApollosRouter.ZeroAmount.selector);
        router.deposit(params);

        vm.stopPrank();
    }

    /**
     * @notice Verifies successful withdrawal through the router.
     */
    function test_Withdraw_Success() public {
        uint256 depositAmount = 10 ether;

        vm.startPrank(alice);
        weth.approve(address(router), depositAmount);

        IApollosRouter.DepositParams memory depositParams =
            IApollosRouter.DepositParams({asset: address(weth), amount: depositAmount, minShares: 0, receiver: alice});
        (, uint256 shares) = router.deposit(depositParams);

        vault.approve(address(router), shares);

        uint256 wethBefore = weth.balanceOf(alice);

        IApollosRouter.WithdrawParams memory withdrawParams =
            IApollosRouter.WithdrawParams({vault: address(vault), shares: shares, minAmount: 0, receiver: alice});
        uint256 received = router.withdraw(withdrawParams);

        uint256 wethAfter = weth.balanceOf(alice);
        vm.stopPrank();

        assertGt(received, 0, "Should receive WETH");
        assertEq(wethAfter - wethBefore, received, "Balance should increase");

        console.log("Withdrew via Router:", received);
    }

    /**
     * @notice Verifies successful withdrawal and unwrapping to native ETH.
     */
    function test_WithdrawETH_Success() public {
        uint256 depositAmount = 5 ether;

        vm.startPrank(alice);
        (, uint256 shares) = router.depositETH{value: depositAmount}(0);

        vault.approve(address(router), shares);

        uint256 ethBefore = alice.balance;
        uint256 received = router.withdrawETH(address(vault), shares, 0);
        uint256 ethAfter = alice.balance;

        vm.stopPrank();

        assertGt(received, 0, "Should receive ETH");
        assertEq(ethAfter - ethBefore, received, "ETH balance should increase");

        console.log("Withdrew ETH:", received);
    }

    /**
     * @notice Verifies retrieval of the vault address associated with an asset.
     */
    function test_GetVaultForAsset() public view {
        address v = router.getVaultForAsset(address(weth));
        assertEq(v, address(vault), "Should return WETH vault");
    }

    /**
     * @notice Verifies the share calculation for a potential deposit.
     */
    function test_PreviewDeposit() public view {
        (address v, uint256 shares) = router.previewDeposit(address(weth), 10 ether);

        assertEq(v, address(vault), "Should return WETH vault");
        assertGt(shares, 0, "Should return expected shares");
    }

    /**
     * @notice Verifies the asset calculation for a potential withdrawal.
     */
    function test_PreviewWithdraw() public {
        vm.startPrank(alice);
        weth.approve(address(router), 10 ether);

        IApollosRouter.DepositParams memory params =
            IApollosRouter.DepositParams({asset: address(weth), amount: 10 ether, minShares: 0, receiver: alice});
        (, uint256 shares) = router.deposit(params);
        vm.stopPrank();

        uint256 expected = router.previewWithdraw(address(vault), shares);
        assertGt(expected, 0, "Should return expected amount");
    }

    /**
     * @notice Verifies the ability to update the asset-to-vault routing table.
     */
    function test_SetAssetVault() public {
        address newVault = makeAddr("newVault");

        router.setAssetVault(address(usdc), newVault);

        assertEq(router.getVaultForAsset(address(usdc)), newVault);
    }

    /**
     * @notice Verifies the ability to update supported cross-chain selectors.
     */
    function test_SetSupportedChain() public {
        uint64 chainSelector = 16015286601757825753;

        router.setSupportedChain(chainSelector, true);

        assertTrue(router.supportedChains(chainSelector));
    }

    /**
     * @notice Verifies the ability to update the protocol's global quote asset.
     */
    function test_SetQuoteAsset() public {
        MockToken dai = new MockToken("DAI", "DAI", 18, false);

        router.setQuoteAsset(address(dai));

        assertEq(router.quoteAsset(), address(dai));
    }

    /**
     * @notice Verifies that fees are 0 when CCIP router is not configured.
     */
    function test_GetCrossChainFee() public view {
        uint256 fee = router.getCrossChainFee(1, address(weth), 10 ether);
        assertEq(fee, 0, "Should return 0 when CCIP router is not configured");
    }

    /**
     * @notice Ensures cross-chain deposit reverts for unsupported chains.
     */
    function test_DepositCrossChain_RevertInvalidChain() public {
        vm.startPrank(alice);
        weth.approve(address(router), 10 ether);

        IApollosRouter.CrossChainDepositParams memory params = IApollosRouter.CrossChainDepositParams({
            destinationChainSelector: 12345,
            destinationRouter: address(0),
            asset: address(weth),
            amount: 10 ether,
            minShares: 0,
            receiver: alice,
            targetBaseAsset: address(weth)
        });

        vm.expectRevert(IApollosRouter.InvalidChainSelector.selector);
        router.depositCrossChain(params);

        vm.stopPrank();
    }

    /**
     * @notice Verifies the owner's ability to rescue ERC20 tokens.
     */
    function test_RescueTokens() public {
        weth.mintTo(address(router), 1 ether);

        uint256 ownerBefore = weth.balanceOf(owner);
        router.rescueTokens(address(weth), 1 ether);
        uint256 ownerAfter = weth.balanceOf(owner);

        assertEq(ownerAfter - ownerBefore, 1 ether, "Should rescue tokens");
    }

    /**
     * @notice Verifies the owner's ability to rescue native ETH.
     */
    function test_RescueETH() public {
        vm.deal(address(router), 1 ether);

        uint256 ownerBefore = owner.balance;
        router.rescueETH();
        uint256 ownerAfter = owner.balance;

        assertEq(ownerAfter - ownerBefore, 1 ether, "Should rescue ETH");
    }
}
