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
import {IApollosFactory} from "../src/interfaces/IApollosFactory.sol";

/**
 * @title DeployAll
 * @notice Complete deployment script for Apollos Finance on Arbitrum (main chain)
 * @dev Deploys all contracts in correct order:
 *      1. Mock Tokens (WETH, WBTC, LINK, USDC)
 *      2. MockUniswapPool + LVRHook + MockAavePool
 *      3. ApollosFactory
 *      4. ApollosVaults (WETH/USDC, WBTC/USDC, LINK/USDC)
 *      5. ApollosRouter (local deposits)
 *      6. ApollosCCIPReceiver (cross-chain deposits with Auto-Zapping)
 *      7. Permissions & Configuration
 *      8. Seed Liquidity
 *
 * Cross-chain architecture:
 *      - Source chains (Base, Lisk): Deploy ApollosRouter only (see DeploySourceChain)
 *      - Destination chain (Arbitrum): Deploy everything (this script)
 *      - CCIP delivers real USDC → CCIPReceiver mints MockUSDC 1:1 → swap → vault
 */
contract DeployAll is Script {
    // ============ Deployed Contracts ============
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
    
    // ============ PoolKeys (stored for CCIPReceiver config) ============
    PoolKey public wethPoolKey;
    PoolKey public wbtcPoolKey;
    PoolKey public linkPoolKey;
    
    // ============ Configuration ============
    uint24 constant BASE_FEE = 3000;        // 0.3%
    int24 constant TICK_SPACING = 60;
    
    // CCIP Router addresses per chain (update for your testnet)
    // Arbitrum Sepolia CCIP Router: https://docs.chain.link/ccip/directory/testnet
    address constant CCIP_ROUTER_ARB_SEPOLIA = 0x2a9C5afB0d0e4BAb2BCdaE109EC4b0c4Be15a165;
    
    // Base Sepolia chain selector for CCIP
    uint64 constant BASE_SEPOLIA_CHAIN_SELECTOR = 10344971235874465080;

    function run() external virtual {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("=== Apollos Finance Full Deployment (Arbitrum) ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);
        
        _deployTokens();
        _deployInfrastructure();
        _deployFactory();
        _deployVaults();
        _deployRouter();
        _deployCCIPReceiver();
        _configurePermissions(deployer);
        _seedLiquidity(deployer);
        
        vm.stopBroadcast();
        
        _printSummary();
    }
    
    // ============ Step 1: Deploy Tokens ============
    
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
    
    // ============ Step 2: Deploy Infrastructure ============
    
    function _deployInfrastructure() internal {
        console.log("--- Step 2: Deploy Infrastructure ---");
        
        // MockUniswapPool
        uniswapPool = new MockUniswapPool();
        console.log("MockUniswapPool:", address(uniswapPool));
        
        // LVRHook (uses MockUniswapPool as pool manager)
        lvrHook = new LVRHook(address(uniswapPool));
        console.log("LVRHook:", address(lvrHook));
        
        // MockAavePool
        aavePool = new MockAavePool();
        console.log("MockAavePool:", address(aavePool));
        
        // Configure Aave reserves (LTV, Liquidation Threshold, Liquidation Bonus)
        aavePool.configureReserve(address(weth), 7500, 8000, 10500); // 75% LTV, 80% liq, 5% bonus
        aavePool.configureReserve(address(wbtc), 7000, 7500, 10500); // 70% LTV, 75% liq, 5% bonus
        aavePool.configureReserve(address(link), 6500, 7000, 10500); // 65% LTV, 70% liq, 5% bonus
        aavePool.configureReserve(address(usdc), 8000, 8500, 10500); // 80% LTV, 85% liq, 5% bonus
        
        // Set asset prices (8 decimals, USD denominated)
        aavePool.setAssetPrice(address(weth), 2000 * 1e8);   // $2,000/ETH
        aavePool.setAssetPrice(address(wbtc), 42000 * 1e8);  // $42,000/BTC
        aavePool.setAssetPrice(address(link), 15 * 1e8);     // $15/LINK
        aavePool.setAssetPrice(address(usdc), 1 * 1e8);      // $1/USDC
        
        console.log("Aave reserves & prices configured");
        console.log("");
    }
    
    // ============ Step 3: Deploy Factory ============
    
    function _deployFactory() internal {
        console.log("--- Step 3: Deploy Factory ---");
        
        factory = new ApollosFactory(
            address(aavePool),
            address(uniswapPool),
            address(lvrHook),
            msg.sender  // Treasury = deployer for now
        );
        console.log("ApollosFactory:", address(factory));
        console.log("");
    }
    
    // ============ Step 4: Deploy Vaults ============
    
    function _deployVaults() internal {
        console.log("--- Step 4: Deploy Vaults ---");
        
        // WETH/USDC Vault
        (wethVault, wethPoolKey) = _createVault(address(weth), "Apollos WETH Vault", "afWETH");
        console.log("afWETH Vault:", wethVault);
        
        // WBTC/USDC Vault
        (wbtcVault, wbtcPoolKey) = _createVault(address(wbtc), "Apollos WBTC Vault", "afWBTC");
        console.log("afWBTC Vault:", wbtcVault);
        
        // LINK/USDC Vault
        (linkVault, linkPoolKey) = _createVault(address(link), "Apollos LINK Vault", "afLINK");
        console.log("afLINK Vault:", linkVault);
        
        console.log("");
    }
    
    function _createVault(
        address baseAsset, 
        string memory name, 
        string memory symbol
    ) internal returns (address vault, PoolKey memory poolKey) {
        // Create PoolKey (V4 requires currency0 < currency1)
        (address token0, address token1) = baseAsset < address(usdc) 
            ? (baseAsset, address(usdc)) 
            : (address(usdc), baseAsset);
            
        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: BASE_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(lvrHook))
        });
        
        // Initialize pool in MockUniswapPool
        uniswapPool.initialize(poolKey);
        
        // Create vault via Factory
        IApollosFactory.VaultParams memory vaultParams = IApollosFactory.VaultParams({
            name: name,
            symbol: symbol,
            baseAsset: baseAsset,
            quoteAsset: address(usdc),
            poolKey: poolKey,
            targetLeverage: 2e18,   // 2x leverage
            maxLeverage: 2.5e18     // 2.5x max
        });
        
        vault = factory.createVault(vaultParams);
    }
    
    // ============ Step 5: Deploy Router (Local Deposits) ============
    
    function _deployRouter() internal {
        console.log("--- Step 5: Deploy Router ---");
        
        router = new ApollosRouter(
            address(factory),
            address(weth),
            CCIP_ROUTER_ARB_SEPOLIA,  // Chainlink CCIP Router on Arbitrum Sepolia
            address(usdc)
        );
        console.log("ApollosRouter:", address(router));
        
        // Set asset → vault mappings
        router.setAssetVault(address(weth), wethVault);
        router.setAssetVault(address(wbtc), wbtcVault);
        router.setAssetVault(address(link), linkVault);
        
        // Enable Base Sepolia as supported source chain
        router.setSupportedChain(BASE_SEPOLIA_CHAIN_SELECTOR, true);
        
        console.log("Router configured with vault mappings & supported chains");
        console.log("");
    }
    
    // ============ Step 6: Deploy CCIPReceiver (Cross-Chain) ============
    
    function _deployCCIPReceiver() internal {
        console.log("--- Step 6: Deploy CCIPReceiver ---");
        
        // Deploy CCIPReceiver with Auto-Zapping support
        // Constructor: ccipRouter, factory, quoteAsset(real USDC), mockQuoteAsset(MockUSDC), swapPool
        ccipReceiver = new ApollosCCIPReceiver(
            CCIP_ROUTER_ARB_SEPOLIA,     // Chainlink CCIP Router on Arbitrum
            address(factory),             // ApollosFactory for vault lookups
            address(0),                   // quoteAsset: real USDC on Arb Sepolia (set later via setQuoteAsset)
            address(usdc),                // mockQuoteAsset: MockUSDC for 1:1 bridge mint
            address(uniswapPool)          // MockUniswapPool for auto-zap swaps
        );
        console.log("ApollosCCIPReceiver:", address(ccipReceiver));
        
        // --- Configure asset → vault mappings ---
        ccipReceiver.setAssetVault(address(weth), wethVault);
        ccipReceiver.setAssetVault(address(wbtc), wbtcVault);
        ccipReceiver.setAssetVault(address(link), linkVault);
        console.log("CCIPReceiver: asset-vault mappings set");
        
        // --- Configure swap routes (MockUSDC → target base asset) ---
        // These use the SAME pool keys as the vault LP pools
        // because vault pools are MockUSDC/MockWETH, MockUSDC/MockWBTC, MockUSDC/MockLINK
        ccipReceiver.setSwapConfig(address(weth), wethPoolKey);
        ccipReceiver.setSwapConfig(address(wbtc), wbtcPoolKey);
        ccipReceiver.setSwapConfig(address(link), linkPoolKey);
        console.log("CCIPReceiver: swap configs set for WETH, WBTC, LINK");
        
        console.log("");
    }
    
    // ============ Step 7: Configure Permissions ============
    
    function _configurePermissions(address deployer) internal {
        console.log("--- Step 7: Configure Permissions ---");
        
        address[3] memory vaults = [wethVault, wbtcVault, linkVault];
        
        for (uint256 i = 0; i < vaults.length; i++) {
            address vault = vaults[i];
            
            // Whitelist vault in MockUniswapPool (so vault can add LP)
            uniswapPool.setWhitelistedVault(vault, true);
            
            // Whitelist vault in LVRHook (so hook allows vault's addLiquidity)
            lvrHook.setWhitelistedVault(vault, true);
            
            // Whitelist vault in MockAavePool (Credit Delegation)
            aavePool.setWhitelistedBorrower(vault, true);
            
            // Set credit limit (1M USDC each vault)
            aavePool.setCreditLimit(vault, address(usdc), 1_000_000 * 1e6);
            
            // Authorize deployer as rebalancer (for Chainlink Workflow)
            ApollosVault(vault).setRebalancer(deployer, true);
        }
        
        // Whitelist CCIPReceiver in MockUniswapPool (so it can swap for auto-zap)
        uniswapPool.setWhitelistedVault(address(ccipReceiver), true);
        
        console.log("All vaults + CCIPReceiver configured with permissions");
        console.log("");
    }
    
    // ============ Step 8: Seed Liquidity ============
    
    function _seedLiquidity(address deployer) internal {
        console.log("--- Step 8: Seed Liquidity ---");
        
        // Mint tokens to deployer for initial interactions
        weth.mintTo(deployer, 100 ether);         // 100 WETH
        wbtc.mintTo(deployer, 5 * 1e8);           // 5 WBTC (8 decimals)
        link.mintTo(deployer, 10_000 ether);      // 10,000 LINK
        usdc.mintTo(deployer, 500_000 * 1e6);     // 500k MockUSDC
        console.log("Minted tokens to deployer");
        
        // Seed MockAavePool with MockUSDC for vault borrowing (3M total)
        usdc.mintTo(address(aavePool), 3_000_000 * 1e6);
        console.log("Seeded AavePool with 3M MockUSDC for borrowing");
        
        // Seed MockUniswapPool with initial liquidity for all pairs
        // This is needed so vaults can add liquidity and swaps can work
        _seedPoolLiquidity(deployer);
        
        console.log("");
    }
    
    function _seedPoolLiquidity(address deployer) internal {
        // Mint extra tokens for pool seeding
        weth.mintTo(deployer, 50 ether);
        wbtc.mintTo(deployer, 2 * 1e8);
        link.mintTo(deployer, 5000 ether);
        usdc.mintTo(deployer, 300_000 * 1e6);
        
        // Approve MockUniswapPool
        weth.approve(address(uniswapPool), type(uint256).max);
        wbtc.approve(address(uniswapPool), type(uint256).max);
        link.approve(address(uniswapPool), type(uint256).max);
        usdc.approve(address(uniswapPool), type(uint256).max);

        // Whitelist deployer temporarily for seeding
        uniswapPool.setWhitelistedVault(deployer, true);
        
        // Seed WETH/USDC pool: 10 WETH + 20,000 USDC ($2,000/ETH)
        {
            (uint256 a0, uint256 a1) = _sortAmounts(address(weth), 10 ether, 20_000 * 1e6);
            uniswapPool.addLiquidity(wethPoolKey, a0, a1, 0, 0);
        }
        console.log("Seeded WETH/USDC pool");
        
        // Seed WBTC/USDC pool: 0.5 WBTC + 21,000 USDC ($42,000/BTC)
        {
            (uint256 a0, uint256 a1) = _sortAmounts(address(wbtc), 0.5e8, 21_000 * 1e6);
            uniswapPool.addLiquidity(wbtcPoolKey, a0, a1, 0, 0);
        }
        console.log("Seeded WBTC/USDC pool");
        
        // Seed LINK/USDC pool: 2000 LINK + 30,000 USDC ($15/LINK)
        {
            (uint256 a0, uint256 a1) = _sortAmounts(address(link), 2000 ether, 30_000 * 1e6);
            uniswapPool.addLiquidity(linkPoolKey, a0, a1, 0, 0);
        }
        console.log("Seeded LINK/USDC pool");
        
        // Remove deployer whitelist (optional)
        // uniswapPool.setWhitelistedVault(deployer, false);
    }
    
    /**
     * @dev Sort amounts to match PoolKey currency ordering (currency0 < currency1)
     */
    function _sortAmounts(
        address baseAsset,
        uint256 baseAmount,
        uint256 quoteAmount
    ) internal view returns (uint256 amount0, uint256 amount1) {
        if (baseAsset < address(usdc)) {
            amount0 = baseAmount;   // baseAsset is currency0
            amount1 = quoteAmount;  // usdc is currency1
        } else {
            amount0 = quoteAmount;  // usdc is currency0
            amount1 = baseAmount;   // baseAsset is currency1
        }
    }
    
    // ============ Print Summary ============
    
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
    }
}

