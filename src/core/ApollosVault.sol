// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// V4 Core Types
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

// Interfaces
import {IApollosVault} from "../interfaces/IApollosVault.sol";
import {IMockAavePool} from "../interfaces/IMockAavePool.sol";
import {IMockUniswapPool} from "../interfaces/IMockUniswapPool.sol";
import {IDataFeedsCache} from "../interfaces/IDataFeedsCache.sol";

/**
 * @title ApollosVault
 * @notice ERC4626 leveraged vault with feed-priority NAV and on-chain fallback.
 * @dev Fresh feed path: totalAssets = cachedNAV + netFlowSinceLastUpdate.
 *      Stale feed path (> maxOracleAge): totalAssets = realtime on-chain NAV.
 */
contract ApollosVault is IApollosVault, ERC4626, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    // ============ Constants ============
    uint256 public constant PRECISION = 1e18;
    uint256 public constant BPS = 10000;
    uint256 public constant MAX_IDLE_BUFFER_BPS = 3000; // 30%

    // ============ Immutables ============
    IERC20 public immutable quoteAsset;
    IMockAavePool public immutable aavePool;
    IMockUniswapPool public immutable uniswapPool;
    PoolKey public poolKey;

    // ============ State Variables ============
    VaultConfig public config;
    bool public paused;

    mapping(address => bool) public authorizedRebalancers;

    uint256 public lpTokenBalance;
    uint256 public protocolFee;
    address public treasury;
    uint256 public pendingFees;
    uint256 public MIN_DEPOSIT;

    IDataFeedsCache public dataFeedsCache;
    bytes32 public navDataId;
    uint256 public maxOracleAge;
    uint256 public idleBufferBps;
    int256 public netFlowSinceLastUpdate;
    uint256 public lastOracleUpdatedAt;

    // ============ Events ============
    event DataFeedConfigUpdated(address indexed cache, bytes32 indexed dataId, uint256 maxOracleAge);
    event KeeperUpdated(address indexed keeper, bool authorized);
    event IdleBufferUpdated(uint256 oldBps, uint256 newBps);
    event NetFlowReset(uint256 oracleUpdatedAt);

    // ============ Errors ============
    error DeprecatedNAVUpdate();

    // ============ Modifiers ============
    modifier whenNotPaused() {
        if (paused) revert VaultPaused();
        _;
    }

    modifier onlyRebalancer() {
        if (!authorizedRebalancers[msg.sender] && msg.sender != owner()) {
            revert NotAuthorized();
        }
        _;
    }

    // ============ Constructor ============
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
            rebalanceThreshold: 1.1e18
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

    // ============ Accountant / NAV Functions ============

    /**
     * @notice Sync checkpoint hook for workflow/manual operator.
     * @dev Resets net flow delta, intended to be called around oracle NAV update cycles.
     */
    function updateNAV(uint256) external override onlyRebalancer {
        _syncOracleCheckpoint();
        netFlowSinceLastUpdate = 0;
        emit NetFlowReset(lastOracleUpdatedAt);
    }

    /**
     * @notice Total assets in base units.
     * @dev Fresh feed: cached NAV + net flow delta.
     *      Stale/missing feed: realtime on-chain NAV fallback.
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

    // ============ Core Functions ============

    /**
     * @notice ERC4626 deposit entrypoint (idle-first)
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

    function _deposit(uint256 amount, address receiver, uint256 minShares) internal returns (uint256 shares) {
        if (amount < MIN_DEPOSIT) revert ZeroAmount();

        _syncOracleCheckpoint();

        shares = previewDeposit(amount);
        if (shares < minShares) revert SlippageExceeded();

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);

        // Immediate deploy mode: borrow quote and add leveraged LP instantly.
        uint256 borrowAmount = _calculateBorrowAmount(amount);
        if (borrowAmount > 0) {
            quoteAsset.safeIncreaseAllowance(address(aavePool), borrowAmount);
            aavePool.borrow(address(quoteAsset), borrowAmount, 2, 0, address(this));

            uint256 lpReceived = _addLiquidity(amount, borrowAmount);
            lpTokenBalance += lpReceived;
        }

        _mint(receiver, shares);
        _increaseNetFlow(amount);

        emit Deposit(receiver, amount, shares, borrowAmount);
    }

    /**
     * @notice Custom withdraw using shares + minAmount
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
     * @notice Keeper-triggered strategy management
     * @dev Rebalance can:
     *      - deploy excess idle capital while preserving idle buffer
     *      - deleverage when health factor drops below threshold
     */
    function rebalance() external override onlyRebalancer nonReentrant returns (uint256 newLeverage) {
        _syncOracleCheckpoint();

        uint256 oldLeverage = _safeGetCurrentLeverage();
        bool didAction;
        uint256 debtRepaid;

        uint256 idleBalance = IERC20(asset()).balanceOf(address(this));
        // Keep withdrawal buffer from currently idle liquidity only.
        // This avoids hard dependency on fresh NAV feed before keeper rebalance execution.
        uint256 targetIdle = (idleBalance * idleBufferBps) / BPS;

        // 1) Deploy excess idle above configured withdrawal buffer.
        if (idleBalance > targetIdle) {
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

        // 2) Deleverage if risk threshold is breached.
        if (needsRebalance()) {
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

    function emergencyWithdraw(uint256 shares) external override returns (uint256 amount) {
        amount = withdraw(shares, 0);
        emit EmergencyWithdraw(msg.sender, shares, amount);
    }

    // ============ View Functions ============

    function getVaultConfig() external view override returns (VaultConfig memory) {
        return config;
    }

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

    function previewDeposit(uint256 amount) public view override(ERC4626, IApollosVault) returns (uint256) {
        return super.previewDeposit(amount);
    }

    function previewWithdraw(uint256 shares) public view override(ERC4626, IApollosVault) returns (uint256) {
        return super.previewRedeem(shares);
    }

    function getSharePrice() external view override returns (uint256 price) {
        return convertToAssets(PRECISION);
    }

    function getHealthFactor() public view override returns (uint256 healthFactor) {
        (,,,,, healthFactor) = aavePool.getUserAccountData(address(this));
        if (healthFactor == 0) healthFactor = type(uint256).max;
    }

    function getCurrentLeverage() public view override returns (uint256 leverage) {
        uint256 totalDebt = _getTotalDebt();
        uint256 assets = totalAssets();

        if (assets == 0) return PRECISION;
        leverage = ((assets + totalDebt) * PRECISION) / assets;
    }

    function needsRebalance() public view override returns (bool needed) {
        uint256 hf = getHealthFactor();
        return hf < config.rebalanceThreshold && hf != type(uint256).max;
    }

    // ============ ERC4626 Conflict Resolution ============

    function decimals() public view override(ERC4626) returns (uint8) {
        return super.decimals();
    }

    function totalSupply() public view override(ERC20, IERC20, IApollosVault) returns (uint256) {
        return super.totalSupply();
    }

    function balanceOf(address account) public view override(ERC20, IERC20, IApollosVault) returns (uint256) {
        return super.balanceOf(account);
    }

    function withdraw(uint256, address, address) public pure override(ERC4626) returns (uint256) {
        revert("Use withdraw(shares, minAmount)");
    }

    // ============ Admin Functions ============

    function updateConfig(uint256 _targetLeverage, uint256 _maxLeverage, uint256 _rebalanceThreshold)
        external
        override
        onlyOwner
    {
        config.targetLeverage = _targetLeverage;
        config.maxLeverage = _maxLeverage;
        config.rebalanceThreshold = _rebalanceThreshold;
    }

    function setPaused(bool _paused) external override onlyOwner {
        paused = _paused;
    }

    function setRebalancer(address rebalancer, bool authorized) external override onlyOwner {
        authorizedRebalancers[rebalancer] = authorized;
        emit KeeperUpdated(rebalancer, authorized);
    }

    function setKeeper(address keeper, bool authorized) external override onlyOwner {
        authorizedRebalancers[keeper] = authorized;
        emit KeeperUpdated(keeper, authorized);
    }

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

    function setMaxOracleAge(uint256 maxAge) external override onlyOwner {
        if (maxAge == 0) revert InvalidOracleConfig();
        maxOracleAge = maxAge;
    }

    function setIdleBufferBps(uint256 bps) external override onlyOwner {
        if (bps == 0 || bps > MAX_IDLE_BUFFER_BPS) revert InvalidOracleConfig();
        uint256 oldBps = idleBufferBps;
        idleBufferBps = bps;
        emit IdleBufferUpdated(oldBps, bps);
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }

    function setProtocolFee(uint256 _fee) external onlyOwner {
        protocolFee = _fee;
    }

    // ============ Internal Functions ============

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

    function _removeLiquidity(uint256 lpAmount) internal returns (uint256 baseReceived, uint256 quoteReceived) {
        (baseReceived, quoteReceived) = uniswapPool.removeLiquidity(poolKey, lpAmount, 0, 0);
    }

    function _getTotalDebt() internal view returns (uint256) {
        return aavePool.getUserDebt(address(this), address(quoteAsset));
    }

    function _calculateRebalanceAmount() internal view returns (uint256) {
        uint256 currentLev;
        try this.getCurrentLeverage() returns (uint256 lev) {
            currentLev = lev;
        } catch {
            // Feed can be stale while workflow is doing rebalance-first then oracle update.
            // In fallback mode, deleverage in small chunks.
            return lpTokenBalance / 10;
        }

        uint256 targetLev = config.targetLeverage;

        if (currentLev <= targetLev) return 0;
        uint256 excessLeverage = currentLev - targetLev;
        return (lpTokenBalance * excessLeverage) / currentLev;
    }

    function _safeGetCurrentLeverage() internal view returns (uint256 leverage) {
        try this.getCurrentLeverage() returns (uint256 lev) {
            return lev;
        } catch {
            return PRECISION;
        }
    }

    function _getRealtimeNavFromOnchain() internal view returns (uint256 totalNav) {
        uint256 idleBase = IERC20(asset()).balanceOf(address(this));
        uint256 idleQuote = IERC20(address(quoteAsset)).balanceOf(address(this));
        uint256 idleQuoteInBase = _convertQuoteToBase(idleQuote);

        uint256 totalDebt = _getTotalDebt();
        if (lpTokenBalance == 0 && totalDebt == 0) return idleBase + idleQuoteInBase;

        uint256 lpValueInBase = _getLPValueInBase();
        uint256 debtInBase = _convertQuoteToBase(totalDebt);
        uint256 strategyNetInBase = lpValueInBase > debtInBase ? (lpValueInBase - debtInBase) : 0;

        // Fallback NAV:
        // totalAssets = idleBase + convertedIdleQuote + LP_Value - Debt
        return idleBase + idleQuoteInBase + strategyNetInBase;
    }

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

    function _swapQuoteToBase(uint256 quoteAmount) internal returns (uint256 baseOut) {
        if (quoteAmount == 0) return 0;
        if (quoteAmount > uint256(type(int256).max)) revert SlippageExceeded();

        quoteAsset.safeIncreaseAllowance(address(uniswapPool), quoteAmount);

        bool zeroForOne = Currency.unwrap(poolKey.currency0) == address(quoteAsset);
        (, baseOut) = uniswapPool.swap(poolKey, zeroForOne, -int256(quoteAmount), 0);
    }

    function _syncOracleCheckpoint() internal {
        if (address(dataFeedsCache) == address(0) || navDataId == bytes32(0)) return;

        (,,, uint256 updatedAt,) = dataFeedsCache.latestRoundData(navDataId);
        if (updatedAt > lastOracleUpdatedAt) {
            lastOracleUpdatedAt = updatedAt;
            netFlowSinceLastUpdate = 0;
            emit NetFlowReset(updatedAt);
        }
    }

    function _applyNetFlow(uint256 cachedNav, int256 netFlow) internal pure returns (uint256 total) {
        if (netFlow >= 0) {
            total = cachedNav + uint256(netFlow);
        } else {
            uint256 absFlow = uint256(-netFlow);
            total = absFlow >= cachedNav ? 0 : cachedNav - absFlow;
        }
    }

    function _increaseNetFlow(uint256 amount) internal {
        if (amount > uint256(type(int256).max)) revert InvalidOracleConfig();
        netFlowSinceLastUpdate += int256(amount);
    }

    function _decreaseNetFlow(uint256 amount) internal {
        if (amount > uint256(type(int256).max)) revert InvalidOracleConfig();
        netFlowSinceLastUpdate -= int256(amount);
    }

    function _getDecimals(address token) internal view returns (uint8) {
        try IERC20Metadata(token).decimals() returns (uint8 tokenDecimals) {
            return tokenDecimals;
        } catch {
            return 18;
        }
    }
}

interface IERC20Metadata {
    function decimals() external view returns (uint8);
}
