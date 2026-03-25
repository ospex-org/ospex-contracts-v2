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

/// @notice Bundles fuzz params to reduce stack depth
struct FuzzParams {
    uint64 odds;
    uint64 invOdds;
    uint256 makerDeposit;
    uint256 takerDeposit;
    uint128 oddsPairId;
    uint256 specId;
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

    address maker = address(0xAAAA);
    address taker = address(0xBBBB);
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

        // Fund maker and taker generously
        token.transfer(maker, 100_000_000_000); // 100k USDC
        token.transfer(taker, 100_000_000_000); // 100k USDC

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

        // Register modules
        core.registerModule(keccak256("POSITION_MODULE"), address(positionModule));
        core.registerModule(keccak256("SPECULATION_MODULE"), address(speculationModule));
        core.registerModule(keccak256("CONTRIBUTION_MODULE"), address(contributionModule));
        core.registerModule(keccak256("TREASURY_MODULE"), address(treasuryModule));
        core.registerModule(keccak256("CONTEST_MODULE"), address(mockContestModule));
        core.registerModule(keccak256("LEADERBOARD_MODULE"), address(mockLeaderboardModule));
        core.registerModule(keccak256("ORACLE_MODULE"), address(this));

        // Grant MARKET_ROLE to test contract so it can call createMatchedPair
        core.setMarketRole(address(this), true);

        // Set up verified contest
        mockContestModule.setContest(1, _verifiedContest());