/**
 * @title DeployAllLocal
 * @notice Local deployment for Anvil testing
 * @dev Run: anvil & forge script script/DeployAll.s.sol:DeployAllLocal --fork-url http://localhost:8545 --broadcast
 */
contract DeployAllLocal is DeployAll {
    function run() external override {
        // Use Anvil's default private key
        uint256 deployerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("=== LOCAL DEPLOYMENT (Anvil) ===");
        console.log("Deployer:", deployer);
        
        vm.startBroadcast(deployerPrivateKey);
        
        _deployTokens();
        _deployInfrastructure();
        _deployFactory();
        _deployVaults();
        _deployRouter();
        _deployCCIPReceiver();
        _configurePermissions(deployer);
        _seedLiquidity(deployer);
        
        vm.stopBroadcast();
        
        _printSummary();
    }
}

/**
 * @title DeploySourceChain
 * @notice Deploy ApollosRouter only on source chains (Base Sepolia, etc.)
 * @dev This is the lightweight deployment for chains that send cross-chain deposits
 *      Run: forge script script/DeployAll.s.sol:DeploySourceChain --rpc-url base_sepolia --broadcast
 *
 * After deployment:
 *      1. Set the CCIPReceiver address on Arbitrum as the destination
 *      2. Enable Arbitrum chain selector as supported
 *      3. Users can call router.depositCrossChain() to deposit via CCIP
 */
