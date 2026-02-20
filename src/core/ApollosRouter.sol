// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";

import {IApollosRouter} from "../interfaces/IApollosRouter.sol";
import {IApollosVault} from "../interfaces/IApollosVault.sol";
import {IApollosFactory} from "../interfaces/IApollosFactory.sol";

/**
 * @notice Minimal interface for standard WETH interactions.
 */
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/**
 * @title ApollosRouter
 * @notice User-facing entry point for local and cross-chain Apollos operations.
 * @author Apollos Team
 * @dev This router provides a unified interface for users to deposit and withdraw from multiple vaults.
 *      It abstracts away the complexities of finding specific vaults, handling native ETH wrapping,
 *      and initiating cross-chain transfers via Chainlink CCIP.
 */
contract ApollosRouter is IApollosRouter, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The factory contract used for vault discovery.
    IApollosFactory public immutable apollosFactory;

    /// @notice The local WETH token contract.
    IWETH public immutable wethContract;

    /// @notice The address of the Chainlink CCIP Router on this chain.
    address public immutable ccipRouterAddress;


    /// @notice Direct mapping for faster routing: asset => vault.
    mapping(address => address) public assetToVault;

    /// @notice List of asset addresses currently supported for direct routing.
    address[] public supportedAssets;

    /// @notice Maps CCIP chain selector to its support status for cross-chain deposits.
    mapping(uint64 => bool) public supportedChains;

    /// @notice The global quote asset (stable) used by the protocol.
    address public quoteAsset;


    /**
     * @notice Initializes the ApollosRouter with mandatory infrastructure addresses.
     * @param _factory Address of the ApollosFactory.
     * @param _weth Address of the WETH contract.
     * @param _ccipRouter Address of the CCIP Router.
     * @param _quoteAsset Address of the stable quote asset.
     */
    constructor(address _factory, address _weth, address _ccipRouter, address _quoteAsset) Ownable(msg.sender) {
        if (_factory == address(0) || _weth == address(0)) revert ZeroAddress();

        apollosFactory = IApollosFactory(_factory);
        wethContract = IWETH(_weth);
        ccipRouterAddress = _ccipRouter;
        quoteAsset = _quoteAsset;
    }

    /**
     * @notice Fallback function to receive native ETH.
     */
    receive() external payable {}

    

    /**
     * @notice Deposits an ERC20 asset into the appropriate vault.
     * @param params Struct containing asset, amount, slippage, and receiver.
     * @return vault The address of the vault where the assets were deposited.
     * @return shares The quantity of afTokens issued.
     */
    function deposit(DepositParams calldata params)
        external
        override
        nonReentrant
        returns (address vault, uint256 shares)
    {
        if (params.amount == 0) revert ZeroAmount();

        vault = _getVaultForAsset(params.asset);
        if (vault == address(0)) revert VaultNotFound();

        // Transfer tokens from user to this router
        IERC20(params.asset).safeTransferFrom(msg.sender, address(this), params.amount);

        // Approve vault to take tokens from this router
        IERC20(params.asset).safeIncreaseAllowance(vault, params.amount);

        // Deposit to vault on behalf of the receiver
        address receiver = params.receiver == address(0) ? msg.sender : params.receiver;
        shares = IApollosVault(vault).depositFor(params.amount, receiver, params.minShares);

        emit Deposit(msg.sender, vault, params.asset, params.amount, shares);
    }

    /**
     * @notice Deposits native ETH by wrapping it to WETH and routing to the WETH vault.
     * @param minShares Minimum acceptable shares to receive.
     * @return vault The address of the WETH vault.
     * @return shares The quantity of afTokens issued.
     */
    function depositETH(uint256 minShares)
        external
        payable
        override
        nonReentrant
        returns (address vault, uint256 shares)
    {
        if (msg.value == 0) revert ZeroAmount();

        vault = _getVaultForAsset(address(wethContract));
        if (vault == address(0)) revert VaultNotFound();

        // Wrap ETH to WETH
        wethContract.deposit{value: msg.value}();

        // Approve vault
        wethContract.approve(vault, msg.value);

        // Deposit to vault
        shares = IApollosVault(vault).depositFor(msg.value, msg.sender, minShares);

        emit Deposit(msg.sender, vault, address(wethContract), msg.value, shares);
    }


    /**
     * @notice Withdraws base assets from a specific vault by burning shares.
     * @param params Struct containing vault, shares, slippage, and receiver.
     * @return amount The quantity of base assets returned.
     */
    function withdraw(WithdrawParams calldata params) external override nonReentrant returns (uint256 amount) {
        if (params.shares == 0) revert ZeroAmount();
        if (params.vault == address(0)) revert ZeroAddress();

        IApollosVault vault = IApollosVault(params.vault);

        // Transfer shares from user to this router
        IERC20(params.vault).safeTransferFrom(msg.sender, address(this), params.shares);

        // Perform withdrawal from vault (this router receives base assets)
        amount = vault.withdraw(params.shares, params.minAmount);

        // Send base assets from router to receiver
        IApollosVault.VaultConfig memory config = vault.getVaultConfig();
        address receiver = params.receiver == address(0) ? msg.sender : params.receiver;
        IERC20(config.baseAsset).safeTransfer(receiver, amount);

        emit Withdraw(msg.sender, params.vault, params.shares, amount);
    }

    /**
     * @notice Withdraws from a WETH vault and unwraps the resulting WETH into native ETH.
     * @param vault The address of the WETH vault.
     * @param shares Number of afTokens to burn.
     * @param minAmount Minimum acceptable native ETH to receive.
     * @return amount Final quantity of native ETH returned.
     */
    function withdrawETH(address vault, uint256 shares, uint256 minAmount)
        external
        override
        nonReentrant
        returns (uint256 amount)
    {
        if (shares == 0) revert ZeroAmount();
        if (vault == address(0)) revert ZeroAddress();

        IApollosVault apollosVault = IApollosVault(vault);

        // Verify it's a WETH vault
        IApollosVault.VaultConfig memory config = apollosVault.getVaultConfig();
        if (config.baseAsset != address(wethContract)) revert UnsupportedAsset();

        // Transfer shares to router
        IERC20(vault).safeTransferFrom(msg.sender, address(this), shares);

        // Withdraw from vault (router receives WETH)
        amount = apollosVault.withdraw(shares, minAmount);

        // Unwrap WETH back to ETH
        wethContract.withdraw(amount);

        // Transfer native ETH to user
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "ETH transfer failed");

        emit Withdraw(msg.sender, vault, shares, amount);
    }


    /**
     * @notice Initiates a cross-chain bridge and deposit operation via Chainlink CCIP.
     * @dev Transfers tokens to this contract, approves CCIP Router, and sends the message.
     * @param params Struct containing destination details, asset, and receiver.
     * @return messageId The unique identifier from Chainlink CCIP.
     */
    function depositCrossChain(CrossChainDepositParams calldata params)
        external
        payable
        override
        nonReentrant
        returns (bytes32 messageId)
    {
        if (params.amount == 0) revert ZeroAmount();
        if (!supportedChains[params.destinationChainSelector]) revert InvalidChainSelector();

        // Take Token from User
        IERC20(params.asset).safeTransferFrom(msg.sender, address(this), params.amount);

        // Approve CCIP router to take the tokens
        IERC20(params.asset).safeIncreaseAllowance(ccipRouterAddress, params.amount);

        // Encode cross-chain payload (for CCIPReceiver decoding)
        bytes memory depositData = abi.encode(
            params.asset, 
            params.amount,
            params.minShares,
            params.receiver,
            msg.sender,
            params.targetBaseAsset
        );

        // Build CCIP message
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: params.asset, amount: params.amount});

        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(params.destinationRouter),
            data: depositData,
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: 500_000})),
            feeToken: address(0) // Pay fee in native ETH
        });

        // Calculate and verify CCIP fees
        uint256 fees = IRouterClient(ccipRouterAddress).getFee(params.destinationChainSelector, evm2AnyMessage);
        if (msg.value < fees) revert InsufficientFee();

        // Send message to Chainlink Router
        messageId =
            IRouterClient(ccipRouterAddress).ccipSend{value: fees}(params.destinationChainSelector, evm2AnyMessage);

        // Refund excess ETH to user
        if (msg.value > fees) {
            (bool success,) = msg.sender.call{value: msg.value - fees}("");
            require(success, "Refund failed");
        }

        emit CrossChainDepositInitiated(
            messageId, params.destinationChainSelector, msg.sender, params.asset, params.amount
        );
    }

    /**
     * @notice Estimates the CCIP bridging fee in native ETH.
     */
    function getCrossChainFee(uint64 destinationChainSelector, address asset, uint256 amount)
        external
        view
        override
        returns (uint256 fee)
    {
        if (ccipRouterAddress == address(0)) return 0;

        // Construct a dummy message for estimation
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: asset, amount: amount});

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(address(0)),
            data: "",
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: 500_000})),
            feeToken: address(0)
        });

        fee = IRouterClient(ccipRouterAddress).getFee(destinationChainSelector, message);
    }

    

    /**
     * @notice Returns the vault address mapped to a specific asset.
     */
    function getVaultForAsset(address asset) external view override returns (address) {
        return _getVaultForAsset(asset);
    }

    /**
     * @dev Internal helper to resolve asset to vault via mapping or factory.
     */
    function _getVaultForAsset(address asset) internal view returns (address) {
        if (assetToVault[asset] != address(0)) {
            return assetToVault[asset];
        }
        return apollosFactory.getVault(asset, quoteAsset);
    }

    /**
     * @notice Returns an array of all asset addresses officially supported for routing.
     */
    function getSupportedAssets() external view override returns (address[] memory) {
        return supportedAssets;
    }

    /**
     * @notice Simulates a deposit to estimate the shares that would be issued.
     */
    function previewDeposit(address asset, uint256 amount)
        external
        view
        override
        returns (address vault, uint256 shares)
    {
        vault = _getVaultForAsset(asset);
        if (vault == address(0)) return (address(0), 0);

        shares = IApollosVault(vault).previewDeposit(amount);
    }

    /**
     * @notice Simulates a withdrawal to estimate the assets that would be returned.
     */
    function previewWithdraw(address vault, uint256 shares) external view override returns (uint256 amount) {
        if (vault == address(0)) return 0;
        amount = IApollosVault(vault).previewWithdraw(shares);
    }

    /**
     * @notice Returns the ApollosFactory address.
     */
    function factory() external view override returns (address) {
        return address(apollosFactory);
    }

    /**
     * @notice Returns the WETH contract address.
     */
    function weth() external view override returns (address) {
        return address(wethContract);
    }

    /**
     * @notice Returns the local CCIP Router address.
     */
    function ccipRouter() external view override returns (address) {
        return ccipRouterAddress;
    }

    

    /**
     * @notice Updates the routing table for a specific asset.
     */
    function setAssetVault(address asset, address vault) external override onlyOwner {
        if (asset == address(0)) revert ZeroAddress();

        // Register as supported asset if new
        if (assetToVault[asset] == address(0) && vault != address(0)) {
            supportedAssets.push(asset);
        }

        assetToVault[asset] = vault;
    }

    /**
     * @notice Enables or disables cross-chain bridging to a specific chain.
     */
    function setSupportedChain(uint64 chainSelector, bool supported) external override onlyOwner {
        supportedChains[chainSelector] = supported;
    }

    /**
     * @notice Updates the protocol's global quote asset.
     */
    function setQuoteAsset(address _quoteAsset) external onlyOwner {
        if (_quoteAsset == address(0)) revert ZeroAddress();
        quoteAsset = _quoteAsset;
    }

    /**
     * @notice Emergency rescue function for tokens stuck in the contract.
     */
    function rescueTokens(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }

    /**
     * @notice Emergency rescue function for native ETH stuck in the contract.
     */
    function rescueETH() external onlyOwner {
        (bool success,) = owner().call{value: address(this).balance}("");
        require(success, "ETH rescue failed");
    }
}
