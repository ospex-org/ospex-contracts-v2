// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {SecondaryMarketModule} from "../../src/modules/SecondaryMarketModule.sol";
import {SpeculationModule} from "../../src/modules/SpeculationModule.sol";
import {PositionModule} from "../../src/modules/PositionModule.sol";
import {TreasuryModule} from "../../src/modules/TreasuryModule.sol";
import {OracleModule} from "../../src/modules/OracleModule.sol";
import {OspexCore} from "../../src/core/OspexCore.sol";
import {
    PositionType,
    SaleListing,
    Position,
    Contest,
    ContestStatus,
    LeagueId,
    WinSide,
    Leaderboard
} from "../../src/core/OspexTypes.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockContestModule} from "../mocks/MockContestModule.sol";
import {MockScorerModule} from "../mocks/MockScorerModule.sol";
import {MockFunctionsRouter} from "../mocks/MockFunctionsRouter.sol";
import {MockLinkToken} from "../mocks/MockLinkToken.sol";

/// @dev Minimal leaderboard mock for transfer lock checks
contract MockLeaderboardModuleInteg {
    mapping(uint256 => mapping(address => mapping(PositionType => uint256))) public s_lockedRisk;
    mapping(uint256 => mapping(address => mapping(PositionType => uint256))) public s_lockedProfit;
    mapping(uint256 => Leaderboard) private leaderboards;

    function getLeaderboard(uint256 leaderboardId) external view returns (Leaderboard memory) {
        return leaderboards[leaderboardId];
    }
}

/**
 * @title SecondaryMarketIntegrationTest
 * @notice End-to-end integration tests covering secondary-market position transfers
 *         through settlement and claiming.
 *
 * @dev Tests verify that positions purchased on the secondary market are claimable
 *      with correct payouts after settlement. Each settlement outcome
 *      (Upper wins, Lower wins, Push, Void) is tested independently.
 *
 * Setup state:
 *   - seller (0x1) = maker, Upper, risk=10 USDC, profit=1 USDC
 *   - buyer  (0x2) = taker, Lower, risk=1 USDC,  profit=10 USDC
 *   - secondaryBuyer (0x4) = not yet positioned
 *   - PositionModule holds 11 USDC
 */
