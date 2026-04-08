// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Contest, ContestMarket, ContestStatus} from "../../src/core/OspexTypes.sol";

// --- MockContestModule ---
// This mock is ONLY used to allow SpeculationModule to call getContest in tests.
// It is NOT used to test contest logic, only to provide the minimum interface for SpeculationModule to function.
// This is necessary because SpeculationModule requires a contest module to be registered in the core.
contract MockContestModule {
    mapping(uint256 => Contest) public contests;
    mapping(uint256 => uint32) public s_contestStartTimes;
    mapping(uint256 => mapping(address => ContestMarket)) public contestMarkets;
    
    function setContest(uint256 contestId, Contest memory contest) external {
        contests[contestId] = contest;
    }
    
    function setContestStartTime(uint256 contestId, uint32 startTime) external {
        s_contestStartTimes[contestId] = startTime;
    }
    
    function setContestMarket(uint256 contestId, address scorer, ContestMarket memory market) external {
        contestMarkets[contestId][scorer] = market;
    }
    
    function getContest(
        uint256 contestId
    ) external view returns (Contest memory) {
        return contests[contestId];
    }

    function isContestScored(uint256 contestId) external view returns (bool) {
        return
            contests[contestId].contestStatus == ContestStatus.Scored ||
            contests[contestId].contestStatus == ContestStatus.ScoredManually;
    }
    
    function getContestMarket(
        uint256 contestId,
        address scorer
    ) external view returns (ContestMarket memory) {
        return contestMarkets[contestId][scorer];
    }
}
