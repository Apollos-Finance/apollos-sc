// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IApollosVault} from "../interfaces/IApollosVault.sol";
import {IMockAavePool} from "../interfaces/IMockAavePool.sol";
import {IMockUniswapPool} from "../interfaces/IMockUniswapPool.sol";
import {IDataFeedsCache} from "../interfaces/IDataFeedsCache.sol";

/**
 * @title ApollosVault
 * @notice ERC4626 Leveraged Yield Vault with Hybrid NAV system.
 * @author Apollos Team
 * @dev This vault employs a 2x leverage strategy by borrowing quote assets from Aave
 *      and providing liquidity to Uniswap V4. It uses a "Hybrid NAV" system:
 *      - Priority Path: Off-chain computed NAV from Chainlink Workflows + Real-time Flow Deltas.
 *      - Fallback Path: Real-time on-chain math valuation (used when feed is stale).
 */
contract ApollosVault is IApollosVault, ERC4626, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    /// @notice Precision multiplier for internal math (18 decimals).
    uint256 public constant PRECISION = 1e18;

    /// @notice Basis points denominator (100% = 10000).
    uint256 public constant BPS = 10000;

    /// @notice Safety cap for the idle withdrawal buffer (30%).
    uint256 public constant MAX_IDLE_BUFFER_BPS = 3000;

    /// @notice Upper health factor band used to trigger releverage (scaled by 1e18).
    uint256 public constant HF_UPPER_BAND = 2.2e18;

    /// @notice The stable asset borrowed to create leverage (e.g., USDC).
    IERC20 public immutable quoteAsset;

    /// @notice The simulated Aave V3 Pool used for borrowing.
    IMockAavePool public immutable aavePool;

    /// @notice The simulated Uniswap V4 Pool used for yield.
    IMockUniswapPool public immutable uniswapPool;

    /// @notice The V4 PoolKey for this vault's liquidity pair.
    PoolKey public poolKey;

    /// @notice Current leverage strategy configuration.
    VaultConfig public config;

    /// @notice Pause status of the vault.
    bool public paused;

    /// @notice Borrow circuit breaker status.
    bool public borrowPaused;

    /// @notice Maps rebalancer addresses to their authorization status.
    mapping(address => bool) public authorizedRebalancers;

    /// @notice Current LP token balance held by the vault.
    uint256 public lpTokenBalance;

    /// @notice Protocol fee in basis points.
    uint256 public protocolFee;

    /// @notice Address where collected fees are sent.
    address public treasury;

    /// @notice Amount of collected but unwithdrawn protocol fees.
    uint256 public pendingFees;

    /// @notice Minimum deposit amount to prevent rounding attacks and dust.
    uint256 public MIN_DEPOSIT;

    /// @notice Shared data feed cache for off-chain NAV updates.
    IDataFeedsCache public dataFeedsCache;

    /// @notice Unique identifier for this vault's NAV feed in the cache.
    bytes32 public navDataId;

    /// @notice Maximum allowed time (in seconds) before the NAV feed is considered stale.
    uint256 public maxOracleAge;

    /// @notice Target percentage of assets kept idle for fast withdrawals.
    uint256 public idleBufferBps;

    /// @notice Cumulative flow delta (deposits - withdrawals) since the last oracle update.
    int256 public netFlowSinceLastUpdate;

    /// @notice Timestamp of the last processed oracle checkpoint.
    uint256 public lastOracleUpdatedAt;

    /**
     * @notice Emitted when the data feed configuration is updated.
     */
    event DataFeedConfigUpdated(address indexed cache, bytes32 indexed dataId, uint256 maxOracleAge);

    /**
     * @notice Emitted when a keeper's authorization status is updated.
     */
    event KeeperUpdated(address indexed keeper, bool authorized);

    /**
     * @notice Emitted when the idle buffer target is changed.
     */
    event IdleBufferUpdated(uint256 oldBps, uint256 newBps);

    /**
     * @notice Emitted when the net flow delta is reset during an oracle synchronization.
     */
    event NetFlowReset(uint256 oracleUpdatedAt);

    /// @notice Thrown when an outdated NAV update method is called.
    error DeprecatedNAVUpdate();

    /// @dev Reverts if the vault is paused.
    modifier whenNotPaused() {
        if (paused) revert VaultPaused();
        _;
    }

    /// @dev Reverts if the caller is neither the owner nor an authorized rebalancer.
    modifier onlyRebalancer() {
        if (!authorizedRebalancers[msg.sender] && msg.sender != owner()) {
            revert NotAuthorized();
        }
        _;
    }

    /**
     * @notice Initializes the ApollosVault.
     * @param _name Descriptive name for the afToken.
     * @param _symbol Ticker symbol for the afToken.
     * @param _baseAsset Underlying asset (e.g., WETH).
     * @param _quoteAsset Borrowed asset (e.g., USDC).
     * @param _aavePool Simulated Aave pool address.
     * @param _uniswapPool Simulated Uniswap pool address.
     * @param _poolKey Uniswap V4 PoolKey structure.
     * @param _targetLeverage Desired leverage (1e18 scale).
     * @param _maxLeverage Emergency deleverage threshold (1e18 scale).
     */
    constructor(
        string memory _name,
        string memory _symbol,
        address _baseAsset,
        address _quoteAsset,
        address _aavePool,
        address _uniswapPool,
        PoolKey memory _poolKey,
        uint256 _targetLeverage,
        uint256 _maxLeverage
    ) ERC4626(IERC20(_baseAsset)) ERC20(_name, _symbol) Ownable(msg.sender) {
        if (_quoteAsset == address(0)) revert ZeroAddress();
        if (_aavePool == address(0) || _uniswapPool == address(0)) revert ZeroAddress();

        quoteAsset = IERC20(_quoteAsset);
        aavePool = IMockAavePool(_aavePool);
        uniswapPool = IMockUniswapPool(_uniswapPool);
        poolKey = _poolKey;

        config = VaultConfig({
            baseAsset: _baseAsset,
            quoteAsset: _quoteAsset,
            targetLeverage: _targetLeverage,
            maxLeverage: _maxLeverage,
            rebalanceThreshold: 1.8e18
        });

        protocolFee = 100; // 1%
        maxOracleAge = 1800; // 30 minutes fallback threshold
        idleBufferBps = 1000; // 10%

        uint8 tokenDecimals = _getDecimals(_baseAsset);
        if (tokenDecimals >= 6) {
            MIN_DEPOSIT = 10 ** (tokenDecimals - 6);
        } else {
            MIN_DEPOSIT = 1;
        }
    }

    /**
     * @notice Syncs the oracle checkpoint and resets net flow delta.
     * @dev Called by Chainlink Workflows or manual operators to finalize an NAV update cycle.
     */
    function updateNAV(uint256) external override onlyRebalancer {
        _syncOracleCheckpoint();
        netFlowSinceLastUpdate = 0;
        emit NetFlowReset(lastOracleUpdatedAt);
    }

    /**
     * @notice Returns the total quantity of base assets managed by the vault.
     * @dev Implements the Hybrid NAV logic:
     *      1. If a fresh feed exists: Cached NAV + Flow Delta.
     *      2. Else: Real-time on-chain fallback calculation.
     * @return Total assets in base asset units.
     */
    function totalAssets() public view override(ERC4626, IApollosVault) returns (uint256) {
        if (address(dataFeedsCache) != address(0) && navDataId != bytes32(0)) {
            // Feed decimals must match base asset decimals to avoid conversion mismatch.
            if (dataFeedsCache.decimals(navDataId) != decimals()) {
                revert InvalidOracleConfig();
            }

            (, int256 answer,, uint256 updatedAt,) = dataFeedsCache.latestRoundData(navDataId);
            bool isFresh = updatedAt != 0 && block.timestamp - updatedAt <= maxOracleAge;

            if (isFresh && answer > 0) {
                int256 effectiveNetFlow = updatedAt > lastOracleUpdatedAt ? int256(0) : netFlowSinceLastUpdate;
                return _applyNetFlow(uint256(answer), effectiveNetFlow);
            }
        }

        // Fallback source when feed is stale/missing/invalid.
        return _getRealtimeNavFromOnchain();
    }

    /**
     * @notice Standard ERC4626 deposit function.
     * @dev Automatically deploys assets into the leveraged strategy.
     * @param assets Amount of base asset to deposit.
     * @param receiver Recipient of the afTokens.
     * @return shares Quantity of shares issued.
     */
    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626, IApollosVault)
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        if (receiver == address(0)) revert ZeroAddress();
        return _deposit(assets, receiver, 0);
    }

    /**
     * @notice Deposits assets on behalf of another receiver with slippage protection.
     * @dev Used by the ApollosRouter and CCIP Receiver.
     */
    function depositFor(uint256 amount, address receiver, uint256 minShares)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (receiver == address(0)) revert ZeroAddress();
        return _deposit(amount, receiver, minShares);
    }

    /**
     * @dev Internal implementation of the deposit logic including immediate deployment.
     */
    function _deposit(uint256 amount, address receiver, uint256 minShares) internal returns (uint256 shares) {
        if (amount < MIN_DEPOSIT) revert ZeroAmount();

        _syncOracleCheckpoint();

        shares = previewDeposit(amount);
        if (shares < minShares) revert SlippageExceeded();

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);

        // Immediate deploy mode: borrow quote and add leveraged LP instantly.
        uint256 borrowAmount;
        if (!borrowPaused) {
            borrowAmount = _calculateBorrowAmount(amount);
            if (borrowAmount > 0) {
                quoteAsset.safeIncreaseAllowance(address(aavePool), borrowAmount);
                aavePool.borrow(address(quoteAsset), borrowAmount, 2, 0, address(this));

                uint256 lpReceived = _addLiquidity(amount, borrowAmount);
                lpTokenBalance += lpReceived;
            }
        }

        _mint(receiver, shares);
        _increaseNetFlow(amount);

        emit Deposit(receiver, amount, shares, borrowAmount);
    }

    /**
     * @notice Withdraws base assets by burning afToken shares.
     * @dev Automatically removes liquidity and repays debt proportionally to fulfill the withdrawal.
     * @param shares Number of afTokens to burn.
     * @param minAmount Minimum acceptable base asset quantity (slippage).
     * @return amount Final quantity of base assets returned.
     */
    function withdraw(uint256 shares, uint256 minAmount)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 amount)
    {
        if (shares == 0) revert ZeroAmount();
        if (balanceOf(msg.sender) < shares) revert InsufficientShares();

        _syncOracleCheckpoint();

        uint256 currentTotalSupply = totalSupply();
        uint256 debtRepaid;
        uint256 lpToRemove = lpTokenBalance == 0 ? 0 : (lpTokenBalance * shares) / currentTotalSupply;
        uint256 totalDebt = _getTotalDebt();
        uint256 debtToRepay = totalDebt == 0 ? 0 : (totalDebt * shares) / currentTotalSupply;
        uint256 quoteReceived;

        if (lpToRemove > 0) {
            (uint256 amount0Received, uint256 amount1Received) = _removeLiquidity(lpToRemove);
            lpTokenBalance -= lpToRemove;

            address currency0 = Currency.unwrap(poolKey.currency0);
            if (currency0 == address(asset())) {
                quoteReceived = amount1Received;
            } else {
                quoteReceived = amount0Received;
            }
        }

        if (debtToRepay > 0 && quoteReceived > 0) {
            uint256 repayAmount = quoteReceived > debtToRepay ? debtToRepay : quoteReceived;
            quoteAsset.safeIncreaseAllowance(address(aavePool), repayAmount);
            aavePool.repay(address(quoteAsset), repayAmount, 2, address(this));
            quoteReceived -= repayAmount;
            debtRepaid = repayAmount;
        }

        if (quoteReceived > 0) {
            _swapQuoteToBase(quoteReceived);
        }

        uint256 idleBalance = IERC20(asset()).balanceOf(address(this));
        amount = (idleBalance * shares) / currentTotalSupply;
        if (amount < minAmount) revert SlippageExceeded();
        if (amount > idleBalance) revert InsufficientIdleLiquidity();

        _burn(msg.sender, shares);
        IERC20(asset()).safeTransfer(msg.sender, amount);
        _decreaseNetFlow(amount);

        emit Withdraw(msg.sender, shares, amount, debtRepaid);
    }

    /**
     * @notice Rebalances the vault to restore its target leverage ratio.
     * @dev Called by Chainlink Keepers. Deploys idle capital or deleverages as needed.
     * @return newLeverage The leverage ratio achieved after rebalancing.
     */
    function rebalance() external override onlyRebalancer nonReentrant returns (uint256 newLeverage) {
        _syncOracleCheckpoint();

        uint256 oldLeverage = _safeGetCurrentLeverage();
        uint256 effectiveHF = _getEffectiveHealthFactor();
        bool didAction;
        uint256 debtRepaid;

        uint256 idleBalance = IERC20(asset()).balanceOf(address(this));
        // Keep withdrawal buffer from currently idle liquidity only.
        uint256 targetIdle = (idleBalance * idleBufferBps) / BPS;

        // Deploy excess idle above configured withdrawal buffer.
        if (!borrowPaused && idleBalance > targetIdle) {
            uint256 deployAmount = idleBalance - targetIdle;
            uint256 borrowAmount = _calculateBorrowAmount(deployAmount);

            if (borrowAmount > 0) {
                quoteAsset.safeIncreaseAllowance(address(aavePool), borrowAmount);
                aavePool.borrow(address(quoteAsset), borrowAmount, 2, 0, address(this));

                uint256 lpReceived = _addLiquidity(deployAmount, borrowAmount);
                lpTokenBalance += lpReceived;
                didAction = true;
            }
        }

        // If HF is too high (underleveraged), releverage by recycling a small LP slice when idle is unavailable.
        if (
            !borrowPaused && effectiveHF > HF_UPPER_BAND && effectiveHF != type(uint256).max && !didAction
                && lpTokenBalance > 0
        ) {
            uint256 lpToRecycle = lpTokenBalance / 20; // 5% LP recycle for incremental releverage.
            if (lpToRecycle == 0) lpToRecycle = lpTokenBalance;

            if (lpToRecycle > 0 && lpToRecycle <= lpTokenBalance) {
                (uint256 amount0Received, uint256 amount1Received) = _removeLiquidity(lpToRecycle);
                lpTokenBalance -= lpToRecycle;

                address currency0 = Currency.unwrap(poolKey.currency0);
                uint256 baseReceived = currency0 == address(asset()) ? amount0Received : amount1Received;
                uint256 quoteReceived = currency0 == address(asset()) ? amount1Received : amount0Received;

                if (baseReceived > 0) {
                    uint256 targetQuoteForBase = _calculateBorrowAmount(baseReceived);
                    uint256 extraBorrow = targetQuoteForBase > quoteReceived ? targetQuoteForBase - quoteReceived : 0;

                    if (extraBorrow > 0) {
                        quoteAsset.safeIncreaseAllowance(address(aavePool), extraBorrow);
                        aavePool.borrow(address(quoteAsset), extraBorrow, 2, 0, address(this));
                    }

                    uint256 quoteToAdd = quoteReceived + extraBorrow;
                    uint256 lpReceived = _addLiquidity(baseReceived, quoteToAdd);
                    lpTokenBalance += lpReceived;
                    didAction = true;
                }
            }
        }

        // Deleverage if HF is below configured lower band.
        if (effectiveHF < config.rebalanceThreshold && effectiveHF != type(uint256).max) {
            uint256 lpToRemove = _calculateRebalanceAmount();
            if (lpToRemove > 0 && lpToRemove <= lpTokenBalance) {
                (uint256 amount0Received, uint256 amount1Received) = _removeLiquidity(lpToRemove);
                address currency0 = Currency.unwrap(poolKey.currency0);
                uint256 quoteReceived = currency0 == address(asset()) ? amount1Received : amount0Received;
                lpTokenBalance -= lpToRemove;

                if (quoteReceived > 0) {
                    quoteAsset.safeIncreaseAllowance(address(aavePool), quoteReceived);
                    aavePool.repay(address(quoteAsset), quoteReceived, 2, address(this));
                    debtRepaid = quoteReceived;
                }

                didAction = true;
            }
        }

        if (!didAction) revert RebalanceNotNeeded();

        newLeverage = _safeGetCurrentLeverage();
        emit Rebalance(oldLeverage, newLeverage, debtRepaid, block.timestamp);
    }

    /**
     * @notice Allows users to exit positions during protocol emergencies.
     */
    function emergencyWithdraw(uint256 shares) external override returns (uint256 amount) {
        amount = withdraw(shares, 0);
        emit EmergencyWithdraw(msg.sender, shares, amount);
    }

    /**
     * @notice Returns the current leverage configuration.
     */
    function getVaultConfig() external view override returns (VaultConfig memory) {
        return config;
    }

    /**
     * @notice Returns a detailed snapshot of the vault state.
     */
    function getVaultState() external view override returns (VaultState memory) {
        return VaultState({
            totalBaseAssets: totalAssets(),
            totalBorrowed: _getTotalDebt(),
            lpTokenValue: lpTokenBalance,
            totalShares: totalSupply(),
            healthFactor: getHealthFactor(),
            currentLeverage: getCurrentLeverage()
        });
    }

    /**
     * @notice Overrides previewDeposit to use the hybrid NAV system.
     */
    function previewDeposit(uint256 amount) public view override(ERC4626, IApollosVault) returns (uint256) {
        return super.previewDeposit(amount);
    }

    /**
     * @notice Overrides previewWithdraw to use the hybrid NAV system.
     */
    function previewWithdraw(uint256 shares) public view override(ERC4626, IApollosVault) returns (uint256) {
        return super.previewRedeem(shares);
    }

    /**
     * @notice Returns the current value of one share in terms of the base asset.
     */
    function getSharePrice() external view override returns (uint256 price) {
        return convertToAssets(PRECISION);
    }

    /**
     * @notice Returns the current Aave health factor.
     */
    function getHealthFactor() public view override returns (uint256 healthFactor) {
        (,,,,, uint256 aaveHealthFactor) = aavePool.getUserAccountData(address(this));
        if (aaveHealthFactor > 0 && aaveHealthFactor != type(uint256).max) {
            return aaveHealthFactor;
        }

        // Credit-delegation mode can report zero/INF despite active debt; use leverage-derived HF.
        return _getEffectiveHealthFactor();
    }

    /**
     * @notice Calculates the effective current leverage ratio.
     */
    function getCurrentLeverage() public view override returns (uint256 leverage) {
        uint256 totalDebt = _getTotalDebt();
        uint256 assets = totalAssets();
        uint256 debtInBase = _convertQuoteToBase(totalDebt);

        if (assets == 0) return PRECISION;
        leverage = ((assets + debtInBase) * PRECISION) / assets;
    }

    /**
     * @notice Checks if the vault requires a rebalance.
     */
    function needsRebalance() public view override returns (bool needed) {
        uint256 hf = _getEffectiveHealthFactor();
        if (hf == type(uint256).max) return false;
        return hf < config.rebalanceThreshold || hf > HF_UPPER_BAND;
    }

    /**
     * @notice Returns the number of decimals for vault shares.
     */
    function decimals() public view override(ERC4626) returns (uint8) {
        return super.decimals();
    }

    /**
     * @notice Returns the total afToken supply.
     */
    function totalSupply() public view override(ERC20, IERC20, IApollosVault) returns (uint256) {
        return super.totalSupply();
    }

    /**
     * @notice Returns the afToken balance of a user.
     */
    function balanceOf(address account) public view override(ERC20, IERC20, IApollosVault) returns (uint256) {
        return super.balanceOf(account);
    }

    /**
     * @dev Disables the default ERC4626 withdraw method in favor of the custom one.
     */
    function withdraw(uint256, address, address) public pure override(ERC4626) returns (uint256) {
        revert("Use withdraw(shares, minAmount)");
    }

    /**
     * @notice Updates the strategy configuration.
     */
    function updateConfig(uint256 _targetLeverage, uint256 _maxLeverage, uint256 _rebalanceThreshold)
        external
        override
        onlyOwner
    {
        config.targetLeverage = _targetLeverage;
        config.maxLeverage = _maxLeverage;
        config.rebalanceThreshold = _rebalanceThreshold;
    }

    /**
     * @notice Toggles the pause state.
     */
    function setPaused(bool _paused) external override onlyOwner {
        paused = _paused;
    }

    /**
     * @notice Toggles the borrow circuit breaker.
     */
    function setBorrowPaused(bool _paused) external override onlyRebalancer {
        if (borrowPaused == _paused) return;
        bool oldPaused = borrowPaused;
        borrowPaused = _paused;
        emit BorrowPauseUpdated(oldPaused, _paused, msg.sender);
    }

    /**
     * @notice Authorizes a rebalancer address.
     */
    function setRebalancer(address rebalancer, bool authorized) external override onlyOwner {
        authorizedRebalancers[rebalancer] = authorized;
        emit KeeperUpdated(rebalancer, authorized);
    }

    /**
     * @notice Authorizes a keeper address.
     */
    function setKeeper(address keeper, bool authorized) external override onlyOwner {
        authorizedRebalancers[keeper] = authorized;
        emit KeeperUpdated(keeper, authorized);
    }

    /**
     * @notice Configures the off-chain data source for NAV updates.
     */
    function setDataFeedConfig(address cache, bytes32 dataId, uint256 maxAge) external override onlyOwner {
        if (cache == address(0)) revert ZeroAddress();
        if (dataId == bytes32(0) || maxAge == 0) revert InvalidOracleConfig();

        dataFeedsCache = IDataFeedsCache(cache);
        navDataId = dataId;
        maxOracleAge = maxAge;
        _syncOracleCheckpoint();
        netFlowSinceLastUpdate = 0;
        emit NetFlowReset(lastOracleUpdatedAt);

        emit DataFeedConfigUpdated(cache, dataId, maxAge);
    }

    /**
     * @notice Updates the maximum allowed age for the NAV feed.
     */
    function setMaxOracleAge(uint256 maxAge) external override onlyOwner {
        if (maxAge == 0) revert InvalidOracleConfig();
        maxOracleAge = maxAge;
    }

    /**
     * @notice Updates the target idle buffer percentage.
     */
    function setIdleBufferBps(uint256 bps) external override onlyOwner {
        if (bps == 0 || bps > MAX_IDLE_BUFFER_BPS) revert InvalidOracleConfig();
        uint256 oldBps = idleBufferBps;
        idleBufferBps = bps;
        emit IdleBufferUpdated(oldBps, bps);
    }

    /**
     * @notice Updates the protocol treasury address.
     */
    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }

    /**
     * @notice Updates the protocol fee.
     */
    function setProtocolFee(uint256 _fee) external onlyOwner {
        protocolFee = _fee;
    }

    /**
     * @dev Calculates the amount of quote asset to borrow based on the target leverage.
     */
    function _calculateBorrowAmount(uint256 baseAmount) internal view returns (uint256) {
        uint256 basePrice = aavePool.assetPrices(address(asset()));
        uint256 quotePrice = aavePool.assetPrices(address(quoteAsset));

        if (basePrice == 0 || quotePrice == 0) return 0;

        uint8 baseDecimals = _getDecimals(address(asset()));
        uint8 quoteDecimals = _getDecimals(address(quoteAsset));

        uint256 borrowValue = (baseAmount * basePrice) / (10 ** baseDecimals);
        uint256 borrowAmount = (borrowValue * (10 ** quoteDecimals)) / quotePrice;

        return borrowAmount;
    }

    /**
     * @dev Internal helper to add liquidity to the MockUniswapPool.
     */
    function _addLiquidity(uint256 baseAmount, uint256 quoteAmount) internal returns (uint256 lpReceived) {
        address currency0 = Currency.unwrap(poolKey.currency0);
        address currency1 = Currency.unwrap(poolKey.currency1);

        uint256 amount0;
        uint256 amount1;

        if (currency0 == address(asset()) && currency1 == address(quoteAsset)) {
            amount0 = baseAmount;
            amount1 = quoteAmount;
        } else if (currency0 == address(quoteAsset) && currency1 == address(asset())) {
            amount0 = quoteAmount;
            amount1 = baseAmount;
        } else {
            revert ZeroAddress();
        }

        if (amount0 == 0 || amount1 == 0) revert SlippageExceeded();

        IERC20(currency0).safeIncreaseAllowance(address(uniswapPool), amount0);
        IERC20(currency1).safeIncreaseAllowance(address(uniswapPool), amount1);

        (,, lpReceived) = uniswapPool.addLiquidity(poolKey, amount0, amount1, 1, 1);
        if (lpReceived == 0) revert SlippageExceeded();
    }

    /**
     * @dev Internal helper to remove liquidity.
     */
    function _removeLiquidity(uint256 lpAmount) internal returns (uint256 baseReceived, uint256 quoteReceived) {
        (baseReceived, quoteReceived) = uniswapPool.removeLiquidity(poolKey, lpAmount, 0, 0);
    }

    /**
     * @dev Returns total outstanding debt in Aave.
     */
    function _getTotalDebt() internal view returns (uint256) {
        return aavePool.getUserDebt(address(this), address(quoteAsset));
    }

    /**
     * @dev Calculates the amount of liquidity to remove to deleverage back to target.
     */
    function _calculateRebalanceAmount() internal view returns (uint256) {
        uint256 currentLev;
        try this.getCurrentLeverage() returns (uint256 lev) {
            currentLev = lev;
        } catch {
            return lpTokenBalance / 10;
        }

        uint256 targetLev = config.targetLeverage;

        if (currentLev <= targetLev) return 0;
        uint256 excessLeverage = currentLev - targetLev;
        return (lpTokenBalance * excessLeverage) / currentLev;
    }

    /**
     * @dev Internal helper to safely retrieve current leverage.
     */
    function _safeGetCurrentLeverage() internal view returns (uint256 leverage) {
        try this.getCurrentLeverage() returns (uint256 lev) {
            return lev;
        } catch {
            return PRECISION;
        }
    }

    /**
     * @dev Returns a leverage-derived effective health factor.
     *      HF = L / (L - 1), where L is leverage in 1e18 precision.
     */
    function _getEffectiveHealthFactor() internal view returns (uint256 hf) {
        uint256 leverage = _safeGetCurrentLeverage();
        if (leverage <= PRECISION) return type(uint256).max;

        uint256 denominator = leverage - PRECISION;
        if (denominator == 0) return type(uint256).max;

        hf = (leverage * PRECISION) / denominator;
    }

    /**
     * @dev Performs the heavy on-chain fallback valuation.
     */
    function _getRealtimeNavFromOnchain() internal view returns (uint256 totalNav) {
        uint256 idleBase = IERC20(asset()).balanceOf(address(this));
        uint256 idleQuote = IERC20(address(quoteAsset)).balanceOf(address(this));
        uint256 idleQuoteInBase = _convertQuoteToBase(idleQuote);

        uint256 totalDebt = _getTotalDebt();
        if (lpTokenBalance == 0 && totalDebt == 0) return idleBase + idleQuoteInBase;

        uint256 lpValueInBase = _getLPValueInBase();
        uint256 debtInBase = _convertQuoteToBase(totalDebt);
        uint256 strategyNetInBase = lpValueInBase > debtInBase ? (lpValueInBase - debtInBase) : 0;

        return idleBase + idleQuoteInBase + strategyNetInBase;
    }

    /**
     * @dev Calculates current market value of LP positions in base asset terms.
     */
    function _getLPValueInBase() internal view returns (uint256 valueInBase) {
        if (lpTokenBalance == 0) return 0;

        (uint256 amount0, uint256 amount1) = uniswapPool.getPositionValue(poolKey.toId(), address(this));
        address currency0 = Currency.unwrap(poolKey.currency0);

        uint256 baseAmount;
        uint256 quoteAmount;
        if (currency0 == address(asset())) {
            baseAmount = amount0;
            quoteAmount = amount1;
        } else {
            baseAmount = amount1;
            quoteAmount = amount0;
        }

        return baseAmount + _convertQuoteToBase(quoteAmount);
    }

    /**
     * @dev Converts quote asset quantity to base asset equivalent via Aave price oracle.
     */
    function _convertQuoteToBase(uint256 quoteAmount) internal view returns (uint256 baseAmount) {
        if (quoteAmount == 0) return 0;

        uint256 basePrice = aavePool.assetPrices(address(asset()));
        uint256 quotePrice = aavePool.assetPrices(address(quoteAsset));
        if (basePrice == 0 || quotePrice == 0) revert InvalidOracleConfig();

        uint8 baseDecimals = _getDecimals(address(asset()));
        uint8 quoteDecimals = _getDecimals(address(quoteAsset));

        uint256 quoteValueUsd = (quoteAmount * quotePrice) / (10 ** quoteDecimals);
        return (quoteValueUsd * (10 ** baseDecimals)) / basePrice;
    }

    /**
     * @dev Internal helper to swap quote tokens back to base tokens.
     */
    function _swapQuoteToBase(uint256 quoteAmount) internal returns (uint256 baseOut) {
        if (quoteAmount == 0) return 0;
        if (quoteAmount > uint256(type(int256).max)) revert SlippageExceeded();

        quoteAsset.safeIncreaseAllowance(address(uniswapPool), quoteAmount);

        bool zeroForOne = Currency.unwrap(poolKey.currency0) == address(quoteAsset);
        (, baseOut) = uniswapPool.swap(poolKey, zeroForOne, -int256(quoteAmount), 0);
    }

    /**
     * @dev Internal handler to synchronize the vault state with latest oracle data.
     */
    function _syncOracleCheckpoint() internal {
        if (address(dataFeedsCache) == address(0) || navDataId == bytes32(0)) return;

        (,,, uint256 updatedAt,) = dataFeedsCache.latestRoundData(navDataId);
        if (updatedAt > lastOracleUpdatedAt) {
            lastOracleUpdatedAt = updatedAt;
            netFlowSinceLastUpdate = 0;
            emit NetFlowReset(updatedAt);
        }
    }

    /**
     * @dev Internal helper to apply flow deltas to cached NAV.
     */
    function _applyNetFlow(uint256 cachedNav, int256 netFlow) internal pure returns (uint256 total) {
        if (netFlow >= 0) {
            total = cachedNav + uint256(netFlow);
        } else {
            uint256 absFlow = uint256(-netFlow);
            total = absFlow >= cachedNav ? 0 : cachedNav - absFlow;
        }
    }

    /**
     * @dev Increases the cumulative net flow delta.
     */
    function _increaseNetFlow(uint256 amount) internal {
        if (amount > uint256(type(int256).max)) revert InvalidOracleConfig();
        netFlowSinceLastUpdate += int256(amount);
    }

    /**
     * @dev Decreases the cumulative net flow delta.
     */
    function _decreaseNetFlow(uint256 amount) internal {
        if (amount > uint256(type(int256).max)) revert InvalidOracleConfig();
        netFlowSinceLastUpdate -= int256(amount);
    }

    /**
     * @dev Internal helper to retrieve token decimals.
     */
    function _getDecimals(address token) internal view returns (uint8) {
        try IERC20Metadata(token).decimals() returns (uint8 tokenDecimals) {
            return tokenDecimals;
        } catch {
            return 18;
        }
    }
}

/**
 * @dev Minimal interface for token metadata.
 */
interface IERC20Metadata {
    function decimals() external view returns (uint8);
}
