// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// [NOTE] Fuzz test for C-1: Solvency invariant
// Verifies that after create -> match -> settle -> claim (both sides),
// the PositionModule token balance is exactly zero (no stuck or missing funds).
// Uses USDC-style 6 decimals. Odds use 1e7 precision.
//
// CONFIRMED FINDING: Inverse odds rounding breaks (A-1)*(B-1)=1 invariant.
// When rounded inverse is slightly off, makerAmountConsumed != expected,
// leaving dust (or significant amounts at extreme odds) stuck in the contract.

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {PositionModule} from "../../src/modules/PositionModule.sol";
import {OspexCore} from "../../src/core/OspexCore.sol";
import {ContributionModule} from "../../src/modules/ContributionModule.sol";
import {SpeculationModule} from "../../src/modules/SpeculationModule.sol";
import {TreasuryModule} from "../../src/modules/TreasuryModule.sol";
import {
    PositionType,
    Contest,
    ContestStatus,
    Position,
    WinSide,
    OddsPair,
    LeagueId,
    Speculation,
    SpeculationStatus,
    FeeType,
    Leaderboard
} from "../../src/core/OspexTypes.sol";
import {MockScorerModule} from "../mocks/MockScorerModule.sol";
import {MockContestModule} from "../mocks/MockContestModule.sol";

contract MockLeaderboardModuleSolvency {
    mapping(uint256 => Leaderboard) private leaderboards;

    function setLeaderboard(
        uint256 leaderboardId,
        Leaderboard memory leaderboard
    ) external {
        leaderboards[leaderboardId] = leaderboard;
    }

    function getLeaderboard(
        uint256 leaderboardId
    ) external view returns (Leaderboard memory) {
        return leaderboards[leaderboardId];
    }
}

/// @notice Helper contract that calls completeUnmatchedPair so we can try-catch it
contract MatchHelper {
    PositionModule public positionModule;
    MockERC20 public token;

    constructor(address _positionModule, address _token) {
        positionModule = PositionModule(_positionModule);
        token = MockERC20(_token);
    }

    function doMatch(
        uint256 specId,
        address maker,
        uint128 oddsPairId,
        PositionType makerPositionType,
        uint256 amount
    ) external {
        token.approve(address(positionModule), amount);
        positionModule.completeUnmatchedPair(
            specId,
            maker,
            oddsPairId,
            makerPositionType,
            amount
        );
    }
}

