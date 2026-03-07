// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title IWorkflowReportReceiver
 * @notice Interface for contracts that receive validated reports from Chainlink workflows.
 */
interface IWorkflowReportReceiver {
    /**
     * @notice Handles the incoming report from a workflow.
     * @param metadata Opaque metadata associated with the report.
     * @param report The encoded report data containing instructions.
     */
    function onReport(bytes calldata metadata, bytes calldata report) external;
}

/**
 * @title GenericWorkflowReceiver
 * @notice A generic receiver for Chainlink Keystone/CRE workflows that routes validated reports to allowed target contracts.
 * @author Apollos Finance
 * @dev This contract acts as a security gateway. It only accepts calls from a `trustedForwarder`
 *      and ensures that only whitelisted `targets` and `selectors` (functions) can be executed.
 *      Report format expected:
 *      - [0:20] bytes: target contract address
 *      - [20:] bytes: target calldata (selector + encoded arguments)
 */
contract GenericWorkflowReceiver is IWorkflowReportReceiver, Ownable {
    /// @notice Error thrown when an address provided is the zero address.
    error ZeroAddress();
    /// @notice Error thrown when the caller is not the authorized forwarder.
    /// @param sender The address of the unauthorized caller.
    error UnauthorizedForwarder(address sender);
    /// @notice Error thrown when the report payload length is too short to be valid.
    error InvalidReportPayload();
    /// @notice Error thrown when the target contract address is not in the allowed whitelist.
    /// @param target The address of the unauthorized target.
    error TargetNotAllowed(address target);
    /// @notice Error thrown when the specific function selector is not allowed for the target contract.
    /// @param target The address of the target contract.
    /// @param selector The 4-byte function selector that was denied.
    error SelectorNotAllowed(address target, bytes4 selector);
    /// @notice Error thrown when the external call to the target contract fails.
    /// @param reason The revert reason returned by the failed call.
    error TargetCallFailed(bytes reason);

    /// @notice Emitted when the trusted forwarder address is updated.
    /// @param oldForwarder The previous forwarder address.
    /// @param newForwarder The new forwarder address.
    event TrustedForwarderUpdated(address indexed oldForwarder, address indexed newForwarder);
    /// @notice Emitted when a target contract's authorization status is changed.
    /// @param target The address of the target contract.
    /// @param allowed True if allowed, false otherwise.
    event TargetAllowed(address indexed target, bool allowed);
    /// @notice Emitted when a specific function route (selector) is authorized for a target.
    /// @param target The address of the target contract.
    /// @param selector The 4-byte function selector.
    /// @param allowed True if the route is now allowed.
    event RouteAllowed(address indexed target, bytes4 indexed selector, bool allowed);
    /// @notice Emitted when a report is successfully forwarded to a target.
    /// @param target The address where the report was sent.
    /// @param selector The function selector executed.
    /// @param payloadHash The keccak256 hash of the forwarded calldata.
    event ReportForwarded(address indexed target, bytes4 indexed selector, bytes32 payloadHash);

    /// @dev Interface ID for ERC165 support check.
    bytes4 private constant ERC165_INTERFACE_ID = 0x01ffc9a7;

    /// @notice The authorized address allowed to call `onReport`. Usually a Chainlink DON or Forwarder.
    address public trustedForwarder;
    /// @notice Mapping of whitelisted target contracts.
    mapping(address => bool) public allowedTargets;
    /// @notice Mapping of whitelisted function selectors per target contract.
    mapping(address => mapping(bytes4 => bool)) public allowedRoutes;

    /**
     * @notice Initializes the receiver with a trusted forwarder.
     * @param _trustedForwarder The address authorized to deliver reports.
     */
    constructor(address _trustedForwarder) Ownable(msg.sender) {
        if (_trustedForwarder == address(0)) revert ZeroAddress();
        trustedForwarder = _trustedForwarder;
    }

    /**
     * @notice Updates the trusted forwarder address.
     * @dev Restricted to the contract owner.
     * @param newForwarder The address of the new authorized forwarder.
     */
    function setTrustedForwarder(address newForwarder) external onlyOwner {
        if (newForwarder == address(0)) revert ZeroAddress();
        address old = trustedForwarder;
        trustedForwarder = newForwarder;
        emit TrustedForwarderUpdated(old, newForwarder);
    }

    /**
     * @notice Enables or disables a target contract for receiving forwarded calls.
     * @dev Restricted to the contract owner.
     * @param target The address of the contract to whitelist/blacklist.
     * @param allowed Set to true to allow, false to deny.
     */
    function setAllowedTarget(address target, bool allowed) external onlyOwner {
        if (target == address(0)) revert ZeroAddress();
        allowedTargets[target] = allowed;
        emit TargetAllowed(target, allowed);
    }

    /**
     * @notice Authorizes a specific function (selector) on a target contract.
     * @dev Restricted to the contract owner.
     * @param target The address of the target contract.
     * @param selector The 4-byte function selector to allow (e.g., bytes4(keccak256("func()"))).
     * @param allowed Set to true to allow, false to deny.
     */
    function setAllowedRoute(address target, bytes4 selector, bool allowed) external onlyOwner {
        if (target == address(0)) revert ZeroAddress();
        allowedRoutes[target][selector] = allowed;
        emit RouteAllowed(target, selector, allowed);
    }

    /**
     * @notice Authorizes multiple function selectors for a single target contract in one call.
     * @dev Restricted to the contract owner.
     * @param target The address of the target contract.
     * @param selectors An array of 4-byte function selectors to authorize.
     * @param allowed Set to true to allow, false to deny.
     */
    function setAllowedRoutes(address target, bytes4[] calldata selectors, bool allowed) external onlyOwner {
        if (target == address(0)) revert ZeroAddress();
        for (uint256 i = 0; i < selectors.length; i++) {
            allowedRoutes[target][selectors[i]] = allowed;
            emit RouteAllowed(target, selectors[i], allowed);
        }
    }

    /**
     * @notice Entry point for Chainlink Workflows to deliver validated reports.
     * @dev Validates the sender, parses the target and selector from the report,
     *      checks whitelists, and forwards the call.
     * @param report The raw report bytes [target(20 bytes) + calldata(selector+args)].
     */
    function onReport(bytes calldata, bytes calldata report) external override {
        if (msg.sender != trustedForwarder) revert UnauthorizedForwarder(msg.sender);
        if (report.length < 24) revert InvalidReportPayload();

        address target;
        bytes4 selector;
        assembly {
            target := shr(96, calldataload(report.offset))
            // bytes4 takes the high-order 4 bytes, so no shift is needed here.
            selector := calldataload(add(report.offset, 20))
        }

        if (!allowedTargets[target]) revert TargetNotAllowed(target);
        if (!allowedRoutes[target][selector]) revert SelectorNotAllowed(target, selector);

        bytes memory payload = report[20:];
        (bool ok, bytes memory reason) = target.call(payload);
        if (!ok) revert TargetCallFailed(reason);

        emit ReportForwarded(target, selector, keccak256(payload));
    }

    /**
     * @notice ERC165 standard function to check supported interfaces.
     * @param interfaceId The interface identifier to check.
     * @return True if the interface is supported.
     */
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IWorkflowReportReceiver).interfaceId || interfaceId == ERC165_INTERFACE_ID;
    }
}
