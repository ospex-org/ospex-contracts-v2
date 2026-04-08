// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionType} from "../core/OspexTypes.sol";

interface IContributionModule {
    /**
     * @notice Handles a contribution, transferring tokens and emitting events
     * @param speculationId The speculation ID
     * @param contributor The address making the contribution
     * @param positionType The position type
     * @param contributionAmount The amount to contribute
     */
    function handleContribution(
        uint256 speculationId,
        address contributor,
        PositionType positionType,
        uint256 contributionAmount
    ) external;

    /**
     * @notice Sets the contribution token (admin only)
     * @param newToken The address of the new contribution token
     */
    function setContributionToken(address newToken) external;

    /**
     * @notice Sets the contribution receiver (admin only)
     * @param newReceiver The address of the new contribution receiver
     */
    function setContributionReceiver(address newReceiver) external;

}
