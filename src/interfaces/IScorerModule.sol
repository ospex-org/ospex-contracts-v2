// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {WinSide} from "../core/OspexTypes.sol";

/**
 * @title IScorerModule
 * @author ospex.org
 * @notice Base interface for all Ospex scoring contracts. Each scorer implements
 *         market-specific logic (moneyline, spread, total) to determine the winning side.
 */
interface IScorerModule {
    /// @notice Determines the winning side of a speculation based on contest outcome
    /// @param contestId The ID of the contest to score
    /// @param lineTicks The line/spread/total number (10x format, 0 for moneyline)
    /// @return The winning side of the speculation
    function determineWinSide(
        uint256 contestId,
        int32 lineTicks
    ) external view returns (WinSide);
}
