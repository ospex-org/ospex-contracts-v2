// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {SpeculationModule} from "../../src/modules/SpeculationModule.sol";
import {Speculation, SpeculationStatus, WinSide, Contest, ContestStatus, FeeType, LeagueId} from "../../src/core/OspexTypes.sol";
import {OspexCore} from "../../src/core/OspexCore.sol";
import {MockContestModule} from "../mocks/MockContestModule.sol";
import {MockScorerModule} from "../mocks/MockScorerModule.sol";
import {TreasuryModule} from "../../src/modules/TreasuryModule.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract SpeculationModuleTest is Test {
    SpeculationModule speculationModule;
    OspexCore core;
    MockContestModule mockContestModule;
    TreasuryModule treasuryModule;
    MockERC20 mockToken;
    uint8 constant TOKEN_DECIMALS = 6;
    uint32 constant VOID_COOLDOWN = 3 days;
    uint256 constant MIN_AMOUNT = 1_000_000; // 1 USDC
    address speculationCreator = address(0x123);

    // Registered scorer module addresses (registered via bootstrap)
    address moneylineScorerAddr;
    address spreadScorerAddr;
    address totalScorerAddr;

    function setUp() public {
        core = new OspexCore();
        mockToken = new MockERC20();
        mockToken.transfer(speculationCreator, 10_000_000);

        // Deploy real modules
        speculationModule = new SpeculationModule(
            address(core), TOKEN_DECIMALS, VOID_COOLDOWN, MIN_AMOUNT
        );
        treasuryModule = new TreasuryModule(
            address(core), address(mockToken), address(0x2),
            1_000_000, 500_000, 500_000
        );

        // Approve TreasuryModule for speculation creation split fees
        mockToken.approve(address(treasuryModule), type(uint256).max);
        vm.prank(speculationCreator);
        mockToken.approve(address(treasuryModule), type(uint256).max);
        mockContestModule = new MockContestModule();

        // Create mock scorer modules for approved-scorer checks
        MockScorerModule mockMoneyline = new MockScorerModule();
        MockScorerModule mockSpread = new MockScorerModule();
        MockScorerModule mockTotal = new MockScorerModule();
        moneylineScorerAddr = address(mockMoneyline);
        spreadScorerAddr = address(mockSpread);
        totalScorerAddr = address(mockTotal);

        // Bootstrap all 12 modules
        bytes32[] memory types = new bytes32[](12);
        address[] memory addrs = new address[](12);
        types[0] = core.CONTEST_MODULE();           addrs[0] = address(mockContestModule);
        types[1] = core.SPECULATION_MODULE();        addrs[1] = address(speculationModule);
        types[2] = core.POSITION_MODULE();           addrs[2] = address(this); // test contract acts as POSITION_MODULE
        types[3] = core.MATCHING_MODULE();           addrs[3] = address(0xD003);
        types[4] = core.ORACLE_MODULE();             addrs[4] = address(0xD004);
        types[5] = core.TREASURY_MODULE();           addrs[5] = address(treasuryModule);
        types[6] = core.LEADERBOARD_MODULE();        addrs[6] = address(0xD006);
        types[7] = core.RULES_MODULE();              addrs[7] = address(0xD007);
        types[8] = core.SECONDARY_MARKET_MODULE();   addrs[8] = address(0xD008);
        types[9] = core.MONEYLINE_SCORER_MODULE();   addrs[9] = moneylineScorerAddr;
        types[10] = core.SPREAD_SCORER_MODULE();     addrs[10] = spreadScorerAddr;
        types[11] = core.TOTAL_SCORER_MODULE();      addrs[11] = totalScorerAddr;
        core.bootstrapModules(types, addrs);
        core.finalize();

        // Set up a default verified contest
        Contest memory defaultContest = Contest({
            awayScore: 0,
            homeScore: 0,
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Verified,
            contestCreator: address(this),
            scoreContestSourceHash: bytes32(0),
            marketUpdateSourceHash: bytes32(0),
            rundownId: "",
            sportspageId: "",
            jsonoddsId: ""
        });
        mockContestModule.setContest(1, defaultContest);
    }

    function testConstructor_SetsImmutables() public view {
        assertEq(speculationModule.i_tokenDecimals(), TOKEN_DECIMALS);
        assertEq(speculationModule.i_minSpeculationAmount(), MIN_AMOUNT);
        assertEq(speculationModule.i_voidCooldown(), VOID_COOLDOWN);
    }

    function testCreateSpeculation_Success() public {
        // createSpeculation now takes (contestId, scorer, lineTicks, maker, taker)
        uint256 id = speculationModule.createSpeculation(
            1, moneylineScorerAddr, 0, address(this), speculationCreator
        );
        Speculation memory s = speculationModule.getSpeculation(id);
        assertEq(s.contestId, 1);
        assertEq(s.speculationScorer, moneylineScorerAddr);
        assertEq(s.lineTicks, 0);
        // speculationCreator in struct = maker (the initiator)
        // Check the stored creator matches what the contract sets
        assertEq(uint(s.speculationStatus), uint(SpeculationStatus.Open));
        assertEq(uint(s.winSide), uint(WinSide.TBD));
    }

    function testSettleSpeculation_Success() public {
        uint256 id = speculationModule.createSpeculation(
            1, moneylineScorerAddr, 0, address(this), speculationCreator
        );

        // Set contest to Scored
        Contest memory contest = Contest({
            awayScore: 1, homeScore: 0, leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored, contestCreator: address(this),
            scoreContestSourceHash: bytes32(0), marketUpdateSourceHash: bytes32(0),
            rundownId: "", sportspageId: "", jsonoddsId: ""
        });
        mockContestModule.setContest(1, contest);

        vm.warp(block.timestamp + 1 hours);
        speculationModule.settleSpeculation(id);
        Speculation memory s = speculationModule.getSpeculation(id);
        assertEq(uint(s.speculationStatus), uint(SpeculationStatus.Closed));
    }

    function testSettleSpeculation_AutoVoidsAfterCooldown() public {
        uint32 nowTime = uint32(block.timestamp + 1);

        uint256 id = speculationModule.createSpeculation(
            1, moneylineScorerAddr, 0, address(this), speculationCreator
        );

        // Contest stays Verified (not scored) — simulates unresolved game
        vm.warp(nowTime + speculationModule.i_voidCooldown() + 1);
        speculationModule.settleSpeculation(id);
        Speculation memory s = speculationModule.getSpeculation(id);
        assertEq(uint(s.winSide), uint(WinSide.Void));
        assertEq(uint(s.speculationStatus), uint(SpeculationStatus.Closed));
    }

    function testSettleSpeculation_RevertsIfNotStarted() public {
        uint256 id = speculationModule.createSpeculation(
            1, moneylineScorerAddr, 0, address(this), speculationCreator
        );

        // Set contest as scored
        Contest memory contest = Contest({
            awayScore: 1, homeScore: 0, leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored, contestCreator: address(this),
            scoreContestSourceHash: bytes32(0), marketUpdateSourceHash: bytes32(0),
            rundownId: "", sportspageId: "", jsonoddsId: ""
        });
        mockContestModule.setContest(1, contest);

        // Set contest start time in the future
        uint32 futureStartTime = uint32(block.timestamp + 1 hours);
        mockContestModule.setContestStartTime(1, futureStartTime);

        vm.expectRevert(
            SpeculationModule.SpeculationModule__SpeculationNotStarted.selector
        );
        speculationModule.settleSpeculation(id);
    }

    function testSettleSpeculation_RevertsIfAlreadySettled() public {
        uint256 id = speculationModule.createSpeculation(
            1, moneylineScorerAddr, 0, address(this), speculationCreator
        );

        Contest memory contest = Contest({
            awayScore: 1, homeScore: 0, leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored, contestCreator: address(this),
            scoreContestSourceHash: bytes32(0), marketUpdateSourceHash: bytes32(0),
            rundownId: "", sportspageId: "", jsonoddsId: ""
        });
        mockContestModule.setContest(1, contest);

        vm.warp(block.timestamp + 1 hours);
        speculationModule.settleSpeculation(id);
        vm.expectRevert(
            SpeculationModule.SpeculationModule__AlreadySettled.selector
        );
        speculationModule.settleSpeculation(id);
    }

    function testGetSpeculation_ReturnsCorrectData() public {
        uint256 id = speculationModule.createSpeculation(
            1, moneylineScorerAddr, 0, address(this), speculationCreator
        );
        Speculation memory s = speculationModule.getSpeculation(id);
        assertEq(s.contestId, 1);
        assertEq(s.speculationScorer, moneylineScorerAddr);
        assertEq(s.lineTicks, 0);
        assertEq(uint(s.speculationStatus), uint(SpeculationStatus.Open));
        assertEq(uint(s.winSide), uint(WinSide.TBD));
    }

    function testGetModuleType_ReturnsCorrectValue() public view {
        assertEq(speculationModule.getModuleType(), keccak256("SPECULATION_MODULE"));
    }

    function testCreateSpeculation_RevertsWhenCalledByNonPositionModule() public {
        address nonPositionModule = address(0x999);
        vm.expectRevert(
            abi.encodeWithSelector(
                SpeculationModule.SpeculationModule__NotAuthorized.selector,
                nonPositionModule
            )
        );
        vm.prank(nonPositionModule);
        speculationModule.createSpeculation(
            1, moneylineScorerAddr, 0, address(0x123), speculationCreator
        );
    }

    function testCreateSpeculation_SuccessWhenCalledByPositionModule() public {
        address maker = address(0x456);
        address takerAddr = address(0x789);

        // Fund and approve TreasuryModule for split fee
        mockToken.transfer(maker, 1_000_000);
        mockToken.transfer(takerAddr, 1_000_000);
        vm.prank(maker);
        mockToken.approve(address(treasuryModule), type(uint256).max);
        vm.prank(takerAddr);
        mockToken.approve(address(treasuryModule), type(uint256).max);

        // Call from POSITION_MODULE (this test contract)
        uint256 id = speculationModule.createSpeculation(
            1, moneylineScorerAddr, 0, maker, takerAddr
        );

        Speculation memory s = speculationModule.getSpeculation(id);
        assertEq(s.contestId, 1);
        assertEq(s.speculationScorer, moneylineScorerAddr);
    }

    // --- Scorer Approval ---

    function testCreateSpeculation_RevertsIfScorerNotApproved() public {
        address unapprovedScorer = address(0xBAD);
        vm.expectRevert(
            SpeculationModule.SpeculationModule__ScorerNotApproved.selector
        );
        speculationModule.createSpeculation(
            1, unapprovedScorer, 42, address(this), speculationCreator
        );
    }

    function testCreateSpeculation_SucceedsWithApprovedScorer() public {
        // All three registered scorer modules should work
        uint256 id = speculationModule.createSpeculation(
            1, spreadScorerAddr, -35, address(this), speculationCreator
        );
        Speculation memory s = speculationModule.getSpeculation(id);
        assertEq(s.speculationScorer, spreadScorerAddr);
    }

    // --- Contest Already Scored ---

    function testCreateSpeculation_RevertsOnScoredContest() public {
        Contest memory contest = Contest({
            awayScore: 3, homeScore: 1, leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored, contestCreator: address(this),
            scoreContestSourceHash: bytes32(0), marketUpdateSourceHash: bytes32(0),
            rundownId: "", sportspageId: "", jsonoddsId: ""
        });
        mockContestModule.setContest(1, contest);

        vm.expectRevert(SpeculationModule.SpeculationModule__ContestAlreadyScored.selector);
        speculationModule.createSpeculation(
            1, moneylineScorerAddr, 0, address(this), speculationCreator
        );
    }

    function testCreateSpeculation_SucceedsOnVerifiedContest() public {
        // Default contest from setUp is Verified
        uint256 id = speculationModule.createSpeculation(
            1, moneylineScorerAddr, 0, address(this), speculationCreator
        );
        Speculation memory s = speculationModule.getSpeculation(id);
        assertEq(s.contestId, 1);
        assertEq(uint(s.speculationStatus), uint(SpeculationStatus.Open));
    }

    // --- Scored Contest Settles by Scorer Even After Cooldown (C-4) ---

    function testSettleSpeculation_ScoredContestSettlesByScorerAfterCooldown() public {
        MockScorerModule mockScorer = MockScorerModule(moneylineScorerAddr);

        uint256 id = speculationModule.createSpeculation(
            1, moneylineScorerAddr, 0, address(this), speculationCreator
        );

        // Contest scored (e.g., late oracle delivery)
        Contest memory contest = Contest({
            awayScore: 3, homeScore: 1, leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored, contestCreator: address(this),
            scoreContestSourceHash: bytes32(0), marketUpdateSourceHash: bytes32(0),
            rundownId: "", sportspageId: "", jsonoddsId: ""
        });
        mockContestModule.setContest(1, contest);

        // Warp well past cooldown — should still settle by scorer, not void
        vm.warp(block.timestamp + speculationModule.i_voidCooldown() + 10 days);
        speculationModule.settleSpeculation(id);

        Speculation memory s = speculationModule.getSpeculation(id);
        assertEq(uint(s.speculationStatus), uint(SpeculationStatus.Closed));
        assertEq(uint(s.winSide), uint(WinSide.Away), "should settle by scorer, not void");
    }

    function testSettleSpeculation_UnresolvedContestStillVoidsAfterCooldown() public {
        uint256 id = speculationModule.createSpeculation(
            1, moneylineScorerAddr, 0, address(this), speculationCreator
        );

        // Contest stays Verified (no scores)
        vm.warp(block.timestamp + speculationModule.i_voidCooldown() + 1);
        speculationModule.settleSpeculation(id);

        Speculation memory s = speculationModule.getSpeculation(id);
        assertEq(uint(s.winSide), uint(WinSide.Void), "unresolved should void");
    }

    // --- Contest Not Finalized ---

    function testSettleSpeculation_RevertsIfContestNotFinalized() public {
        uint256 id = speculationModule.createSpeculation(
            1, moneylineScorerAddr, 0, address(this), speculationCreator
        );

        // Contest remains Verified (NOT scored)
        uint32 startTime = uint32(block.timestamp + 1);
        vm.warp(startTime + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                SpeculationModule.SpeculationModule__ContestNotFinalized.selector, 1
            )
        );
        speculationModule.settleSpeculation(id);
    }

    // --- LineTicks Validation ---

    function testCreateSpeculation_RevertsIfMoneylineScorerWithNonZeroLineTicks() public {
        vm.expectRevert(SpeculationModule.SpeculationModule__InvalidLineTicks.selector);
        speculationModule.createSpeculation(
            1, moneylineScorerAddr, 5, address(this), speculationCreator
        );
    }

    function testCreateSpeculation_SucceedsIfMoneylineScorerWithZeroLineTicks() public {
        uint256 id = speculationModule.createSpeculation(
            1, moneylineScorerAddr, 0, address(this), speculationCreator
        );
        Speculation memory s = speculationModule.getSpeculation(id);
        assertEq(s.lineTicks, 0);
    }

    function testCreateSpeculation_RevertsIfTotalScorerWithNegativeLineTicks() public {
        vm.expectRevert(SpeculationModule.SpeculationModule__InvalidLineTicks.selector);
        speculationModule.createSpeculation(
            1, totalScorerAddr, -100, address(this), speculationCreator
        );
    }

    function testCreateSpeculation_SucceedsIfTotalScorerWithPositiveLineTicks() public {
        uint256 id = speculationModule.createSpeculation(
            1, totalScorerAddr, 2250, address(this), speculationCreator
        );
        Speculation memory s = speculationModule.getSpeculation(id);
        assertEq(s.lineTicks, 2250);
    }

    function testCreateSpeculation_SpreadScorerAllowsAnyLineTicks() public {
        uint256 id = speculationModule.createSpeculation(
            1, spreadScorerAddr, -35, address(this), speculationCreator
        );
        Speculation memory s = speculationModule.getSpeculation(id);
        assertEq(s.lineTicks, -35);
    }

    // --- Branch Coverage: Constructor ---

    function testConstructor_RevertsOnZeroAddress() public {
        vm.expectRevert(SpeculationModule.SpeculationModule__InvalidAddress.selector);
        new SpeculationModule(address(0), 6, 3 days, 1_000_000);
    }

    // --- Branch Coverage: SpeculationExists ---

    function testCreateSpeculation_RevertsIfDuplicate() public {
        // First creation succeeds
        speculationModule.createSpeculation(
            1, moneylineScorerAddr, 0, address(this), speculationCreator
        );
        // Same contest/scorer/lineTicks → revert
        vm.expectRevert(SpeculationModule.SpeculationModule__SpeculationExists.selector);
        speculationModule.createSpeculation(
            1, moneylineScorerAddr, 0, address(this), speculationCreator
        );
    }

    // --- Branch Coverage: ContestNotVerified ---

    function testCreateSpeculation_RevertsOnUnverifiedContest() public {
        Contest memory unverified = Contest({
            awayScore: 0, homeScore: 0, leagueId: LeagueId.Unknown,
            contestStatus: ContestStatus.Unverified, contestCreator: address(this),
            scoreContestSourceHash: bytes32(0), marketUpdateSourceHash: bytes32(0),
            rundownId: "rd", sportspageId: "", jsonoddsId: ""
        });
        mockContestModule.setContest(99, unverified);

        vm.expectRevert(SpeculationModule.SpeculationModule__ContestNotVerified.selector);
        speculationModule.createSpeculation(
            99, moneylineScorerAddr, 0, address(this), speculationCreator
        );
    }

    // --- Branch Coverage: InvalidSpeculationId ---

    function testSettleSpeculation_RevertsOnZeroId() public {
        vm.expectRevert(SpeculationModule.SpeculationModule__InvalidSpeculationId.selector);
        speculationModule.settleSpeculation(0);
    }

    function testSettleSpeculation_RevertsOnIdAboveCounter() public {
        vm.expectRevert(SpeculationModule.SpeculationModule__InvalidSpeculationId.selector);
        speculationModule.settleSpeculation(999);
    }
}
