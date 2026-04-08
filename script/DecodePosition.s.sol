// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {PositionModule} from "../src/modules/PositionModule.sol";
import {SpeculationModule} from "../src/modules/SpeculationModule.sol";
import {Position, PositionType, Speculation, SpeculationStatus, WinSide} from "../src/core/OspexTypes.sol";

/// @notice This script needs a full rewrite for the new Position struct (riskAmount/profitAmount).
///         Stubbed out to unblock compilation.
contract DecodePosition is Script {
    address constant POSITION_MODULE = 0xba309c1900bB1Ffd6FA62dfEBFdA350738eE735e;
    address constant SPECULATION_MODULE = 0xAC3af7f720EAa73611A932574a7A57cc32CEd24d;

    function run() external view {
        uint256 speculationId = vm.envOr("SPECULATION_ID", uint256(98));
        address user = vm.envOr("USER_ADDRESS", address(0x89fe160bBBe59eAF428f23F095B71E5C0EdCDfa3));
        PositionType positionType = PositionType.Upper;

        PositionModule positionManager = PositionModule(POSITION_MODULE);
        SpeculationModule speculationManager = SpeculationModule(SPECULATION_MODULE);

        // Get the position (new interface: no oddsPairId)
        Position memory position = positionManager.getPosition(
            speculationId,
            user,
            positionType
        );

        if (position.riskAmount == 0) {
            console.log("\n==== Position Not Found ====");
            console.log("No position found for:");
            console.log("Speculation ID:", speculationId);
            console.log("User:", user);
            string memory posTypeStr = positionType == PositionType.Upper ? "Upper (Away/Over)" : "Lower (Home/Under)";
            console.log("Position Type:", posTypeStr);
            return;
        }

        console.log("\n==== Position Information ====");
        console.log("Speculation ID:", speculationId);
        console.log("User:", user);

        string memory posTypeStr2 = position.positionType == PositionType.Upper ? "Upper (Away/Over)" : "Lower (Home/Under)";
        console.log("Position Type:", posTypeStr2);

        console.log("\n-- Amounts --");
        console.log("Risk Amount:", position.riskAmount);
        console.log("Profit Amount:", position.profitAmount);

        console.log("\n-- Amounts (in USDC) --");
        console.log("Risk Amount (USDC):", position.riskAmount / 1e6);
        console.log("Profit Amount (USDC):", position.profitAmount / 1e6);

        // Get speculation information
        try speculationManager.getSpeculation(speculationId) returns (Speculation memory speculation) {
            console.log("\n-- Speculation Information --");
            console.log("Contest ID:", speculation.contestId);
            console.log("Speculation Scorer:", speculation.speculationScorer);
            console.log("The Number (Line/Spread/Total):", int256(speculation.lineTicks));

            string memory statusStr = speculation.speculationStatus == SpeculationStatus.Open ? "Open" : "Closed";
            console.log("Status:", statusStr);

            if (speculation.speculationStatus == SpeculationStatus.Closed) {
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

                bool positionWon = false;
                if (speculation.winSide == WinSide.Away && position.positionType == PositionType.Upper) positionWon = true;
                if (speculation.winSide == WinSide.Home && position.positionType == PositionType.Lower) positionWon = true;
                if (speculation.winSide == WinSide.Over && position.positionType == PositionType.Upper) positionWon = true;
                if (speculation.winSide == WinSide.Under && position.positionType == PositionType.Lower) positionWon = true;

                console.log("This Position Result:", positionWon ? "WON" : "LOST");
            }
        } catch {
            console.log("\n-- Could not fetch speculation information --");
        }
    }
}
