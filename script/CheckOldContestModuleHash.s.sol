// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";

// Simple interface to call the function
interface IContestModule {
    function s_createContestSourceHash() external view returns (bytes32);
}

contract CheckOldContestModuleHash is Script {
    // We'll check both addresses to be sure
    address constant CONTEST_MODULE_1 = 0x336EfaBe3a35121BF5B74B19be169901642830eF;
    // Add second address if you have it
    // address constant CONTEST_MODULE_2 = 0x...; 
    
    function run() external view {
        console.log("=== CHECKING CONTEST MODULE HASHES ===");
        
        checkContestModule("Contest Module 1", CONTEST_MODULE_1);
        // checkContestModule("Contest Module 2", CONTEST_MODULE_2);
        
        console.log("\n=== REFERENCE HASHES ===");
        console.log("Current calculated hash (from your createContest.js file):");
        console.logBytes32(0x376f28fb981884a8e31a081bf1cbb25e75171e86dbcde69e0d911ebad515bd3b);
        console.log("Hash contract expects (from deploy):");
        console.logBytes32(0x74533c92d0380a7aa2c8d597453cdcea7350344971be3df02623fe339002f9ab);
    }
    
    function checkContestModule(string memory name, address moduleAddress) internal view {
        console.log("\n--- Checking", name, "---");
        console.log("Address:", moduleAddress);
        
        IContestModule contestModule = IContestModule(moduleAddress);
        
        try contestModule.s_createContestSourceHash() returns (bytes32 hash) {
            console.log("Hash stored in contract:");
            console.logBytes32(hash);
            
        } catch {
            console.log(" ERROR: Could not read hash from this contract");
        }
    }
}
