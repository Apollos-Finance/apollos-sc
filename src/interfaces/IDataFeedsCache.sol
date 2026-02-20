// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IDataFeedsCache
 * @notice Interface for the Shared Data Feeds Cache.
 * @author Apollos Team
 * @dev This cache stores and serves off-chain computed data (like portfolio NAV)
 *      to various protocol components. It provides a standard interface similar to
 *      Chainlink's AggregatorV3.
 */
interface IDataFeedsCache {
    /**
     * @notice Retrieves the latest data for a specific feed.
     * @param dataId The unique keccak256 identifier for the data feed.
     * @return roundId The sequential ID of the update round.
     * @return answer The actual data value (e.g., NAV in USD).
     * @return startedAt The timestamp when the update round was initiated.
     * @return updatedAt The timestamp when the data was last committed.
     * @return answeredInRound The round ID in which the answer was computed.
     */
    function latestRoundData(bytes32 dataId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /**
     * @notice Returns the number of decimal places for a specific data feed.
     * @param dataId The unique identifier for the feed.
     * @return The decimal precision.
     */
    function decimals(bytes32 dataId) external view returns (uint8);
}