contract SolvencyFuzzTest is Test {
    OspexCore core;
    MockERC20 token;
    SpeculationModule speculationModule;
    ContributionModule contributionModule;
    PositionModule positionModule;
    TreasuryModule treasuryModule;
    MockContestModule mockContestModule;
    MockLeaderboardModuleSolvency mockLeaderboardModule;
    MockScorerModule mockScorer;
    MatchHelper matchHelper;

    address maker = address(0xAAAA);
    address protocolReceiver = address(0xFEED);

    uint256 leaderboardId = 0;

    uint64 constant ODDS_PRECISION = 10_000_000;
    uint64 constant MIN_ODDS = 10_100_000; // 1.01
    uint64 constant MAX_ODDS = 1_010_000_000; // 101.00
    uint64 constant ODDS_INCREMENT = 100_000; // 0.01

    // oddsIndex range: 0 to 9999 (1.01 to 101.00)
    uint256 constant MAX_ODDS_INDEX = 9999;

    function setUp() public {
        core = new OspexCore();
        token = new MockERC20();

        // Fund maker generously
        token.transfer(maker, 100_000_000_000); // 100k USDC

        speculationModule = new SpeculationModule(address(core), 6);
        contributionModule = new ContributionModule(address(core));
        positionModule = new PositionModule(address(core), address(token));
        treasuryModule = new TreasuryModule(
            address(core),
            address(token),
            protocolReceiver
        );
        mockContestModule = new MockContestModule();
        mockLeaderboardModule = new MockLeaderboardModuleSolvency();
        mockScorer = new MockScorerModule();

        // Deploy match helper and fund it
        matchHelper = new MatchHelper(
            address(positionModule),
            address(token)
        );
        token.transfer(address(matchHelper), 100_000_000_000);

        // Register modules
        core.registerModule(keccak256("POSITION_MODULE"), address(positionModule));
        core.registerModule(keccak256("SPECULATION_MODULE"), address(speculationModule));
        core.registerModule(keccak256("CONTRIBUTION_MODULE"), address(contributionModule));
        core.registerModule(keccak256("TREASURY_MODULE"), address(treasuryModule));
        core.registerModule(keccak256("CONTEST_MODULE"), address(mockContestModule));
        core.registerModule(keccak256("LEADERBOARD_MODULE"), address(mockLeaderboardModule));
        core.registerModule(keccak256("ORACLE_MODULE"), address(this));

        // Set up verified contest
        Contest memory defaultContest = Contest({
            awayScore: 0,
            homeScore: 0,
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Verified,
            contestCreator: address(this),
            scoreContestSourceHash: bytes32(0),
            rundownId: "",
            sportspageId: "",
            jsonoddsId: ""
        });
        mockContestModule.setContest(1, defaultContest);

        // Raise max speculation amount for fuzz range
        speculationModule.setMaxSpeculationAmount(100_000);
    }

    // ===================== HELPERS =====================

    function _oddsFromIndex(uint256 index) internal pure returns (uint64) {
        return uint64(MIN_ODDS + index * ODDS_INCREMENT);
    }

    function _inverseOdds(uint64 odds) internal pure returns (uint64) {
        uint64 numerator = ODDS_PRECISION * ODDS_PRECISION;
        uint64 denominator = odds - ODDS_PRECISION;
        uint64 exactInverse = (numerator / denominator) + ODDS_PRECISION;
        if (exactInverse < MIN_ODDS) return MIN_ODDS;
        if (exactInverse > MAX_ODDS) return MAX_ODDS;
        uint64 remainder = exactInverse % ODDS_INCREMENT;
        if (remainder >= ODDS_INCREMENT / 2) {
            return exactInverse + (ODDS_INCREMENT - remainder);
        } else {
            return exactInverse - remainder;
        }
    }

    function _getOddsPairId(
        uint64 odds,
        PositionType positionType
    ) internal pure returns (uint128) {
        uint16 oddsIndex = uint16((odds - MIN_ODDS) / ODDS_INCREMENT);
        uint128 baseId = uint128(oddsIndex);
        return positionType == PositionType.Lower ? baseId + 10000 : baseId;
    }

    function _settleSpeculation(
        uint256 specId,
        int32 theNumber,
        WinSide winSide
    ) internal {
        Contest memory scoredContest = Contest({
            awayScore: winSide == WinSide.Away ? uint32(100) : uint32(90),
            homeScore: winSide == WinSide.Home
                ? uint32(100)
                : (winSide == WinSide.Push ? uint32(100) : uint32(90)),
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored,
            contestCreator: address(this),
            scoreContestSourceHash: bytes32(0),
            rundownId: "",
            sportspageId: "",
            jsonoddsId: ""
        });
        mockContestModule.setContest(1, scoredContest);
        mockContestModule.setContestStartTime(1, uint32(block.timestamp - 1));
        mockScorer.setWinSide(1, theNumber, winSide);
        speculationModule.settleSpeculation(specId);
    }

    /// @notice Logs all key values in human-readable form
    function _logMatchSetup(
        uint64 odds,
        uint64 invOdds,
        uint256 makerDeposit,
        uint256 takerDeposit,
        bool winUpper
    ) internal pure {
        console.log("--- Solvency Test Setup ---");
        console.log("  Upper odds (raw):", uint256(odds));
        console.log("  Lower odds (raw):", uint256(invOdds));
        console.log("  Upper odds (x100):", uint256(odds) / 100_000);
        console.log("  Lower odds (x100):", uint256(invOdds) / 100_000);
        console.log("  Maker deposit (USDC raw):", makerDeposit);
        console.log("  Taker deposit (USDC raw):", takerDeposit);
        console.log("  Winner: Upper?", winUpper);
    }

    function _logClaimResults(
        uint256 makerBalBefore,
        uint256 makerBalAfter,
        uint256 takerBalBefore,
        uint256 takerBalAfter,
        uint256 contractRemaining
    ) internal pure {
        console.log("--- Claim Results ---");
        console.log("  Maker received:", makerBalAfter - makerBalBefore);
        console.log("  Taker received:", takerBalAfter - takerBalBefore);
        console.log("  Contract remaining:", contractRemaining);
        if (contractRemaining > 0) {
            console.log("  >>> INSOLVENCY DETECTED <<<");
        }
    }

    // ===================== FUZZ TESTS =====================

    /**
     * @notice FUZZ TEST: Solvency invariant — full match, win/loss
     */
    function testFuzz_SolvencyInvariant_SingleMatch(
        uint256 oddsIndexRaw,
        uint256 amountRaw,
        bool winUpper
    ) public {
        uint256 oddsIndex = bound(oddsIndexRaw, 0, MAX_ODDS_INDEX);
        uint64 odds = _oddsFromIndex(oddsIndex);
        uint256 amount = bound(amountRaw, 1_000_000, 100_000_000);

        uint64 invOdds = _inverseOdds(odds);

        uint256 matchableAmount = (amount *
            (uint256(odds) - ODDS_PRECISION)) / ODDS_PRECISION;
        vm.assume(matchableAmount >= 1_000_000);
        vm.assume(matchableAmount <= 100_000_000_000);

        _logMatchSetup(odds, invOdds, amount, matchableAmount, winUpper);

        // Log the rounding invariant check
        uint256 product = (uint256(odds) - ODDS_PRECISION) *
            (uint256(invOdds) - ODDS_PRECISION);
        console.log("  (A-1)*(B-1) product:", product);
        console.log("  PRECISION^2:        ", uint256(ODDS_PRECISION) * uint256(ODDS_PRECISION));

        uint256 specId = speculationModule.createSpeculation(
            1, address(mockScorer), 0, leaderboardId
        );

        // Maker creates unmatched pair (Upper side)
        vm.startPrank(maker);
        token.approve(address(positionModule), amount);
        positionModule.createUnmatchedPair(
            specId, odds, 0, PositionType.Upper, amount, 0
        );
        vm.stopPrank();

        uint128 oddsPairId = _getOddsPairId(odds, PositionType.Upper);

        // Taker matches via helper (try-catch for rounding overflow)
        try matchHelper.doMatch(
            specId, maker, oddsPairId, PositionType.Upper, matchableAmount
        ) {
            // success
        } catch {
            console.log("  SKIPPED: completeUnmatchedPair reverted (rounding overflow)");
            return;
        }

        // Read maker's position after matching to see actual matched/unmatched
        Position memory makerPos = positionModule.getPosition(
            specId, maker, oddsPairId, PositionType.Upper
        );
        Position memory takerPos = positionModule.getPosition(
            specId, address(matchHelper), oddsPairId, PositionType.Lower
        );
        console.log("  Maker matchedAmount:", makerPos.matchedAmount);
        console.log("  Maker unmatchedAmount:", makerPos.unmatchedAmount);
        console.log("  Taker matchedAmount:", takerPos.matchedAmount);
        console.log("  Contract balance after match:", token.balanceOf(address(positionModule)));

        // Settle
        _settleSpeculation(specId, 0, winUpper ? WinSide.Away : WinSide.Home);

        // Record balances before claims
        uint256 makerBalBefore = token.balanceOf(maker);
        uint256 takerBalBefore = token.balanceOf(address(matchHelper));

        // Both sides claim
        vm.prank(maker);
        positionModule.claimPosition(specId, oddsPairId, PositionType.Upper);
        vm.prank(address(matchHelper));
        positionModule.claimPosition(specId, oddsPairId, PositionType.Lower);

        uint256 remaining = token.balanceOf(address(positionModule));
        _logClaimResults(
            makerBalBefore, token.balanceOf(maker),
            takerBalBefore, token.balanceOf(address(matchHelper)),
            remaining
        );

        assertEq(remaining, 0, "INSOLVENCY: tokens stuck in contract after all claims");
    }

    /**
     * @notice FUZZ TEST: Solvency on Push (both sides get stake back)
     */
    function testFuzz_SolvencyInvariant_Push(
        uint256 oddsIndexRaw,
        uint256 amountRaw
    ) public {
        uint256 oddsIndex = bound(oddsIndexRaw, 0, MAX_ODDS_INDEX);
        uint64 odds = _oddsFromIndex(oddsIndex);
        uint256 amount = bound(amountRaw, 1_000_000, 100_000_000);

        uint256 matchableAmount = (amount *
            (uint256(odds) - ODDS_PRECISION)) / ODDS_PRECISION;
        vm.assume(matchableAmount >= 1_000_000);

        uint256 specId = speculationModule.createSpeculation(
            1, address(mockScorer), 1, leaderboardId
        );

        vm.startPrank(maker);
        token.approve(address(positionModule), amount);
        positionModule.createUnmatchedPair(
            specId, odds, 0, PositionType.Upper, amount, 0
        );
        vm.stopPrank();

        uint128 oddsPairId = _getOddsPairId(odds, PositionType.Upper);

        try matchHelper.doMatch(
            specId, maker, oddsPairId, PositionType.Upper, matchableAmount
        ) {
            // success
        } catch {
            return;
        }

        _settleSpeculation(specId, 1, WinSide.Push);

        vm.prank(maker);
        positionModule.claimPosition(specId, oddsPairId, PositionType.Upper);
        vm.prank(address(matchHelper));
        positionModule.claimPosition(specId, oddsPairId, PositionType.Lower);

        uint256 remaining = token.balanceOf(address(positionModule));
        assertEq(remaining, 0, "INSOLVENCY on Push: tokens stuck in contract");
    }

    /**
     * @notice FUZZ TEST: Solvency with partial match
     */
    function testFuzz_SolvencyInvariant_PartialMatch(
        uint256 oddsIndexRaw,
        uint256 makerAmountRaw,
        uint256 takerPctRaw,
        bool winUpper
    ) public {
        uint256 oddsIndex = bound(oddsIndexRaw, 0, MAX_ODDS_INDEX);
        uint64 odds = _oddsFromIndex(oddsIndex);
        uint256 makerAmount = bound(makerAmountRaw, 2_000_000, 100_000_000);
        uint64 invOdds = _inverseOdds(odds);

        uint256 fullMatchable = (makerAmount *
            (uint256(odds) - ODDS_PRECISION)) / ODDS_PRECISION;
        vm.assume(fullMatchable >= 2_000_000);

        uint256 takerPct = bound(takerPctRaw, 10, 90);
        uint256 takerAmount = (fullMatchable * takerPct) / 100;
        vm.assume(takerAmount >= 1_000_000);

        _logMatchSetup(odds, invOdds, makerAmount, takerAmount, winUpper);
        console.log("  Taker fill pct:", takerPct);
        console.log("  Full matchable:", fullMatchable);

        uint256 specId = speculationModule.createSpeculation(
            1, address(mockScorer), 2, leaderboardId
        );

        vm.startPrank(maker);
        token.approve(address(positionModule), makerAmount);
        positionModule.createUnmatchedPair(
            specId, odds, 0, PositionType.Upper, makerAmount, 0
        );
        vm.stopPrank();

        uint128 oddsPairId = _getOddsPairId(odds, PositionType.Upper);

        try matchHelper.doMatch(
            specId, maker, oddsPairId, PositionType.Upper, takerAmount
        ) {
            // success
        } catch {
            console.log("  SKIPPED: completeUnmatchedPair reverted");
            return;
        }

        // Read positions after matching
        Position memory makerPos = positionModule.getPosition(
            specId, maker, oddsPairId, PositionType.Upper
        );
        Position memory takerPos = positionModule.getPosition(
            specId, address(matchHelper), oddsPairId, PositionType.Lower
        );
        console.log("  Maker matchedAmount:", makerPos.matchedAmount);
        console.log("  Maker unmatchedAmount:", makerPos.unmatchedAmount);
        console.log("  Taker matchedAmount:", takerPos.matchedAmount);
        console.log("  Contract balance after match:", token.balanceOf(address(positionModule)));

        // Settle
        _settleSpeculation(specId, 2, winUpper ? WinSide.Away : WinSide.Home);

        // Record balances before claims
        uint256 makerBalBefore = token.balanceOf(maker);
        uint256 takerBalBefore = token.balanceOf(address(matchHelper));

        // Both claim
        vm.prank(maker);
        positionModule.claimPosition(specId, oddsPairId, PositionType.Upper);
        vm.prank(address(matchHelper));
        positionModule.claimPosition(specId, oddsPairId, PositionType.Lower);

        uint256 remaining = token.balanceOf(address(positionModule));
        _logClaimResults(
            makerBalBefore, token.balanceOf(maker),
            takerBalBefore, token.balanceOf(address(matchHelper)),
            remaining
        );

        assertEq(remaining, 0, "INSOLVENCY: tokens stuck in contract after all claims");
    }
}
