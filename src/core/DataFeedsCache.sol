// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IDataFeedsCache} from "../interfaces/IDataFeedsCache.sol";

/**
 * @title DataFeedsCache
 * @notice Centralized on-chain storage for off-chain computed data feeds (NAV, Risk Scores, etc.).
 * @author Apollos Team
 * @dev This contract mimics the Chainlink AggregatorV3 interface to provide a familiar integration 
 *      pattern for protocol contracts. It allows authorized keepers to update data values 
 *      derived from complex off-chain computations (Workflows).
 */
contract DataFeedsCache is IDataFeedsCache, Ownable {
    
    /**
     * @notice Data structure representing a single update round for a data feed.
     * @param roundId The sequential identifier for the update.
     * @param answer The recorded data value.
     * @param startedAt The timestamp when the update process began.
     * @param updatedAt The timestamp when the data was committed to the blockchain.
     * @param answeredInRound The round ID in which the calculation was finalized.
     */
    struct RoundData {
        uint80 roundId;
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        uint80 answeredInRound;
    }

    /// @notice Thrown when a zero address is provided for a restricted role.
    error ZeroAddress();
    
    /// @notice Thrown when a non-authorized address attempts to update data.
    error NotAuthorized();
    
    /// @notice Thrown when attempting to update a feed that hasn't been initialized.
    error FeedNotConfigured();
    
    /// @notice Thrown when an update contains a timestamp older than the current record.
    error OlderTimestamp();

    /**
     * @notice Emitted when the primary updater address is changed.
     */
    event UpdaterSet(address indexed oldUpdater, address indexed newUpdater);
    
    /**
     * @notice Emitted when a keeper's authorization status is modified.
     */
    event KeeperSet(address indexed keeper, bool authorized);
    
    /**
     * @notice Emitted when a new data feed is initialized with its precision metadata.
     */
    event FeedConfigured(bytes32 indexed dataId, uint8 decimals);
    
    /**
     * @notice Emitted when a feed's value is updated.
     */
    event RoundDataUpdated(bytes32 indexed dataId, uint80 roundId, int256 answer, uint256 updatedAt);

    /// @notice The primary address authorized to commit data updates.
    address public updater;
    
    /// @notice Maps addresses to their auxiliary keeper authorization status.
    mapping(address => bool) public keepers;
    
    /// @dev Internal mapping storing the latest round data for each feed ID.
    mapping(bytes32 => RoundData) private rounds;
    
    /// @dev Internal mapping storing the decimal precision for each feed ID.
    mapping(bytes32 => uint8) private feedDecimals;

    /// @dev Reverts if the caller is not the owner, the primary updater, or an authorized keeper.
    modifier onlyKeeper() {
        if (msg.sender != owner() && msg.sender != updater && !keepers[msg.sender]) revert NotAuthorized();
        _;
    }

    /**
     * @notice Initializes the cache with an initial updater address.
     * @param initialUpdater The address allowed to push data updates.
     */
    constructor(address initialUpdater) Ownable(msg.sender) {
        if (initialUpdater == address(0)) revert ZeroAddress();
        updater = initialUpdater;
        emit UpdaterSet(address(0), initialUpdater);
    }

    /**
     * @notice Updates the primary updater role.
     * @param newUpdater The address of the new updater.
     */
    function setUpdater(address newUpdater) external onlyOwner {
        if (newUpdater == address(0)) revert ZeroAddress();
        address old = updater;
        updater = newUpdater;
        emit UpdaterSet(old, newUpdater);
    }

    /**
     * @notice Grants or revokes keeper status for an address.
     * @param keeper The address to modify.
     * @param authorized True to authorize, false to revoke.
     */
    function setKeeper(address keeper, bool authorized) external onlyOwner {
        if (keeper == address(0)) revert ZeroAddress();
        keepers[keeper] = authorized;
        emit KeeperSet(keeper, authorized);
    }

    /**
     * @notice Initializes a new data feed.
     * @param dataId The unique keccak256 identifier for the feed.
     * @param decimals_ The decimal precision of the feed's values.
     */
    function configureFeed(bytes32 dataId, uint8 decimals_) external onlyOwner {
        feedDecimals[dataId] = decimals_;
        emit FeedConfigured(dataId, decimals_);
    }

    /**
     * @notice Records a new data point for a specific feed.
     * @dev Automatically increments the round ID. Validates that the timestamp is strictly increasing.
     * @param dataId The identifier of the feed.
     * @param answer The new data value.
     * @param updatedAt The timestamp associated with the data.
     */
    function updateRoundData(bytes32 dataId, int256 answer, uint256 updatedAt) external onlyKeeper {
        if (feedDecimals[dataId] == 0) revert FeedNotConfigured();

        RoundData storage current = rounds[dataId];
        if (updatedAt <= current.updatedAt) revert OlderTimestamp();

        uint80 newRoundId = current.roundId + 1;
        rounds[dataId] = RoundData({
            roundId: newRoundId, answer: answer, startedAt: updatedAt, updatedAt: updatedAt, answeredInRound: newRoundId
        });

        emit RoundDataUpdated(dataId, newRoundId, answer, updatedAt);
    }

    /**
     * @notice Returns the latest data for a feed (AggregatorV3 style).
     */
    function latestRoundData(bytes32 dataId)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        RoundData memory r = rounds[dataId];
        return (r.roundId, r.answer, r.startedAt, r.updatedAt, r.answeredInRound);
    }

    /**
     * @notice Returns the decimal precision of a feed.
     */
    function decimals(bytes32 dataId) external view override returns (uint8) {
        return feedDecimals[dataId];
    }
}
