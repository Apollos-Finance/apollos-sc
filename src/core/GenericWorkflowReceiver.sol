// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IWorkflowReportReceiver {
    function onReport(bytes calldata metadata, bytes calldata report) external;
}

/**
 * @title GenericWorkflowReceiver
 * @notice Generic Keystone/CRE receiver that routes validated reports to allowed targets.
 * @dev Report format:
 *      - first 20 bytes: target contract address
 *      - remaining bytes: target calldata (selector + encoded args)
 */
contract GenericWorkflowReceiver is IWorkflowReportReceiver, Ownable {
    error ZeroAddress();
    error UnauthorizedForwarder(address sender);
    error InvalidReportPayload();
    error TargetNotAllowed(address target);
    error SelectorNotAllowed(address target, bytes4 selector);
    error TargetCallFailed(bytes reason);

    event TrustedForwarderUpdated(address indexed oldForwarder, address indexed newForwarder);
    event TargetAllowed(address indexed target, bool allowed);
    event RouteAllowed(address indexed target, bytes4 indexed selector, bool allowed);
    event ReportForwarded(address indexed target, bytes4 indexed selector, bytes32 payloadHash);

    bytes4 private constant ERC165_INTERFACE_ID = 0x01ffc9a7;

    address public trustedForwarder;
    mapping(address => bool) public allowedTargets;
    mapping(address => mapping(bytes4 => bool)) public allowedRoutes;

    constructor(address _trustedForwarder) Ownable(msg.sender) {
        if (_trustedForwarder == address(0)) revert ZeroAddress();
        trustedForwarder = _trustedForwarder;
    }

    function setTrustedForwarder(address newForwarder) external onlyOwner {
        if (newForwarder == address(0)) revert ZeroAddress();
        address old = trustedForwarder;
        trustedForwarder = newForwarder;
        emit TrustedForwarderUpdated(old, newForwarder);
    }

    function setAllowedTarget(address target, bool allowed) external onlyOwner {
        if (target == address(0)) revert ZeroAddress();
        allowedTargets[target] = allowed;
        emit TargetAllowed(target, allowed);
    }

    function setAllowedRoute(address target, bytes4 selector, bool allowed) external onlyOwner {
        if (target == address(0)) revert ZeroAddress();
        allowedRoutes[target][selector] = allowed;
        emit RouteAllowed(target, selector, allowed);
    }

    function setAllowedRoutes(address target, bytes4[] calldata selectors, bool allowed) external onlyOwner {
        if (target == address(0)) revert ZeroAddress();
        for (uint256 i = 0; i < selectors.length; i++) {
            allowedRoutes[target][selectors[i]] = allowed;
            emit RouteAllowed(target, selectors[i], allowed);
        }
    }

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

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IWorkflowReportReceiver).interfaceId || interfaceId == ERC165_INTERFACE_ID;
    }
}
