// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {SpeculationModule} from "../src/modules/SpeculationModule.sol";
import {Speculation, SpeculationStatus, WinSide} from "../src/core/OspexTypes.sol";

contract DecodeSpeculation is Script {
    address constant SPECULATION_MODULE =
        0xAC3af7f720EAa73611A932574a7A57cc32CEd24d;

    function run() external view {
        uint256 speculationId = vm.envOr("SPECULATION_ID", uint256(136));

        SpeculationModule speculationModule = SpeculationModule(
            SPECULATION_MODULE
        );
        Speculation memory speculation = speculationModule.getSpeculation(
            speculationId
        );

        // Display speculation information in a readable format
        console.log("\n==== Speculation Information ====");
        console.log("Speculation ID:", speculationId);
        console.log("Contest ID:", speculation.contestId);

        // Status (convert enum to string)
        string memory statusStr;
        if (speculation.speculationStatus == SpeculationStatus.Open)
            statusStr = "Open";
        else if (speculation.speculationStatus == SpeculationStatus.Closed)
            statusStr = "Closed";
        else statusStr = "Unknown";

        // Win side (convert enum to string)
        string memory winSideStr;
        if (speculation.winSide == WinSide.TBD) winSideStr = "TBD";
        else if (speculation.winSide == WinSide.Home) winSideStr = "Home";
        else if (speculation.winSide == WinSide.Away) winSideStr = "Away";
        else if (speculation.winSide == WinSide.Over) winSideStr = "Over";
        else if (speculation.winSide == WinSide.Under) winSideStr = "Under";
        else if (speculation.winSide == WinSide.Push) winSideStr = "Push";
        else if (speculation.winSide == WinSide.Void) winSideStr = "Void";
        else if (speculation.winSide == WinSide.Forfeit) winSideStr = "Forfeit";
        else winSideStr = "Unknown";

        console.log("Status:", statusStr);
        console.log("Win Side:", winSideStr);
        console.log("Creator:", speculation.speculationCreator);
        console.log("Scorer:", speculation.speculationScorer);

        console.log("\n-- Timestamps & Numbers --");
        console.log(
            "The Number (Line/Spread/Total):",
            int256(speculation.theNumber)
        );
    }
}
