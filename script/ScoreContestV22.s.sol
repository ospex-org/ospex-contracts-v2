// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {OracleModule} from "../src/modules/OracleModule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ScoreContestV22
 * @notice Score a contest via Chainlink Functions oracle
 * @dev Run with:
 *   forge script script/ScoreContestV22.s.sol:ScoreContestV22 \
 *     --rpc-url <RPC_URL> --account my-deployer --broadcast --via-ir --optimize -vvvvv
 *
 *   Override contest ID: CONTEST_ID=9 forge script ...
 */
contract ScoreContestV22 is Script {
    // Amoy v2.4 deployment (2026-04-10)
    address constant ORACLE_MODULE = 0x18F8BFfB2250635A419982eAe69099d97f596F8F;
    address constant LINK_TOKEN = 0x0Fd9e8d3aF1aaee056EB9e802c3A762a667b1904;
    bytes constant ENCRYPTED_SECRETS_URLS =
        hex"d32013655bd4b1e55a6bf1b7e9df07280379d299a2e13b2e6aa7f033eb350502373d4e9b4d0feb9815338c6806e04f17636b64b989ce8065060163d51309b71324fb7c8952361b9eb91bb743b58596c404886518e9c0541b905f235f8db209fadd41615c1f436fbfc4cbfbb84124a4921ac3e83ad351189e145317ce17e49ecaeae9919bd6d44a3436de52df4f441e1ba9f5d74d562a541cadbaef5963a206490e2d2fd62b291d3d79ef98521ee0ed50345f6f7aab1d0d0a78af95a015ec051dd00eda0fd3eff0beb853c2d3a5b94a6589";

    function getScoreSourceCode() internal view returns (string memory) {
        return vm.readFile("chainlink-functions/scoreContest.js");
    }

    function run() external {
        uint256 contestId = vm.envOr("CONTEST_ID", uint256(9));
        address deployer = vm.envOr(
            "DEPLOYER",
            address(0x89fe160bBBe59eAF428f23F095B71E5C0EdCDfa3)
        );

        vm.startBroadcast(deployer);

        OracleModule oracleModule = OracleModule(ORACLE_MODULE);
        string memory sourceCode = getScoreSourceCode();

        console.log("\n--- Scoring Contest ---");
        console.log("Contest ID:", contestId);
        console.log("Source hash:");
        console.logBytes32(keccak256(abi.encodePacked(sourceCode)));

        // Approve LINK to OracleModule (0.004 LINK per call, approve 0.01 for safety)
        uint256 linkAmount = 10_000_000_000_000_000; // 0.01 LINK
        IERC20(LINK_TOKEN).approve(ORACLE_MODULE, linkAmount);
        console.log("LINK approved:", linkAmount);

        // Score the contest
        try oracleModule.scoreContestFromOracle(
            contestId,
            sourceCode,
            ENCRYPTED_SECRETS_URLS,
            416,     // subscriptionId
            300000   // gasLimit
        ) {
            console.log("Score request submitted! Waiting for Chainlink callback...");
            console.log("Check Supabase chain_events for CONTEST_SCORES_SET");
        } catch Error(string memory reason) {
            console.log("Error:", reason);
        } catch (bytes memory lowLevelData) {
            console.log("Failed with low level error");
            console.logBytes(lowLevelData);
        }

        vm.stopBroadcast();
    }
}
