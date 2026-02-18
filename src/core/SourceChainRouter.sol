// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";

/**
 * @title SourceChainRouter
 * @notice Lightweight router for source chains (Base Sepolia) - CCIP bridging only
 * @dev This contract bridges assets to Arbitrum Sepolia via Chainlink CCIP
 *      It does NOT have:
 *      - Factory integration
 *      - WETH wrapping
 *      - Vault mappings
 *      - Local deposit/withdraw
 *
 *      Only function: Bridge USDC to Arbitrum → deposit to vault
 */
contract SourceChainRouter is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Immutables ============

    /// @notice Chainlink CCIP Router on this chain
    address public immutable ccipRouter;

    // ============ State Variables ============

    /// @notice Destination CCIPReceiver address on Arbitrum
    address public destinationReceiver;

    /// @notice Supported destination chain selectors
    mapping(uint64 => bool) public supportedChains;

    /// @notice Supported assets for bridging
    mapping(address => bool) public supportedAssets;

    // ============ Events ============

    event CrossChainBridgeInitiated(
        bytes32 indexed messageId,
        uint64 indexed destinationChain,
        address indexed sender,
        address asset,
        uint256 amount,
        address receiver,
        address targetBaseAsset,
        uint256 minShares
    );

    event DestinationReceiverUpdated(address indexed oldReceiver, address indexed newReceiver);
    event SupportedChainUpdated(uint64 indexed chainSelector, bool supported);
    event SupportedAssetUpdated(address indexed asset, bool supported);

    // ============ Errors ============

    error ZeroAddress();
    error ZeroAmount();
    error InvalidChainSelector();
    error UnsupportedAsset();
    error InsufficientFee(uint256 required, uint256 provided);

    // ============ Constructor ============

    constructor(address _ccipRouter) Ownable(msg.sender) {
        if (_ccipRouter == address(0)) revert ZeroAddress();
        ccipRouter = _ccipRouter;
    }

    // ============ Main Function ============

    /**
     * @notice Bridge asset to Arbitrum Sepolia
     * @param asset Token address to bridge (e.g., USDC)
     * @param amount Amount to bridge
     * @param destinationChain CCIP chain selector for Arbitrum Sepolia
     * @param receiver Address to receive vault shares on Arbitrum
     * @param minShares Minimum vault shares to receive (slippage protection)
     * @param targetBaseAsset Base asset of target vault on Arbitrum (WETH/WBTC/LINK)
     * @return messageId CCIP message ID
     */
    function bridgeToArbitrum(
        address asset,
        uint256 amount,
        uint64 destinationChain,
        address receiver,
        uint256 minShares,
        address targetBaseAsset
    ) external payable nonReentrant returns (bytes32 messageId) {
        if (amount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (!supportedChains[destinationChain]) revert InvalidChainSelector();
        if (!supportedAssets[asset]) revert UnsupportedAsset();

        // 1. Transfer asset from user to this contract
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        // 2. Approve CCIP router
        IERC20(asset).safeIncreaseAllowance(ccipRouter, amount);

        // 3. Encode destination deposit data (must match CCIPReceiver decoding)
        // Order: sourceAsset, amount, minShares, receiver, originalSender, targetBaseAsset
        bytes memory depositData = abi.encode(
            asset, // sourceAsset (USDC on Base)
            amount, // amount to bridge
            minShares, // minimum vault shares (slippage protection)
            receiver, // beneficiary on Arbitrum
            msg.sender, // originalSender (for tracking)
            targetBaseAsset // target vault base asset (WETH/WBTC/LINK)
        );

        // 4. Build CCIP message
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: asset, amount: amount});

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(destinationReceiver),
            data: depositData,
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: 500_000})),
            feeToken: address(0) // Pay fee in native token
        });

        // 5. Calculate fee
        uint256 fee = IRouterClient(ccipRouter).getFee(destinationChain, message);
        if (msg.value < fee) revert InsufficientFee(fee, msg.value);

        // 6. Send via CCIP
        messageId = IRouterClient(ccipRouter).ccipSend{value: fee}(destinationChain, message);

        // 7. Refund excess fee
        if (msg.value > fee) {
            (bool success,) = msg.sender.call{value: msg.value - fee}("");
            require(success, "Refund failed");
        }

        emit CrossChainBridgeInitiated(
            messageId, destinationChain, msg.sender, asset, amount, receiver, targetBaseAsset, minShares
        );
    }

    // ============ View Functions ============

    /**
     * @notice Get CCIP fee estimate for bridging
     * @param destinationChain CCIP chain selector
     * @param asset Token to bridge
     * @param amount Amount to bridge
     * @param minShares Minimum shares expected
     * @param targetBaseAsset Target vault base asset
     * @return fee Required fee in native token
     */
    function getBridgeFee(
        uint64 destinationChain,
        address asset,
        uint256 amount,
        uint256 minShares,
        address targetBaseAsset
    ) external view returns (uint256 fee) {
        if (!supportedChains[destinationChain]) revert InvalidChainSelector();
        if (!supportedAssets[asset]) revert UnsupportedAsset();

        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: asset, amount: amount});

        // Encode with 6 fields to match actual message
        bytes memory depositData = abi.encode(
            asset,
            amount,
            minShares,
            msg.sender, // receiver placeholder
            msg.sender, // originalSender placeholder
            targetBaseAsset
        );

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(destinationReceiver),
            data: depositData,
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: 500_000})),
            feeToken: address(0)
        });

        return IRouterClient(ccipRouter).getFee(destinationChain, message);
    }

    // ============ Admin Functions ============

    /**
     * @notice Set destination CCIPReceiver address on Arbitrum
     * @param _receiver CCIPReceiver contract address
     */
    function setDestinationReceiver(address _receiver) external onlyOwner {
        if (_receiver == address(0)) revert ZeroAddress();

        address oldReceiver = destinationReceiver;
        destinationReceiver = _receiver;

        emit DestinationReceiverUpdated(oldReceiver, _receiver);
    }

    /**
     * @notice Enable/disable destination chain
     * @param chainSelector CCIP chain selector
     * @param supported True to enable, false to disable
     */
    function setSupportedChain(uint64 chainSelector, bool supported) external onlyOwner {
        supportedChains[chainSelector] = supported;
        emit SupportedChainUpdated(chainSelector, supported);
    }

    /**
     * @notice Enable/disable asset for bridging
     * @param asset Token address
     * @param supported True to enable, false to disable
     */
    function setSupportedAsset(address asset, bool supported) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        supportedAssets[asset] = supported;
        emit SupportedAssetUpdated(asset, supported);
    }

    /**
     * @notice Rescue stuck tokens (emergency)
     * @param token Token address
     * @param amount Amount to rescue
     */
    function rescueTokens(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }

    /**
     * @notice Rescue stuck ETH (emergency)
     */
    function rescueETH() external onlyOwner {
        (bool success,) = owner().call{value: address(this).balance}("");
        require(success, "ETH rescue failed");
    }

    // ============ Receive ETH ============

    receive() external payable {}
}
