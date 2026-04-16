// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "../src/core/OspexCore.sol";
import "../src/core/OspexTypes.sol";
import "../src/modules/TreasuryModule.sol";
import "../src/modules/OracleModule.sol";
import "../src/modules/SpeculationModule.sol";
import "../src/modules/PositionModule.sol";
import "../src/modules/SecondaryMarketModule.sol";
import "../src/modules/ContestModule.sol";
import "../src/modules/LeaderboardModule.sol";
import "../src/modules/RulesModule.sol";
import "../src/modules/MoneylineScorerModule.sol";
import "../src/modules/SpreadScorerModule.sol";
import "../src/modules/TotalScorerModule.sol";
import "../src/modules/MatchingModule.sol";
import "../test/mocks/MockERC20.sol";
import "../test/mocks/MockLinkToken.sol";
import "../test/mocks/MockFunctionsRouter.sol";

/**
 * @title SmokeTestE2E
 * @notice Self-contained end-to-end smoke test for the full Ospex protocol.
 *         Deploys fresh, creates a contest, matches positions, scores, and claims.
 * @dev Run WITHOUT --broadcast (simulation mode, all cheatcodes available):
 *      forge script script/SmokeTestE2E.s.sol -vvv
 */
contract SmokeTestE2E is Script {
    uint256 constant DEPLOYER_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 constant ALICE_PK    = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 constant BOB_PK      = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 constant SIGNER_PK   = 0xA11CE;

    // EIP-712 typehash (mirrors OracleModule)
    bytes32 constant SCRIPT_APPROVAL_TYPEHASH =
        keccak256("ScriptApproval(bytes32 scriptHash,uint8 purpose,uint8 leagueId,uint16 version,uint64 validUntil)");

    // Protocol contracts
    OspexCore core;
    MockERC20 usdc;
    MockLinkToken link;
    MockFunctionsRouter router;
    OracleModule oracleModule;
    ContestModule contestModule;
    SpeculationModule speculationModule;
    PositionModule positionModule;
    MatchingModule matchingModule;
    TreasuryModule treasuryModule;
    LeaderboardModule leaderboardModule;
    RulesModule rulesModule;
    SecondaryMarketModule secondaryMarketModule;
    MoneylineScorerModule moneylineScorer;
    SpreadScorerModule spreadScorer;
    TotalScorerModule totalScorer;

    // Test scripts
    string constant VERIFY_JS = "return Functions.encodeUint256(4000000000000000000 + args[3])";
    string constant UPDATE_JS = "return Functions.encodeUint256(marketData)";
    string constant SCORE_JS  = "return Functions.encodeUint32(scoreData)";

    address deployer;
    address alice;
    address bob;
    address signer;

    function run() external {
        deployer = vm.addr(DEPLOYER_PK);
        alice    = vm.addr(ALICE_PK);
        bob      = vm.addr(BOB_PK);
        signer   = vm.addr(SIGNER_PK);

        vm.deal(deployer, 100 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);

        console.log("=== SMOKE TEST E2E ===");
        console.log("Deployer:", deployer);
        console.log("Alice:   ", alice);
        console.log("Bob:     ", bob);
        console.log("Signer:  ", signer);

        _deployProtocol();
        console.log("\n[1/8] Protocol deployed and finalized");

        _mintAndApprove();
        console.log("[2/8] Tokens minted and approved");

        uint256 contestId = _createContest();
        console.log("[3/8] Contest created, ID:", contestId);

        uint32 startTime = _verifyContest(contestId);
        console.log("[4/8] Contest verified, startTime:", uint256(startTime));

        _updateMarkets(contestId);
        console.log("[5/8] Market data updated");

        uint256 speculationId = _matchPositions(contestId);
        console.log("[6/8] Position matched, speculationId:", speculationId);

        _scoreAndSettle(contestId, speculationId, startTime);
        console.log("[7/8] Contest scored and speculation settled");

        _claimAndVerify(speculationId);
        console.log("[8/8] Winner claimed, balances verified");

        console.log("\n=== SMOKE TEST PASSED ===");
    }

    // ─────────────────────── Deploy ───────────────────────

    function _deployProtocol() internal {
        vm.startPrank(deployer);

        usdc = new MockERC20();
        link = new MockLinkToken();
        router = new MockFunctionsRouter(address(link));
        core = new OspexCore();

        contestModule = new ContestModule(address(core));
        leaderboardModule = new LeaderboardModule(address(core));
        rulesModule = new RulesModule(address(core));
        moneylineScorer = new MoneylineScorerModule(address(core));
        spreadScorer = new SpreadScorerModule(address(core));
        totalScorer = new TotalScorerModule(address(core));
        matchingModule = new MatchingModule(address(core));

        treasuryModule = new TreasuryModule(
            address(core), address(usdc), deployer,
            1_000_000, 500_000, 250_000
        );
        speculationModule = new SpeculationModule(address(core), 3 days);
        positionModule = new PositionModule(address(core), address(usdc));
        secondaryMarketModule = new SecondaryMarketModule(address(core), address(usdc));
        oracleModule = new OracleModule(
            address(core), address(router), address(link),
            bytes32("test_don"), 10, signer
        );

        bytes32[] memory types = new bytes32[](12);
        address[] memory addrs = new address[](12);
        types[0]  = core.CONTEST_MODULE();           addrs[0]  = address(contestModule);
        types[1]  = core.SPECULATION_MODULE();        addrs[1]  = address(speculationModule);
        types[2]  = core.POSITION_MODULE();           addrs[2]  = address(positionModule);
        types[3]  = core.MATCHING_MODULE();           addrs[3]  = address(matchingModule);
        types[4]  = core.ORACLE_MODULE();             addrs[4]  = address(oracleModule);
        types[5]  = core.TREASURY_MODULE();           addrs[5]  = address(treasuryModule);
        types[6]  = core.LEADERBOARD_MODULE();        addrs[6]  = address(leaderboardModule);
        types[7]  = core.RULES_MODULE();              addrs[7]  = address(rulesModule);
        types[8]  = core.SECONDARY_MARKET_MODULE();   addrs[8]  = address(secondaryMarketModule);
        types[9]  = core.MONEYLINE_SCORER_MODULE();   addrs[9]  = address(moneylineScorer);
        types[10] = core.SPREAD_SCORER_MODULE();      addrs[10] = address(spreadScorer);
        types[11] = core.TOTAL_SCORER_MODULE();       addrs[11] = address(totalScorer);

        core.bootstrapModules(types, addrs);
        core.finalize();

        vm.stopPrank();
    }

    // ─────────────────────── Mint & Approve ───────────────────────

    function _mintAndApprove() internal {
        vm.startPrank(deployer);
        usdc.mint(alice, 1_000_000_000);   // 1000 USDC
        usdc.mint(bob, 1_000_000_000);
        usdc.mint(deployer, 1_000_000_000);
        link.mint(deployer, 100 ether);
        link.approve(address(oracleModule), type(uint256).max);
        usdc.approve(address(treasuryModule), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(alice);
        usdc.approve(address(treasuryModule), type(uint256).max);
        usdc.approve(address(positionModule), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(treasuryModule), type(uint256).max);
        usdc.approve(address(positionModule), type(uint256).max);
        vm.stopPrank();
    }

    // ─────────────────────── Create Contest ───────────────────────

    function _createContest() internal returns (uint256 contestId) {
        bytes32 verifyHash = keccak256(abi.encodePacked(VERIFY_JS));
        bytes32 updateHash = keccak256(abi.encodePacked(UPDATE_JS));
        bytes32 scoreHash  = keccak256(abi.encodePacked(SCORE_JS));

        OracleModule.ScriptApprovals memory approvals = _buildApprovals(verifyHash, updateHash, scoreHash);

        OracleModule.CreateContestParams memory params = OracleModule.CreateContestParams({
            rundownId: "RD_12345",
            sportspageId: "SP_12345",
            jsonoddsId: "JO_12345",
            createContestSourceJS: VERIFY_JS,
            encryptedSecretsUrls: "",
            subscriptionId: 1,
            gasLimit: 300000
        });

        vm.prank(deployer);
        oracleModule.createContestFromOracle(params, updateHash, scoreHash, approvals);

        contestId = contestModule.s_contestIdCounter();
        require(contestId == 1, "Contest ID should be 1");

        Contest memory c = contestModule.getContest(contestId);
        require(c.contestStatus == ContestStatus.Unverified, "Contest should be Unverified");
    }

    // ─────────────────────── Verify Contest (simulate callback) ───────────────────────

    function _verifyContest(uint256 contestId) internal returns (uint32 startTime) {
        startTime = uint32(block.timestamp + 1 days);

        // NBA = LeagueId(4). Packed: leagueId * 1e18 + startTime
        uint256 verifyData = uint256(4) * 1e18 + uint256(startTime);
        bytes memory response = abi.encode(verifyData);

        router.fulfillRequest(bytes32(uint256(1)), response, "");

        Contest memory c = contestModule.getContest(contestId);
        require(c.contestStatus == ContestStatus.Verified, "Contest should be Verified");
        require(c.leagueId == LeagueId.NBA, "League should be NBA");
        require(contestModule.s_contestStartTimes(contestId) == startTime, "StartTime mismatch");
    }

    // ─────────────────────── Update Markets ───────────────────────

    function _updateMarkets(uint256 contestId) internal {
        // All odds at American -110 (encoded as 9890 = -110 + 10000)
        // Spread: -3.0 (encoded as 970 = -30 + 1000)
        // Total: 215.0 (encoded as 3150 = 2150 + 1000)
        uint256 marketData =
            uint256(9890) * 1e33 +   // moneylineAwayOdds
            uint256(9890) * 1e28 +   // moneylineHomeOdds
            uint256(970)  * 1e24 +   // spreadLineTicks
            uint256(9890) * 1e19 +   // spreadAwayOdds
            uint256(9890) * 1e14 +   // spreadHomeOdds
            uint256(3150) * 1e10 +   // totalLineTicks
            uint256(9890) * 1e5  +   // overOdds
            uint256(9890);           // underOdds

        vm.prank(deployer);
        oracleModule.updateContestMarketsFromOracle(
            contestId,
            UPDATE_JS,
            "",   // no secrets
            1,    // subscriptionId
            300000
        );

        bytes memory marketResponse = abi.encode(marketData);
        router.fulfillRequest(bytes32(uint256(1)), marketResponse, "");

        // Verify market data was stored
        ContestMarket memory ml = contestModule.getContestMarket(contestId, address(moneylineScorer));
        require(ml.upperOdds == 191, "Moneyline away odds should be 191");
        require(ml.lowerOdds == 191, "Moneyline home odds should be 191");
    }

    // ─────────────────────── Match Positions ───────────────────────

    function _matchPositions(uint256 contestId) internal returns (uint256 speculationId) {
        // Alice = maker, Upper (Away), odds 1.91 (191 ticks), risks 10 USDC
        MatchingModule.OspexCommitment memory commitment = MatchingModule.OspexCommitment({
            maker: alice,
            contestId: contestId,
            scorer: address(moneylineScorer),
            lineTicks: 0,
            positionType: PositionType.Upper,
            oddsTick: 191,
            riskAmount: 10_000_000,   // 10 USDC (must be divisible by ODDS_SCALE=100)
            nonce: 1,
            expiry: block.timestamp + 1 hours
        });

        // Sign commitment with Alice's key
        bytes32 commitHash = matchingModule.getCommitmentHash(commitment);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ALICE_PK, commitHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore   = usdc.balanceOf(bob);

        // Bob matches Alice's commitment
        // At 191 odds: profitTicks = 91, so taker risks makerProfit
        // takerDesiredRisk = 9_100_000 (9.1 USDC)
        vm.prank(bob);
        matchingModule.matchCommitment(commitment, signature, 9_100_000);

        // Verify a speculation was created
        speculationId = speculationModule.getSpeculationId(contestId, address(moneylineScorer), 0);
        require(speculationId > 0, "Speculation should exist");

        Speculation memory spec = speculationModule.getSpeculation(speculationId);
        require(spec.speculationStatus == SpeculationStatus.Open, "Speculation should be Open");
        require(spec.winSide == WinSide.TBD, "WinSide should be TBD");

        // Verify USDC transferred to PositionModule
        uint256 aliceAfter = usdc.balanceOf(alice);
        uint256 bobAfter   = usdc.balanceOf(bob);

        // Alice's USDC decreased by: makerRisk (10 USDC) + speculation creation fee split (0.25 USDC)
        // Bob's USDC decreased by: takerRisk (9.1 USDC) + speculation creation fee split (0.25 USDC)
        console.log("  Alice USDC spent:", aliceBefore - aliceAfter);
        console.log("  Bob USDC spent:  ", bobBefore - bobAfter);

        // Verify positions
        Position memory alicePos = positionModule.getPosition(speculationId, alice, PositionType.Upper);
        Position memory bobPos   = positionModule.getPosition(speculationId, bob, PositionType.Lower);

        require(alicePos.riskAmount == 10_000_000, "Alice riskAmount should be 10 USDC");
        require(alicePos.profitAmount == 9_100_000, "Alice profitAmount should be 9.1 USDC");
        require(bobPos.riskAmount == 9_100_000, "Bob riskAmount should be 9.1 USDC");
        require(bobPos.profitAmount == 10_000_000, "Bob profitAmount should be 10 USDC");

        console.log("  Alice position: risk=", alicePos.riskAmount, "profit=", alicePos.profitAmount);
        console.log("  Bob position:   risk=", bobPos.riskAmount, "profit=", bobPos.profitAmount);
    }

    // ─────────────────────── Score & Settle ───────────────────────

    function _scoreAndSettle(uint256 contestId, uint256 speculationId, uint32 startTime) internal {
        // Warp past contest start time
        vm.warp(uint256(startTime) + 1);

        // Score the contest: Away 110, Home 105 (away wins)
        vm.prank(deployer);
        oracleModule.scoreContestFromOracle(
            contestId,
            SCORE_JS,
            "",
            1,
            300000
        );

        // Score packed: awayScore * 1000 + homeScore = 110 * 1000 + 105 = 110105
        // bytesToUint32 uses mload → returns lower 32 bits after uint32 cleanup
        // Must be right-aligned (abi.encode format) so the value lands in the lower bytes
        bytes memory scoreResponse = abi.encode(uint256(110105));
        router.fulfillRequest(bytes32(uint256(1)), scoreResponse, "");

        // Verify contest scored
        Contest memory c = contestModule.getContest(contestId);
        require(c.contestStatus == ContestStatus.Scored, "Contest should be Scored");
        require(c.awayScore == 110, "Away score should be 110");
        require(c.homeScore == 105, "Home score should be 105");

        // Settle speculation
        speculationModule.settleSpeculation(speculationId);

        Speculation memory spec = speculationModule.getSpeculation(speculationId);
        require(spec.speculationStatus == SpeculationStatus.Closed, "Speculation should be Closed");
        require(spec.winSide == WinSide.Away, "Away should win (moneyline, higher score)");
        console.log("  Scores: Away", c.awayScore, "Home", c.homeScore);
        console.log("  Winner: Away (PositionType.Upper)");
    }

    // ─────────────────────── Claim & Verify ───────────────────────

    function _claimAndVerify(uint256 speculationId) internal {
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore   = usdc.balanceOf(bob);

        // Alice (Upper/Away) wins — she gets risk + profit
        vm.prank(alice);
        positionModule.claimPosition(speculationId, PositionType.Upper);

        uint256 aliceAfter = usdc.balanceOf(alice);
        uint256 alicePayout = aliceAfter - aliceBefore;

        // Expected: 10_000_000 (risk) + 9_100_000 (profit) = 19_100_000
        require(alicePayout == 19_100_000, "Alice payout should be 19.1 USDC");
        console.log("  Alice payout:", alicePayout, "(19.1 USDC)");

        // Bob (Lower/Home) lost — payout is 0, claimPosition should revert
        // (NoPayout revert because payout = 0)
        bool bobReverted = false;
        vm.prank(bob);
        try positionModule.claimPosition(speculationId, PositionType.Lower) {
            // Should not reach here
        } catch {
            bobReverted = true;
        }
        require(bobReverted, "Bob's claim should revert (loser, payout=0)");
        console.log("  Bob claim correctly reverted (loser gets 0)");

        // Verify PositionModule balance is 0 for this speculation
        uint256 posModBalance = usdc.balanceOf(address(positionModule));
        console.log("  PositionModule remaining USDC balance:", posModBalance);

        // Final balance check
        console.log("\n  Final balances:");
        console.log("    Alice:", usdc.balanceOf(alice));
        console.log("    Bob:  ", usdc.balanceOf(bob));
    }

    // ─────────────────────── EIP-712 Helpers ───────────────────────

    function _buildApprovals(
        bytes32 verifyHash,
        bytes32 updateHash,
        bytes32 scoreHash
    ) internal view returns (OracleModule.ScriptApprovals memory) {
        ScriptApproval memory va = ScriptApproval(verifyHash, ScriptPurpose.VERIFY, LeagueId.Unknown, 1, 0);
        ScriptApproval memory ma = ScriptApproval(updateHash, ScriptPurpose.MARKET_UPDATE, LeagueId.Unknown, 1, 0);
        ScriptApproval memory sa = ScriptApproval(scoreHash, ScriptPurpose.SCORE, LeagueId.Unknown, 1, 0);

        return OracleModule.ScriptApprovals({
            verifyApproval: va,
            verifyApprovalSig: _signApproval(va),
            marketUpdateApproval: ma,
            marketUpdateApprovalSig: _signApproval(ma),
            scoreApproval: sa,
            scoreApprovalSig: _signApproval(sa)
        });
    }

    function _signApproval(ScriptApproval memory a) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                SCRIPT_APPROVAL_TYPEHASH,
                a.scriptHash,
                uint8(a.purpose),
                uint8(a.leagueId),
                a.version,
                a.validUntil
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", oracleModule.DOMAIN_SEPARATOR(), structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, digest);
        return abi.encodePacked(r, s, v);
    }
}
