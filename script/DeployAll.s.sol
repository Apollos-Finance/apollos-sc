// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

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
import {ApollosCCIPReceiver} from "../src/core/ApollosCCIPReceiver.sol";
import {DataFeedsCache} from "../src/core/DataFeedsCache.sol";
import {IApollosFactory} from "../src/interfaces/IApollosFactory.sol";
import {SourceChainRouter} from "../src/core/SourceChainRouter.sol";

/**
 * @title DeployAll
 * @notice Full system deployment script for Apollos Finance on Arbitrum Sepolia.
 * @author Apollos Finance Team
 */
contract DeployAll is Script {
    MockToken public weth;
    MockToken public wbtc;
    MockToken public link;
    MockToken public usdc;

    MockUniswapPool public uniswapPool;
    MockAavePool public aavePool;
    LVRHook public lvrHook;

    ApollosFactory public factory;
    address public wethVault;
    address public wbtcVault;
    address public linkVault;
    ApollosRouter public router;
    ApollosCCIPReceiver public ccipReceiver;
    DataFeedsCache public dataFeedsCache;

    PoolKey public wethPoolKey;
    PoolKey public wbtcPoolKey;
    PoolKey public linkPoolKey;

    uint24 constant BASE_FEE = 3000;
    int24 constant TICK_SPACING = 60;

    address constant CCIP_ROUTER_ARB_SEPOLIA = 0x2a9C5afB0d0e4BAb2BCdaE109EC4b0c4Be15a165;
    uint64 constant BASE_SEPOLIA_CHAIN_SELECTOR = 10344971235874465080;
    address constant CCIP_BNM_BASE_SEPOLIA = 0x88A2d74F47a237a62e7A51cdDa67270CE381555e;
    address constant CCIP_BNM_ARB_SEPOLIA = 0xA8C0c11bf64AF62CDCA6f93D3769B88BdD7cb93D;
    bytes32 constant WETH_NAV = keccak256("WETH_NAV");
    bytes32 constant WBTC_NAV = keccak256("WBTC_NAV");
    bytes32 constant LINK_NAV = keccak256("LINK_NAV");
    bytes32 constant WETH_VAR  = keccak256("APOLLOS_VAR_WETH");
    bytes32 constant WBTC_VAR  = keccak256("APOLLOS_VAR_WBTC");
    bytes32 constant LINK_VAR  = keccak256("APOLLOS_VAR_LINK");

    /**
     * @notice Entry point for the deployment script.
     */
    function run() external virtual {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address workflowOperator = vm.envOr("WORKFLOW_UPDATER_ADDRESS", deployer);

        console.log("=== Apollos Finance Full Deployment (Arbitrum) ===");
        console.log("Deployer:", deployer);
        console.log("Workflow operator (keeper/updater):", workflowOperator);
        console.log("Chain ID:", block.chainid);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        _deployTokens();
        _deployInfrastructure();
        _deployFactory();
        _deployDataFeedsCache(workflowOperator);
        _deployVaults();
        _deployRouter();
        _deployCCIPReceiver(deployer);
        _configurePermissions(workflowOperator);
        _seedLiquidity(deployer);

        vm.stopBroadcast();

        _printSummary();
    }

    /**
     * @notice Deploys mock versions of WETH, WBTC, LINK, and USDC.
     */
    function _deployTokens() internal {
        console.log("--- Step 1: Deploy Mock Tokens ---");

        weth = new MockToken("Wrapped Ether", "WETH", 18, true);
        console.log("WETH:", address(weth));

        wbtc = new MockToken("Wrapped Bitcoin", "WBTC", 8, false);
        console.log("WBTC:", address(wbtc));

        link = new MockToken("Chainlink Token", "LINK", 18, false);
        console.log("LINK:", address(link));

        usdc = new MockToken("USD Coin", "USDC", 6, false);
        console.log("USDC:", address(usdc));
        console.log("");
    }

    /**
     * @notice Deploys and configures Aave, Uniswap, and LVR Hook mocks.
     */
    function _deployInfrastructure() internal {
        console.log("--- Step 2: Deploy Infrastructure ---");

        uniswapPool = new MockUniswapPool();
        console.log("MockUniswapPool:", address(uniswapPool));

        lvrHook = new LVRHook(address(uniswapPool));
        console.log("LVRHook:", address(lvrHook));

        aavePool = new MockAavePool();
        console.log("MockAavePool:", address(aavePool));

        aavePool.configureReserve(address(weth), 7500, 8000, 10500);
        aavePool.configureReserve(address(wbtc), 7000, 7500, 10500);
        aavePool.configureReserve(address(link), 6500, 7000, 10500);
        aavePool.configureReserve(address(usdc), 8000, 8500, 10500);

        aavePool.setAssetPrice(address(weth), 2000 * 1e8);
        aavePool.setAssetPrice(address(wbtc), 70000 * 1e8);
        aavePool.setAssetPrice(address(link), 9 * 1e8);
        aavePool.setAssetPrice(address(usdc), 1 * 1e8);

        console.log("Aave reserves & prices configured");
        console.log("");
    }

    /**
     * @notice Deploys the Apollos Vault Factory.
     */
    function _deployFactory() internal {
        console.log("--- Step 3: Deploy Factory ---");

        factory = new ApollosFactory(address(aavePool), address(uniswapPool), address(lvrHook), msg.sender);
        console.log("ApollosFactory:", address(factory));
        console.log("");
    }

    /**
     * @notice Deploys the off-chain data feed cache for NAV updates.
     */
    function _deployDataFeedsCache(address workflowOperator) internal {
        console.log("--- Step 3.5: Deploy DataFeedsCache ---");

        dataFeedsCache = new DataFeedsCache(workflowOperator);
        console.log("DataFeedsCache:", address(dataFeedsCache));
        console.log("DataFeedsCache updater:", workflowOperator);

        dataFeedsCache.setKeeper(workflowOperator, true);

        dataFeedsCache.configureFeed(WETH_NAV, 18);
        dataFeedsCache.configureFeed(WBTC_NAV, 8);
        dataFeedsCache.configureFeed(LINK_NAV, 18);
        dataFeedsCache.configureFeed(WETH_VAR, 0);   
        dataFeedsCache.configureFeed(WBTC_VAR, 0);
        dataFeedsCache.configureFeed(LINK_VAR, 0);
        console.log("Data feed ids configured: WETH_NAV, WBTC_NAV, LINK_NAV, WETH_VAR, WBTC_VAR, LINK_VAR");
        console.log("");
    }

    /**
     * @notice Deploys standard leveraged vaults via the Factory.
     */
    function _deployVaults() internal {
        console.log("--- Step 4: Deploy Vaults ---");

        (wethVault, wethPoolKey) = _createVault(address(weth), "Apollos WETH Vault", "afWETH");
        console.log("afWETH Vault:", wethVault);

        (wbtcVault, wbtcPoolKey) = _createVault(address(wbtc), "Apollos WBTC Vault", "afWBTC");
        console.log("afWBTC Vault:", wbtcVault);

        (linkVault, linkPoolKey) = _createVault(address(link), "Apollos LINK Vault", "afLINK");
        console.log("afLINK Vault:", linkVault);

        console.log("");
    }

    /**
     * @notice Helper function to initialize Uniswap pools and deploy individual vaults.
     */
    function _createVault(address baseAsset, string memory name, string memory symbol)
        internal
        returns (address vault, PoolKey memory poolKey)
    {
        (address token0, address token1) =
            baseAsset < address(usdc) ? (baseAsset, address(usdc)) : (address(usdc), baseAsset);

        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: BASE_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(lvrHook))
        });

        uniswapPool.initialize(poolKey);

        IApollosFactory.VaultParams memory vaultParams = IApollosFactory.VaultParams({
            name: name,
            symbol: symbol,
            baseAsset: baseAsset,
            quoteAsset: address(usdc),
            poolKey: poolKey,
            targetLeverage: 2e18,
            maxLeverage: 2.5e18
        });

        vault = factory.createVault(vaultParams);
    }

    /**
     * @notice Deploys and configures the local ApollosRouter.
     */
    function _deployRouter() internal {
        console.log("--- Step 5: Deploy Router ---");

        router = new ApollosRouter(address(factory), address(weth), CCIP_ROUTER_ARB_SEPOLIA, address(usdc));
        console.log("ApollosRouter:", address(router));

        router.setAssetVault(address(weth), wethVault);
        router.setAssetVault(address(wbtc), wbtcVault);
        router.setAssetVault(address(link), linkVault);

        router.setSupportedChain(BASE_SEPOLIA_CHAIN_SELECTOR, true);

        console.log("Router configured with vault mappings & supported chains");
        console.log("");
    }

    /**
     * @notice Deploys the CCIP Receiver and configures Auto-Zap routes.
     */
    function _deployCCIPReceiver(address deployer) internal {
        console.log("--- Step 6: Deploy CCIPReceiver ---");

        ccipReceiver = new ApollosCCIPReceiver(
            CCIP_ROUTER_ARB_SEPOLIA, address(factory), address(0), address(usdc), address(uniswapPool)
        );
        console.log("ApollosCCIPReceiver:", address(ccipReceiver));

        uint256 reserveAmount = 1_000_000 * 1e6;
        usdc.mintTo(deployer, reserveAmount);
        usdc.transfer(address(ccipReceiver), reserveAmount);
        console.log("Funded CCIPReceiver with 100k USDC reserve");

        ccipReceiver.setAssetVault(address(weth), wethVault);
        ccipReceiver.setAssetVault(address(wbtc), wbtcVault);
        ccipReceiver.setAssetVault(address(link), linkVault);
        ccipReceiver.setAssetMapping(CCIP_BNM_BASE_SEPOLIA, CCIP_BNM_ARB_SEPOLIA);
        console.log("CCIPReceiver: asset-vault mappings set");

        ccipReceiver.setSwapConfig(address(weth), wethPoolKey);
        ccipReceiver.setSwapConfig(address(wbtc), wbtcPoolKey);
        ccipReceiver.setSwapConfig(address(link), linkPoolKey);
        console.log("CCIPReceiver: swap configs set for WETH, WBTC, LINK");

        console.log("");
    }

    /**
     * @notice Grants whitelists and authorization between protocol components.
     */
    function _configurePermissions(address workflowOperator) internal {
        console.log("--- Step 7: Configure Permissions ---");

        address[3] memory vaults = [wethVault, wbtcVault, linkVault];
        bytes32[3] memory navIds = [WETH_NAV, WBTC_NAV, LINK_NAV];

        for (uint256 i = 0; i < vaults.length; i++) {
            address vault = vaults[i];

            uniswapPool.setWhitelistedVault(vault, true);
            lvrHook.setWhitelistedVault(vault, true);
            aavePool.setWhitelistedBorrower(vault, true);
            aavePool.setCreditLimit(vault, address(usdc), 1_000_000 * 1e6);

            ApollosVault(vault).setKeeper(workflowOperator, true);
            ApollosVault(vault).setRebalancer(workflowOperator, true);

            ApollosVault(vault).setDataFeedConfig(address(dataFeedsCache), navIds[i], 1800);
        }

        uniswapPool.setWhitelistedVault(address(ccipReceiver), true);

        console.log("All vaults + CCIPReceiver configured with permissions");
        console.log("");
    }

    /**
     * @notice Sets up initial liquidity for testing and demonstration.
     */
    function _seedLiquidity(address deployer) internal {
        console.log("--- Step 8: Seed Liquidity ---");

        weth.mintTo(deployer, 100 ether);
        wbtc.mintTo(deployer, 5 * 1e8);
        link.mintTo(deployer, 10_000 ether);
        usdc.mintTo(deployer, 500_000 * 1e6);
        console.log("Minted tokens to deployer");

        uint256 investorUsdc = 3_000_000 * 1e6;
        address[3] memory vaults = [wethVault, wbtcVault, linkVault];
        uint256 delegationPerVault = investorUsdc / vaults.length;

        usdc.mintTo(deployer, investorUsdc);
        usdc.approve(address(aavePool), investorUsdc);
        aavePool.supply(address(usdc), investorUsdc, deployer, 0);

        for (uint256 i = 0; i < vaults.length; i++) {
            aavePool.setCreditDelegation(vaults[i], address(usdc), delegationPerVault);
        }

        console.log("Deployer supplied investor USDC and delegated all to vaults");

        _seedPoolLiquidity(deployer);

        console.log("");
    }

    /**
     * @notice Bootsraps Uniswap pools with deep liquidity ($1M TVL each).
     */
    function _seedPoolLiquidity(address deployer) internal {
        console.log("--- Seeding $1M TVL per Pool ---");

        weth.mintTo(deployer, 300 ether);
        wbtc.mintTo(deployer, 10 * 1e8);
        link.mintTo(deployer, 60_000 ether);
        usdc.mintTo(deployer, 2_000_000 * 1e6);

        weth.approve(address(uniswapPool), type(uint256).max);
        wbtc.approve(address(uniswapPool), type(uint256).max);
        link.approve(address(uniswapPool), type(uint256).max);
        usdc.approve(address(uniswapPool), type(uint256).max);

        uniswapPool.setWhitelistedVault(deployer, true);
        lvrHook.setWhitelistedVault(deployer, true);

        {
            (uint256 a0, uint256 a1) = _sortAmounts(address(weth), 250 ether, 500_000 * 1e6);
            uniswapPool.addLiquidity(wethPoolKey, a0, a1, 0, 0);
        }
        console.log("Seeded WETH/USDC pool ($1M TVL)");

        {
            (uint256 a0, uint256 a1) = _sortAmounts(address(wbtc), 715000000, 500_000 * 1e6);
            uniswapPool.addLiquidity(wbtcPoolKey, a0, a1, 0, 0);
        }
        console.log("Seeded WBTC/USDC pool ($1M TVL)");

        {
            (uint256 a0, uint256 a1) = _sortAmounts(address(link), 55556 ether, 500_000 * 1e6);
            uniswapPool.addLiquidity(linkPoolKey, a0, a1, 0, 0);
        }
        console.log("Seeded LINK/USDC pool ($1M TVL)");
    }

    /**
     * @dev Internal helper to sort token amounts based on PoolKey ordering.
     */
    function _sortAmounts(address baseAsset, uint256 baseAmount, uint256 quoteAmount)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        if (baseAsset < address(usdc)) {
            amount0 = baseAmount;
            amount1 = quoteAmount;
        } else {
            amount0 = quoteAmount;
            amount1 = baseAmount;
        }
    }

    /**
     * @notice Displays a summary of all deployed contract addresses.
     */
    function _printSummary() internal view {
        console.log("========================================");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("========================================");
        console.log("");
        console.log("--- Token Addresses ---");
        console.log("WETH:", address(weth));
        console.log("WBTC:", address(wbtc));
        console.log("LINK:", address(link));
        console.log("USDC (Mock):", address(usdc));
        console.log("");
        console.log("--- Infrastructure ---");
        console.log("MockUniswapPool:", address(uniswapPool));
        console.log("MockAavePool:", address(aavePool));
        console.log("LVRHook:", address(lvrHook));
        console.log("DataFeedsCache:", address(dataFeedsCache));
        console.log("");
        console.log("--- Core Protocol ---");
        console.log("ApollosFactory:", address(factory));
        console.log("afWETH Vault:", wethVault);
        console.log("afWBTC Vault:", wbtcVault);
        console.log("afLINK Vault:", linkVault);
        console.log("ApollosRouter:", address(router));
        console.log("ApollosCCIPReceiver:", address(ccipReceiver));
        console.log("");
        console.log("--- .env Format ---");
        console.log("WETH_ADDRESS=", address(weth));
        console.log("WBTC_ADDRESS=", address(wbtc));
        console.log("LINK_ADDRESS=", address(link));
        console.log("USDC_ADDRESS=", address(usdc));
        console.log("FACTORY_ADDRESS=", address(factory));
        console.log("WETH_VAULT_ADDRESS=", wethVault);
        console.log("WBTC_VAULT_ADDRESS=", wbtcVault);
        console.log("LINK_VAULT_ADDRESS=", linkVault);
        console.log("ROUTER_ADDRESS=", address(router));
        console.log("CCIP_RECEIVER_ADDRESS=", address(ccipReceiver));
        console.log("UNISWAP_POOL_ADDRESS=", address(uniswapPool));
        console.log("AAVE_POOL_ADDRESS=", address(aavePool));
        console.log("LVR_HOOK_ADDRESS=", address(lvrHook));
        console.log("DATA_FEEDS_CACHE_ADDRESS=", address(dataFeedsCache));
        console.log("WORKFLOW_UPDATER_ADDRESS=", dataFeedsCache.updater());
        console.log("WETH_NAV_ID=", uint256(WETH_NAV));
        console.log("WBTC_NAV_ID=", uint256(WBTC_NAV));
        console.log("LINK_NAV_ID=", uint256(LINK_NAV));
        console.log("WETH_VAR_ID=", uint256(WETH_VAR));
        console.log("WBTC_VAR_ID=", uint256(WBTC_VAR));
        console.log("LINK_VAR_ID=", uint256(LINK_VAR));
    }
}
