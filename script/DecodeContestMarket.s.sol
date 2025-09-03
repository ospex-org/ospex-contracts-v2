// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {ContestModule} from "../src/modules/ContestModule.sol";
import {OspexCore} from "../src/core/OspexCore.sol";
import {Contest, ContestMarket, ContestStatus} from "../src/core/OspexTypes.sol";

contract DecodeContestMarket is Script {
    address constant CONTEST_MODULE = 0x8bE406158D7709A72f1331F3186881C19e0e6193;
    // address constant OSPEX_CORE = 0x129a5c0fbA5f448F4b7cF4E1469D80cf8EceaEDb;
    
    function run() external view {
        uint256 contestId = vm.envOr("CONTEST_ID", uint256(2));
        
        ContestModule contestModule = ContestModule(CONTEST_MODULE);
        // OspexCore ospexCore = OspexCore(OSPEX_CORE);
        
        // Get scorer addresses from core registry
        address moneylineScorer = 0x27e201c4faaC66829a30C0cbf1e6eC4E535CB97c;
        address spreadScorer = 0x0431aB14F02d023ed1Eb1452ef2a5aA259F3a734;
        address totalScorer = 0xD06FF0BfBE4004752b13e657d9ead74F7B125FE0;
        
        // Display contest market information in a readable format
        console.log("\n==== Contest Markets Information ====");
        console.log("Contest ID:", contestId);
        
        console.log("\n-- Scorer Addresses --");
        console.log("Moneyline Scorer:", moneylineScorer);
        console.log("Spread Scorer:", spreadScorer);
        console.log("Total Scorer:", totalScorer);
        
        // Get each market separately
        ContestMarket memory moneylineMarket = contestModule.getContestMarket(contestId, moneylineScorer);
        ContestMarket memory spreadMarket = contestModule.getContestMarket(contestId, spreadScorer);
        ContestMarket memory totalMarket = contestModule.getContestMarket(contestId, totalScorer);
        
        console.log("\n==== MONEYLINE MARKET ====");
        console.log("The Number (should be 0):", uint256(int256(moneylineMarket.theNumber)));
        console.log("Upper Odds (Away):", moneylineMarket.upperOdds);
        console.log("Lower Odds (Home):", moneylineMarket.lowerOdds);
        console.log("Last Updated:", moneylineMarket.lastUpdated);
        int256 awayAmericanOdds = _convertToAmericanOdds(moneylineMarket.upperOdds);
        int256 homeAmericanOdds = _convertToAmericanOdds(moneylineMarket.lowerOdds);
        console.log("Away Odds (American, raw):", awayAmericanOdds >= 0 ? uint256(awayAmericanOdds) : uint256(-awayAmericanOdds));
        console.log("Away Odds is negative:", awayAmericanOdds < 0);
        console.log("Home Odds (American, raw):", homeAmericanOdds >= 0 ? uint256(homeAmericanOdds) : uint256(-homeAmericanOdds));
        console.log("Home Odds is negative:", homeAmericanOdds < 0);
        
        console.log("\n==== SPREAD MARKET ====");
        console.log("The Number (raw):", uint256(int256(spreadMarket.theNumber)));
        if (spreadMarket.theNumber < 0) {
            console.log("  (negative value, actual: -", uint256(-int256(spreadMarket.theNumber)), ")");
        }
        console.log("Upper Odds (Away):", spreadMarket.upperOdds);
        console.log("Lower Odds (Home):", spreadMarket.lowerOdds);
        console.log("Last Updated:", spreadMarket.lastUpdated);
        
        // Convert spread number (should be in increments of 10, e.g., 15 = 1.5)
        int256 spreadInt = int256(spreadMarket.theNumber);
        console.log("Spread raw value:", uint256(int256(spreadMarket.theNumber)));
        console.log("Spread divided by 10:", uint256(spreadInt >= 0 ? spreadInt : -spreadInt) / 10);
        console.log("Spread remainder:", uint256(spreadInt >= 0 ? spreadInt : -spreadInt) % 10);
        console.log("Spread is negative:", spreadInt < 0);
        int256 spreadAwayAmericanOdds = _convertToAmericanOdds(spreadMarket.upperOdds);
        int256 spreadHomeAmericanOdds = _convertToAmericanOdds(spreadMarket.lowerOdds);
        console.log("Away Odds (American, raw):", spreadAwayAmericanOdds >= 0 ? uint256(spreadAwayAmericanOdds) : uint256(-spreadAwayAmericanOdds));
        console.log("Away Odds is negative:", spreadAwayAmericanOdds < 0);
        console.log("Home Odds (American, raw):", spreadHomeAmericanOdds >= 0 ? uint256(spreadHomeAmericanOdds) : uint256(-spreadHomeAmericanOdds));
        console.log("Home Odds is negative:", spreadHomeAmericanOdds < 0);
        
        console.log("\n==== TOTAL MARKET ====");
        console.log("The Number (raw):", uint256(int256(totalMarket.theNumber)));
        console.log("Upper Odds (Over):", totalMarket.upperOdds);
        console.log("Lower Odds (Under):", totalMarket.lowerOdds);
        console.log("Last Updated:", totalMarket.lastUpdated);
        
        // Convert total number (should be in increments of 10, e.g., 95 = 9.5)
        int256 totalInt = int256(totalMarket.theNumber);
        console.log("Total raw value:", uint256(totalInt));
        console.log("Total divided by 10:", uint256(totalInt) / 10);
        console.log("Total remainder:", uint256(totalInt) % 10);
        int256 overAmericanOdds = _convertToAmericanOdds(totalMarket.upperOdds);
        int256 underAmericanOdds = _convertToAmericanOdds(totalMarket.lowerOdds);
        console.log("Over Odds (American, raw):", overAmericanOdds >= 0 ? uint256(overAmericanOdds) : uint256(-overAmericanOdds));
        console.log("Over Odds is negative:", overAmericanOdds < 0);
        console.log("Under Odds (American, raw):", underAmericanOdds >= 0 ? uint256(underAmericanOdds) : uint256(-underAmericanOdds));
        console.log("Under Odds is negative:", underAmericanOdds < 0);
    }
    
    function _convertToAmericanOdds(uint64 scaledDecimalOdds) internal pure returns (int256) {
        // Convert from 1e7 precision scaled decimal to American odds
        if (scaledDecimalOdds == 0) return 0; // Handle zero case
        
        uint256 decimalOdds = scaledDecimalOdds; // Already in 1e7 format
        
        if (decimalOdds >= 20000000) { // >= 2.0 in decimal odds
            // Positive American odds: (decimal - 1) * 100
            return int256((decimalOdds - 10000000) / 100000); // Convert to +XXX format
        } else if (decimalOdds > 10000000) { // > 1.0 but < 2.0 in decimal odds
            // Negative American odds: -100 / (decimal - 1)
            return -int256(1000000000 / (decimalOdds - 10000000)); // Convert to -XXX format
        } else {
            return 0; // Invalid odds
        }
    }
}
