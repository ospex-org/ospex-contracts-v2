// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * @title IOspexReporter
 * @author ospex.org
 * @notice The one read every reporter has. When the timelock approves a reporter, the games set calls it and
 *         emits what it returns, so the values a reporter was built with are on chain, read from the reporter
 *         itself, from the moment it is approved. Nothing the approver supplies stands in for them, and a
 *         reporter without this read cannot be approved.
 * @dev The read is generic so that the games set knows nothing of any one kind of reporter. Each reporter
 *      documents how its values are encoded. The launch reporter returns
 *      `abi.encode(address forwarder, address workflowOwner, bytes32 workflowId)`. The games set refuses an
 *      empty answer. It emits the answer as read and checks nothing in it: that the values are true and fixed
 *      is for review.
 */
interface IOspexReporter {
    /// @notice The values this reporter was built with and can never change, ABI-encoded. Never empty.
    function fixedValues() external view returns (bytes memory values);
}
