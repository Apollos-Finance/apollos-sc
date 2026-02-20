// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DataFeedsCache} from "../src/core/DataFeedsCache.sol";

/**
 * @title DataFeedsCacheTest
 * @notice Test suite for verifying the DataFeedsCache functionality.
 * @author Apollos Finance Team
 */
contract DataFeedsCacheTest is Test {
    DataFeedsCache public cache;

    address public owner = makeAddr("owner");
    address public updater = makeAddr("updater");
    address public keeper = makeAddr("keeper");
    address public attacker = makeAddr("attacker");

    bytes32 constant WETH_NAV = keccak256("WETH_NAV");

    /**
     * @notice Sets up the test environment by deploying the cache and configuring a feed.
     */
    function setUp() public {
        vm.startPrank(owner);
        cache = new DataFeedsCache(updater);
        cache.configureFeed(WETH_NAV, 18);
        vm.stopPrank();
    }

    /**
     * @notice Verifies that the authorized updater can successfully commit new data.
     */
    function test_UpdateByUpdater() public {
        vm.prank(updater);
        cache.updateRoundData(WETH_NAV, int256(42 ether), block.timestamp);

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = cache.latestRoundData(WETH_NAV);
        assertEq(roundId, 1);
        assertEq(answer, int256(42 ether));
        assertEq(updatedAt, block.timestamp);
        assertEq(answeredInRound, 1);
    }

    /**
     * @notice Verifies that both owner and authorized keepers can update data.
     */
    function test_UpdateByOwnerAndKeeper() public {
        vm.prank(owner);
        cache.setKeeper(keeper, true);

        vm.prank(owner);
        cache.updateRoundData(WETH_NAV, int256(10 ether), block.timestamp);

        vm.prank(keeper);
        cache.updateRoundData(WETH_NAV, int256(11 ether), block.timestamp + 1);

        (uint80 roundId, int256 answer,,,) = cache.latestRoundData(WETH_NAV);
        assertEq(roundId, 2);
        assertEq(answer, int256(11 ether));
    }

    /**
     * @notice Ensures that unauthorized addresses cannot update data feeds.
     */
    function test_RevertWhenUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert(DataFeedsCache.NotAuthorized.selector);
        cache.updateRoundData(WETH_NAV, int256(1), block.timestamp);
    }

    /**
     * @notice Ensures that data updates must have a strictly increasing timestamp.
     */
    function test_RevertWhenOlderTimestamp() public {
        vm.startPrank(updater);
        cache.updateRoundData(WETH_NAV, int256(100), block.timestamp);
        vm.expectRevert(DataFeedsCache.OlderTimestamp.selector);
        cache.updateRoundData(WETH_NAV, int256(101), block.timestamp);
        vm.stopPrank();
    }
}
