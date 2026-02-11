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

/**
 * @title Deploy
 * @notice Main deployment script for Apollos Finance on Arbitrum Sepolia
 * @dev Run: forge script script/Deploy.s.sol:Deploy --rpc-url $ARBITRUM_SEPOLIA_RPC_URL --broadcast --verify
 */
contract Deploy is Script {
    // Deployed contract addresses
    MockToken public weth;
    MockToken public usdc;
    MockToken public link;
    MockToken public wbtc;
    
    MockUniswapPool public pool;
    MockAavePool public aavePool;
    LVRHook public lvrHook;

    function run() external virtual {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("=== Apollos Finance Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // ============ Step 1: Deploy Mock Tokens ============
        console.log("--- Deploying Mock Tokens ---");
        
        // WETH (isWETH = true)
        weth = new MockToken("Wrapped Ether", "WETH", 18, true);
        console.log("WETH deployed at:", address(weth));
        
        // USDC (isWETH = false)
        usdc = new MockToken("USD Coin", "USDC", 6, false);
        console.log("USDC deployed at:", address(usdc));
        
        // LINK (isWETH = false)
        link = new MockToken("Chainlink", "LINK", 18, false);
        console.log("LINK deployed at:", address(link));
        
        // WBTC (isWETH = false)
        wbtc = new MockToken("Wrapped Bitcoin", "WBTC", 8, false);
        console.log("WBTC deployed at:", address(wbtc));
        
        console.log("");

        // ============ Step 2: Deploy MockUniswapPool ============
        console.log("--- Deploying MockUniswapPool ---");
        pool = new MockUniswapPool();
        console.log("MockUniswapPool deployed at:", address(pool));
        console.log("");

        // ============ Step 3: Deploy LVRHook ============
        console.log("--- Deploying LVRHook ---");
        lvrHook = new LVRHook(address(pool));
        console.log("LVRHook deployed at:", address(lvrHook));
        console.log("");

        // ============ Step 4: Deploy MockAavePool ============
        console.log("--- Deploying MockAavePool ---");
        aavePool = new MockAavePool();
        console.log("MockAavePool deployed at:", address(aavePool));
        
        // Configure WETH reserve: 75% LTV, 80% liquidation, 5% bonus
        aavePool.configureReserve(address(weth), 7500, 8000, 10500);
        console.log("WETH reserve configured");
        
        // Configure USDC reserve: 80% LTV, 85% liquidation, 5% bonus
        aavePool.configureReserve(address(usdc), 8000, 8500, 10500);
        console.log("USDC reserve configured");
        
        // Set initial prices (8 decimals)
        aavePool.setAssetPrice(address(weth), 2000 * 1e8);  // $2000
        aavePool.setAssetPrice(address(usdc), 1 * 1e8);     // $1
        console.log("Asset prices set");
        console.log("");

        // ============ Step 5: Initialize Pools ============
        console.log("--- Initializing Pools ---");
        
        // Ensure currency0 < currency1 (V4 requirement)
        (address token0, address token1) = address(weth) < address(usdc) 
            ? (address(weth), address(usdc)) 
            : (address(usdc), address(weth));
            
        PoolKey memory wethUsdcKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,          // 0.3% base fee
            tickSpacing: 60,    // Standard tick spacing
            hooks: IHooks(address(lvrHook))
        });
        
        pool.initialize(wethUsdcKey);
        console.log("WETH/USDC Pool initialized");
        
        console.log("");

        // ============ Step 6: Configure Permissions ============
        console.log("--- Configuring Permissions ---");
        
        // Pool whitelists LVRHook's vault (placeholder - will be ApollosVault later)
        pool.setWhitelistedVault(deployer, true);
        console.log("Deployer whitelisted in Pool (for testing)");
        
        // LVRHook whitelists deployer for testing
        lvrHook.setWhitelistedVault(deployer, true);
        console.log("Deployer whitelisted in LVRHook (for testing)");
        
        vm.stopBroadcast();

        // ============ Summary ============
        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("");
        console.log("Copy these addresses to your .env:");
        console.log("MOCK_WETH_ADDRESS=", address(weth));
        console.log("MOCK_USDC_ADDRESS=", address(usdc));
        console.log("MOCK_LINK_ADDRESS=", address(link));
        console.log("MOCK_WBTC_ADDRESS=", address(wbtc));
        console.log("MOCK_UNISWAP_POOL_ADDRESS=", address(pool));
        console.log("MOCK_AAVE_POOL_ADDRESS=", address(aavePool));
        console.log("LVR_HOOK_ADDRESS=", address(lvrHook));
    }
}

/**
 * @title DeployLocal
 * @notice Deployment script for local testing (Anvil)
 * @dev Run: forge script script/Deploy.s.sol:DeployLocal --fork-url http://localhost:8545 --broadcast
 */
contract DeployLocal is Deploy {
    function run() external override {
        // Use Anvil's default private key
        uint256 deployerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy all contracts
        weth = new MockToken("Wrapped Ether", "WETH", 18, true);
        usdc = new MockToken("USD Coin", "USDC", 6, false);
        link = new MockToken("Chainlink", "LINK", 18, false);
        wbtc = new MockToken("Wrapped Bitcoin", "WBTC", 8, false);
        
        pool = new MockUniswapPool();
        lvrHook = new LVRHook(address(pool));
        
        // Deploy and configure AavePool
        aavePool = new MockAavePool();
        aavePool.configureReserve(address(weth), 7500, 8000, 10500);
        aavePool.configureReserve(address(usdc), 8000, 8500, 10500);
        aavePool.setAssetPrice(address(weth), 2000 * 1e8);
        aavePool.setAssetPrice(address(usdc), 1 * 1e8);
        
        // Initialize WETH/USDC pool
        (address token0, address token1) = address(weth) < address(usdc) 
            ? (address(weth), address(usdc)) 
            : (address(usdc), address(weth));
            
        PoolKey memory wethUsdcKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(lvrHook))
        });
        
        pool.initialize(wethUsdcKey);
        
        // Whitelist for testing
        address deployer = vm.addr(deployerPrivateKey);
        pool.setWhitelistedVault(deployer, true);
        lvrHook.setWhitelistedVault(deployer, true);
        
        // Mint test tokens
        weth.mintTo(deployer, 1000 ether);
        usdc.mintTo(deployer, 1_000_000 * 1e6); // 1M USDC
        
        vm.stopBroadcast();
        
        console.log("=== Local Deployment Complete ===");
        console.log("WETH:", address(weth));
        console.log("USDC:", address(usdc));
        console.log("Pool:", address(pool));
        console.log("AavePool:", address(aavePool));
        console.log("LVRHook:", address(lvrHook));
    }
}
