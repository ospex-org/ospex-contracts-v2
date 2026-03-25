// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {PositionModule} from "../src/modules/PositionModule.sol";
import {SpeculationModule} from "../src/modules/SpeculationModule.sol";
import {Position, PositionType, OddsPair, Speculation, SpeculationStatus, WinSide} from "../src/core/OspexTypes.sol";

contract DecodePosition is Script {
    // Contract addresses from deployment - change these to your deployed contract addresses
    address constant POSITION_MODULE = 0xba309c1900bB1Ffd6FA62dfEBFdA350738eE735e;
    address constant SPECULATION_MODULE = 0xAC3af7f720EAa73611A932574a7A57cc32CEd24d;
    
    function run() external view {
        // Hardcode the values you want to look up here
        uint256 speculationId = vm.envOr("SPECULATION_ID", uint256(98)); // Example speculation ID
        address user = vm.envOr("USER_ADDRESS", address(0x89fe160bBBe59eAF428f23F095B71E5C0EdCDfa3)); // Example user address with correct checksum
        // uint128 oddsPairId = vm.envOr("ODDS_PAIR_ID", uint128(189)); // Example oddsPairId
        uint128 oddsPairId = 99;
        PositionType positionType = PositionType.Upper; // Change to Upper if needed - you can also make this an env var
        
        PositionModule positionManager = PositionModule(POSITION_MODULE);
        SpeculationModule speculationManager = SpeculationModule(SPECULATION_MODULE);
        
        // Get the position
        Position memory position = positionManager.getPosition(
            speculationId,
            user,
            oddsPairId,
            positionType
        );
        
        // Check if position exists
        if (position.poolId == 0) {
            console.log("\n==== Position Not Found ====");
            console.log("No position found for:");
            console.log("Speculation ID:", speculationId);
            console.log("User:", user);
            console.log("OddsPairId:", uint256(oddsPairId));
            string memory posTypeStr = positionType == PositionType.Upper ? "Upper (Away/Over)" : "Lower (Home/Under)";
            console.log("Position Type:", posTypeStr);
            return;
        }
        
        // Display position information
        console.log("\n==== Position Information ====");
        console.log("Speculation ID:", speculationId);
        console.log("User:", user);
        console.log("Pool ID:", uint256(position.poolId));
        
        // Position type
        string memory posTypeStr2 = position.positionType == PositionType.Upper ? "Upper (Away/Over)" : "Lower (Home/Under)";
        console.log("Position Type:", posTypeStr2);
        
        // Amounts
        console.log("\n-- Amounts --");
        console.log("Matched Amount:", position.matchedAmount);
        
        // In USDC (6 decimals) - uncomment if you want to see USD values
        console.log("\n-- Amounts (in USDC) --");
        console.log("Matched Amount (USDC):", position.matchedAmount / 1e6);
        
        // Get associated odds
        try positionManager.getOddsPair(position.poolId) returns (OddsPair memory oddsPair) {
            console.log("\n-- Odds Information --");
            console.log("OddsPair ID:", oddsPair.oddsPairId);
            console.log("Upper Odds (raw):", oddsPair.upperOdds);
            console.log("Lower Odds (raw):", oddsPair.lowerOdds);
            
            // Convert to decimal odds (divide by ODDS_PRECISION = 1e7)
            uint256 oddsPrecision = positionManager.ODDS_PRECISION();
            console.log("Upper Odds (decimal):", oddsPair.upperOdds / (oddsPrecision / 100)); // Shows as 200 for 2.00 odds
            console.log("Lower Odds (decimal):", oddsPair.lowerOdds / (oddsPrecision / 100));
            
            // Display the odds for this specific position
            if (position.positionType == PositionType.Upper) {
                console.log("This Position's Odds (decimal):", oddsPair.upperOdds / (oddsPrecision / 100));
            } else {
                console.log("This Position's Odds (decimal):", oddsPair.lowerOdds / (oddsPrecision / 100));
            }
            
            // Show original requested odds if available
            try positionManager.getOriginalOdds(position.poolId) returns (uint64 originalOdds) {
                console.log("Original Requested Odds (decimal):", originalOdds / (oddsPrecision / 100));
            } catch {
                console.log("Original odds not available");
            }
            
        } catch {
            console.log("\n-- Could not fetch odds information --");
        }
        
        // Get speculation information
        try speculationManager.getSpeculation(speculationId) returns (Speculation memory speculation) {
            console.log("\n-- Speculation Information --");
            console.log("Contest ID:", speculation.contestId);
            console.log("Speculation Scorer:", speculation.speculationScorer);
            console.log("The Number (Line/Spread/Total):", int256(speculation.theNumber));
            
            string memory statusStr = speculation.speculationStatus == SpeculationStatus.Open ? "Open" : "Closed";
            console.log("Status:", statusStr);
            
            if (speculation.speculationStatus == SpeculationStatus.Closed) {
                // Show winning side
                string memory winSideStr;
                if (speculation.winSide == WinSide.TBD) winSideStr = "TBD";
                else if (speculation.winSide == WinSide.Away) winSideStr = "Away";
                else if (speculation.winSide == WinSide.Home) winSideStr = "Home";
                else if (speculation.winSide == WinSide.Over) winSideStr = "Over";
                else if (speculation.winSide == WinSide.Under) winSideStr = "Under";
                else if (speculation.winSide == WinSide.Push) winSideStr = "Push";
                else if (speculation.winSide == WinSide.Forfeit) winSideStr = "Forfeit";
                else if (speculation.winSide == WinSide.Void) winSideStr = "Void";
                else winSideStr = "Unknown";
                
                console.log("Winning Side:", winSideStr);
                
                // Determine if this position won
                bool positionWon = false;
                if (speculation.winSide == WinSide.Away && position.positionType == PositionType.Upper) positionWon = true; // Away
                if (speculation.winSide == WinSide.Home && position.positionType == PositionType.Lower) positionWon = true; // Home
                if (speculation.winSide == WinSide.Over && position.positionType == PositionType.Upper) positionWon = true; // Over
                if (speculation.winSide == WinSide.Under && position.positionType == PositionType.Lower) positionWon = true; // Under
                
                console.log("This Position Result:", positionWon ? "WON" : "LOST");
            }
        } catch {
            console.log("\n-- Could not fetch speculation information --");
        }
        
        // Display related information if this position is matched
        if (position.matchedAmount > 0) {
            console.log("\n-- Matching Information --");
            console.log("This position has", position.matchedAmount / 1e6, "USDC matched");
            console.log("To find the opposing position, look for:");
            
            PositionType opposingType = position.positionType == PositionType.Upper ? 
                PositionType.Lower : PositionType.Upper;
            
            string memory opposingTypeStr = opposingType == PositionType.Upper ? 
                "Upper (Away/Over)" : "Lower (Home/Under)";
                
            console.log("- Same speculation ID and oddsPairId");
            console.log("- Position Type:", opposingTypeStr);
        }
        
    }
} 