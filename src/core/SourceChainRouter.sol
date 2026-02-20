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
 * @notice Lightweight bridge-only router for Apollos source chains (Base).
 * @author Apollos Team
 * @dev This contract handles the initiation of cross-chain deposit messages via Chainlink CCIP.
 *      It does not manage local vaults or WETH wrapping, serving purely as a gateway to
 *      the Arbitrum deployment.
 */
contract SourceChainRouter is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The address of the local Chainlink CCIP Router.
    address public immutable ccipRouter;

    /// @notice The address of the ApollosCCIPReceiver on the target chain.
    address public destinationReceiver;

    /// @notice Maps CCIP chain selectors to their support status.
    mapping(uint64 => bool) public supportedChains;

    /// @notice Maps asset addresses to their support status for bridging.
    mapping(address => bool) public supportedAssets;

    /**
     * @notice Emitted when a cross-chain bridge and deposit process is successfully initiated.
     */
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

    /**
     * @notice Emitted when the target receiver address is updated.
     */
    event DestinationReceiverUpdated(address indexed oldReceiver, address indexed newReceiver);

    /**
     * @notice Emitted when a destination chain's support status is modified.
     */
    event SupportedChainUpdated(uint64 indexed chainSelector, bool supported);

    /**
     * @notice Emitted when an asset's bridge support status is modified.
     */
    event SupportedAssetUpdated(address indexed asset, bool supported);

    /// @notice Thrown when a zero address is provided for a critical role or parameter.
    error ZeroAddress();

    /// @notice Thrown when an operation is attempted with zero amount.
    error ZeroAmount();

    /// @notice Thrown when an unsupported target chain is selected.
    error InvalidChainSelector();

    /// @notice Thrown when an unsupported asset is provided for bridging.
    error UnsupportedAsset();

    /// @notice Thrown when the provided native token amount does not cover CCIP fees.
    error InsufficientFee(uint256 required, uint256 provided);

    /**
     * @notice Initializes the SourceChainRouter.
     * @param _ccipRouter The address of the local CCIP Router.
     */
    constructor(address _ccipRouter) Ownable(msg.sender) {
        if (_ccipRouter == address(0)) revert ZeroAddress();
        ccipRouter = _ccipRouter;
    }

    /**
     * @notice Bridges assets to Arbitrum and initiates a vault deposit.
     * @dev Encodes vault routing instructions into the CCIP message payload.
     * @param asset The address of the token to bridge (e.g., USDC).
     * @param amount The quantity of tokens to bridge.
     * @param destinationChain The CCIP selector for the destination chain.
     * @param receiver The final beneficiary address on the destination chain.
     * @param minShares Minimum acceptable shares to receive (slippage protection).
     * @param targetBaseAsset The base asset of the target vault on Arbitrum.
     * @return messageId The unique identifier from Chainlink CCIP.
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

        // Take Token from User
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        // Approve CCIP router
        IERC20(asset).safeIncreaseAllowance(ccipRouter, amount);

        // Encode cross-chain payload
        bytes memory depositData = abi.encode(asset, amount, minShares, receiver, msg.sender, targetBaseAsset);

        // Build CCIP message
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: asset, amount: amount});

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(destinationReceiver),
            data: depositData,
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: 500_000})),
            feeToken: address(0) // Pay fee in native token
        });

        // Verify and pay fees
        uint256 fee = IRouterClient(ccipRouter).getFee(destinationChain, message);
        if (msg.value < fee) revert InsufficientFee(fee, msg.value);

        // Execute bridging
        messageId = IRouterClient(ccipRouter).ccipSend{value: fee}(destinationChain, message);

        // Refund excess native token
        if (msg.value > fee) {
            (bool success,) = msg.sender.call{value: msg.value - fee}("");
            require(success, "Refund failed");
        }

        emit CrossChainBridgeInitiated(
            messageId, destinationChain, msg.sender, asset, amount, receiver, targetBaseAsset, minShares
        );
    }

    /**
     * @notice Estimates the CCIP fee required for a specific bridging operation.
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

        bytes memory depositData = abi.encode(asset, amount, minShares, msg.sender, msg.sender, targetBaseAsset);

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(destinationReceiver),
            data: depositData,
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: 500_000})),
            feeToken: address(0)
        });

        return IRouterClient(ccipRouter).getFee(destinationChain, message);
    }

    /**
     * @notice Updates the destination CCIPReceiver address.
     */
    function setDestinationReceiver(address _receiver) external onlyOwner {
        if (_receiver == address(0)) revert ZeroAddress();

        address oldReceiver = destinationReceiver;
        destinationReceiver = _receiver;

        emit DestinationReceiverUpdated(oldReceiver, _receiver);
    }

    /**
     * @notice Enables or disables a destination chain.
     */
    function setSupportedChain(uint64 chainSelector, bool supported) external onlyOwner {
        supportedChains[chainSelector] = supported;
        emit SupportedChainUpdated(chainSelector, supported);
    }

    /**
     * @notice Enables or disables an asset for bridging.
     */
    function setSupportedAsset(address asset, bool supported) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        supportedAssets[asset] = supported;
        emit SupportedAssetUpdated(asset, supported);
    }

    /**
     * @notice Emergency rescue function for ERC20 tokens.
     */
    function rescueTokens(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }

    /**
     * @notice Emergency rescue function for native ETH.
     */
    function rescueETH() external onlyOwner {
        (bool success,) = owner().call{value: address(this).balance}("");
        require(success, "ETH rescue failed");
    }

    /**
     * @notice Allows the contract to receive native ETH for fee refunds.
     */
    receive() external payable {}
}
