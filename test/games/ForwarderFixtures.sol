// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IReceiver} from "../../src/interfaces/cre/IReceiver.sol";
import {IERC165} from "../../src/interfaces/cre/IERC165.sol";

/// @dev A stand-in for Chainlink's forwarder, as the reporter sees it: the one address that calls onReport. It
///      does what the production forwarder does on the way to a receiver, and nothing of what it does before
///      (the signatures and the transmission record are the DON's business): it checks ERC-165 for IReceiver
///      with bounded static calls, then calls onReport with the metadata and the report it is handed, and
///      bubbles the receiver's revert so a caller sees the receiver's own reason. It takes a report from anyone,
///      since it is a test double for the reporter and the games set, not for the forwarder.
contract MockForwarder {
    string public constant typeAndVersion = "KeystoneForwarder 1.0.0";

    error NotAReceiver(address receiver);

    function isForwarder(address forwarder) external view returns (bool) {
        return forwarder == address(this);
    }

    /// @dev Routes a report. Reverts with the receiver's own reason if the receiver refuses it.
    function report(address receiver, bytes calldata metadata, bytes calldata data) external {
        if (
            !_supports(receiver, type(IERC165).interfaceId) || _supports(receiver, 0xffffffff)
                || !_supports(receiver, type(IReceiver).interfaceId)
        ) revert NotAReceiver(receiver);
        (bool ok, bytes memory err) = receiver.call(abi.encodeCall(IReceiver.onReport, (metadata, data)));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(err, 0x20), mload(err))
            }
        }
    }

    function _supports(address receiver, bytes4 interfaceId) private view returns (bool) {
        (bool ok, bytes memory answer) =
            receiver.staticcall{gas: 30_000}(abi.encodeCall(IERC165.supportsInterface, (interfaceId)));
        return ok && answer.length >= 32 && abi.decode(answer, (bool));
    }
}
