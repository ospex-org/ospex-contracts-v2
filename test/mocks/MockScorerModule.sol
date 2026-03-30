// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {WinSide} from "../../src/core/OspexTypes.sol";

// --- MockScorerModule ---
// This mock implements the IScorerModule interface to provide the determineWinSide function
contract MockScorerModule {
    mapping(uint256 => mapping(int32 => WinSide)) private s_customWinSides;
    WinSide private s_defaultWinSide = WinSide.Away;

    // Set a specific win side for a contestId + lineTicks combination
    function setWinSide(uint256 contestId, int32 lineTicks, WinSide winSide) external {
        s_customWinSides[contestId][lineTicks] = winSide;
    }

    // Set the default win side returned when no specific mapping exists
    function setDefaultWinSide(WinSide winSide) external {
        s_defaultWinSide = winSide;
    }

    // Implementation of IScorerModule's determineWinSide function
    function determineWinSide(uint256 contestId, int32 lineTicks) external view returns (WinSide) {
        // Return custom win side if set for this contestId + lineTicks
        if (s_customWinSides[contestId][lineTicks] != WinSide.TBD) {
            return s_customWinSides[contestId][lineTicks];
        }
        // Otherwise return the default win side
        return s_defaultWinSide;
    }
}

