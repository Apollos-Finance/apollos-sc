// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// V4 Core Types & Interfaces
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

/**
 * @title LVRHook
 * @notice Uniswap V4 Hook for LVR (Loss-Versus-Rebalancing) Protection
 * @dev Implements IHooks interface:
 *      - beforeSwap: Returns dynamic fee based on market volatility (set by Chainlink Workflow)
 *      - beforeAddLiquidity: Restricts deposits to whitelisted ApollosVaults only
 * 
 * Integration with Chainlink Workflow:
 *      - lvr-protection.ts fetches Binance OHLCV data
 *      - Gemini AI analyzes volatility & sentiment
 *      - Workflow calls setDynamicFee() with new fee based on risk score
 */
contract LVRHook is IHooks, Ownable {
    using PoolIdLibrary for PoolKey;

    // ============ Constants ============
    /// @notice Flag to indicate dynamic fee override (bit 24 = 0x800000)
    /// @dev MUST match DYNAMIC_FEE_FLAG in MockUniswapPool.sol
    uint24 public constant OVERRIDE_FEE_FLAG = 0x800000;
    
    /// @notice Maximum allowed dynamic fee (50% = 500000 in V4 format)
    uint24 public constant MAX_DYNAMIC_FEE = 500000;
    
    /// @notice Minimum fee during normal conditions (0.05% = 500)
    uint24 public constant MIN_FEE = 500;
    
    /// @notice Threshold fee for time-lock fallback (1% = 10000)
    uint24 public constant HIGH_FEE_THRESHOLD = 10000;
    
    /// @notice Time-lock duration before auto-reset (6 hours)
    uint256 public constant FALLBACK_TIMEOUT = 6 hours;

    // ============ State Variables ============
    /// @notice Dynamic fee for each pool (set by Chainlink Workflow)
    mapping(PoolId => uint24) public dynamicFees;
    
    /// @notice Whitelisted ApollosVault addresses
    mapping(address => bool) public whitelistedVaults;
    
    /// @notice Authorized Chainlink Workflow address (can update fees)
    address public workflowAuthorizer;
    
    /// @notice MockUniswapPool address for callback verification
    address public poolManager;
    
    /// @notice Last fee update timestamp per pool
    mapping(PoolId => uint256) public lastFeeUpdate;

    // ============ Events ============
    event DynamicFeeUpdated(PoolId indexed poolId, uint24 oldFee, uint24 newFee, uint256 timestamp);
    event VaultWhitelisted(address indexed vault, bool status);
    event WorkflowAuthorizerUpdated(address indexed oldAuthorizer, address indexed newAuthorizer);
    event PoolManagerUpdated(address indexed oldManager, address indexed newManager);
    event HighVolatilityDetected(PoolId indexed poolId, uint24 newFee, string reason);

    // ============ Errors ============
    error NotAuthorized();
    error InvalidFee();
    error NotWhitelistedVault();
    error PoolManagerNotSet();

    // ============ Constructor ============
    constructor(address _poolManager) Ownable(msg.sender) {
        poolManager = _poolManager;
        workflowAuthorizer = msg.sender; // Owner starts as authorizer
    }

    // ============ Modifiers ============
    modifier onlyWorkflowOrOwner() {
        if (msg.sender != workflowAuthorizer && msg.sender != owner()) {
            revert NotAuthorized();
        }
        _;
    }

    modifier onlyPoolManager() {
        if (msg.sender != poolManager) revert PoolManagerNotSet();
        _;
    }

    // ============ V4 Hook Implementation ============

    /**
     * @notice Called before a swap - returns dynamic fee for LVR protection
     * @dev Chainlink Workflow updates dynamicFees mapping based on volatility analysis
     * @param key The pool key
     * @return selector The function selector
     * @return delta Zero delta (no token modifications)
     * @return fee Dynamic fee with override flag set
     */
    function beforeSwap(
        address /* sender */,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata /* params */,
        bytes calldata /* hookData */
    ) external view override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        
        // Get current dynamic fee (set by Chainlink Workflow)
        uint24 currentFee = dynamicFees[poolId];
        uint256 lastUpdate = lastFeeUpdate[poolId];
        
        // TIME-LOCK FALLBACK: If fee is high and stale, auto-reset to MIN_FEE
        // This prevents the system from being stuck in emergency mode if Workflow dies
        if (currentFee > HIGH_FEE_THRESHOLD && lastUpdate > 0) {
            uint256 timeSinceUpdate = block.timestamp - lastUpdate;
            if (timeSinceUpdate > FALLBACK_TIMEOUT) {
                // Fee is stale (>6 hours) and high (>1%), reset to minimum
                currentFee = MIN_FEE;
            }
        }
        
        // If no dynamic fee set, use minimum
        if (currentFee == 0) {
            currentFee = MIN_FEE;
        }
        
        // Return fee with override flag (tells pool to use this fee)
        uint24 feeWithFlag = currentFee | OVERRIDE_FEE_FLAG;
        
        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            feeWithFlag
        );
    }

    /**
     * @notice Called before liquidity is added - restricts to whitelisted vaults
     * @dev Only ApollosVault contracts should be able to add liquidity
     * @param sender The address adding liquidity (must be whitelisted)
     * @return selector The function selector (reverts if not whitelisted)
     */
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata /* key */,
        IPoolManager.ModifyLiquidityParams calldata /* params */,
        bytes calldata /* hookData */
    ) external view override returns (bytes4) {
        // Check if sender is whitelisted ApollosVault
        if (!whitelistedVaults[sender]) {
            revert NotWhitelistedVault();
        }
        
        return IHooks.beforeAddLiquidity.selector;
    }

    // ============ Dynamic Fee Management (Chainlink Workflow) ============

    /**
     * @notice Set dynamic fee for a pool (called by Chainlink Workflow)
     * @dev This is triggered by lvr-protection.ts when volatility is detected
     * @param poolId The pool identifier
     * @param newFee New fee in V4 format (1e6 = 100%)
     */
    function setDynamicFee(PoolId poolId, uint24 newFee) external onlyWorkflowOrOwner {
        if (newFee > MAX_DYNAMIC_FEE) revert InvalidFee();
        
        uint24 oldFee = dynamicFees[poolId];
        dynamicFees[poolId] = newFee;
        lastFeeUpdate[poolId] = block.timestamp;
        
        emit DynamicFeeUpdated(poolId, oldFee, newFee, block.timestamp);
    }

    /**
     * @notice Set dynamic fee with reason (for logging/monitoring)
     * @param poolId The pool identifier
     * @param newFee New fee
     * @param reason Description of why fee changed (e.g., "High CEX-DEX spread")
     */
    function setDynamicFeeWithReason(
        PoolId poolId, 
        uint24 newFee, 
        string calldata reason
    ) external onlyWorkflowOrOwner {
        if (newFee > MAX_DYNAMIC_FEE) revert InvalidFee();
        
        uint24 oldFee = dynamicFees[poolId];
        dynamicFees[poolId] = newFee;
        lastFeeUpdate[poolId] = block.timestamp;
        
        emit DynamicFeeUpdated(poolId, oldFee, newFee, block.timestamp);
        emit HighVolatilityDetected(poolId, newFee, reason);
    }

    /**
     * @notice Batch update fees for multiple pools
     * @param poolIds Array of pool IDs
     * @param fees Array of fees
     */
    function batchSetDynamicFees(
        PoolId[] calldata poolIds, 
        uint24[] calldata fees
    ) external onlyWorkflowOrOwner {
        require(poolIds.length == fees.length, "Length mismatch");
        
        for (uint256 i = 0; i < poolIds.length; i++) {
            if (fees[i] > MAX_DYNAMIC_FEE) revert InvalidFee();
            
            uint24 oldFee = dynamicFees[poolIds[i]];
            dynamicFees[poolIds[i]] = fees[i];
            lastFeeUpdate[poolIds[i]] = block.timestamp;
            
            emit DynamicFeeUpdated(poolIds[i], oldFee, fees[i], block.timestamp);
        }
    }

    /**
     * @notice Reset fee to minimum (end of high volatility period)
     * @param poolId The pool identifier
     */
    function resetFee(PoolId poolId) external onlyWorkflowOrOwner {
        uint24 oldFee = dynamicFees[poolId];
        dynamicFees[poolId] = MIN_FEE;
        lastFeeUpdate[poolId] = block.timestamp;
        
        emit DynamicFeeUpdated(poolId, oldFee, MIN_FEE, block.timestamp);
    }

    // ============ Vault Whitelist Management ============

    /**
     * @notice Add or remove vault from whitelist
     * @param vault ApollosVault address
     * @param status True to whitelist, false to remove
     */
    function setWhitelistedVault(address vault, bool status) external onlyOwner {
        whitelistedVaults[vault] = status;
        emit VaultWhitelisted(vault, status);
    }

    /**
     * @notice Batch whitelist multiple vaults
     * @param vaults Array of vault addresses
     * @param statuses Array of whitelist statuses
     */
    function batchSetWhitelistedVaults(
        address[] calldata vaults, 
        bool[] calldata statuses
    ) external onlyOwner {
        require(vaults.length == statuses.length, "Length mismatch");
        
        for (uint256 i = 0; i < vaults.length; i++) {
            whitelistedVaults[vaults[i]] = statuses[i];
            emit VaultWhitelisted(vaults[i], statuses[i]);
        }
    }

    // ============ Admin Functions ============

    /**
     * @notice Set the Chainlink Workflow authorizer address
     * @param _authorizer New authorizer address
     */
    function setWorkflowAuthorizer(address _authorizer) external onlyOwner {
        address oldAuthorizer = workflowAuthorizer;
        workflowAuthorizer = _authorizer;
        emit WorkflowAuthorizerUpdated(oldAuthorizer, _authorizer);
    }

    /**
     * @notice Set the pool manager address
     * @param _poolManager New pool manager address
     */
    function setPoolManager(address _poolManager) external onlyOwner {
        address oldManager = poolManager;
        poolManager = _poolManager;
        emit PoolManagerUpdated(oldManager, _poolManager);
    }

    // ============ View Functions ============

    /**
     * @notice Get current dynamic fee for a pool
     * @param poolId The pool identifier
     * @return fee Current dynamic fee
     */
    function getDynamicFee(PoolId poolId) external view returns (uint24) {
        uint24 fee = dynamicFees[poolId];
        return fee == 0 ? MIN_FEE : fee;
    }

    /**
     * @notice Check if a vault is whitelisted
     * @param vault Address to check
     * @return True if whitelisted
     */
    function isVaultWhitelisted(address vault) external view returns (bool) {
        return whitelistedVaults[vault];
    }

    /**
     * @notice Get fee info for a pool
     * @param poolId The pool identifier
     * @return fee Current fee
     * @return lastUpdate Last update timestamp
     * @return isHighVolatility True if fee > 1% (10000)
     */
    function getFeeInfo(PoolId poolId) external view returns (
        uint24 fee,
        uint256 lastUpdate,
        bool isHighVolatility
    ) {
        fee = dynamicFees[poolId];
        if (fee == 0) fee = MIN_FEE;
        lastUpdate = lastFeeUpdate[poolId];
        isHighVolatility = fee > 10000; // > 1%
    }

    // ============ Unused Hook Functions (Required by IHooks) ============
    // These return the selector to indicate they're implemented but do nothing

    function beforeInitialize(
        address,
        PoolKey calldata,
        uint160
    ) external pure override returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(
        address,
        PoolKey calldata,
        uint160,
        int24
    ) external pure override returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, int128) {
        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(
        address,
        PoolKey calldata,
        uint256,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(
        address,
        PoolKey calldata,
        uint256,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IHooks.afterDonate.selector;
    }
}
