// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {MoneylineScorerModule} from "../../src/modules/MoneylineScorerModule.sol";
import {SpreadScorerModule} from "../../src/modules/SpreadScorerModule.sol";
import {TotalScorerModule} from "../../src/modules/TotalScorerModule.sol";
import {Contest, WinSide, ContestStatus, Speculation, LeagueId} from "../../src/core/OspexTypes.sol";
import {OspexCore} from "../../src/core/OspexCore.sol";
import {IContestModule} from "../../src/interfaces/IContestModule.sol";
import {SpeculationModule} from "../../src/modules/SpeculationModule.sol";
import {TreasuryModule} from "../../src/modules/TreasuryModule.sol";
import {PositionModule} from "../../src/modules/PositionModule.sol";
import {LeaderboardModule} from "../../src/modules/LeaderboardModule.sol";
import {RulesModule} from "../../src/modules/RulesModule.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockContestModule} from "../mocks/MockContestModule.sol";

contract ScorerModuleTest is Test {
    MoneylineScorerModule moneyline;
    SpreadScorerModule spread;
    TotalScorerModule total;
    OspexCore core;
    MockContestModule mockContest;
    SpeculationModule speculationModule;
    TreasuryModule treasuryModule;
    PositionModule positionModule;
    LeaderboardModule leaderboardModule;
    RulesModule rulesModule;
    MockERC20 token;
    uint256 nextContestId;
    // Stores the intended final contest state (with Scored status) for _finalizeContest
    mapping(uint256 => Contest) private _finalContests;

    function setUp() public {
        core = new OspexCore();
        token = new MockERC20();

        // Create modules
        moneyline = new MoneylineScorerModule(address(core));
        spread = new SpreadScorerModule(address(core));
        total = new TotalScorerModule(address(core));
        mockContest = new MockContestModule();
        speculationModule = new SpeculationModule(address(core), 6, 3 days, 1_000_000);
        treasuryModule = new TreasuryModule(
            address(core), address(token), address(0x2),
            1_000_000, 500_000, 500_000
        );

        // Approve TreasuryModule for speculation creation split fees
        token.approve(address(treasuryModule), type(uint256).max);
        positionModule = new PositionModule(address(core), address(token));
        leaderboardModule = new LeaderboardModule(address(core));
        rulesModule = new RulesModule(address(core));

        // Bootstrap all 12 modules
        bytes32[] memory types = new bytes32[](12);
        address[] memory addrs = new address[](12);
        types[0] = core.CONTEST_MODULE();           addrs[0] = address(mockContest);
        types[1] = core.SPECULATION_MODULE();        addrs[1] = address(speculationModule);
        types[2] = core.POSITION_MODULE();           addrs[2] = address(this); // test contract acts as POSITION_MODULE
        types[3] = core.MATCHING_MODULE();           addrs[3] = address(0xD003);
        types[4] = core.ORACLE_MODULE();             addrs[4] = address(0xD004);
        types[5] = core.TREASURY_MODULE();           addrs[5] = address(treasuryModule);
        types[6] = core.LEADERBOARD_MODULE();        addrs[6] = address(leaderboardModule);
        types[7] = core.RULES_MODULE();              addrs[7] = address(rulesModule);
        types[8] = core.SECONDARY_MARKET_MODULE();   addrs[8] = address(0xD008);
        types[9] = core.MONEYLINE_SCORER_MODULE();   addrs[9] = address(moneyline);
        types[10] = core.SPREAD_SCORER_MODULE();     addrs[10] = address(spread);
        types[11] = core.TOTAL_SCORER_MODULE();      addrs[11] = address(total);
        core.bootstrapModules(types, addrs);
        core.finalize();
    }

    // --- MoneylineScorerModule ---
    function testMoneyline_AwayWins() public {
        uint256 contestId = _storeContest(_contest(10, 5, ContestStatus.Scored));
        uint256 speculationId = speculationModule.createSpeculation(
            contestId,
            address(moneyline),
            0,
            address(this),
            address(this)
        );
        _finalizeContest(contestId);
        vm.warp(block.timestamp + 2);
        speculationModule.settleSpeculation(speculationId);
        Speculation memory s = speculationModule.getSpeculation(speculationId);
        assertEq(uint(s.winSide), uint(WinSide.Away));
    }
    function testMoneyline_HomeWins() public {
        uint256 contestId = _storeContest(_contest(3, 7, ContestStatus.Scored));
        uint256 speculationId = speculationModule.createSpeculation(
            contestId,
            address(moneyline),
            0,
            address(this),
            address(this)
        );
        _finalizeContest(contestId);
        vm.warp(block.timestamp + 2);
        speculationModule.settleSpeculation(speculationId);
        Speculation memory s = speculationModule.getSpeculation(speculationId);
        assertEq(uint(s.winSide), uint(WinSide.Home));
    }
    function testMoneyline_Push() public {
        uint256 contestId = _storeContest(_contest(8, 8, ContestStatus.Scored));
        uint256 speculationId = speculationModule.createSpeculation(
            contestId,
            address(moneyline),
            0,
            address(this),
            address(this)
        );
        _finalizeContest(contestId);
        vm.warp(block.timestamp + 2);
        speculationModule.settleSpeculation(speculationId);
        Speculation memory s = speculationModule.getSpeculation(speculationId);
        assertEq(uint(s.winSide), uint(WinSide.Push));
    }

    function testMoneyline_Revert_NotSpeculationModule() public {
        uint256 contestId = _storeContest(_contest(10, 5, ContestStatus.Scored));
        address notSpeculationModule = address(0xCAFE);
        vm.expectRevert(
            abi.encodeWithSelector(
                MoneylineScorerModule.MoneylineScorerModule__NotSpeculationModule.selector,
                notSpeculationModule
            )
        );
        vm.prank(notSpeculationModule);
        moneyline.determineWinSide(contestId, 0);
    }

    function testMoneyline_Revert_ModuleNotSet() public {
        // Create a new core without registering the speculation module
        OspexCore newCore = new OspexCore();
        MoneylineScorerModule newMoneyline = new MoneylineScorerModule(address(newCore));

        // Bootstrap with contest module but NOT speculation module — use a partial
        // bootstrap that omits SPECULATION_MODULE. Since finalize() requires all 12,
        // we skip finalize. The scorer only needs to look up SPECULATION_MODULE.
        // bootstrapModules doesn't require all 12 — finalize does.
        bytes32[] memory types = new bytes32[](1);
        address[] memory addrs = new address[](1);
        types[0] = newCore.CONTEST_MODULE();  addrs[0] = address(mockContest);
        newCore.bootstrapModules(types, addrs);

        uint256 contestId = _storeContest(_contest(10, 5, ContestStatus.Scored));

        vm.expectRevert(
            abi.encodeWithSelector(
                MoneylineScorerModule.MoneylineScorerModule__ModuleNotSet.selector,
                keccak256("SPECULATION_MODULE")
            )
        );
        vm.prank(address(0x1234)); // Any address will trigger the module lookup
        newMoneyline.determineWinSide(contestId, 0);
    }
    // --- SpreadScorerModule ---
    function testSpread_AwayCovers_PositiveSpread() public {
        // Home favored by 3, but home only wins by 2
        uint256 contestId = _storeContest(_contest(10, 12, ContestStatus.Scored));
        int32 spreadNum = 30; // 3.0 in 10x format
        uint256 speculationId = speculationModule.createSpeculation(
            contestId,
            address(spread),
            spreadNum,
            address(this),
            address(this)
        );
        _finalizeContest(contestId);
        vm.warp(block.timestamp + 2);
        speculationModule.settleSpeculation(speculationId);
        Speculation memory s = speculationModule.getSpeculation(speculationId);
        assertEq(uint(s.winSide), uint(WinSide.Away));
    }
    function testSpread_HomeCovers_PositiveSpread() public {
        // Home favored by 3, home wins by 4
        uint256 contestId = _storeContest(_contest(10, 14, ContestStatus.Scored));
        int32 spreadNum = 30; // 3.0 in 10x format
        uint256 speculationId = speculationModule.createSpeculation(
            contestId,
            address(spread),
            spreadNum,
            address(this),
            address(this)
        );
        _finalizeContest(contestId);
        vm.warp(block.timestamp + 2);
        speculationModule.settleSpeculation(speculationId);
        Speculation memory s = speculationModule.getSpeculation(speculationId);
        assertEq(uint(s.winSide), uint(WinSide.Home));
    }
    function testSpread_AwayCovers_NegativeSpread() public {
        // Away favored by 4.0 (-40 in 10x), away wins by 5
        // adjustedAway = 170 + (-40) = 130, scaledHome = 120 => Away covers
        uint256 contestId = _storeContest(_contest(17, 12, ContestStatus.Scored));
        int32 spreadNum = -40; // -4.0 in 10x format
        uint256 speculationId = speculationModule.createSpeculation(
            contestId,
            address(spread),
            spreadNum,
            address(this),
            address(this)
        );
        _finalizeContest(contestId);
        vm.warp(block.timestamp + 2);
        speculationModule.settleSpeculation(speculationId);
        Speculation memory s = speculationModule.getSpeculation(speculationId);
        assertEq(uint(s.winSide), uint(WinSide.Away));
    }
    function testSpread_HomeCovers_NegativeSpread() public {
        // Away favored by 4 (-4), home loses by 2
        uint256 contestId = _storeContest(_contest(14, 12, ContestStatus.Scored));
        int32 spreadNum = -40; // -4.0 in 10x format
        uint256 speculationId = speculationModule.createSpeculation(
            contestId,
            address(spread),
            spreadNum,
            address(this),
            address(this)
        );
        _finalizeContest(contestId);
        vm.warp(block.timestamp + 2);
        speculationModule.settleSpeculation(speculationId);
        Speculation memory s = speculationModule.getSpeculation(speculationId);
        assertEq(uint(s.winSide), uint(WinSide.Home));
    }
    function testSpread_Push_ExactMargin() public {
        // Home favored by 2.0, home wins by exactly 2 => Push
        // adjustedAway = 100 + 20 = 120, scaledHome = 120 => Push
        uint256 contestId = _storeContest(_contest(10, 12, ContestStatus.Scored));
        int32 spreadNum = 20; // 2.0 in 10x format
        uint256 speculationId = speculationModule.createSpeculation(
            contestId,
            address(spread),
            spreadNum,
            address(this),
            address(this)
        );
        _finalizeContest(contestId);
        vm.warp(block.timestamp + 2);
        speculationModule.settleSpeculation(speculationId);
        Speculation memory s = speculationModule.getSpeculation(speculationId);
        assertEq(uint(s.winSide), uint(WinSide.Push));
    }
    // --- Spread 10x half-point tests ---
    function testSpread_AwayCovers_NegativeHalfPoint() public {
        // Celtics (away) 104, Lakers (home) 100, spread -35 (Away favored by 3.5)
        // adjustedAway = 1040 + (-35) = 1005, scaledHome = 1000 => Away covers
        uint256 contestId = _storeContest(_contest(104, 100, ContestStatus.Scored));
        int32 spreadNum = -35; // -3.5 in 10x format
        uint256 speculationId = speculationModule.createSpeculation(
            contestId,
            address(spread),
            spreadNum,
            address(this),
            address(this)
        );
        _finalizeContest(contestId);
        vm.warp(block.timestamp + 2);
        speculationModule.settleSpeculation(speculationId);
        Speculation memory s = speculationModule.getSpeculation(speculationId);
        assertEq(uint(s.winSide), uint(WinSide.Away));
    }
    function testSpread_HomeCovers_NegativeHalfPoint() public {
        // Celtics (away) 104, Lakers (home) 101, spread -35 (Away favored by 3.5)
        // adjustedAway = 1040 + (-35) = 1005, scaledHome = 1010 => Home (didn't cover)
        uint256 contestId = _storeContest(_contest(104, 101, ContestStatus.Scored));
        int32 spreadNum = -35; // -3.5 in 10x format
        uint256 speculationId = speculationModule.createSpeculation(
            contestId,
            address(spread),
            spreadNum,
            address(this),
            address(this)
        );
        _finalizeContest(contestId);
        vm.warp(block.timestamp + 2);
        speculationModule.settleSpeculation(speculationId);
        Speculation memory s = speculationModule.getSpeculation(speculationId);
        assertEq(uint(s.winSide), uint(WinSide.Home));
    }
    function testSpread_Push_NegativeWholePoint() public {
        // Celtics (away) 104, Lakers (home) 101, spread -30 (Away favored by 3.0)
        // adjustedAway = 1040 + (-30) = 1010, scaledHome = 1010 => Push
        uint256 contestId = _storeContest(_contest(104, 101, ContestStatus.Scored));
        int32 spreadNum = -30; // -3.0 in 10x format
        uint256 speculationId = speculationModule.createSpeculation(
            contestId,
            address(spread),
            spreadNum,
            address(this),
            address(this)
        );
        _finalizeContest(contestId);
        vm.warp(block.timestamp + 2);
        speculationModule.settleSpeculation(speculationId);
        Speculation memory s = speculationModule.getSpeculation(speculationId);
        assertEq(uint(s.winSide), uint(WinSide.Push));
    }
    function testSpread_Revert_NotSpeculationModule() public {
        uint256 contestId = _storeContest(_contest(10, 12, ContestStatus.Scored));
        address notSpeculationModule = address(0xCAFE);
        vm.expectRevert(
            abi.encodeWithSelector(
                SpreadScorerModule.SpreadScorerModule__NotSpeculationModule.selector,
                notSpeculationModule
            )
        );
        vm.prank(notSpeculationModule);
        spread.determineWinSide(contestId, 3);
    }
    // --- TotalScorerModule ---
    function testTotal_Over() public {
        uint256 contestId = _storeContest(_contest(10, 15, ContestStatus.Scored));
        int32 totalNum = 240; // 24.0 in 10x format
        uint256 speculationId = speculationModule.createSpeculation(
            contestId,
            address(total),
            totalNum,
            address(this),
            address(this)
        );
        _finalizeContest(contestId);
        vm.warp(block.timestamp + 2);
        speculationModule.settleSpeculation(speculationId);
        Speculation memory s = speculationModule.getSpeculation(speculationId);
        assertEq(uint(s.winSide), uint(WinSide.Over));
    }
    function testTotal_Under() public {
        uint256 contestId = _storeContest(_contest(7, 8, ContestStatus.Scored));
        int32 totalNum = 200; // 20.0 in 10x format
        uint256 speculationId = speculationModule.createSpeculation(
            contestId,
            address(total),
            totalNum,
            address(this),
            address(this)
        );
        _finalizeContest(contestId);
        vm.warp(block.timestamp + 2);
        speculationModule.settleSpeculation(speculationId);
        Speculation memory s = speculationModule.getSpeculation(speculationId);
        assertEq(uint(s.winSide), uint(WinSide.Under));
    }
    function testTotal_Push_Exact() public {
        // Away 10, Home 10, total 200 (20.0) — scaledTotal = 200 == lineTicks => Push
        uint256 contestId = _storeContest(_contest(10, 10, ContestStatus.Scored));
        int32 totalNum = 200; // 20.0 in 10x format
        uint256 speculationId = speculationModule.createSpeculation(
            contestId,
            address(total),
            totalNum,
            address(this),
            address(this)
        );
        _finalizeContest(contestId);
        vm.warp(block.timestamp + 2);
        speculationModule.settleSpeculation(speculationId);
        Speculation memory s = speculationModule.getSpeculation(speculationId);
        assertEq(uint(s.winSide), uint(WinSide.Push));
    }
    // --- Total 10x half-point tests ---
    function testTotal_Over_HalfPoint() public {
        // Away 110, Home 108, total 2175 (217.5)
        // scaledTotal = (110 + 108) * 10 = 2180, 2180 >= 2175 => Over
        uint256 contestId = _storeContest(_contest(110, 108, ContestStatus.Scored));
        int32 totalNum = 2175; // 217.5 in 10x format
        uint256 speculationId = speculationModule.createSpeculation(
            contestId,
            address(total),
            totalNum,
            address(this),
            address(this)
        );
        _finalizeContest(contestId);
        vm.warp(block.timestamp + 2);
        speculationModule.settleSpeculation(speculationId);
        Speculation memory s = speculationModule.getSpeculation(speculationId);
        assertEq(uint(s.winSide), uint(WinSide.Over));
    }
    function testTotal_Under_HalfPoint() public {
        // Away 110, Home 107, total 2175 (217.5)
        // scaledTotal = (110 + 107) * 10 = 2170, 2170 < 2175 => Under
        uint256 contestId = _storeContest(_contest(110, 107, ContestStatus.Scored));
        int32 totalNum = 2175; // 217.5 in 10x format
        uint256 speculationId = speculationModule.createSpeculation(
            contestId,
            address(total),
            totalNum,
            address(this),
            address(this)
        );
        _finalizeContest(contestId);
        vm.warp(block.timestamp + 2);
        speculationModule.settleSpeculation(speculationId);
        Speculation memory s = speculationModule.getSpeculation(speculationId);
        assertEq(uint(s.winSide), uint(WinSide.Under));
    }
    function testTotal_Push_ExactWholeNumber() public {
        // Away 110, Home 110, total 2200 (220.0)
        // scaledTotal = (110 + 110) * 10 = 2200, 2200 == 2200 => Push
        uint256 contestId = _storeContest(_contest(110, 110, ContestStatus.Scored));
        int32 totalNum = 2200; // 220.0 in 10x format
        uint256 speculationId = speculationModule.createSpeculation(
            contestId,
            address(total),
            totalNum,
            address(this),
            address(this)
        );
        _finalizeContest(contestId);
        vm.warp(block.timestamp + 2);
        speculationModule.settleSpeculation(speculationId);
        Speculation memory s = speculationModule.getSpeculation(speculationId);
        assertEq(uint(s.winSide), uint(WinSide.Push));
    }
    function testTotal_Over_OneAboveWholeNumber() public {
        // Away 111, Home 110, total 2200 (220.0)
        // scaledTotal = (111 + 110) * 10 = 2210, 2210 > 2200 => Over
        uint256 contestId = _storeContest(_contest(111, 110, ContestStatus.Scored));
        int32 totalNum = 2200; // 220.0 in 10x format
        uint256 speculationId = speculationModule.createSpeculation(
            contestId,
            address(total),
            totalNum,
            address(this),
            address(this)
        );
        _finalizeContest(contestId);
        vm.warp(block.timestamp + 2);
        speculationModule.settleSpeculation(speculationId);
        Speculation memory s = speculationModule.getSpeculation(speculationId);
        assertEq(uint(s.winSide), uint(WinSide.Over));
    }

    function testTotal_Revert_NotSpeculationModule() public {
        uint256 contestId = _storeContest(_contest(10, 15, ContestStatus.Scored));
        address notSpeculationModule = address(0xDEAD);
        vm.expectRevert(
            abi.encodeWithSelector(
                TotalScorerModule.TotalScorerModule__NotSpeculationModule.selector,
                notSpeculationModule
            )
        );
        vm.prank(notSpeculationModule);
        total.determineWinSide(contestId, 24);
    }
    // --- Helpers ---
    function _contest(
        uint32 away,
        uint32 home,
        ContestStatus status
    ) internal pure returns (Contest memory) {
        return
            Contest({
                awayScore: away,
                homeScore: home,
                leagueId: LeagueId.NBA,
                contestStatus: status,
                contestCreator: address(0),
                verifySourceHash: bytes32(0),
                marketUpdateSourceHash: bytes32(0),
                scoreContestSourceHash: bytes32(0),
                rundownId: "",
                sportspageId: "",
                jsonoddsId: ""
            });
    }
    function _storeContest(Contest memory c) internal returns (uint256) {
        uint256 contestId = nextContestId++;
        // Save the intended final state (with scores + Scored status)
        _finalContests[contestId] = c;
        // Store as Verified so speculations can be created
        Contest memory verified = c;
        verified.contestStatus = ContestStatus.Verified;
        mockContest.setContest(contestId, verified);
        return contestId;
    }
    /// @dev Restores the contest to its intended final state (Scored) for settlement
    function _finalizeContest(uint256 contestId) internal {
        mockContest.setContest(contestId, _finalContests[contestId]);
    }

    // --- Constructor Zero-Address Tests ---

    function testMoneylineConstructor_RevertsOnZeroAddress() public {
        vm.expectRevert(MoneylineScorerModule.MoneylineScorerModule__InvalidOspexCore.selector);
        new MoneylineScorerModule(address(0));
    }

    function testSpreadConstructor_RevertsOnZeroAddress() public {
        vm.expectRevert(SpreadScorerModule.SpreadScorerModule__InvalidOspexCore.selector);
        new SpreadScorerModule(address(0));
    }

    function testTotalConstructor_RevertsOnZeroAddress() public {
        vm.expectRevert(TotalScorerModule.TotalScorerModule__InvalidOspexCore.selector);
        new TotalScorerModule(address(0));
    }
}
