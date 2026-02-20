// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

/**
 * @title LVRHook
 * @notice Uniswap V4 Hook for Loss-Versus-Rebalancing (LVR) protection.
 * @author Apollos Team
 * @dev This hook implements dynamic swap fees based on real-time market volatility analysis.
 *      Key features:
 *      - `beforeSwap`: Injects a dynamic fee calculated off-chain by Chainlink Workflows.
 *      - `beforeAddLiquidity`: Restricts liquidity provision to whitelisted protocol vaults only.
 *      - Time-lock Fallback: Automatically resets fees to a safe minimum if updates are stale.
 */
contract LVRHook is IHooks, Ownable {
    using PoolIdLibrary for PoolKey;

    /// @notice Flag used by the Pool Manager to recognize a dynamic fee override (bit 24).
    uint24 public constant OVERRIDE_FEE_FLAG = 0x800000;

    /// @notice Maximum safety cap for the dynamic swap fee (50%).
    uint24 public constant MAX_DYNAMIC_FEE = 500000;

    /// @notice Baseline fee applied during periods of low volatility (0.05%).
    uint24 public constant MIN_FEE = 500;

    /// @notice Threshold above which the stale data fallback mechanism is armed (1%).
    uint24 public constant HIGH_FEE_THRESHOLD = 10000;

    /// @notice Maximum allowed time without an update before high fees are reset (6 hours).
    uint256 public constant FALLBACK_TIMEOUT = 6 hours;

    /// @notice Current dynamic fee configured for each pool identifier.
    mapping(PoolId => uint24) public dynamicFees;

    /// @notice Maps addresses to their authorization status for adding liquidity.
    mapping(address => bool) public whitelistedVaults;

    /// @notice Authorized external address allowed to update dynamic fees.
    address public workflowAuthorizer;

    /// @notice The Uniswap V4 Pool Manager (or Mock) that performs the callbacks.
    address public poolManager;

    /// @notice Records the block timestamp of the last fee update for each pool.
    mapping(PoolId => uint256) public lastFeeUpdate;

    /**
     * @notice Emitted when a pool's dynamic fee is updated.
     */
    event DynamicFeeUpdated(PoolId indexed poolId, uint24 oldFee, uint24 newFee, uint256 timestamp);

    /**
     * @notice Emitted when a vault's whitelist status is modified.
     */
    event VaultWhitelisted(address indexed vault, bool status);

    /**
     * @notice Emitted when the authorized workflow address is updated.
     */
    event WorkflowAuthorizerUpdated(address indexed oldAuthorizer, address indexed newAuthorizer);

    /**
     * @notice Emitted when the pool manager address is updated.
     */
    event PoolManagerUpdated(address indexed oldManager, address indexed newManager);

    /**
     * @notice Emitted when an extreme volatility event is logged by the workflow.
     */
    event HighVolatilityDetected(PoolId indexed poolId, uint24 newFee, string reason);

    /// @notice Thrown when an unauthorized caller attempts to update a fee or authorizer.
    error NotAuthorized();

    /// @notice Thrown when a provided fee value exceeds the safety cap.
    error InvalidFee();

    /// @notice Thrown when a non-whitelisted address attempts to add liquidity.
    error NotWhitelistedVault();

    /// @notice Thrown if the callback is received from an unrecognized pool manager.
    error PoolManagerNotSet();

    /**
     * @notice Initializes the LVRHook.
     * @param _poolManager Address of the Uniswap V4 Pool Manager.
     */
    constructor(address _poolManager) Ownable(msg.sender) {
        poolManager = _poolManager;
        workflowAuthorizer = msg.sender;
    }

    /// @dev Restricts access to the owner or the authorized workflow account.
    modifier onlyWorkflowOrOwner() {
        if (msg.sender != workflowAuthorizer && msg.sender != owner()) {
            revert NotAuthorized();
        }
        _;
    }

    /// @dev Ensures the call originates from the configured pool manager.
    modifier onlyPoolManager() {
        if (msg.sender != poolManager) revert PoolManagerNotSet();
        _;
    }

    /**
     * @notice Callback triggered before a swap occurs in the pool manager.
     * @dev Calculates and returns the dynamic fee with the override flag set.
     *      Includes a safety fallback: if high fees are stale (> 6h), they reset to MIN_FEE.
     */
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        external
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();

        uint24 currentFee = dynamicFees[poolId];
        uint256 lastUpdate = lastFeeUpdate[poolId];

        // TIME-LOCK FALLBACK
        if (currentFee > HIGH_FEE_THRESHOLD && lastUpdate > 0) {
            uint256 timeSinceUpdate = block.timestamp - lastUpdate;
            if (timeSinceUpdate > FALLBACK_TIMEOUT) {
                currentFee = MIN_FEE;
            }
        }

        if (currentFee == 0) {
            currentFee = MIN_FEE;
        }

        // Apply override flag bit
        uint24 feeWithFlag = currentFee | OVERRIDE_FEE_FLAG;

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeWithFlag);
    }

    /**
     * @notice Callback triggered before liquidity is added.
     * @dev Validates that the sender is an authorized protocol vault.
     */
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view override returns (bytes4) {
        if (!whitelistedVaults[sender]) {
            revert NotWhitelistedVault();
        }

        return IHooks.beforeAddLiquidity.selector;
    }

    /**
     * @notice Updates the dynamic fee for a specific pool.
     * @dev Called by Chainlink Workflows based on off-chain volatility analysis.
     * @param poolId The ID of the Uniswap V4 pool.
     * @param newFee The new fee in basis points (1e6 = 100%).
     */
    function setDynamicFee(PoolId poolId, uint24 newFee) external onlyWorkflowOrOwner {
        if (newFee > MAX_DYNAMIC_FEE) revert InvalidFee();

        uint24 oldFee = dynamicFees[poolId];
        dynamicFees[poolId] = newFee;
        lastFeeUpdate[poolId] = block.timestamp;

        emit DynamicFeeUpdated(poolId, oldFee, newFee, block.timestamp);
    }

    /**
     * @notice Updates the dynamic fee and logs a reason for the change.
     */
    function setDynamicFeeWithReason(PoolId poolId, uint24 newFee, string calldata reason)
        external
        onlyWorkflowOrOwner
    {
        if (newFee > MAX_DYNAMIC_FEE) revert InvalidFee();

        uint24 oldFee = dynamicFees[poolId];
        dynamicFees[poolId] = newFee;
        lastFeeUpdate[poolId] = block.timestamp;

        emit DynamicFeeUpdated(poolId, oldFee, newFee, block.timestamp);
        emit HighVolatilityDetected(poolId, newFee, reason);
    }

    /**
     * @notice Updates dynamic fees for multiple pools in a single batch.
     */
    function batchSetDynamicFees(PoolId[] calldata poolIds, uint24[] calldata fees) external onlyWorkflowOrOwner {
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
     * @notice Manually resets a pool's fee to the protocol minimum.
     */
    function resetFee(PoolId poolId) external onlyWorkflowOrOwner {
        uint24 oldFee = dynamicFees[poolId];
        dynamicFees[poolId] = MIN_FEE;
        lastFeeUpdate[poolId] = block.timestamp;

        emit DynamicFeeUpdated(poolId, oldFee, MIN_FEE, block.timestamp);
    }

    /**
     * @notice Configures the whitelist status for a vault.
     */
    function setWhitelistedVault(address vault, bool status) external onlyOwner {
        whitelistedVaults[vault] = status;
        emit VaultWhitelisted(vault, status);
    }

    /**
     * @notice Batch configures whitelist status for multiple vaults.
     */
    function batchSetWhitelistedVaults(address[] calldata vaults, bool[] calldata statuses) external onlyOwner {
        require(vaults.length == statuses.length, "Length mismatch");

        for (uint256 i = 0; i < vaults.length; i++) {
            whitelistedVaults[vaults[i]] = statuses[i];
            emit VaultWhitelisted(vaults[i], statuses[i]);
        }
    }

    /**
     * @notice Updates the authorized workflow authorizer address.
     */
    function setWorkflowAuthorizer(address _authorizer) external onlyOwner {
        address oldAuthorizer = workflowAuthorizer;
        workflowAuthorizer = _authorizer;
        emit WorkflowAuthorizerUpdated(oldAuthorizer, _authorizer);
    }

    /**
     * @notice Updates the pool manager address.
     */
    function setPoolManager(address _poolManager) external onlyOwner {
        address oldManager = poolManager;
        poolManager = _poolManager;
        emit PoolManagerUpdated(oldManager, _poolManager);
    }

    /**
     * @notice Returns the effective dynamic fee for a pool.
     */
    function getDynamicFee(PoolId poolId) external view returns (uint24) {
        uint24 fee = dynamicFees[poolId];
        return fee == 0 ? MIN_FEE : fee;
    }

    /**
     * @notice Checks if a vault address is whitelisted.
     */
    function isVaultWhitelisted(address vault) external view returns (bool) {
        return whitelistedVaults[vault];
    }

    /**
     * @notice Returns comprehensive fee metadata for a pool.
     */
    function getFeeInfo(PoolId poolId) external view returns (uint24 fee, uint256 lastUpdate, bool isHighVolatility) {
        fee = dynamicFees[poolId];
        if (fee == 0) fee = MIN_FEE;
        lastUpdate = lastFeeUpdate[poolId];
        isHighVolatility = fee > 10000; // > 1%
    }

    // ============ Unused V4 Hook Placeholders ============

    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
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

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        override
        returns (bytes4, int128)
    {
        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }
}
