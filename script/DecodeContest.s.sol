// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {ContestModule} from "../src/modules/ContestModule.sol";
import {Contest, ContestStatus} from "../src/core/OspexTypes.sol";

contract DecodeContest is Script {
    address constant CONTEST_MODULE = 0x41f2F71cd6B3fbFd3A4C82E60ea9288Aa86Fe32d;
    
    function run() external view {
        uint256 contestId = vm.envOr("CONTEST_ID", uint256(222));
        
        ContestModule contestModule = ContestModule(CONTEST_MODULE);
        Contest memory contest = contestModule.getContest(contestId);
        
        // Display contest information in a readable format
        console.log("\n==== Contest Information ====");
        console.log("Contest ID:", contestId);
        
        // Status (convert enum to string)
        string memory statusStr;
        if (contest.contestStatus == ContestStatus.Unverified) statusStr = "Unverified";
        else if (contest.contestStatus == ContestStatus.Verified) statusStr = "Verified";
        else if (contest.contestStatus == ContestStatus.Scored) statusStr = "Scored";
        else statusStr = "Unknown";
        
        console.log("Status:", statusStr);
        console.log("Creator:", contest.contestCreator);
        console.log("Score Contest Source Hash:");
        console.logBytes32(contest.scoreContestSourceHash);
        
        console.log("\n-- API IDs --");
        console.log("Rundown ID:", contest.rundownId);
        console.log("Sportspage ID:", contest.sportspageId);
        console.log("JSONOdds ID:", contest.jsonoddsId);
        
        console.log("\n-- Scores --");
        console.log("Home Score:", contest.homeScore);
        console.log("Away Score:", contest.awayScore);
    }
}