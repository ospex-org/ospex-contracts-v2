// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {ContestModule} from "../../src/modules/ContestModule.sol";
import {TreasuryModule} from "../../src/modules/TreasuryModule.sol";
import {Contest, ContestMarket, ContestStatus, FeeType, LeagueId} from "../../src/core/OspexTypes.sol";
import {OspexCore} from "../../src/core/OspexCore.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract ContestModuleTest is Test {
    ContestModule contestModule;
    TreasuryModule treasuryModule;
    OspexCore core;
    MockERC20 mockToken;
    address oracleModule = address(0xBEEF);
    address notOracle = address(0xBAD);
    address contestCreator = address(0x123);

    // Mock scorer addresses for updateContestMarkets tests
    address moneylineScorer = address(0xAAA1);
    address spreadScorer = address(0xAAA2);
    address totalScorer = address(0xAAA3);

    function setUp() public {
        core = new OspexCore();
        mockToken = new MockERC20();

        // Fund account for fee test
        mockToken.transfer(contestCreator, 10_000_000);

        // Deploy modules with real fees
        contestModule = new ContestModule(address(core));
        treasuryModule = new TreasuryModule(
            address(core),
            address(mockToken),
            address(0x2), // protocolReceiver
            1_000_000, 500_000, 500_000
        );

        // Approve TreasuryModule for contest creation fees
        vm.prank(contestCreator);
        mockToken.approve(address(treasuryModule), type(uint256).max);

        // Bootstrap all 12 modules (use dummy addresses for ones we don't test)
        bytes32[] memory types = new bytes32[](12);
        address[] memory addrs = new address[](12);
        types[0] = core.CONTEST_MODULE();           addrs[0] = address(contestModule);
        types[1] = core.SPECULATION_MODULE();        addrs[1] = address(0xD001);
        types[2] = core.POSITION_MODULE();           addrs[2] = address(0xD002);
        types[3] = core.MATCHING_MODULE();           addrs[3] = address(0xD003);
        types[4] = core.ORACLE_MODULE();             addrs[4] = oracleModule;
        types[5] = core.TREASURY_MODULE();           addrs[5] = address(treasuryModule);
        types[6] = core.LEADERBOARD_MODULE();        addrs[6] = address(0xD006);
        types[7] = core.RULES_MODULE();              addrs[7] = address(0xD007);
        types[8] = core.SECONDARY_MARKET_MODULE();   addrs[8] = address(0xD008);
        types[9] = core.MONEYLINE_SCORER_MODULE();   addrs[9] = moneylineScorer;
        types[10] = core.SPREAD_SCORER_MODULE();     addrs[10] = spreadScorer;
        types[11] = core.TOTAL_SCORER_MODULE();      addrs[11] = totalScorer;
        core.bootstrapModules(types, addrs);
        core.finalize();
    }

    function testConstructor_RevertsOnZeroCore() public {
        vm.expectRevert(
            ContestModule.ContestModule__InvalidCoreAddress.selector
        );
        new ContestModule(address(0));
    }

    function testGetModuleType() public view {
        assertEq(contestModule.getModuleType(), keccak256("CONTEST_MODULE"));
    }

    function testCreateContest_OnlyOracleModule() public {
        vm.prank(oracleModule);
        uint256 contestId = contestModule.createContest(
            "rd", "sp", "jo",
            bytes32(0),
            bytes32("marketHash"),
            bytes32("scoreHash"),
            LeagueId.Unknown,
            contestCreator
        );
        Contest memory c = contestModule.getContest(contestId);
        assertEq(c.rundownId, "rd");
        assertEq(c.sportspageId, "sp");
        assertEq(c.jsonoddsId, "jo");
        assertEq(c.scoreContestSourceHash, bytes32("scoreHash"));
        assertEq(c.marketUpdateSourceHash, bytes32("marketHash"));
        assertEq(c.contestCreator, contestCreator);
        assertEq(uint(c.contestStatus), uint(ContestStatus.Unverified));
    }

    function testCreateContest_RevertsIfNotOracleModule() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ContestModule.ContestModule__NotOracleModule.selector,
                notOracle
            )
        );
        vm.prank(notOracle);
        contestModule.createContest(
            "rd", "sp", "jo",
            bytes32(0),
            bytes32("marketHash"),
            bytes32("scoreHash"),
            LeagueId.Unknown,
            contestCreator
        );
    }

    function testSetContestStatus_OnlyOracleModule() public {
        vm.prank(oracleModule);
        uint256 contestId = contestModule.createContest(
            "rd", "sp", "jo",
            bytes32(0),
            bytes32("marketHash"),
            bytes32("scoreHash"),
            LeagueId.Unknown,
            contestCreator
        );
        vm.prank(oracleModule);
        contestModule.setContestLeagueIdAndStartTime(contestId, LeagueId.NBA, uint32(block.timestamp));
        Contest memory c = contestModule.getContest(contestId);
        assertEq(uint(c.contestStatus), uint(ContestStatus.Verified));
    }

    function testSetContestStatus_RevertsIfNotOracleModule() public {
        vm.prank(oracleModule);
        uint256 contestId = contestModule.createContest(
            "rd", "sp", "jo",
            bytes32(0),
            bytes32("marketHash"),
            bytes32("scoreHash"),
            LeagueId.Unknown,
            contestCreator
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                ContestModule.ContestModule__NotOracleModule.selector,
                notOracle
            )
        );
        vm.prank(notOracle);
        contestModule.setContestLeagueIdAndStartTime(contestId, LeagueId.NBA, uint32(block.timestamp));
    }

    function testSetScores_OracleModuleCanSet() public {
        vm.prank(oracleModule);
        uint256 contestId = contestModule.createContest(
            "rd", "sp", "jo",
            bytes32(0),
            bytes32("marketHash"),
            bytes32("scoreHash"),
            LeagueId.Unknown,
            contestCreator
        );
        // Must verify contest first (setScores requires Verified status)
        vm.prank(oracleModule);
        contestModule.setContestLeagueIdAndStartTime(contestId, LeagueId.NBA, uint32(block.timestamp));

        vm.prank(oracleModule);
        contestModule.setScores(contestId, 11, 22);
        Contest memory c = contestModule.getContest(contestId);
        assertEq(c.awayScore, 11);
        assertEq(c.homeScore, 22);
    }

    function testSetScores_RevertsIfNotOracle() public {
        vm.prank(oracleModule);
        uint256 contestId = contestModule.createContest(
            "rd", "sp", "jo",
            bytes32(0),
            bytes32("marketHash"),
            bytes32("scoreHash"),
            LeagueId.Unknown,
            contestCreator
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                ContestModule.ContestModule__NotOracleModule.selector,
                notOracle
            )
        );
        vm.prank(notOracle);
        contestModule.setScores(contestId, 1, 2);
    }

    function testGetContest_ReturnsCorrectData() public {
        vm.prank(oracleModule);
        uint256 contestId = contestModule.createContest(
            "rd", "sp", "jo",
            bytes32(0),
            bytes32("marketHash"),
            bytes32("scoreHash"),
            LeagueId.Unknown,
            contestCreator
        );
        Contest memory c = contestModule.getContest(contestId);
        assertEq(c.rundownId, "rd");
        assertEq(c.sportspageId, "sp");
        assertEq(c.jsonoddsId, "jo");
        assertEq(c.scoreContestSourceHash, bytes32("scoreHash"));
        assertEq(c.marketUpdateSourceHash, bytes32("marketHash"));
        assertEq(c.contestCreator, contestCreator);
        assertEq(uint(c.contestStatus), uint(ContestStatus.Unverified));
    }

    function testCreateContest_WithFee_ChargesFee() public {
        // Deploy a separate treasury with non-zero fee for this specific test
        OspexCore feeCore = new OspexCore();
        MockERC20 feeToken = new MockERC20();
        feeToken.transfer(contestCreator, 10_000_000);

        uint256 fee = 1_000_000; // 1.00 USDC
        ContestModule feeContestModule = new ContestModule(address(feeCore));
        TreasuryModule feeTreasury = new TreasuryModule(
            address(feeCore), address(feeToken), address(0x2),
            fee, 0, 0
        );
        address feeOracle = address(0xFEED);

        bytes32[] memory types = new bytes32[](12);
        address[] memory addrs = new address[](12);
        types[0] = feeCore.CONTEST_MODULE();           addrs[0] = address(feeContestModule);
        types[1] = feeCore.SPECULATION_MODULE();        addrs[1] = address(0xF001);
        types[2] = feeCore.POSITION_MODULE();           addrs[2] = address(0xF002);
        types[3] = feeCore.MATCHING_MODULE();           addrs[3] = address(0xF003);
        types[4] = feeCore.ORACLE_MODULE();             addrs[4] = feeOracle;
        types[5] = feeCore.TREASURY_MODULE();           addrs[5] = address(feeTreasury);
        types[6] = feeCore.LEADERBOARD_MODULE();        addrs[6] = address(0xF006);
        types[7] = feeCore.RULES_MODULE();              addrs[7] = address(0xF007);
        types[8] = feeCore.SECONDARY_MARKET_MODULE();   addrs[8] = address(0xF008);
        types[9] = feeCore.MONEYLINE_SCORER_MODULE();   addrs[9] = address(0xF009);
        types[10] = feeCore.SPREAD_SCORER_MODULE();     addrs[10] = address(0xF00A);
        types[11] = feeCore.TOTAL_SCORER_MODULE();      addrs[11] = address(0xF00B);
        feeCore.bootstrapModules(types, addrs);
        feeCore.finalize();

        // Approve treasury for contestCreator
        vm.prank(contestCreator);
        feeToken.approve(address(feeTreasury), fee);

        uint256 creatorBefore = feeToken.balanceOf(contestCreator);

        vm.prank(feeOracle);
        feeContestModule.createContest(
            "rd", "sp", "jo",
            bytes32(0),
            bytes32("marketHash"),
            bytes32("scoreHash"),
            LeagueId.Unknown,
            contestCreator
        );

        // Check that the contestCreator's balance decreased by the fee
        assertEq(feeToken.balanceOf(contestCreator), creatorBefore - fee);
    }

    // --- Update Contest Markets Tests ---
    function testUpdateContestMarkets_Success() public {
        uint256 contestId = 1;

        uint16 moneylineAwayOdds = 150;
        uint16 moneylineHomeOdds = 250;
        int32 spreadLineTicks = -35;
        uint16 spreadAwayOdds = 180;
        uint16 spreadHomeOdds = 220;
        int32 totalLineTicks = 2250;
        uint16 overOdds = 190;
        uint16 underOdds = 210;

        vm.expectEmit(true, true, true, true);
        emit ContestModule.ContestMarketsUpdated(
            contestId,
            uint32(block.timestamp),
            spreadLineTicks,
            totalLineTicks,
            moneylineAwayOdds,
            moneylineHomeOdds,
            spreadAwayOdds,
            spreadHomeOdds,
            overOdds,
            underOdds
        );

        vm.prank(oracleModule);
        contestModule.updateContestMarkets(
            contestId,
            moneylineAwayOdds,
            moneylineHomeOdds,
            spreadLineTicks,
            spreadAwayOdds,
            spreadHomeOdds,
            totalLineTicks,
            overOdds,
            underOdds
        );

        // Verify all three markets
        ContestMarket memory moneylineMarket = contestModule.getContestMarket(contestId, moneylineScorer);
        assertEq(moneylineMarket.lineTicks, 0);
        assertEq(moneylineMarket.upperOdds, moneylineAwayOdds);
        assertEq(moneylineMarket.lowerOdds, moneylineHomeOdds);

        ContestMarket memory spreadMarket = contestModule.getContestMarket(contestId, spreadScorer);
        assertEq(spreadMarket.lineTicks, spreadLineTicks);
        assertEq(spreadMarket.upperOdds, spreadAwayOdds);
        assertEq(spreadMarket.lowerOdds, spreadHomeOdds);

        ContestMarket memory totalMarket = contestModule.getContestMarket(contestId, totalScorer);
        assertEq(totalMarket.lineTicks, totalLineTicks);
        assertEq(totalMarket.upperOdds, overOdds);
        assertEq(totalMarket.lowerOdds, underOdds);
    }

    function testUpdateContestMarkets_RevertsIfNotOracleModule() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ContestModule.ContestModule__NotOracleModule.selector,
                notOracle
            )
        );
        vm.prank(notOracle);
        contestModule.updateContestMarkets(1, 150, 250, -35, 180, 220, 2250, 190, 210);
    }

    function testUpdateContestMarkets_HandlesEdgeCaseValues() public {
        uint256 contestId = 2;
        vm.prank(oracleModule);
        contestModule.updateContestMarkets(
            contestId, 105, 500, -150, 105, 500, 5000, 105, 500
        );

        ContestMarket memory spreadMarket = contestModule.getContestMarket(contestId, spreadScorer);
        assertEq(spreadMarket.lineTicks, -150);
        assertEq(spreadMarket.upperOdds, 105);
        assertEq(spreadMarket.lowerOdds, 500);
    }

    // --- Get Contest Market Tests ---
    function testGetContestMarket_ReturnsCorrectData() public {
        uint256 contestId = 1;
        vm.prank(oracleModule);
        contestModule.updateContestMarkets(
            contestId, 160, 240, -25, 170, 230, 2100, 180, 220
        );

        ContestMarket memory moneylineMarket = contestModule.getContestMarket(contestId, moneylineScorer);
        assertEq(moneylineMarket.lineTicks, 0);
        assertEq(moneylineMarket.upperOdds, 160);
        assertEq(moneylineMarket.lowerOdds, 240);

        ContestMarket memory spreadMarket = contestModule.getContestMarket(contestId, spreadScorer);
        assertEq(spreadMarket.lineTicks, -25);
        assertEq(spreadMarket.upperOdds, 170);
        assertEq(spreadMarket.lowerOdds, 230);

        ContestMarket memory totalMarket = contestModule.getContestMarket(contestId, totalScorer);
        assertEq(totalMarket.lineTicks, 2100);
        assertEq(totalMarket.upperOdds, 180);
        assertEq(totalMarket.lowerOdds, 220);
    }

    function testGetContestMarket_ReturnsEmptyForNonExistent() public view {
        ContestMarket memory market = contestModule.getContestMarket(999, address(0x999));
        assertEq(market.lineTicks, 0);
        assertEq(market.upperOdds, 0);
        assertEq(market.lowerOdds, 0);
        assertEq(market.lastUpdated, 0);
    }

    // --- Scoring Immutability Tests ---

    function testSetScores_OracleCannotRescore() public {
        vm.prank(oracleModule);
        uint256 contestId = contestModule.createContest(
            "rd", "sp", "jo",
            bytes32(0), bytes32("marketHash"), bytes32("scoreHash"),
            LeagueId.Unknown, contestCreator
        );
        vm.prank(oracleModule);
        contestModule.setContestLeagueIdAndStartTime(contestId, LeagueId.NBA, uint32(block.timestamp));

        // First score succeeds
        vm.prank(oracleModule);
        contestModule.setScores(contestId, 100, 95);
        Contest memory c = contestModule.getContest(contestId);
        assertEq(uint(c.contestStatus), uint(ContestStatus.Scored));
        assertEq(c.awayScore, 100);
        assertEq(c.homeScore, 95);

        // Second score reverts
        vm.prank(oracleModule);
        vm.expectRevert(
            abi.encodeWithSelector(ContestModule.ContestModule__AlreadyScored.selector, contestId)
        );
        contestModule.setScores(contestId, 110, 90);

        // Scores unchanged
        Contest memory c2 = contestModule.getContest(contestId);
        assertEq(c2.awayScore, 100);
        assertEq(c2.homeScore, 95);
    }

    // --- Validation Tests ---

    function testSetContestLeagueIdAndStartTime_RevertsIfUnknownLeague() public {
        vm.prank(oracleModule);
        uint256 contestId = contestModule.createContest(
            "rd", "sp", "jo",
            bytes32(0), bytes32("marketHash"), bytes32("scoreHash"),
            LeagueId.Unknown, contestCreator
        );
        vm.prank(oracleModule);
        vm.expectRevert(ContestModule.ContestModule__InvalidValue.selector);
        contestModule.setContestLeagueIdAndStartTime(contestId, LeagueId.Unknown, uint32(block.timestamp));
    }

    function testSetContestLeagueIdAndStartTime_RevertsIfStartTimeZero() public {
        vm.prank(oracleModule);
        uint256 contestId = contestModule.createContest(
            "rd", "sp", "jo",
            bytes32(0), bytes32("marketHash"), bytes32("scoreHash"),
            LeagueId.Unknown, contestCreator
        );
        vm.prank(oracleModule);
        vm.expectRevert(ContestModule.ContestModule__InvalidValue.selector);
        contestModule.setContestLeagueIdAndStartTime(contestId, LeagueId.NBA, 0);
    }

    function testUpdateContestMarkets_RevertsIfAnyOddsZero() public {
        vm.prank(oracleModule);
        vm.expectRevert(ContestModule.ContestModule__InvalidMarketData.selector);
        contestModule.updateContestMarkets(1, 0, 250, -35, 180, 220, 2250, 190, 210);
    }

    function testUpdateContestMarkets_RevertsIfUnderOddsZero() public {
        vm.prank(oracleModule);
        vm.expectRevert(ContestModule.ContestModule__InvalidMarketData.selector);
        contestModule.updateContestMarkets(1, 150, 250, -35, 180, 220, 2250, 190, 0);
    }

    function testUpdateContestMarkets_RevertsIfNegativeTotalLineTicks() public {
        vm.prank(oracleModule);
        vm.expectRevert(ContestModule.ContestModule__InvalidMarketData.selector);
        contestModule.updateContestMarkets(1, 150, 250, -35, 180, 220, -10, 190, 210);
    }

    function testCreateContest_RevertsIfAllSourceIdsEmpty() public {
        vm.prank(oracleModule);
        vm.expectRevert(ContestModule.ContestModule__InvalidValue.selector);
        contestModule.createContest(
            "", "", "",
            bytes32(0), bytes32("marketHash"), bytes32("scoreHash"),
            LeagueId.Unknown, contestCreator
        );
    }

    function testCreateContest_SucceedsWithOneSourceId() public {
        vm.prank(oracleModule);
        uint256 contestId = contestModule.createContest(
            "", "", "jo",
            bytes32(0), bytes32("marketHash"), bytes32("scoreHash"),
            LeagueId.Unknown, contestCreator
        );
        Contest memory c = contestModule.getContest(contestId);
        assertEq(c.jsonoddsId, "jo");
    }
}
