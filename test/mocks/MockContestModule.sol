// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Contest} from "../../src/core/OspexTypes.sol";

// --- MockContestModule ---
// This mock is ONLY used to allow SpeculationModule to call getContest in tests.
// It is NOT used to test contest logic, only to provide the minimum interface for SpeculationModule to function.
// This is necessary because SpeculationModule requires a contest module to be registered in the core.
contract MockContestModule {
    mapping(uint256 => Contest) public contests;
    function setContest(uint256 contestId, Contest memory contest) external {
        contests[contestId] = contest;
    }
    function getContest(
        uint256 contestId
    ) external view returns (Contest memory) {
        return contests[contestId];
    }
}
