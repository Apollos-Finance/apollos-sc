// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IDataFeedsCache} from "../interfaces/IDataFeedsCache.sol";

/**
 * @title DataFeedsCache
 * @notice Shared on-chain cache for workflow-computed NAV feeds (one dataId per vault)
 * @dev Designed to mimic Chainlink-style latestRoundData while allowing multiple ids in one contract
 */
contract DataFeedsCache is IDataFeedsCache, Ownable {
    struct RoundData {
        uint80 roundId;
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        uint80 answeredInRound;
    }

    error ZeroAddress();
    error NotAuthorized();
    error FeedNotConfigured();
    error OlderTimestamp();

    event UpdaterSet(address indexed oldUpdater, address indexed newUpdater);
    event KeeperSet(address indexed keeper, bool authorized);
    event FeedConfigured(bytes32 indexed dataId, uint8 decimals);
    event RoundDataUpdated(bytes32 indexed dataId, uint80 roundId, int256 answer, uint256 updatedAt);

    address public updater;
    mapping(address => bool) public keepers;
    mapping(bytes32 => RoundData) private rounds;
    mapping(bytes32 => uint8) private feedDecimals;

    modifier onlyKeeper() {
        if (msg.sender != owner() && msg.sender != updater && !keepers[msg.sender]) revert NotAuthorized();
        _;
    }

    constructor(address initialUpdater) Ownable(msg.sender) {
        if (initialUpdater == address(0)) revert ZeroAddress();
        updater = initialUpdater;
        emit UpdaterSet(address(0), initialUpdater);
    }

    function setUpdater(address newUpdater) external onlyOwner {
        if (newUpdater == address(0)) revert ZeroAddress();
        address old = updater;
        updater = newUpdater;
        emit UpdaterSet(old, newUpdater);
    }

    function setKeeper(address keeper, bool authorized) external onlyOwner {
        if (keeper == address(0)) revert ZeroAddress();
        keepers[keeper] = authorized;
        emit KeeperSet(keeper, authorized);
    }

    function configureFeed(bytes32 dataId, uint8 decimals_) external onlyOwner {
        feedDecimals[dataId] = decimals_;
        emit FeedConfigured(dataId, decimals_);
    }

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

    function latestRoundData(bytes32 dataId)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        RoundData memory r = rounds[dataId];
        return (r.roundId, r.answer, r.startedAt, r.updatedAt, r.answeredInRound);
    }

    function decimals(bytes32 dataId) external view override returns (uint8) {
        return feedDecimals[dataId];
    }
}