        // Raise max speculation amount for fuzz range
        speculationModule.setMaxSpeculationAmount(100_000);
    }

    // ===================== EXTERNAL WRAPPER (for try-catch) =====================

    /// @notice External wrapper so try-catch can be used on createMatchedPair
    function callCreateMatchedPair(
        uint256 specId,
        uint64 odds,
        PositionType makerPositionType,
        address _maker,
        uint256 makerAmountRemaining,
        address _taker,
        uint256 takerAmount
    ) external {
        positionModule.createMatchedPair(
            specId, odds, makerPositionType, _maker, makerAmountRemaining, _taker, takerAmount, 0, 0
        );
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

    function _verifiedContest() internal view returns (Contest memory) {
        return Contest({
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

    /// @notice Approves tokens and attempts to create matched pair, returns false if reverted
    function _approveAndMatch(FuzzParams memory p) internal returns (bool) {
        vm.prank(maker);
        token.approve(address(positionModule), p.makerDeposit);
        vm.prank(taker);
        token.approve(address(positionModule), p.takerDeposit);

        try this.callCreateMatchedPair(
            p.specId, p.odds, PositionType.Upper, maker, p.makerDeposit, taker, p.takerDeposit
        ) {
            return true;
        } catch {
            return false;
        }
    }

    /// @notice Claims winning side (or both on push) and asserts zero remaining balance
    function _claimWinnerAndAssert(FuzzParams memory p, WinSide winSide) internal {
        if (winSide == WinSide.Push || winSide == WinSide.Void || winSide == WinSide.Forfeit) {
            // Both sides get their stake back
            vm.prank(maker);
            positionModule.claimPosition(p.specId, p.oddsPairId, PositionType.Upper);
            vm.prank(taker);
            positionModule.claimPosition(p.specId, p.oddsPairId, PositionType.Lower);
        } else if (winSide == WinSide.Away || winSide == WinSide.Over) {
            // Upper wins — maker claims all
            vm.prank(maker);
            positionModule.claimPosition(p.specId, p.oddsPairId, PositionType.Upper);
        } else {
            // Lower wins — taker claims all
            vm.prank(taker);
            positionModule.claimPosition(p.specId, p.oddsPairId, PositionType.Lower);
        }

        uint256 remaining = token.balanceOf(address(positionModule));
        assertEq(remaining, 0, "INSOLVENCY: tokens stuck in contract after all claims");
    }

    /// @notice Logs match setup
    function _logMatchSetup(FuzzParams memory p, bool winUpper) internal pure {
        console.log("--- Solvency Test Setup ---");
        console.log("  Upper odds (raw):", uint256(p.odds));
        console.log("  Lower odds (raw):", uint256(p.invOdds));
        console.log("  Upper odds (x100):", uint256(p.odds) / 100_000);
        console.log("  Lower odds (x100):", uint256(p.invOdds) / 100_000);
        console.log("  Maker deposit (USDC raw):", p.makerDeposit);
        console.log("  Taker deposit (USDC raw):", p.takerDeposit);
        console.log("  Winner: Upper?", winUpper);
    }

    /// @notice Logs positions after matching
    function _logPositions(FuzzParams memory p) internal view {
        Position memory makerPos = positionModule.getPosition(
            p.specId, maker, p.oddsPairId, PositionType.Upper
        );
        Position memory takerPos = positionModule.getPosition(
            p.specId, taker, p.oddsPairId, PositionType.Lower
        );
        console.log("  Maker matchedAmount:", makerPos.matchedAmount);
        console.log("  Taker matchedAmount:", takerPos.matchedAmount);
        console.log("  Contract balance after match:", token.balanceOf(address(positionModule)));
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

        uint256 matchableAmount = (amount *
            (uint256(odds) - ODDS_PRECISION)) / ODDS_PRECISION;
        vm.assume(matchableAmount >= 1_000_000);
        vm.assume(matchableAmount <= 100_000_000_000);

        FuzzParams memory p = FuzzParams({
            odds: odds,
            invOdds: _inverseOdds(odds),
            makerDeposit: amount,
            takerDeposit: matchableAmount,
            oddsPairId: _getOddsPairId(odds, PositionType.Upper),
            specId: speculationModule.createSpeculation(1, address(mockScorer), 0, leaderboardId)
        });

        _logMatchSetup(p, winUpper);

        // Log the rounding invariant check
        uint256 product = (uint256(odds) - ODDS_PRECISION) *
            (uint256(p.invOdds) - ODDS_PRECISION);
        console.log("  (A-1)*(B-1) product:", product);
        console.log("  PRECISION^2:        ", uint256(ODDS_PRECISION) * uint256(ODDS_PRECISION));

        if (!_approveAndMatch(p)) {
            console.log("  SKIPPED: createMatchedPair reverted (rounding overflow)");
            return;
        }

        _logPositions(p);

        // Settle
        WinSide winSide = winUpper ? WinSide.Away : WinSide.Home;
        _settleSpeculation(p.specId, 0, winSide);

        // Claim winner and assert solvency
        _claimWinnerAndAssert(p, winSide);
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

        FuzzParams memory p = FuzzParams({
            odds: odds,
            invOdds: _inverseOdds(odds),
            makerDeposit: amount,
            takerDeposit: matchableAmount,
            oddsPairId: _getOddsPairId(odds, PositionType.Upper),
            specId: speculationModule.createSpeculation(1, address(mockScorer), 1, leaderboardId)
        });

        if (!_approveAndMatch(p)) {
            return;
        }

        _settleSpeculation(p.specId, 1, WinSide.Push);
        _claimWinnerAndAssert(p, WinSide.Push);
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

        uint256 fullMatchable = (makerAmount *
            (uint256(odds) - ODDS_PRECISION)) / ODDS_PRECISION;
        vm.assume(fullMatchable >= 2_000_000);

        uint256 takerPct = bound(takerPctRaw, 10, 90);
        uint256 takerAmount = (fullMatchable * takerPct) / 100;
        vm.assume(takerAmount >= 1_000_000);

        FuzzParams memory p = FuzzParams({
            odds: odds,
            invOdds: _inverseOdds(odds),
            makerDeposit: makerAmount,
            takerDeposit: takerAmount,
            oddsPairId: _getOddsPairId(odds, PositionType.Upper),
            specId: speculationModule.createSpeculation(1, address(mockScorer), 2, leaderboardId)
        });

        _logMatchSetup(p, winUpper);
        console.log("  Taker fill pct:", takerPct);
        console.log("  Full matchable:", fullMatchable);

        if (!_approveAndMatch(p)) {
            console.log("  SKIPPED: createMatchedPair reverted");
            return;
        }

        _logPositions(p);

        // Settle
        WinSide winSide = winUpper ? WinSide.Away : WinSide.Home;
        _settleSpeculation(p.specId, 2, winSide);

        // Claim winner and assert solvency
        _claimWinnerAndAssert(p, winSide);
    }
}
