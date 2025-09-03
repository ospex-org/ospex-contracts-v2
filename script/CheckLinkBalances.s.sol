// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CheckLinkBalances is Script {
    // LINK token on Amoy
    address constant LINK_TOKEN = 0x0Fd9e8d3aF1aaee056EB9e802c3A762a667b1904;
    
    // Oracle addresses
    address constant OLD_ORACLE = 0x69BCAD36617475756A036c9024F1d6d6bfcEAb23;
    address constant NEW_ORACLE = 0xc8536E7cca2af6E9B632167810Ff55CD203a5a81;
    
    function run() external view {
        address deployer = vm.envOr("DEPLOYER", address(0x89fe160bBBe59eAF428f23F095B71E5C0EdCDfa3));
        
        IERC20 linkToken = IERC20(LINK_TOKEN);
        
        console.log("=== LINK BALANCE CHECK ===");
        console.log("LINK Token:", LINK_TOKEN);
        console.log("Deployer:", deployer);
        console.log("Old Oracle:", OLD_ORACLE);
        console.log("New Oracle:", NEW_ORACLE);
        console.log("");
        
        // Check deployer LINK balance
        uint256 deployerBalance = linkToken.balanceOf(deployer);
        console.log("Deployer LINK balance:", deployerBalance / 1e18, "LINK");
        
        // Check old oracle LINK balance
        uint256 oldOracleBalance = linkToken.balanceOf(OLD_ORACLE);
        console.log("Old Oracle LINK balance:", oldOracleBalance / 1e18, "LINK");
        
        // Check new oracle LINK balance  
        uint256 newOracleBalance = linkToken.balanceOf(NEW_ORACLE);
        console.log("New Oracle LINK balance:", newOracleBalance / 1e18, "LINK");
        
        // Check allowances
        uint256 oldAllowance = linkToken.allowance(deployer, OLD_ORACLE);
        console.log("Allowance to Old Oracle:", oldAllowance / 1e18, "LINK");
        
        uint256 newAllowance = linkToken.allowance(deployer, NEW_ORACLE);
        console.log("Allowance to New Oracle:", newAllowance / 1e18, "LINK");
        
        console.log("");
        console.log("=== DIAGNOSIS ===");
        
        if (oldOracleBalance > 0) {
            console.log(" Old Oracle has", oldOracleBalance / 1e18, "LINK - you can transfer some to new oracle");
        }
        
        if (newOracleBalance == 0 && newAllowance == 0) {
            console.log(" New Oracle has no LINK and no allowance");
            console.log("   SOLUTION: Either:");
            console.log("   1. Transfer LINK directly to New Oracle, OR");
            console.log("   2. Approve New Oracle to spend your LINK");
        }
        
        if (deployerBalance > 0) {
            console.log(" Deployer has", deployerBalance / 1e18, "LINK available");
        }
    }
}
