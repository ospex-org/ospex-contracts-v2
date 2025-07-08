// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {WinSide} from "../core/OspexTypes.sol";

/**
 * @title IScorerModule

 * @author ospex.org
 * @notice Base interface for all Ospex scoring contracts
 * @dev Defines the standard interface that all scoring contracts must implement
 */
interface IScorerModule {
    /**
     * @notice Determines the winning side of a speculation based on contest outcome
     * @param contestId The ID of the contest to score
     * @param theNumber The line/spread/total number for the speculation
     * @return WinSide The winning side of the speculation
     */

    function determineWinSide(
        uint256 contestId,
        int32 theNumber
    ) external view returns (WinSide);
}