contract DeploySourceChain is Script {
    // Arbitrum Sepolia chain selector for CCIP
    uint64 constant ARB_SEPOLIA_CHAIN_SELECTOR = 3478487238524512106;
    
    // CCIP Router on Base Sepolia
    address constant CCIP_ROUTER_BASE_SEPOLIA = 0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("=== Source Chain Router Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // On source chain, we don't have a factory — Router works standalone
        // We pass address(0) for factory since source chain Router only does cross-chain sends
        ApollosRouter sourceRouter = new ApollosRouter(
            address(0),                    // No factory on source chain  
            address(0),                    // No WETH wrapping needed on source chain
            CCIP_ROUTER_BASE_SEPOLIA,      // Chainlink CCIP Router on this chain
            address(0)                     // No quote asset on source chain
        );
        
        // Enable Arbitrum as destination
        sourceRouter.setSupportedChain(ARB_SEPOLIA_CHAIN_SELECTOR, true);
        
        vm.stopBroadcast();
        
        console.log("");
        console.log("=== SOURCE CHAIN DEPLOYMENT COMPLETE ===");
        console.log("ApollosRouter:", address(sourceRouter));
        console.log("");
        console.log("--- Next Steps ---");
        console.log("1. On Arbitrum: ccipReceiver.setAuthorizedSource(BASE_SELECTOR, sourceRouter, true)");
        console.log("2. On Arbitrum: ccipReceiver.setAssetMapping(USDC_BASE, USDC_ARB_REAL)");
        console.log("3. Frontend: set SOURCE_ROUTER_ADDRESS=", address(sourceRouter));
    }
}
