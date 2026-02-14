// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {SourceChainRouter} from "../src/core/SourceChainRouter.sol";

/**
 * @title DeploySourceChain
 * @notice Deploy SourceChainRouter on Base Sepolia (source chain for bridging)
 * @dev This is a standalone deployment script for source chains
 * 
 * Usage:
 *   forge script script/DeploySourceChain.s.sol:DeploySourceChain \
 *     --rpc-url https://sepolia.base.org \
 *     --private-key YOUR_PRIVATE_KEY \
 *     --broadcast \
 *
 * After deployment, you MUST:
 *   1. Copy CCIPReceiver address from Arbitrum deployment
 *   2. Call: sourceRouter.setDestinationReceiver(CCIP_RECEIVER_ADDRESS)
 *   3. On Arbitrum: ccipReceiver.setAuthorizedSource(BASE_SELECTOR, sourceRouter, true)
 */
contract DeploySourceChain is Script {
    // ============ Constants ============
    
    /// @notice Arbitrum Sepolia chain selector for CCIP
    uint64 constant ARB_SEPOLIA_CHAIN_SELECTOR = 3478487238524512106;
    
    /// @notice Chainlink CCIP Router on Base Sepolia
    address constant CCIP_ROUTER_BASE_SEPOLIA = 0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93;
    
    /// @notice Base Sepolia USDC (official Chainlink testnet USDC)
    address constant USDC_BASE_SEPOLIA = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    
    // ============ Main Deployment ============
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("========================================");
        console.log("Source Chain Router Deployment");
        console.log("========================================");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", deployer);
        console.log("");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy SourceChainRouter (minimal contract for CCIP bridging)
        SourceChainRouter sourceRouter = new SourceChainRouter(
            CCIP_ROUTER_BASE_SEPOLIA
        );
        console.log("SourceChainRouter deployed:", address(sourceRouter));
        
        // Configure: Enable Arbitrum Sepolia as destination
        sourceRouter.setSupportedChain(ARB_SEPOLIA_CHAIN_SELECTOR, true);
        console.log("Enabled chain selector:", ARB_SEPOLIA_CHAIN_SELECTOR);
        
        // Configure: Whitelist USDC as supported asset
        sourceRouter.setSupportedAsset(USDC_BASE_SEPOLIA, true);
        console.log("Whitelisted asset (USDC):", USDC_BASE_SEPOLIA);
        
        vm.stopBroadcast();
        
        // Print deployment summary
        _printSummary(sourceRouter);
    }
    
    // ============ Helper Functions ============
    
    function _printSummary(SourceChainRouter sourceRouter) internal view {
        console.log("");
        console.log("========================================");
        console.log("DEPLOYMENT COMPLETE");
        console.log("========================================");
        console.log("");
        console.log("--- Deployed Contracts ---");
        console.log("SourceChainRouter:   ", address(sourceRouter));
        console.log("");
        console.log("--- Configuration ---");
        console.log("CCIP Router:         ", CCIP_ROUTER_BASE_SEPOLIA);
        console.log("Supported Asset:     ", USDC_BASE_SEPOLIA);
        console.log("Destination Chain:    Arbitrum Sepolia");
        console.log("");
        console.log("========================================");
        console.log("MANUAL CONFIGURATION REQUIRED");
        console.log("========================================");
        console.log("");
        console.log("Step 1: Get CCIPReceiver address from Arbitrum deployment");
        console.log("        (Check Arbitrum deployment logs or .env file)");
        console.log("");
        console.log("Step 2: Configure SourceChainRouter destination");
        console.log("        Run on Base Sepolia:");
        console.log("        cast send", address(sourceRouter), "\\");
        console.log("          \"setDestinationReceiver(address)\" \\");
        console.log("          <CCIP_RECEIVER_ADDRESS> \\");
        console.log("          --rpc-url $BASE_RPC --private-key $PRIVATE_KEY");
        console.log("");
        console.log("Step 3: Authorize SourceRouter on Arbitrum");
        console.log("        Run on Arbitrum Sepolia:");
        console.log("        cast send <CCIP_RECEIVER_ADDRESS> \\");
        console.log("          \"setAuthorizedSource(uint64,address,bool)\" \\");
        console.log("          10344971235874465080", address(sourceRouter), "true \\");
        console.log("          --rpc-url $ARB_RPC --private-key $PRIVATE_KEY");
        console.log("");
        console.log("Step 4: Update frontend .env");
        console.log("        NEXT_PUBLIC_SOURCE_ROUTER_ADDRESS=", address(sourceRouter));
        console.log("");
        console.log("========================================");
    }
}
