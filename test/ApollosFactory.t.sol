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
import {IApollosFactory} from "../src/interfaces/IApollosFactory.sol";

/**
 * @title ApollosFactoryTest
 * @notice Test suite for ApollosFactory
 */
contract ApollosFactoryTest is Test {
    MockToken public weth;
    MockToken public usdc;
    MockToken public wbtc;
    MockUniswapPool public uniswapPool;
    MockAavePool public aavePool;
    LVRHook public lvrHook;
    ApollosFactory public factory;

    address public owner;
    address public treasury;
    address public alice = makeAddr("alice");

    PoolKey public wethUsdcKey;
    PoolKey public wbtcUsdcKey;

    function setUp() public {
        owner = address(this);
        treasury = makeAddr("treasury");

        // Deploy tokens
        weth = new MockToken("Wrapped Ether", "WETH", 18, true);
        usdc = new MockToken("USD Coin", "USDC", 6, false);
        wbtc = new MockToken("Wrapped Bitcoin", "WBTC", 8, false);

        // Deploy pools
        uniswapPool = new MockUniswapPool();
        lvrHook = new LVRHook(address(uniswapPool));
        aavePool = new MockAavePool();

        // Configure Aave
        aavePool.configureReserve(address(weth), 7500, 8000, 10500);
        aavePool.configureReserve(address(usdc), 8000, 8500, 10500);
        aavePool.configureReserve(address(wbtc), 7000, 7500, 11000);
        aavePool.setAssetPrice(address(weth), 2000 * 1e8);
        aavePool.setAssetPrice(address(usdc), 1 * 1e8);
        aavePool.setAssetPrice(address(wbtc), 40000 * 1e8);

        // Create PoolKeys
        (address t0, address t1) =
            address(weth) < address(usdc) ? (address(weth), address(usdc)) : (address(usdc), address(weth));
        wethUsdcKey = PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(lvrHook))
        });

        (t0, t1) = address(wbtc) < address(usdc) ? (address(wbtc), address(usdc)) : (address(usdc), address(wbtc));
        wbtcUsdcKey = PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(lvrHook))
        });

        // Initialize pools
        uniswapPool.initialize(wethUsdcKey);
        uniswapPool.initialize(wbtcUsdcKey);

        // Deploy factory
        factory = new ApollosFactory(address(aavePool), address(uniswapPool), address(lvrHook), treasury);
    }

    // ============ Create Vault Tests ============

    function test_CreateVault_Success() public {
        IApollosFactory.VaultParams memory params = IApollosFactory.VaultParams({
            name: "Apollos WETH Vault",
            symbol: "afWETH",
            baseAsset: address(weth),
            quoteAsset: address(usdc),
            poolKey: wethUsdcKey,
            targetLeverage: 2e18,
            maxLeverage: 2.5e18
        });

        address vault = factory.createVault(params);

        assertTrue(vault != address(0), "Vault should be deployed");
        assertTrue(factory.isVaultRegistered(vault), "Should be registered as vault");
        assertEq(factory.vaultCount(), 1, "Vault count should be 1");
        console.log("Created vault at:", vault);
    }

    function test_CreateVault_MultipleVaults() public {
        // Create WETH vault
        IApollosFactory.VaultParams memory wethParams = IApollosFactory.VaultParams({
            name: "Apollos WETH Vault",
            symbol: "afWETH",
            baseAsset: address(weth),
            quoteAsset: address(usdc),
            poolKey: wethUsdcKey,
            targetLeverage: 2e18,
            maxLeverage: 2.5e18
        });
        address wethVault = factory.createVault(wethParams);

        // Create WBTC vault
        IApollosFactory.VaultParams memory wbtcParams = IApollosFactory.VaultParams({
            name: "Apollos WBTC Vault",
            symbol: "afWBTC",
            baseAsset: address(wbtc),
            quoteAsset: address(usdc),
            poolKey: wbtcUsdcKey,
            targetLeverage: 1.5e18,
            maxLeverage: 2e18
        });
        address wbtcVault = factory.createVault(wbtcParams);

        assertEq(factory.vaultCount(), 2, "Should have 2 vaults");
        assertTrue(wethVault != wbtcVault, "Vaults should be different");
    }

    function test_CreateVault_RevertDuplicate() public {
        IApollosFactory.VaultParams memory params = IApollosFactory.VaultParams({
            name: "Apollos WETH Vault",
            symbol: "afWETH",
            baseAsset: address(weth),
            quoteAsset: address(usdc),
            poolKey: wethUsdcKey,
            targetLeverage: 2e18,
            maxLeverage: 2.5e18
        });

        factory.createVault(params);

        vm.expectRevert(IApollosFactory.VaultAlreadyExists.selector);
        factory.createVault(params);
    }

    // ============ Registry Tests ============

    function test_GetVault() public {
        IApollosFactory.VaultParams memory params = IApollosFactory.VaultParams({
            name: "Apollos WETH Vault",
            symbol: "afWETH",
            baseAsset: address(weth),
            quoteAsset: address(usdc),
            poolKey: wethUsdcKey,
            targetLeverage: 2e18,
            maxLeverage: 2.5e18
        });

        address created = factory.createVault(params);
        address fetched = factory.getVault(address(weth), address(usdc));

        assertEq(created, fetched, "Should return same vault");
    }

    function test_GetAllVaults() public {
        // Create two vaults
        IApollosFactory.VaultParams memory params1 = IApollosFactory.VaultParams({
            name: "Apollos WETH Vault",
            symbol: "afWETH",
            baseAsset: address(weth),
            quoteAsset: address(usdc),
            poolKey: wethUsdcKey,
            targetLeverage: 2e18,
            maxLeverage: 2.5e18
        });
        factory.createVault(params1);

        IApollosFactory.VaultParams memory params2 = IApollosFactory.VaultParams({
            name: "Apollos WBTC Vault",
            symbol: "afWBTC",
            baseAsset: address(wbtc),
            quoteAsset: address(usdc),
            poolKey: wbtcUsdcKey,
            targetLeverage: 1.5e18,
            maxLeverage: 2e18
        });
        factory.createVault(params2);

        address[] memory allVaults = factory.getAllVaults();
        assertEq(allVaults.length, 2, "Should return all vaults");
    }

    // ============ Protocol Fee Tests ============

    function test_SetProtocolFee() public {
        uint256 newFee = 500; // 5%

        factory.setProtocolFee(newFee);

        assertEq(factory.protocolFee(), newFee);
    }

    function test_SetProtocolFee_RevertExceedsMax() public {
        uint256 tooHighFee = 2000; // 20%

        vm.expectRevert(IApollosFactory.InvalidParameters.selector);
        factory.setProtocolFee(tooHighFee);
    }

    // ============ Treasury Tests ============

    function test_SetTreasury() public {
        address newTreasury = makeAddr("newTreasury");

        factory.setTreasury(newTreasury);

        assertEq(factory.treasury(), newTreasury);
    }

    function test_SetTreasury_RevertZeroAddress() public {
        vm.expectRevert(IApollosFactory.ZeroAddress.selector);
        factory.setTreasury(address(0));
    }

    // ============ View Functions Tests ============

    function test_GetVaultInfo() public {
        IApollosFactory.VaultParams memory params = IApollosFactory.VaultParams({
            name: "Apollos WETH Vault",
            symbol: "afWETH",
            baseAsset: address(weth),
            quoteAsset: address(usdc),
            poolKey: wethUsdcKey,
            targetLeverage: 2e18,
            maxLeverage: 2.5e18
        });

        address vault = factory.createVault(params);

        IApollosFactory.VaultInfo memory info = factory.getVaultInfo(vault);

        assertEq(info.vault, vault);
        assertEq(info.baseAsset, address(weth));
        assertEq(info.quoteAsset, address(usdc));
        assertTrue(info.isActive);
    }

    // ============ Access Control Tests ============

    function test_CreateVault_RevertNotOwner() public {
        IApollosFactory.VaultParams memory params = IApollosFactory.VaultParams({
            name: "Apollos WETH Vault",
            symbol: "afWETH",
            baseAsset: address(weth),
            quoteAsset: address(usdc),
            poolKey: wethUsdcKey,
            targetLeverage: 2e18,
            maxLeverage: 2.5e18
        });

        vm.prank(alice);
        vm.expectRevert();
        factory.createVault(params);
    }
}
