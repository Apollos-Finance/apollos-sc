// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {MockToken} from "../src/mocks/MockToken.sol";
import {MockUniswapPool} from "../src/mocks/MockUniswapPool.sol";
import {LVRHook} from "../src/core/LVRHook.sol";

/**
 * @title AddLiquidity
 * @notice Script to add liquidity to existing Uniswap V4 pools
 * @dev Run this AFTER DeployAll.s.sol if you need more liquidity
 * 
 * Usage:
 *   forge script script/AddLiquidity.s.sol:AddLiquidity --rpc-url <RPC> --broadcast
 * 
 * Env Vars Required:
 *   - UNISWAP_POOL_ADDRESS
 *   - LVR_HOOK_ADDRESS
 *   - WETH_ADDRESS, WBTC_ADDRESS, LINK_ADDRESS, USDC_ADDRESS
 */
contract AddLiquidity is Script {
    // ============ Config ============
    
    // Pool configuration (must match DeployAll.s.sol)
    uint24 constant POOL_FEE = 3000;
    int24 constant TICK_SPACING = 60;
    
    // ============ State ============
    
    MockUniswapPool uniswapPool;
    LVRHook lvrHook;
    MockToken weth;
    MockToken wbtc;
    MockToken link;
    MockToken usdc;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("=== Add Liquidity Script ===");
        console.log("Deployer:", deployer);
        
        // 1. Load contracts from env
        _loadContracts();
        
        vm.startBroadcast(deployerPrivateKey);
        
        // 2. Mint tokens to deployer
        _mintTokens(deployer);
        
        // 3. Approve Uniswap
        _approveTokens(address(uniswapPool));
        
        // 4. Whitelist deployer (needed to add liquidity)
        uniswapPool.setWhitelistedVault(deployer, true);
        lvrHook.setWhitelistedVault(deployer, true);
        
        // 5. Add Liquidity
        _addLiquidity();
        
        // 6. Remove whitelist (optional, better to leave it for future testing)
        // uniswapPool.setWhitelistedVault(deployer, false);
        // lvrHook.setWhitelistedVault(deployer, false);
        
        vm.stopBroadcast();
        console.log("=== Liquidity Added Successfully ===");
    }
    
    function _loadContracts() internal {
        uniswapPool = MockUniswapPool(vm.envAddress("UNISWAP_POOL_ADDRESS"));
        lvrHook = LVRHook(vm.envAddress("LVR_HOOK_ADDRESS"));
        
        weth = MockToken(payable(vm.envAddress("WETH_ADDRESS")));
        wbtc = MockToken(payable(vm.envAddress("WBTC_ADDRESS")));
        link = MockToken(payable(vm.envAddress("LINK_ADDRESS")));
        usdc = MockToken(payable(vm.envAddress("USDC_ADDRESS")));
        
        console.log("Loaded Uniswap Pool:", address(uniswapPool));
    }
    
    function _mintTokens(address to) internal {
        // Mint enough for the liquidity addition
        weth.mintTo(to, 1000 ether);
        wbtc.mintTo(to, 50 * 1e8);
        usdc.mintTo(to, 6_000_000 * 1e6); // Covers both pools
        console.log("Minted fresh tokens to deployer");
    }
    
    function _approveTokens(address spender) internal {
        weth.approve(spender, type(uint256).max);
        wbtc.approve(spender, type(uint256).max);
        usdc.approve(spender, type(uint256).max);
        console.log("Approved tokens");
    }
    
    function _addLiquidity() internal {
        // --- 1. WETH/USDC Pool ---
        // Amount: 1,000 WETH + 2,000,000 USDC ($2,000/ETH)
        PoolKey memory wethKey = _getPoolKey(address(weth), address(usdc));
        {
            (uint256 a0, uint256 a1) = _sortAmounts(address(weth), 1000 ether, 2_000_000 * 1e6);
            uniswapPool.addLiquidity(wethKey, a0, a1, 0, 0);
            console.log("Added liquidity to WETH/USDC pool");
        }
        
        // --- 2. WBTC/USDC Pool ---
        // Amount: 50 WBTC + 3,500,000 USDC ($70,000/BTC)
        PoolKey memory wbtcKey = _getPoolKey(address(wbtc), address(usdc));
        {
            (uint256 a0, uint256 a1) = _sortAmounts(address(wbtc), 50 * 1e8, 3_500_000 * 1e6);
            uniswapPool.addLiquidity(wbtcKey, a0, a1, 0, 0);
             console.log("Added liquidity to WBTC/USDC pool");
        }
    }
    
    // --- Helpers ---
    
    function _getPoolKey(address tokenA, address tokenB) internal view returns (PoolKey memory) {
        (Currency currency0, Currency currency1) = _sortCurrencies(tokenA, tokenB);
        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(lvrHook))
        });
    }

    function _sortCurrencies(address tokenA, address tokenB) internal pure returns (Currency currency0, Currency currency1) {
        if (tokenA < tokenB) {
            currency0 = Currency.wrap(tokenA);
            currency1 = Currency.wrap(tokenB);
        } else {
            currency0 = Currency.wrap(tokenB);
            currency1 = Currency.wrap(tokenA);
        }
    }
    
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
}
