// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {SourceChainRouter} from "../src/core/SourceChainRouter.sol";
import {IApollosCCIPReceiver} from "../src/interfaces/IApollosCCIPReceiver.sol";

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
 *     --multi \
 *
 * Required env:
 *   CCIP_RECEIVER_ADDRESS_ON_ARBITRUM=<receiver_address>
 *   RPC_URL=<arbitrum_rpc_url>
 */
contract DeploySourceChain is Script {
    // ============ Constants ============
    
    /// @notice Arbitrum Sepolia chain selector for CCIP
    uint64 constant ARB_SEPOLIA_CHAIN_SELECTOR = 3478487238524512106;

    /// @notice Base Sepolia chain selector for CCIP
    uint64 constant BASE_SEPOLIA_CHAIN_SELECTOR = 10344971235874465080;

    /// @notice Arbitrum Sepolia chain id
    uint256 constant ARB_SEPOLIA_CHAIN_ID = 421614;

    /// @notice Base Sepolia chain id
    uint256 constant BASE_SEPOLIA_CHAIN_ID = 84532;
    
    /// @notice Chainlink CCIP Router on Base Sepolia
    address constant CCIP_ROUTER_BASE_SEPOLIA = 0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93;
    
    /// @notice Base Sepolia CCIP-BnM (Chainlink test token for CCIP)
    /// 1 CCIP-BnM = 10 USDC equivalent for vault share calculations
    address constant CCIP_BNM_BASE_SEPOLIA = 0x88A2d74F47a237a62e7A51cdDa67270CE381555e;
    
    // ============ Main Deployment ============
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address ccipReceiverOnArbitrum = vm.envAddress("CCIP_RECEIVER_ADDRESS_ON_ARBITRUM");
        string memory arbitrumRpcUrl = vm.envString("RPC_URL");
        
        console.log("========================================");
        console.log("Source Chain Router Deployment");
        console.log("========================================");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", deployer);
        console.log("CCIPReceiver (Arbitrum):", ccipReceiverOnArbitrum);
        console.log("");

        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "DeploySourceChain must run on Base Sepolia");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy SourceChainRouter (minimal contract for CCIP bridging)
        SourceChainRouter sourceRouter = new SourceChainRouter(
            CCIP_ROUTER_BASE_SEPOLIA
        );
        console.log("SourceChainRouter deployed:", address(sourceRouter));
        
        // Configure: Enable Arbitrum Sepolia as destination
        sourceRouter.setSupportedChain(ARB_SEPOLIA_CHAIN_SELECTOR, true);
        console.log("Enabled chain selector:", ARB_SEPOLIA_CHAIN_SELECTOR);
        
        // Configure: Whitelist CCIP-BnM as supported asset (1 CCIP-BnM = 10 USDC equivalent)
        sourceRouter.setSupportedAsset(CCIP_BNM_BASE_SEPOLIA, true);
        console.log("Whitelisted asset (CCIP-BnM):", CCIP_BNM_BASE_SEPOLIA);

        // Configure destination receiver directly from env
        sourceRouter.setDestinationReceiver(ccipReceiverOnArbitrum);
        console.log("Destination receiver set:", ccipReceiverOnArbitrum);
        
        vm.stopBroadcast();

        // Auto-authorize this SourceChainRouter on Arbitrum CCIPReceiver
        _authorizeSourceOnArbitrum(
            deployerPrivateKey,
            arbitrumRpcUrl,
            ccipReceiverOnArbitrum,
            address(sourceRouter)
        );
        
        // Print deployment summary
        _printSummary(sourceRouter, ccipReceiverOnArbitrum);
    }
    
    // ============ Helper Functions ============
    
    function _authorizeSourceOnArbitrum(
        uint256 deployerPrivateKey,
        string memory arbitrumRpcUrl,
        address ccipReceiverOnArbitrum,
        address sourceRouter
    ) internal {
        console.log("");
        console.log("Switching to Arbitrum Sepolia for authorization...");

        vm.createSelectFork(arbitrumRpcUrl);
        require(block.chainid == ARB_SEPOLIA_CHAIN_ID, "RPC_URL is not Arbitrum Sepolia");

        vm.startBroadcast(deployerPrivateKey);
        IApollosCCIPReceiver(ccipReceiverOnArbitrum).setAuthorizedSource(
            BASE_SEPOLIA_CHAIN_SELECTOR,
            sourceRouter,
            true
        );
        vm.stopBroadcast();

        console.log("Authorized source on Arbitrum CCIPReceiver");
    }

    function _printSummary(SourceChainRouter sourceRouter, address ccipReceiverOnArbitrum) internal view {
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
        console.log("Supported Asset:      CCIP-BnM (1 = 10 USDC equivalent)");
        console.log("CCIP-BnM Address:    ", CCIP_BNM_BASE_SEPOLIA);
        console.log("Destination Chain:    Arbitrum Sepolia");
        console.log("Destination Receiver: ", ccipReceiverOnArbitrum);
        console.log("");
        console.log("No manual post-deploy setup required.");
        console.log("Update frontend .env:");
        console.log("NEXT_PUBLIC_SOURCE_ROUTER_ADDRESS=", address(sourceRouter));
        console.log("");
        console.log("========================================");
    }
}