contract SecondaryMarketIntegrationTest is Test {
    OspexCore public core;
    MockERC20 public token;
    SpeculationModule public speculationModule;
    PositionModule public positionModule;
    SecondaryMarketModule public market;
    MockContestModule public mockContestModule;
    TreasuryModule public treasuryModule;
    OracleModule public oracleModule;
    MockFunctionsRouter public mockRouter;
    MockLinkToken public mockLinkToken;
    MockScorerModule public mockMoneyline;
    MockScorerModule public mockSpread;

    address public seller = address(0x1);
    address public buyer = address(0x2);
    address public secondaryBuyer = address(0x4);
    uint256 public speculationId;

    address moneylineScorerAddr;
    address spreadScorerAddr;
    address totalScorerAddr;

    function setUp() public {
        core = new OspexCore();
        token = new MockERC20();
        speculationModule = new SpeculationModule(address(core), 3 days);
        positionModule = new PositionModule(address(core), address(token));
        treasuryModule = new TreasuryModule(
            address(core), address(token), address(0xFEED),
            1_000_000, 500_000, 500_000
        );

        mockRouter = new MockFunctionsRouter(address(0x456));
        mockLinkToken = new MockLinkToken();

        oracleModule = new OracleModule(
            address(core), address(mockRouter), address(mockLinkToken),
            bytes32(uint256(0x1234)), 1e18, address(0xA11CE)
        );

        mockContestModule = new MockContestModule();
        MockLeaderboardModuleInteg mockLeaderboard = new MockLeaderboardModuleInteg();
        market = new SecondaryMarketModule(address(core), address(token));

        mockMoneyline = new MockScorerModule();
        mockSpread = new MockScorerModule();
        MockScorerModule mockTotal = new MockScorerModule();
        moneylineScorerAddr = address(mockMoneyline);
        spreadScorerAddr = address(mockSpread);
        totalScorerAddr = address(mockTotal);

        bytes32[] memory types = new bytes32[](12);
        address[] memory addrs = new address[](12);
        types[0]  = core.CONTEST_MODULE();         addrs[0]  = address(mockContestModule);
        types[1]  = core.SPECULATION_MODULE();      addrs[1]  = address(speculationModule);
        types[2]  = core.POSITION_MODULE();         addrs[2]  = address(positionModule);
        types[3]  = core.MATCHING_MODULE();         addrs[3]  = address(this);
        types[4]  = core.ORACLE_MODULE();           addrs[4]  = address(oracleModule);
        types[5]  = core.TREASURY_MODULE();         addrs[5]  = address(treasuryModule);
        types[6]  = core.LEADERBOARD_MODULE();      addrs[6]  = address(mockLeaderboard);
        types[7]  = core.RULES_MODULE();            addrs[7]  = address(0xD007);
        types[8]  = core.SECONDARY_MARKET_MODULE(); addrs[8]  = address(market);
        types[9]  = core.MONEYLINE_SCORER_MODULE(); addrs[9]  = moneylineScorerAddr;
        types[10] = core.SPREAD_SCORER_MODULE();    addrs[10] = spreadScorerAddr;
        types[11] = core.TOTAL_SCORER_MODULE();     addrs[11] = totalScorerAddr;
        core.bootstrapModules(types, addrs);
        core.finalize();

        Contest memory contest = Contest({
            awayScore: 0, homeScore: 0, leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Verified, contestCreator: address(this),
            verifySourceHash: bytes32(0), marketUpdateSourceHash: bytes32(0),
            scoreContestSourceHash: bytes32(0),
            rundownId: "", sportspageId: "", jsonoddsId: ""
        });
        mockContestModule.setContest(1, contest);
        mockContestModule.setContestStartTime(1, uint32(block.timestamp));

        token.mint(seller, 1000e6);
        token.mint(buyer, 1000e6);
        token.mint(secondaryBuyer, 1000e6);
        vm.deal(seller, 10 ether);
        vm.deal(buyer, 10 ether);
        vm.deal(secondaryBuyer, 10 ether);

        vm.prank(seller);
        token.approve(address(positionModule), type(uint256).max);
        vm.prank(buyer);
        token.approve(address(positionModule), type(uint256).max);
        vm.prank(seller);
        token.approve(address(treasuryModule), type(uint256).max);
        vm.prank(buyer);
        token.approve(address(treasuryModule), type(uint256).max);

        // Matched pair: seller=maker(Upper, risk=10e6), buyer=taker(Lower, risk=1e6)
        speculationId = positionModule.recordFill(
            1, moneylineScorerAddr, 0, PositionType.Upper,
            seller, 10e6, buyer, 1e6
        );
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// @dev Seller lists full Upper position for 5 USDC, secondaryBuyer buys it
    function _sellFullPositionToSecondaryBuyer() internal {
        vm.prank(seller);
        market.listPositionForSale(speculationId, PositionType.Upper, 5e6, 10e6, 1e6);

        vm.startPrank(secondaryBuyer);
        token.approve(address(market), 5e6);
        bytes32 hash = market.getListingHash(speculationId, seller, PositionType.Upper);
        market.buyPosition(speculationId, seller, PositionType.Upper, 10e6, hash);
        vm.stopPrank();
    }

    /// @dev Score contest and settle the default speculation with the given outcome
    function _settleDefault(WinSide outcome) internal {
        if (outcome == WinSide.Void) {
            // Auto-void: warp past voidCooldown (3 days) without scoring the contest
            vm.warp(block.timestamp + 3 days + 1);
            speculationModule.settleSpeculation(speculationId);
        } else {
            vm.warp(block.timestamp + 1 hours);
            Contest memory scored = Contest({
                awayScore: 1, homeScore: 0, leagueId: LeagueId.NBA,
                contestStatus: ContestStatus.Scored, contestCreator: address(this),
                verifySourceHash: bytes32(0), marketUpdateSourceHash: bytes32(0),
                scoreContestSourceHash: bytes32(0),
                rundownId: "", sportspageId: "", jsonoddsId: ""
            });
            mockContestModule.setContest(1, scored);
            mockMoneyline.setWinSide(1, 0, outcome);
            speculationModule.settleSpeculation(speculationId);
        }
    }

    // =========================================================================
    // 1. E2E: Secondary buy -> Upper wins -> claims
    // =========================================================================

    /// @notice Upper wins: secondary buyer (Upper) gets risk+profit, original buyer (Lower) gets nothing
    function testE2E_SecondaryBuy_SettleUpperWins_Claims() public {
        _sellFullPositionToSecondaryBuyer();

        // Sanity: secondary buyer now holds the Upper position
        Position memory sbPos = positionModule.getPosition(speculationId, secondaryBuyer, PositionType.Upper);
        assertEq(sbPos.riskAmount, 10e6, "Secondary buyer should hold 10e6 risk");
        assertEq(sbPos.profitAmount, 1e6, "Secondary buyer should hold 1e6 profit");

        _settleDefault(WinSide.Away);

        // Secondary buyer claims Upper: payout = 10e6 + 1e6 = 11e6
        uint256 sbBalBefore = token.balanceOf(secondaryBuyer);
        vm.prank(secondaryBuyer);
        positionModule.claimPosition(speculationId, PositionType.Upper);
        assertEq(token.balanceOf(secondaryBuyer) - sbBalBefore, 11e6, "Upper winner payout");

        // Original buyer (Lower, loser) has no payout
        vm.prank(buyer);
        vm.expectRevert(PositionModule.PositionModule__NoPayout.selector);
        positionModule.claimPosition(speculationId, PositionType.Lower);

        // Seller has pending sale proceeds from the secondary sale
        assertEq(market.getPendingSaleProceeds(seller), 5e6, "Seller sale proceeds");
    }

    // =========================================================================
    // 2. E2E: Secondary buy -> Lower wins -> claims
    // =========================================================================

    /// @notice Lower wins: original buyer (Lower) gets risk+profit, secondary buyer (Upper) gets nothing
    function testE2E_SecondaryBuy_SettleLowerWins_Claims() public {
        _sellFullPositionToSecondaryBuyer();
        _settleDefault(WinSide.Home);

        // Original buyer claims Lower: payout = 1e6 + 10e6 = 11e6
        uint256 buyerBalBefore = token.balanceOf(buyer);
        vm.prank(buyer);
        positionModule.claimPosition(speculationId, PositionType.Lower);
        assertEq(token.balanceOf(buyer) - buyerBalBefore, 11e6, "Lower winner payout");

        // Secondary buyer (Upper, loser) has no payout
        vm.prank(secondaryBuyer);
        vm.expectRevert(PositionModule.PositionModule__NoPayout.selector);
        positionModule.claimPosition(speculationId, PositionType.Upper);

        assertEq(market.getPendingSaleProceeds(seller), 5e6, "Seller sale proceeds");
    }

    // =========================================================================
    // 3. E2E: Secondary buy -> Push -> claims
    // =========================================================================

    /// @notice Push: both sides receive their risk back
    function testE2E_SecondaryBuy_SettlePush_Claims() public {
        _sellFullPositionToSecondaryBuyer();
        _settleDefault(WinSide.Push);

        // Secondary buyer claims Upper: payout = risk = 10e6
        uint256 sbBalBefore = token.balanceOf(secondaryBuyer);
        vm.prank(secondaryBuyer);
        positionModule.claimPosition(speculationId, PositionType.Upper);
        assertEq(token.balanceOf(secondaryBuyer) - sbBalBefore, 10e6, "Upper push payout");

        // Original buyer claims Lower: payout = risk = 1e6
        uint256 buyerBalBefore = token.balanceOf(buyer);
        vm.prank(buyer);
        positionModule.claimPosition(speculationId, PositionType.Lower);
        assertEq(token.balanceOf(buyer) - buyerBalBefore, 1e6, "Lower push payout");

        // PositionModule fully drained for this speculation
        assertEq(token.balanceOf(address(positionModule)), 0, "PositionModule drained");
    }

    // =========================================================================
    // 4. E2E: Secondary buy -> Void (auto-void) -> claims
    // =========================================================================

    /// @notice Void (auto-void via cooldown): both sides receive their risk back
    function testE2E_SecondaryBuy_SettleVoid_Claims() public {
        _sellFullPositionToSecondaryBuyer();
        _settleDefault(WinSide.Void);

        // Secondary buyer claims Upper: payout = risk = 10e6
        uint256 sbBalBefore = token.balanceOf(secondaryBuyer);
        vm.prank(secondaryBuyer);
        positionModule.claimPosition(speculationId, PositionType.Upper);
        assertEq(token.balanceOf(secondaryBuyer) - sbBalBefore, 10e6, "Upper void payout");

        // Original buyer claims Lower: payout = risk = 1e6
        uint256 buyerBalBefore = token.balanceOf(buyer);
        vm.prank(buyer);
        positionModule.claimPosition(speculationId, PositionType.Lower);
        assertEq(token.balanceOf(buyer) - buyerBalBefore, 1e6, "Lower void payout");

        // PositionModule fully drained
        assertEq(token.balanceOf(address(positionModule)), 0, "PositionModule drained");
    }

    // =========================================================================
    // 5. Same user holds both Upper and Lower -> Push -> both claims succeed
    // =========================================================================

    /**
     * @notice Alice is taker (Upper) on fill 1, then maker (Lower) on fill 2.
     *         After Push settlement, both positions claim independently.
     *
     * Fill 1: bob=maker(Lower,10e6), alice=taker(Upper,2e6)
     * Fill 2: alice=maker(Lower,5e6), charlie=taker(Upper,1e6)
     *
     * Alice positions after fills:
     *   Upper: risk=2e6, profit=10e6
     *   Lower: risk=5e6, profit=1e6
     *
     * Push payout: Upper=2e6 + Lower=5e6 = 7e6 = total risk in
     */
    function testE2E_SameUserBothSides_Push_BothClaim() public {
        address alice = address(0x10);
        address bob = address(0x11);
        address charlie = address(0x12);

        token.mint(alice, 1000e6);
        token.mint(bob, 1000e6);
        token.mint(charlie, 1000e6);

        vm.prank(alice);
        token.approve(address(positionModule), type(uint256).max);
        vm.prank(bob);
        token.approve(address(positionModule), type(uint256).max);
        vm.prank(charlie);
        token.approve(address(positionModule), type(uint256).max);
        vm.prank(alice);
        token.approve(address(treasuryModule), type(uint256).max);
        vm.prank(bob);
        token.approve(address(treasuryModule), type(uint256).max);
        vm.prank(charlie);
        token.approve(address(treasuryModule), type(uint256).max);

        // Fill 1: bob=maker(Lower,10e6), alice=taker(Upper,2e6)
        // Creates new speculation (contestId=1, spreadScorer, lineTicks=42)
        uint256 specId = positionModule.recordFill(
            1, spreadScorerAddr, 42, PositionType.Lower,
            bob, 10e6, alice, 2e6
        );

        // Fill 2 on same speculation: alice=maker(Lower,5e6), charlie=taker(Upper,1e6)
        uint256 specId2 = positionModule.recordFill(
            1, spreadScorerAddr, 42, PositionType.Lower,
            alice, 5e6, charlie, 1e6
        );
        assertEq(specId, specId2, "Both fills on same speculation");

        // Verify alice has both sides
        Position memory aliceUpper = positionModule.getPosition(specId, alice, PositionType.Upper);
        Position memory aliceLower = positionModule.getPosition(specId, alice, PositionType.Lower);
        assertEq(aliceUpper.riskAmount, 2e6, "Alice Upper risk");
        assertEq(aliceUpper.profitAmount, 10e6, "Alice Upper profit");
        assertEq(aliceLower.riskAmount, 5e6, "Alice Lower risk");
        assertEq(aliceLower.profitAmount, 1e6, "Alice Lower profit");

        // Settle with Push
        vm.warp(block.timestamp + 1 hours);
        Contest memory scored = Contest({
            awayScore: 1, homeScore: 0, leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored, contestCreator: address(this),
            verifySourceHash: bytes32(0), marketUpdateSourceHash: bytes32(0),
            scoreContestSourceHash: bytes32(0),
            rundownId: "", sportspageId: "", jsonoddsId: ""
        });
        mockContestModule.setContest(1, scored);
        mockSpread.setWinSide(1, 42, WinSide.Push);
        speculationModule.settleSpeculation(specId);

        // Alice claims Upper: payout = risk = 2e6
        uint256 aliceBal0 = token.balanceOf(alice);
        vm.prank(alice);
        positionModule.claimPosition(specId, PositionType.Upper);
        uint256 upperPayout = token.balanceOf(alice) - aliceBal0;
        assertEq(upperPayout, 2e6, "Alice Upper push payout");

        // Alice claims Lower: payout = risk = 5e6
        uint256 aliceBal1 = token.balanceOf(alice);
        vm.prank(alice);
        positionModule.claimPosition(specId, PositionType.Lower);
        uint256 lowerPayout = token.balanceOf(alice) - aliceBal1;
        assertEq(lowerPayout, 5e6, "Alice Lower push payout");

        // Net payout = total risk in
        assertEq(upperPayout + lowerPayout, 2e6 + 5e6, "Net payout equals total risk");

        // Both positions marked claimed
        assertTrue(
            positionModule.getPosition(specId, alice, PositionType.Upper).claimed,
            "Alice Upper claimed"
        );
        assertTrue(
            positionModule.getPosition(specId, alice, PositionType.Lower).claimed,
            "Alice Lower claimed"
        );
    }

    // =========================================================================
    // 6. Partial secondary fill -> cancel residual -> seller claims remaining
    // =========================================================================

    /**
     * @notice Seller lists 100e6 risk. Secondary buyer takes 60e6. Seller cancels the
     *         remaining 40e6 listing. After settlement (Upper wins), seller claims 44e6
     *         on the residual position.
     *
     * Listing: price=50, risk=100, profit=10
     * Partial buy: 60 risk -> 6 profit, 30 price
     * Residual listing: risk=40, profit=4, price=20 -> cancelled
     * Seller remaining position: risk=40, profit=4
     * Upper wins payout: 40+4 = 44
     */
    function testE2E_PartialFill_CancelResidual_SellerClaims() public {
        // Create a larger position on a separate speculation
        uint256 specId = positionModule.recordFill(
            1, spreadScorerAddr, 99, PositionType.Upper,
            seller, 100e6, buyer, 10e6
        );

        // Seller lists full position: price=50e6, risk=100e6, profit=10e6
        vm.prank(seller);
        market.listPositionForSale(specId, PositionType.Upper, 50e6, 100e6, 10e6);

        // Secondary buyer takes 60e6 of risk (purchasePrice = 30e6)
        vm.startPrank(secondaryBuyer);
        token.approve(address(market), 30e6);
        bytes32 hash = market.getListingHash(specId, seller, PositionType.Upper);
        market.buyPosition(specId, seller, PositionType.Upper, 60e6, hash);
        vm.stopPrank();

        // Verify residual listing
        SaleListing memory listing = market.getSaleListing(specId, seller, PositionType.Upper);
        assertEq(listing.riskAmount, 40e6, "Residual listing risk");
        assertEq(listing.profitAmount, 4e6, "Residual listing profit");
        assertEq(listing.price, 20e6, "Residual listing price");

        // Seller cancels residual listing
        vm.prank(seller);
        market.cancelListing(specId, PositionType.Upper);

        // Listing deleted
        SaleListing memory cancelled = market.getSaleListing(specId, seller, PositionType.Upper);
        assertEq(cancelled.riskAmount, 0, "Listing should be deleted");

        // Seller's position retains the unsold 40e6 risk, 4e6 profit
        Position memory sellerPos = positionModule.getPosition(specId, seller, PositionType.Upper);
        assertEq(sellerPos.riskAmount, 40e6, "Seller remaining risk");
        assertEq(sellerPos.profitAmount, 4e6, "Seller remaining profit");
        assertFalse(sellerPos.claimed, "Seller position not yet claimed");

        // Settle with Upper wins
        vm.warp(block.timestamp + 1 hours);
        Contest memory scored = Contest({
            awayScore: 3, homeScore: 1, leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored, contestCreator: address(this),
            verifySourceHash: bytes32(0), marketUpdateSourceHash: bytes32(0),
            scoreContestSourceHash: bytes32(0),
            rundownId: "", sportspageId: "", jsonoddsId: ""
        });
        mockContestModule.setContest(1, scored);
        mockSpread.setWinSide(1, 99, WinSide.Away);
        speculationModule.settleSpeculation(specId);

        // Seller claims remaining 40e6 + 4e6 = 44e6
        uint256 sellerBalBefore = token.balanceOf(seller);
        vm.prank(seller);
        positionModule.claimPosition(specId, PositionType.Upper);
        assertEq(token.balanceOf(seller) - sellerBalBefore, 44e6, "Seller remaining payout");

        assertTrue(
            positionModule.getPosition(specId, seller, PositionType.Upper).claimed,
            "Seller position claimed"
        );
    }
}
