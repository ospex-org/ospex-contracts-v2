// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {OracleModule} from "../src/modules/OracleModule.sol";
import {ContestModule} from "../src/modules/ContestModule.sol";

/**
 * @title CreateContest
 * @notice Script to create a new contest with teams on the Ospex platform
 * @dev Run with: forge script script/contest/CreateContest.s.sol:CreateContest --rpc-url [RPC_URL] --broadcast --account [ACCOUNT]
 */
contract CreateContestV21 is Script {
    // Address of deployed contest manager on Amoy
    address constant ORACLE_MODULE = 0x69BCAD36617475756A036c9024F1d6d6bfcEAb23;
    address constant CONTEST_MODULE =
        0x336EfaBe3a35121BF5B74B19be169901642830eF;
    bytes constant ENCRYPTED_SECRETS_URLS =
        hex"a3eaa393bebdc029324c0450fdf911ba029685e2051858d5fe17b1d6b32d442ed293c6cfd01fff7aa49e165d181e13a51a9fb838c9deb048b787c6d4c7295b53211e11b5592d74639d3a9664cd4bb81adcbb327ec5192c76704b6b84b35789b88549438257c12693c6850cdc50bf51e72acd83626293835b80a1187183571061192899b62786e10639209bda99bd3275590d121b563dc9aab9d912cf9ea4a1e14b829593eb0f1cc4bed2642f8ad622228d54439106c5984b36b94f609d68e5b1df74e2441661febdc58e55e64ab7f6dd0b";

    // Function to read the file content as a string during script compilation
    function getSourceCode() internal view returns (string memory) {
        string memory path = "chainlink-functions/createContest.js";
        return vm.readFile(path);
    }

    function run() external {
        // Get deployer address
        address deployer = vm.envOr(
            "DEPLOYER",
            address(0x89fe160bBBe59eAF428f23F095B71E5C0EdCDfa3)
        );
        vm.startBroadcast(deployer);

        OracleModule oracleModule = OracleModule(ORACLE_MODULE);

        ContestModule contestModule = ContestModule(CONTEST_MODULE);

        // Get the source code
        string memory sourceCode = getSourceCode();

        // Calculate hash from source code
        bytes32 calculatedHash = keccak256(abi.encodePacked(sourceCode));
        console.log("Source code length:", bytes(sourceCode).length, "bytes");
        console.log("Calculated source hash:");
        console.logBytes32(calculatedHash);

        // Get current hash from contract
        bytes32 contractHash;
        try contestModule.s_createContestSourceHash() returns (
            bytes32 currentHash
        ) {
            contractHash = currentHash;
            console.log("Current contract hash:");
            console.logBytes32(contractHash);

            if (calculatedHash == contractHash) {
                console.log("MATCH: Source hash matches contract hash");
            } else {
                console.log("MISMATCH: Source hash differs from contract hash");
            }
        } catch {
            console.log("Failed to read current hash from contract");
        }

        // Log information before creating the contest
        console.log("\nCreating contest with following parameters:");
        console.log("RundownId: 3b60170d2cf90cc1ca746493af4fd175");
        console.log("SportspageId: 323507");
        console.log("JsonoddsId: 099debaf-d9e2-4889-8b0b-45232b18602a");
        console.log("SubscriptionId: 416");
        console.log("GasLimit: 300000");

        // Try to create a contest and catch any errors
        try
            oracleModule.createContestFromOracle(
                "3b60170d2cf90cc1ca746493af4fd175",
                "323507",
                "099debaf-d9e2-4889-8b0b-45232b18602a",
                sourceCode,
                bytes32(
                    0xcb2a11db3190c322239b52afb3caefccfccd850566834819b012c5520f8d31cd
                ),
                1,
                ENCRYPTED_SECRETS_URLS,
                416,
                300000
            )
        {
            console.log("Contest creation transaction submitted successfully");
        } catch Error(string memory reason) {
            console.log("Error:", reason);

            // If we have a revert reason, check if it's the hash error
            if (
                bytes(reason).length > 0 &&
                keccak256(abi.encodePacked(reason)) ==
                keccak256(
                    abi.encodePacked(
                        "OspexContestManager__IncorrectSourceHash()"
                    )
                )
            ) {
                console.log("\nDetected IncorrectSourceHash error!");
                console.log("Attempted source hash:");
                console.logBytes32(calculatedHash);

                if (contractHash != bytes32(0)) {
                    console.log("Contract expected hash:");
                    console.logBytes32(contractHash);

                    console.log("\nTo fix this issue, either:");
                    console.log(
                        "1. Update your source code to match the expected hash"
                    );
                    console.log("2. Update the contract's expected hash with:");
                    console.log(
                        "   contestManager.setContestSourceHash(calculatedHash)"
                    );
                }
            }
        } catch (bytes memory lowLevelData) {
            console.log("Failed with low level error");
            console.logBytes(lowLevelData);
        }

        vm.stopBroadcast();
    }
}
