// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC1363Receiver} from "@openzeppelin/contracts/interfaces/IERC1363Receiver.sol";
import {console} from "forge-std/console.sol";

/// @notice Mock implementation of Chainlink Functions Router
/// @dev Simulates the behavior of the real Chainlink DON network
contract MockFunctionsRouter is IERC1363Receiver {
    address public immutable i_linkToken;
    bytes32 public s_lastRequestId;
    mapping(bytes32 => address) public s_requesters;

    // Constants to match real Functions Router
    uint16 public constant MINIMUM_REQUEST_CONFIRMATIONS = 1;
    
    bool public shouldFailOnTransferReceived = false;
    function setShouldFailOnTransferReceived(bool fail) external {
        shouldFailOnTransferReceived = fail;
    }

    constructor(address linkToken) {
        i_linkToken = linkToken;
    }

    function onTransferReceived(
        address,
        address,
        uint256,
        bytes memory
    ) external view override returns (bytes4) {
        if (shouldFailOnTransferReceived) {
            revert("MockFunctionsRouter: onTransferReceived forced failure");
        }
        return this.onTransferReceived.selector;
    }

    /// @notice Mock implementation of Chainlink Functions request sending
    /// @dev Interface matches IFunctionsRouter
    function sendRequest(
        uint64 subscriptionId,
        bytes memory data,
        uint16 dataVersion,
        uint32 callbackGasLimit,
        bytes32 donId
    ) external returns (bytes32) {
        console.log("=== MockFunctionsRouter::sendRequest ===");
        console.log("subscriptionId:", subscriptionId);
        console.log("data length:", data.length);
        console.log("dataVersion:", dataVersion);
        console.log("callbackGasLimit:", callbackGasLimit);
        console.logBytes32(donId);

        // Generate a deterministic requestId
        bytes32 requestId = bytes32(uint256(1));
        s_lastRequestId = requestId;
        s_requesters[requestId] = msg.sender;
        return requestId;
    }

    /// @notice Simulates DON response with realistic oracle data
    /// @dev In production, this would be called by the Chainlink DON with real data
    function fulfillRequest(
        bytes32 requestId,
        bytes memory response_override,
        bytes memory error
    ) external {
        address requester = s_requesters[requestId];
        require(requester != address(0), "Request not found");

        console.log("=== MockFunctionsRouter::fulfillRequest ===");
        console.log("requestId:", uint256(requestId));
        console.log("requester:", requester);

        bytes memory response;
        if (response_override.length > 0) {
            response = response_override;
        } else {
            // Default response
            response = abi.encode(uint256(1));
        }
        
        console.log("=== Mock Router Response ===");
        console.log("Response length:", response.length);
        console.logBytes(response);
        
        // Try to decode the response
        uint256 decoded = abi.decode(response, (uint256));
        console.log("Decoded value:", decoded);

        console.log("Simulated DON response");
        console.log("Calling fulfillRequest with response:");
        console.logBytes(response);

        (bool success, bytes memory returnData) = requester.call(
            abi.encodeWithSignature(
                "handleOracleFulfillment(bytes32,bytes,bytes)",
                requestId,
                response,
                error
            )
        );

        if (!success) {
            // Forward the revert data from the callback
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }
}
