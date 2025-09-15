// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {LeaderboardModule} from "../src/modules/LeaderboardModule.sol";
import {ITreasuryModule} from "../src/interfaces/ITreasuryModule.sol";
import {Leaderboard} from "../src/core/OspexTypes.sol";

contract DecodeLeaderboard is Script {
    address constant LEADERBOARD_MODULE = 0x050d836a4819488034E9aAd2eE5608c713E0F5dE;
    address constant TREASURY_MODULE = 0x8a92F03e5C1a7334C14801d9bf609C51E3EaC1C8;
    
    function run() external view {
        uint256 leaderboardId = vm.envOr("LEADERBOARD_ID", uint256(4));
        address userAddress = vm.envOr("USER_ADDRESS", address(0x30CB6F160ff723Fc9Eca646a4BD24Ff4b9e4f7Bb));
        
        LeaderboardModule leaderboardModule = LeaderboardModule(LEADERBOARD_MODULE);
        ITreasuryModule treasuryModule = ITreasuryModule(TREASURY_MODULE);
        Leaderboard memory leaderboard = leaderboardModule.getLeaderboard(leaderboardId);
        
        // Display leaderboard information in a readable format
        console.log("\n==== Leaderboard Information ====");
        console.log("Leaderboard ID:", leaderboardId);
        
        console.log("\n-- Financial Details --");
        uint256 actualPrizePool = treasuryModule.getPrizePool(leaderboardId);
        console.log("Prize Pool (from Treasury):", actualPrizePool);
        console.log("Entry Fee:", leaderboard.entryFee);
        console.log("Yield Strategy:", leaderboard.yieldStrategy);
        
        console.log("\n-- Time Configuration --");
        console.log("Start Time:", leaderboard.startTime);
        console.log("End Time:", leaderboard.endTime);
        console.log("Safety Period Duration:", leaderboard.safetyPeriodDuration);
        console.log("ROI Submission Window:", leaderboard.roiSubmissionWindow);
        console.log("Claim Window:", leaderboard.claimWindow);
        
        // Calculate derived timestamps
        console.log("\n-- Calculated Timestamps --");
        uint32 safetyPeriodEnd = leaderboard.endTime + leaderboard.safetyPeriodDuration;
        uint32 roiSubmissionEnd = safetyPeriodEnd + leaderboard.roiSubmissionWindow;
        uint32 claimWindowEnd = roiSubmissionEnd + leaderboard.claimWindow;
        
        console.log("Safety Period Ends:", safetyPeriodEnd);
        console.log("ROI Submission Ends:", roiSubmissionEnd);
        console.log("Claim Window Ends:", claimWindowEnd);
        
        // Current time context
        uint32 currentTime = uint32(block.timestamp);
        console.log("\n-- Current Time Context --");
        console.log("Current Timestamp:", currentTime);
        
        // Determine current phase
        string memory currentPhase;
        if (currentTime < leaderboard.endTime) {
            currentPhase = "ACTIVE";
        } else if (currentTime < safetyPeriodEnd) {
            currentPhase = "SAFETY_PERIOD";
        } else if (currentTime < roiSubmissionEnd) {
            currentPhase = "ROI_SUBMISSION";
        } else if (currentTime < claimWindowEnd) {
            currentPhase = "CLAIM_WINDOW";
        } else {
            currentPhase = "EXPIRED";
        }
        
        console.log("Current Phase:", currentPhase);
        
        // Validation checks
        console.log("\n-- Validation Checks --");
        console.log("Has Prize Pool:", actualPrizePool > 0 ? "YES" : "NO");
        console.log("Has Yield Strategy:", leaderboard.yieldStrategy != address(0) ? "YES" : "NO");
        console.log("Is Time Valid:", leaderboard.endTime > leaderboard.startTime ? "YES" : "NO");
        
        // LeaderboardScoring information
        console.log("\n==== LeaderboardScoring Information ====");
        console.log("User Address:", userAddress);
        
        // Get all the scoring data
        int256 userROI = leaderboardModule.getUserROI(leaderboardId, userAddress);
        address[] memory winners = leaderboardModule.getWinners(leaderboardId);
        int256 highestROI = leaderboardModule.getHighestROI(leaderboardId);
        bool hasUserClaimed = leaderboardModule.hasClaimed(leaderboardId, userAddress);
        
        console.log("\n-- User Specific Data --");
        console.log("User ROI:", userROI);
        console.log("User Has Claimed:", hasUserClaimed ? "YES" : "NO");
        
        console.log("\n-- Leaderboard Scoring State --");
        console.log("Highest ROI:", highestROI);
        console.log("Number of Winners:", winners.length);
        
        if (winners.length > 0) {
            console.log("\n-- Winners List --");
            for (uint i = 0; i < winners.length; i++) {
                console.log("Winner", i + 1, ":", winners[i]);
                // Check if this user is the current user
                if (winners[i] == userAddress) {
                    console.log("  ^^ THIS IS THE CURRENT USER ^^");
                }
            }
        } else {
            console.log("No winners recorded yet");
        }
        
        // Critical claim validation checks
        console.log("\n-- Claim Validation Checks --");
        console.log("User has submitted ROI:", userROI != 0 ? "YES" : "NO");
        console.log("User is in winners list:", isUserInWinners(winners, userAddress) ? "YES" : "NO");
        console.log("Prize pool exists:", actualPrizePool > 0 ? "YES" : "NO");
        console.log("User has not claimed:", !hasUserClaimed ? "YES" : "NO");
        bool inClaimWindow = (currentTime >= roiSubmissionEnd && currentTime < claimWindowEnd);
        console.log("In claim window:", inClaimWindow ? "YES" : "NO");
    }
    
    // Helper function to check if user is in winners array
    function isUserInWinners(address[] memory winners, address user) internal pure returns (bool) {
        for (uint i = 0; i < winners.length; i++) {
            if (winners[i] == user) {
                return true;
            }
        }
        return false;
    }
}
