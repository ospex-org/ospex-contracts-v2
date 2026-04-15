// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {OracleModule} from "../src/modules/OracleModule.sol";
import {ScriptApproval, ScriptPurpose, LeagueId} from "../src/core/OspexTypes.sol";

/**
 * @title CreateContestV22
 * @notice Script to create a new contest via Chainlink Functions oracle
 * @dev Updated for zero-admin refactor — no more source hash validation in ContestModule
 */
contract CreateContestV22 is Script {
    // Amoy v2.3 deployment (2026-04-10)
    address constant ORACLE_MODULE = 0x18F8BFfB2250635A419982eAe69099d97f596F8F;
    bytes constant ENCRYPTED_SECRETS_URLS =
        hex"d32013655bd4b1e55a6bf1b7e9df07280379d299a2e13b2e6aa7f033eb350502373d4e9b4d0feb9815338c6806e04f17636b64b989ce8065060163d51309b71324fb7c8952361b9eb91bb743b58596c404886518e9c0541b905f235f8db209fadd41615c1f436fbfc4cbfbb84124a4921ac3e83ad351189e145317ce17e49ecaeae9919bd6d44a3436de52df4f441e1ba9f5d74d562a541cadbaef5963a206490e2d2fd62b291d3d79ef98521ee0ed50345f6f7aab1d0d0a78af95a015ec051dd00eda0fd3eff0beb853c2d3a5b94a6589";

    function getSourceCode() internal view returns (string memory) {
        string memory path = "chainlink-functions/createContest.js";
        return vm.readFile(path);
    }

    function _buildApprovals() internal pure returns (OracleModule.ScriptApprovals memory) {
        return OracleModule.ScriptApprovals({
            verifyApproval: ScriptApproval(bytes32(0), ScriptPurpose.VERIFY, LeagueId.Unknown, 0, 0),
            verifyApprovalSig: "",
            marketUpdateApproval: ScriptApproval(bytes32(0), ScriptPurpose.MARKET_UPDATE, LeagueId.Unknown, 0, 0),
            marketUpdateApprovalSig: "",
            scoreApproval: ScriptApproval(bytes32(0), ScriptPurpose.SCORE, LeagueId.Unknown, 0, 0),
            scoreApprovalSig: ""
        });
    }

    function _createContest(OracleModule oracleModule, string memory sourceCode) internal {
        OracleModule.CreateContestParams memory params = OracleModule.CreateContestParams({
            rundownId: "afe40b8598c5675226a0f6b6acacf820",
            sportspageId: "329277",
            jsonoddsId: "c76d1939-52b3-4df2-b64c-026ca51e852e",
            createContestSourceJS: sourceCode,
            encryptedSecretsUrls: ENCRYPTED_SECRETS_URLS,
            subscriptionId: 416,
            gasLimit: 300000
        });

        try
            oracleModule.createContestFromOracle(
                params,
                bytes32(0x7f5ce70565133fedb2e0f1aeb925f38a3b26924917cff852e7de40a9297119b4), // marketUpdateSourceHash
                bytes32(0xcb2a11db3190c322239b52afb3caefccfccd850566834819b012c5520f8d31cd), // scoreContestSourceHash
                _buildApprovals()
            )
        {
            console.log("Contest creation transaction submitted successfully");
        } catch Error(string memory reason) {
            console.log("Error:", reason);
        } catch (bytes memory lowLevelData) {
            console.log("Failed with low level error");
            console.logBytes(lowLevelData);
        }
    }

    function run() external {
        address deployer = vm.envOr(
            "DEPLOYER",
            address(0x89fe160bBBe59eAF428f23F095B71E5C0EdCDfa3)
        );
        vm.startBroadcast(deployer);

        OracleModule oracleModule = OracleModule(ORACLE_MODULE);
        string memory sourceCode = getSourceCode();

        bytes32 calculatedHash = keccak256(abi.encodePacked(sourceCode));
        console.log("Source code length:", bytes(sourceCode).length, "bytes");
        console.log("Calculated source hash:");
        console.logBytes32(calculatedHash);

        console.log("\nCreating contest with following parameters:");
        console.log("RundownId: afe40b8598c5675226a0f6b6acacf820");
        console.log("SportspageId: 329277");
        console.log("JsonoddsId: c76d1939-52b3-4df2-b64c-026ca51e852e");
        console.log("SubscriptionId: 416");
        console.log("GasLimit: 300000");

        _createContest(oracleModule, sourceCode);

        vm.stopBroadcast();
    }
}
