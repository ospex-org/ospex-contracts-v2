// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {SecondaryMarketModule} from "../../src/modules/SecondaryMarketModule.sol";
import {SpeculationModule} from "../../src/modules/SpeculationModule.sol";
import {PositionModule} from "../../src/modules/PositionModule.sol";
import {TreasuryModule} from "../../src/modules/TreasuryModule.sol";
import {OracleModule} from "../../src/modules/OracleModule.sol";
import {OspexCore} from "../../src/core/OspexCore.sol";
import {PositionType, SaleListing, Position, Contest, ContestStatus, LeagueId} from "../../src/core/OspexTypes.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockContestModule} from "../mocks/MockContestModule.sol";
import {MockScorerModule} from "../mocks/MockScorerModule.sol";
import {MockFunctionsRouter} from "../mocks/MockFunctionsRouter.sol";
import {MockLinkToken} from "../mocks/MockLinkToken.sol";
import {Leaderboard} from "../../src/core/OspexTypes.sol";

contract MockLeaderboardModuleSM {
    mapping(uint256 => mapping(address => mapping(PositionType => uint256))) public s_lockedRisk;
    mapping(uint256 => mapping(address => mapping(PositionType => uint256))) public s_lockedProfit;
    mapping(uint256 => Leaderboard) private leaderboards;

    function getLeaderboard(uint256 leaderboardId) external view returns (Leaderboard memory) {
        return leaderboards[leaderboardId];
    }
}

contract SecondaryMarketModuleTest is Test {
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
    address public seller = address(0x1);
    address public buyer = address(0x2);
    address public nonAdmin = address(0x3);
    uint256 public speculationId;
    PositionType public positionType = PositionType.Upper;

    // Registered scorer module addresses
    address moneylineScorerAddr;
    address spreadScorerAddr;
    address totalScorerAddr;

    function setUp() public {
        // Deploy core and modules
        core = new OspexCore();

        token = new MockERC20();
        speculationModule = new SpeculationModule(address(core), 3 days);
        positionModule = new PositionModule(
            address(core),
            address(token)
        );
        treasuryModule = new TreasuryModule(
            address(core), address(token), address(0xFEED),
            1_000_000, 500_000, 500_000
        );

        // Create mock Chainlink contracts
        mockRouter = new MockFunctionsRouter(address(0x456)); // dummy linkToken for router
        mockLinkToken = new MockLinkToken();
        bytes32 donId = bytes32(uint256(0x1234));

        // Create OracleModule with proper mocks
        oracleModule = new OracleModule(
            address(core),
            address(mockRouter),
            address(mockLinkToken),
            donId,
            1e18,
            address(0xA11CE) // approvedSigner (not used in secondary market tests)
        );

        // Create and register MockContestModule
        mockContestModule = new MockContestModule();

        // Register mock leaderboard module (needed for transfer lock checks)
        MockLeaderboardModuleSM mockLeaderboard = new MockLeaderboardModuleSM();

        // Deploy secondary market module (2 params: core, token)
        market = new SecondaryMarketModule(
            address(core),
            address(token)
        );

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
        types[0]  = core.CONTEST_MODULE();           addrs[0]  = address(mockContestModule);
        types[1]  = core.SPECULATION_MODULE();        addrs[1]  = address(speculationModule);
        types[2]  = core.POSITION_MODULE();           addrs[2]  = address(positionModule);
        types[3]  = core.MATCHING_MODULE();           addrs[3]  = address(this); // test contract acts as MATCHING_MODULE
        types[4]  = core.ORACLE_MODULE();             addrs[4]  = address(oracleModule);
        types[5]  = core.TREASURY_MODULE();           addrs[5]  = address(treasuryModule);
        types[6]  = core.LEADERBOARD_MODULE();        addrs[6]  = address(mockLeaderboard);
        types[7]  = core.RULES_MODULE();              addrs[7]  = address(0xD007);
        types[8]  = core.SECONDARY_MARKET_MODULE();   addrs[8]  = address(market);
        types[9]  = core.MONEYLINE_SCORER_MODULE();   addrs[9]  = moneylineScorerAddr;
        types[10] = core.SPREAD_SCORER_MODULE();      addrs[10] = spreadScorerAddr;
        types[11] = core.TOTAL_SCORER_MODULE();       addrs[11] = totalScorerAddr;
        core.bootstrapModules(types, addrs);
        core.finalize();

        // Set up a verified contest for speculation creation
        Contest memory contest = Contest({
            awayScore: 0,
            homeScore: 0,
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Verified,
            contestCreator: address(this),
            verifySourceHash: bytes32(0),
            marketUpdateSourceHash: bytes32(0),
            scoreContestSourceHash: bytes32(0),
            rundownId: "",
            sportspageId: "",
            jsonoddsId: ""
        });
        mockContestModule.setContest(1, contest);
        mockContestModule.setContestStartTime(1, uint32(block.timestamp));

        // Fund seller and buyer
        token.mint(seller, 1000e6);
        token.mint(buyer, 1000e6);

        // Give accounts some ETH
        vm.deal(seller, 10 ether);
        vm.deal(buyer, 10 ether);

        // Seller and buyer approve PositionModule
        vm.prank(seller);
        token.approve(address(positionModule), type(uint256).max);
        vm.prank(buyer);
        token.approve(address(positionModule), type(uint256).max);

        // Seller and buyer approve TreasuryModule for speculation creation fees
        vm.prank(seller);
        token.approve(address(treasuryModule), type(uint256).max);
        vm.prank(buyer);
        token.approve(address(treasuryModule), type(uint256).max);

        // Create matched pair via recordFill: seller is maker (Upper), buyer is taker (Lower)
        // At 1.10 odds: makerRisk=10e6, takerRisk=1e6
        // Seller position: {riskAmount:10e6, profitAmount:1e6, Upper}
        // Buyer position:  {riskAmount:1e6, profitAmount:10e6, Lower}
        speculationId = positionModule.recordFill(
            1,                    // contestId
            moneylineScorerAddr,  // scorer (must be a registered scorer module)
            0,                    // lineTicks (0 for moneyline)
            positionType,         // makerPositionType = Upper
            seller,               // maker
            10e6,                 // makerRisk
            buyer,                // taker
            1e6                   // takerRisk
        );
    }

    function testListPositionForSale() public {
        vm.startPrank(seller);
        uint256 price = 5e6; // 5 USDC
        uint256 riskAmount = 10e6;
        uint256 profitAmount = 1e6;
        market.listPositionForSale(
            speculationId,
            positionType,
            price,
            riskAmount,
            profitAmount
        );
        SaleListing memory listing = market.getSaleListing(
            speculationId,
            seller,
            positionType
        );
        assertEq(listing.price, price, "Price should match");
        assertEq(listing.riskAmount, riskAmount, "Risk amount should match");
        assertEq(listing.profitAmount, profitAmount, "Profit amount should match");
        vm.stopPrank();
    }

    // --- SecondaryMarketModule Comprehensive Tests ---

    // 1. Listing a Position for Sale
    function testListPositionForSale_RevertsIfPriceZero() public {
        vm.startPrank(seller);
        uint256 price = 0;
        uint256 riskAmount = 10e6;
        uint256 profitAmount = 1e6;
        vm.expectRevert(
            SecondaryMarketModule.SecondaryMarketModule__InvalidAmount.selector
        );
        market.listPositionForSale(
            speculationId,
            positionType,
            price,
            riskAmount,
            profitAmount
        );
        vm.stopPrank();
    }

    function testListPositionForSale_RevertsIfRiskAmountAbovePosition() public {
        address notMatched = address(0xB0B);
        vm.startPrank(notMatched);
        uint256 price = 5e6;
        uint256 riskAmount = 10e6;
        uint256 profitAmount = 1e6;
        vm.expectRevert(
            abi.encodeWithSelector(
                SecondaryMarketModule
                    .SecondaryMarketModule__AmountAboveMaximum
                    .selector,
                riskAmount
            )
        );
        market.listPositionForSale(
            speculationId,
            positionType,
            price,
            riskAmount,
            profitAmount
        );
        vm.stopPrank();
    }

    function testListPositionForSale_RevertsIfPositionClaimed() public {
        // First settle and claim the position
        vm.warp(block.timestamp + 1 hours);
        Contest memory scored = Contest({
            awayScore: 3, homeScore: 1, leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored, contestCreator: address(this),
            verifySourceHash: bytes32(0), marketUpdateSourceHash: bytes32(0), scoreContestSourceHash: bytes32(0),
            rundownId: "", sportspageId: "", jsonoddsId: ""
        });
        mockContestModule.setContest(1, scored);
        speculationModule.settleSpeculation(speculationId);

        // Claim the position
        vm.prank(seller);
        positionModule.claimPosition(speculationId, positionType);

        // Try to list — should revert (speculation not active since it's settled)
        vm.prank(seller);
        vm.expectRevert(
            SecondaryMarketModule.SecondaryMarketModule__SpeculationNotActive.selector
        );
        market.listPositionForSale(speculationId, positionType, 5e6, 10e6, 1e6);
    }

    function testBuyPosition_RevertsIfPositionClaimed() public {
        // List first
        vm.prank(seller);
        market.listPositionForSale(speculationId, positionType, 5e6, 10e6, 1e6);

        // Settle and claim
        vm.warp(block.timestamp + 1 hours);
        Contest memory scored = Contest({
            awayScore: 3, homeScore: 1, leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored, contestCreator: address(this),
            verifySourceHash: bytes32(0), marketUpdateSourceHash: bytes32(0), scoreContestSourceHash: bytes32(0),
            rundownId: "", sportspageId: "", jsonoddsId: ""
        });
        mockContestModule.setContest(1, scored);
        speculationModule.settleSpeculation(speculationId);

        vm.prank(seller);
        positionModule.claimPosition(speculationId, positionType);

        // Try to buy — should revert (speculation not active since it's settled)
        vm.prank(buyer);
        vm.expectRevert(
            SecondaryMarketModule.SecondaryMarketModule__SpeculationNotActive.selector
        );
        market.buyPosition(speculationId, seller, positionType, 5e6);
    }

    // 2. Buying a Position
    function testBuyPosition_RevertsIfBuyerIsSeller() public {
        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 riskAmount = 10e6;
        uint256 profitAmount = 1e6;
        market.listPositionForSale(
            speculationId,
            positionType,
            price,
            riskAmount,
            profitAmount
        );
        vm.expectRevert(
            SecondaryMarketModule
                .SecondaryMarketModule__CannotBuyOwnPosition
                .selector
        );
        market.buyPosition(
            speculationId,
            seller,
            positionType,
            1e6
        );
        vm.stopPrank();
    }

    function testBuyPosition_RevertsIfAmountZero() public {
        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 riskAmount = 10e6;
        uint256 profitAmount = 1e6;
        market.listPositionForSale(
            speculationId,
            positionType,
            price,
            riskAmount,
            profitAmount
        );
        vm.stopPrank();
        vm.startPrank(buyer);
        vm.expectRevert(
            SecondaryMarketModule
                .SecondaryMarketModule__InvalidAmount
                .selector
        );
        market.buyPosition(speculationId, seller, positionType, 0);
        vm.stopPrank();
    }

    function testBuyPosition_RevertsIfAmountAboveListing() public {
        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 riskAmount = 10e6;
        uint256 profitAmount = 1e6;
        market.listPositionForSale(
            speculationId,
            positionType,
            price,
            riskAmount,
            profitAmount
        );
        vm.stopPrank();
        vm.startPrank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                SecondaryMarketModule
                    .SecondaryMarketModule__AmountAboveMaximum
                    .selector,
                riskAmount + 1
            )
        );
        market.buyPosition(
            speculationId,
            seller,
            positionType,
            riskAmount + 1
        );
        vm.stopPrank();
    }

    // 3. Claiming Sale Proceeds
    function testClaimSaleProceeds_RevertsIfNoProceeds() public {
        vm.startPrank(seller);
        vm.expectRevert(
            SecondaryMarketModule
                .SecondaryMarketModule__NoProceedsAvailable
                .selector
        );
        market.claimSaleProceeds();
        vm.stopPrank();
    }

    // 4. Canceling a Listing
    function testCancelListing_RevertsIfListingNotActive() public {
        vm.startPrank(seller);
        vm.expectRevert(
            SecondaryMarketModule
                .SecondaryMarketModule__ListingNotActive
                .selector
        );
        market.cancelListing(speculationId, positionType);
        vm.stopPrank();
    }

    // 5. Updating a Listing
    function testUpdateListing_RevertsIfListingNotActive() public {
        vm.startPrank(seller);
        vm.expectRevert(
            SecondaryMarketModule
                .SecondaryMarketModule__ListingNotActive
                .selector
        );
        market.updateListing(
            speculationId,
            positionType,
            10e6,
            10e6,
            1e6
        );
        vm.stopPrank();
    }

    function testUpdateListing_RevertsIfSpeculationNotOpen() public {
        // Create a new speculation via recordFill with a spread scorer
        uint256 testSpecId = positionModule.recordFill(
            1,                    // contestId
            spreadScorerAddr,     // scorer (registered spread scorer)
            42,                   // lineTicks
            positionType,         // makerPositionType = Upper
            seller,               // maker
            10e6,                 // makerRisk
            buyer,                // taker
            1e6                   // takerRisk
        );

        // Now seller can list the position with the matched amount
        vm.startPrank(seller);
        market.listPositionForSale(
            testSpecId,
            positionType,
            1e6, // price
            1e6, // riskAmount
            1e6  // profitAmount
        );
        vm.stopPrank();

        // Warp to after speculation start time
        vm.warp(block.timestamp + 1 hours);

        // Setup contest for settlement
        Contest memory contest = Contest({
            awayScore: 1,
            homeScore: 0,
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored, // Set to Scored
            contestCreator: address(this),
            verifySourceHash: bytes32(0),
            marketUpdateSourceHash: bytes32(0),
            scoreContestSourceHash: bytes32(0),
            rundownId: "",
            sportspageId: "",
            jsonoddsId: ""
        });
        mockContestModule.setContest(1, contest);

        // Settle the speculation to close it (permissionless)
        speculationModule.settleSpeculation(testSpecId);

        // Try to update the listing after speculation is closed
        vm.startPrank(seller);
        uint256 newPrice = 2e6;
        uint256 newRiskAmount = 1e6;
        uint256 newProfitAmount = 1e6;
        vm.expectRevert(
            SecondaryMarketModule
                .SecondaryMarketModule__SpeculationNotActive
                .selector
        );
        market.updateListing(
            testSpecId,
            positionType,
            newPrice,
            newRiskAmount,
            newProfitAmount
        );
        vm.stopPrank();
    }

    // 6. View Functions
    function testGetSaleListing_ReturnsCorrectListing() public {
        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 riskAmount = 10e6;
        uint256 profitAmount = 1e6;
        market.listPositionForSale(
            speculationId,
            positionType,
            price,
            riskAmount,
            profitAmount
        );
        SaleListing memory listing = market.getSaleListing(
            speculationId,
            seller,
            positionType
        );
        assertEq(listing.price, price, "Price should match");
        assertEq(listing.riskAmount, riskAmount, "Risk amount should match");
        assertEq(listing.profitAmount, profitAmount, "Profit amount should match");
        vm.stopPrank();
    }

    function testGetPendingSaleProceeds_ReturnsCorrectAmount() public {
        // List and buy a position
        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 riskAmount = 10e6;
        uint256 profitAmount = 1e6;
        market.listPositionForSale(
            speculationId,
            positionType,
            price,
            riskAmount,
            profitAmount
        );
        vm.stopPrank();
        vm.startPrank(buyer);
        token.approve(address(market), price);
        market.buyPosition(
            speculationId,
            seller,
            positionType,
            riskAmount
        );
        vm.stopPrank();
        uint256 proceeds = market.getPendingSaleProceeds(seller);
        assertEq(proceeds, price, "Proceeds should match sale price");

        // Verify buyer position after purchase
        // profitAmount = (listing.profitAmount * riskAmount) / listing.riskAmount = (1e6 * 10e6) / 10e6 = 1e6
        Position memory buyerPos = positionModule.getPosition(speculationId, buyer, positionType);
        assertEq(buyerPos.riskAmount, 10e6, "Buyer should receive risk");
        assertEq(buyerPos.profitAmount, 1e6, "Buyer should receive profit");

        // Verify seller position decreased
        Position memory sellerPos = positionModule.getPosition(speculationId, seller, positionType);
        assertEq(sellerPos.riskAmount, 10e6 - 10e6, "Seller risk should decrease");
        assertEq(sellerPos.profitAmount, 1e6 - 1e6, "Seller profit should decrease");
    }

    // 7. Event Emission (example for listing)
    function testListPositionForSale_EmitsEvents() public {
        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 riskAmount = 10e6;
        uint256 profitAmount = 1e6;
        // Expect local event
        vm.expectEmit(true, true, false, true);
        emit SecondaryMarketModule.PositionListed(
            speculationId,
            seller,
            positionType,
            price,
            riskAmount,
            profitAmount,
            uint32(block.timestamp)
        );
        // Expect core event (emitted by core contract)
        vm.expectEmit(true, true, false, true, address(core));
        emit OspexCore.CoreEventEmitted(
            keccak256("POSITION_LISTED"),
            address(market),
            abi.encode(
                speculationId,
                seller,
                positionType,
                price,
                riskAmount,
                profitAmount,
                uint32(block.timestamp)
            )
        );
        market.listPositionForSale(
            speculationId,
            positionType,
            price,
            riskAmount,
            profitAmount
        );
        vm.stopPrank();
    }

    // --- Additional Coverage for SecondaryMarketModule ---

    // 1. claimSaleProceeds
    function testClaimSaleProceeds_HappyPathAndEvents() public {
        // List and buy a position to generate proceeds
        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 riskAmount = 10e6;
        uint256 profitAmount = 1e6;
        market.listPositionForSale(
            speculationId,
            positionType,
            price,
            riskAmount,
            profitAmount
        );
        vm.stopPrank();
        vm.startPrank(buyer);
        token.approve(address(market), price);
        market.buyPosition(
            speculationId,
            seller,
            positionType,
            riskAmount
        );
        vm.stopPrank();

        // Verify buyer position after purchase
        // profitAmount = (1e6 * 10e6) / 10e6 = 1e6
        Position memory buyerPosAfterClaim = positionModule.getPosition(speculationId, buyer, positionType);
        assertEq(buyerPosAfterClaim.riskAmount, 10e6, "Buyer should receive risk");
        assertEq(buyerPosAfterClaim.profitAmount, 1e6, "Buyer should receive profit");

        // Verify seller position decreased
        Position memory sellerPosAfterClaim = positionModule.getPosition(speculationId, seller, positionType);
        assertEq(sellerPosAfterClaim.riskAmount, 0, "Seller risk should decrease");
        assertEq(sellerPosAfterClaim.profitAmount, 0, "Seller profit should decrease");

        // Seller claims proceeds
        vm.startPrank(seller);
        uint256 before = token.balanceOf(seller);
        vm.expectEmit(true, false, false, true);
        emit SecondaryMarketModule.SaleProceedsClaimed(seller, price);
        vm.expectEmit(true, true, false, true, address(core));
        emit OspexCore.CoreEventEmitted(
            keccak256("SALE_PROCEEDS_CLAIMED"),
            address(market),
            abi.encode(seller, price)
        );
        market.claimSaleProceeds();
        uint256 afterBal = token.balanceOf(seller);
        assertEq(afterBal, before + price, "Seller should receive proceeds");
        // Proceeds should be zero after claim
        assertEq(
            market.getPendingSaleProceeds(seller),
            0,
            "Proceeds should be zero after claim"
        );
        vm.stopPrank();
    }

    // 2. cancelListing
    function testCancelListing_HappyPathAndEvents() public {
        // List a position
        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 riskAmount = 10e6;
        uint256 profitAmount = 1e6;
        market.listPositionForSale(
            speculationId,
            positionType,
            price,
            riskAmount,
            profitAmount
        );
        // Cancel listing
        vm.expectEmit(true, true, false, true);
        emit SecondaryMarketModule.ListingCancelled(
            speculationId,
            seller,
            positionType
        );
        vm.expectEmit(true, true, false, true, address(core));
        emit OspexCore.CoreEventEmitted(
            keccak256("LISTING_CANCELLED"),
            address(market),
            abi.encode(speculationId, seller, positionType)
        );
        market.cancelListing(speculationId, positionType);
        SaleListing memory listing = market.getSaleListing(
            speculationId,
            seller,
            positionType
        );
        assertEq(listing.riskAmount, 0, "Listing should be deleted");
        vm.stopPrank();
    }
    function testCancelListing_RevertsIfPositionDoesNotExist() public {
        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 riskAmount = 10e6;
        uint256 profitAmount = 1e6;
        market.listPositionForSale(
            speculationId,
            positionType,
            price,
            riskAmount,
            profitAmount
        );
        // Try to cancel a listing for a different positionType (Lower) that doesn't exist
        vm.expectRevert(
            SecondaryMarketModule
                .SecondaryMarketModule__ListingNotActive
                .selector
        );
        market.cancelListing(speculationId, PositionType.Lower);
        vm.stopPrank();
    }
    function testCancelListing_RevertsIfPositionClaimed() public {
        // Create a separate fill with spread scorer so we can settle and claim
        uint256 testSpecId = positionModule.recordFill(
            1,                     // contestId
            spreadScorerAddr,      // scorer (registered spread scorer - defaults to Away = Upper wins)
            42,                    // lineTicks
            positionType,          // makerPositionType = Upper
            seller,                // maker
            10e6,                  // makerRisk
            buyer,                 // taker
            1e6                    // takerRisk
        );

        // Seller lists the position
        vm.prank(seller);
        market.listPositionForSale(testSpecId, positionType, 5e6, 10e6, 1e6);

        // Settle: warp past start, set contest as Scored, MockScorerModule returns Away (Upper wins)
        vm.warp(block.timestamp + 1 hours);
        Contest memory contest = Contest({
            awayScore: 1,
            homeScore: 0,
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored,
            contestCreator: address(this),
            verifySourceHash: bytes32(0),
            marketUpdateSourceHash: bytes32(0),
            scoreContestSourceHash: bytes32(0),
            rundownId: "",
            sportspageId: "",
            jsonoddsId: ""
        });
        mockContestModule.setContest(1, contest);
        speculationModule.settleSpeculation(testSpecId);

        // Seller claims winnings (Upper won)
        vm.prank(seller);
        positionModule.claimPosition(testSpecId, positionType);

        // Now try to cancel the listing -- position is claimed, should revert
        vm.prank(seller);
        vm.expectRevert(SecondaryMarketModule.SecondaryMarketModule__PositionAlreadyClaimed.selector);
        market.cancelListing(testSpecId, positionType);
    }

    // 3. updateListing
    function testUpdateListing_HappyPathAndEvents() public {
        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 riskAmount = 10e6;
        uint256 profitAmount = 1e6;
        market.listPositionForSale(
            speculationId,
            positionType,
            price,
            riskAmount,
            profitAmount
        );
        uint256 newPrice = 6e6;
        uint256 newRiskAmount = 8e6;
        uint256 newProfitAmount = 1e6;
        vm.expectEmit(true, true, false, true);
        emit SecondaryMarketModule.ListingUpdated(
            speculationId,
            seller,
            positionType,
            price,
            newPrice,
            riskAmount,
            newRiskAmount,
            profitAmount,
            newProfitAmount
        );
        vm.expectEmit(true, true, false, true, address(core));
        emit OspexCore.CoreEventEmitted(
            keccak256("LISTING_UPDATED"),
            address(market),
            abi.encode(
                speculationId,
                seller,
                positionType,
                price,
                newPrice,
                riskAmount,
                newRiskAmount,
                profitAmount,
                newProfitAmount
            )
        );
        market.updateListing(
            speculationId,
            positionType,
            newPrice,
            newRiskAmount,
            newProfitAmount
        );
        SaleListing memory listing = market.getSaleListing(
            speculationId,
            seller,
            positionType
        );
        assertEq(listing.price, newPrice, "Price should update");
        assertEq(listing.riskAmount, newRiskAmount, "Risk amount should update");
        assertEq(listing.profitAmount, newProfitAmount, "Profit amount should update");
        vm.stopPrank();
    }
    function testUpdateListing_RevertsIfNewRiskAmountAbovePosition() public {
        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 riskAmount = 10e6;
        uint256 profitAmount = 1e6;
        market.listPositionForSale(
            speculationId,
            positionType,
            price,
            riskAmount,
            profitAmount
        );
        uint256 newRiskAmount = 20e6;
        vm.expectRevert(
            abi.encodeWithSelector(
                SecondaryMarketModule
                    .SecondaryMarketModule__AmountAboveMaximum
                    .selector,
                newRiskAmount
            )
        );
        market.updateListing(
            speculationId,
            positionType,
            0,
            newRiskAmount,
            0
        );
        vm.stopPrank();
    }

    // 4. getModuleType
    function testGetModuleType_ReturnsCorrectType() public view {
        assertEq(
            market.getModuleType(),
            keccak256("SECONDARY_MARKET_MODULE"),
            "Module type should match"
        );
    }

    // 5. buyPosition happy path
    function testBuyPosition_HappyPathAndEvents() public {
        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 riskAmount = 10e6;
        uint256 profitAmount = 1e6;
        market.listPositionForSale(
            speculationId,
            positionType,
            price,
            riskAmount,
            profitAmount
        );
        vm.stopPrank();
        vm.startPrank(buyer);
        token.approve(address(market), price);
        // buyPosition derives profitAmount and purchasePrice proportionally
        // Buying full riskAmount: profitAmount = (1e6 * 10e6) / 10e6 = 1e6, purchasePrice = (5e6 * 10e6) / 10e6 = 5e6
        vm.expectEmit(true, true, true, true);
        emit SecondaryMarketModule.PositionSold(
            speculationId,
            seller,
            positionType,
            buyer,
            riskAmount,
            profitAmount,
            price
        );
        vm.expectEmit(true, true, true, true, address(core));
        emit OspexCore.CoreEventEmitted(
            keccak256("POSITION_SOLD"),
            address(market),
            abi.encode(
                speculationId,
                seller,
                positionType,
                buyer,
                riskAmount,
                profitAmount,
                price
            )
        );
        market.buyPosition(
            speculationId,
            seller,
            positionType,
            riskAmount
        );
        vm.stopPrank();
        // Listing should be deleted
        SaleListing memory listing = market.getSaleListing(
            speculationId,
            seller,
            positionType
        );
        assertEq(listing.riskAmount, 0, "Listing should be deleted after full buy");
        // Proceeds should be correct
        assertEq(
            market.getPendingSaleProceeds(seller),
            price,
            "Proceeds should match sale price"
        );

        // Verify buyer position after purchase
        // profitAmount = (1e6 * 10e6) / 10e6 = 1e6
        Position memory buyerPosHappy = positionModule.getPosition(speculationId, buyer, positionType);
        assertEq(buyerPosHappy.riskAmount, 10e6, "Buyer should receive risk");
        assertEq(buyerPosHappy.profitAmount, 1e6, "Buyer should receive profit");

        // Verify seller position decreased
        Position memory sellerPosHappy = positionModule.getPosition(speculationId, seller, positionType);
        assertEq(sellerPosHappy.riskAmount, 0, "Seller risk should decrease");
        assertEq(sellerPosHappy.profitAmount, 0, "Seller profit should decrease");
    }

    function testConstructor_RevertsOnZeroAddresses() public {
        address valid = address(token);
        address zero = address(0);
        vm.expectRevert(
            SecondaryMarketModule.SecondaryMarketModule__InvalidAddress.selector
        );
        new SecondaryMarketModule(zero, valid);
        vm.expectRevert(
            SecondaryMarketModule.SecondaryMarketModule__InvalidAddress.selector
        );
        new SecondaryMarketModule(valid, zero);
    }

    function testBuyPosition_PartialBuyReducesListing() public {
        vm.startPrank(seller);
        uint256 price = 10e6;
        uint256 riskAmount = 10e6;
        uint256 profitAmount = 1e6;
        market.listPositionForSale(
            speculationId,
            positionType,
            price,
            riskAmount,
            profitAmount
        );
        vm.stopPrank();
        vm.startPrank(buyer);
        token.approve(address(market), price / 2);
        market.buyPosition(
            speculationId,
            seller,
            positionType,
            riskAmount / 2
        );
        vm.stopPrank();
        SaleListing memory listing = market.getSaleListing(
            speculationId,
            seller,
            positionType
        );
        assertEq(
            listing.riskAmount,
            riskAmount / 2,
            "Listing riskAmount should be reduced after partial buy"
        );
        assertEq(
            listing.price,
            price / 2,
            "Listing price should be reduced proportionally after partial buy"
        );
        // profitAmount should also be reduced proportionally
        assertEq(
            listing.profitAmount,
            profitAmount / 2,
            "Listing profitAmount should be reduced proportionally after partial buy"
        );

        // Verify buyer position after partial purchase
        // profitAmount = (1e6 * 5e6) / 10e6 = 500000 (0.5 USDC)
        Position memory buyerPosPartial = positionModule.getPosition(speculationId, buyer, positionType);
        assertEq(buyerPosPartial.riskAmount, 5e6, "Buyer should receive risk");
        assertEq(buyerPosPartial.profitAmount, 500000, "Buyer should receive profit");

        // Verify seller position decreased
        Position memory sellerPosPartial = positionModule.getPosition(speculationId, seller, positionType);
        assertEq(sellerPosPartial.riskAmount, 10e6 - 5e6, "Seller risk should decrease");
        assertEq(sellerPosPartial.profitAmount, 1e6 - 500000, "Seller profit should decrease");
    }
    function testUpdateListing_OnlyPrice() public {
        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 riskAmount = 10e6;
        uint256 profitAmount = 1e6;
        market.listPositionForSale(
            speculationId,
            positionType,
            price,
            riskAmount,
            profitAmount
        );
        uint256 newPrice = 6e6;
        market.updateListing(
            speculationId,
            positionType,
            newPrice,
            0,
            0
        );
        SaleListing memory listing = market.getSaleListing(
            speculationId,
            seller,
            positionType
        );
        assertEq(listing.price, newPrice, "Price should update");
        assertEq(listing.riskAmount, riskAmount, "Risk amount should not change");
        assertEq(listing.profitAmount, profitAmount, "Profit amount should not change");
        vm.stopPrank();
    }
    function testUpdateListing_OnlyRiskAmount() public {
        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 riskAmount = 10e6;
        uint256 profitAmount = 1e6;
        market.listPositionForSale(
            speculationId,
            positionType,
            price,
            riskAmount,
            profitAmount
        );
        uint256 newRiskAmount = 8e6;
        market.updateListing(
            speculationId,
            positionType,
            0,
            newRiskAmount,
            0
        );
        SaleListing memory listing = market.getSaleListing(
            speculationId,
            seller,
            positionType
        );
        assertEq(listing.price, price, "Price should not change");
        assertEq(listing.riskAmount, newRiskAmount, "Risk amount should update");
        assertEq(listing.profitAmount, profitAmount, "Profit amount should not change");
        vm.stopPrank();
    }
    function testUpdateListing_NeitherPriceNorAmounts() public {
        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 riskAmount = 10e6;
        uint256 profitAmount = 1e6;
        market.listPositionForSale(
            speculationId,
            positionType,
            price,
            riskAmount,
            profitAmount
        );
        market.updateListing(speculationId, positionType, 0, 0, 0);
        SaleListing memory listing = market.getSaleListing(
            speculationId,
            seller,
            positionType
        );
        assertEq(listing.price, price, "Price should not change");
        assertEq(listing.riskAmount, riskAmount, "Risk amount should not change");
        assertEq(listing.profitAmount, profitAmount, "Profit amount should not change");
        vm.stopPrank();
    }
    function testUpdateListing_AllFields() public {
        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 riskAmount = 10e6;
        uint256 profitAmount = 1e6;
        market.listPositionForSale(
            speculationId,
            positionType,
            price,
            riskAmount,
            profitAmount
        );
        uint256 newPrice = 6e6;
        uint256 newRiskAmount = 8e6;
        uint256 newProfitAmount = 1e6;
        market.updateListing(
            speculationId,
            positionType,
            newPrice,
            newRiskAmount,
            newProfitAmount
        );
        SaleListing memory listing = market.getSaleListing(
            speculationId,
            seller,
            positionType
        );
        assertEq(listing.price, newPrice, "Price should update");
        assertEq(listing.riskAmount, newRiskAmount, "Risk amount should update");
        assertEq(listing.profitAmount, newProfitAmount, "Profit amount should update");
        vm.stopPrank();
    }

    function testSecondaryMarket_Revert_ModuleNotSet() public {
        // Create a new core and market instance without registering required modules
        OspexCore newCore = new OspexCore();
        SecondaryMarketModule newMarket = new SecondaryMarketModule(
            address(newCore),
            address(token)
        );

        // Bootstrap only the market itself but NOT the speculation module
        // We need all 12 modules registered, but we use dummy addresses for most
        // and intentionally skip finalize so speculation module lookup fails
        // Actually: the module lookup via getModule returns address(0) when not registered,
        // so we just need to NOT register SPECULATION_MODULE.
        // But bootstrapModules requires all 12 for finalize(). So instead, just call
        // listPositionForSale on a non-finalized core that doesn't have SPECULATION_MODULE.

        // Try to list a position - this will call _getModule for SPECULATION_MODULE
        // which won't be registered, causing the revert
        vm.startPrank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(
                SecondaryMarketModule.SecondaryMarketModule__ModuleNotSet.selector,
                keccak256("SPECULATION_MODULE")
            )
        );
        newMarket.listPositionForSale(
            speculationId,
            positionType,
            5e6, // price
            10e6, // riskAmount
            1e6  // profitAmount
        );
        vm.stopPrank();
    }

    // --- H-3 FIX VERIFICATION TESTS ---

    /**
     * @notice Test that multiple sequential partial buys maintain correct price-per-unit
     * @dev This is the key test for verifying H-3 fix: listing.price must be reduced
     *      proportionally after each partial buy so subsequent buyers pay fair price
     *
     * Scenario:
     * - Seller lists 10 riskAmount for 100 USDC total (10 USDC per unit)
     * - Buyer 1 buys 4 riskAmount, should pay 40 USDC
     * - Buyer 2 buys 3 riskAmount, should pay 30 USDC
     * - Buyer 3 buys remaining 3 riskAmount, should pay 30 USDC
     * - Total paid should equal original listing price (100 USDC)
     */
    function testBuyPosition_MultiplePartialBuys_MaintainsCorrectPricing() public {
        // Setup: seller lists 10 riskAmount for 100 USDC, profitAmount=1e6
        uint256 totalPrice = 100e6;
        uint256 totalRiskAmount = 10e6;
        uint256 totalProfitAmount = 1e6;
        uint256 pricePerUnit = totalPrice / totalRiskAmount; // 10 USDC per unit

        vm.startPrank(seller);
        market.listPositionForSale(
            speculationId,
            positionType,
            totalPrice,
            totalRiskAmount,
            totalProfitAmount
        );
        vm.stopPrank();

        // Create additional buyers
        address buyer2 = address(0x3333);
        address buyer3 = address(0x4444);
        token.transfer(buyer2, 100e6);
        token.transfer(buyer3, 100e6);

        // Buyer 1 buys 4 riskAmount
        uint256 buyer1RiskAmount = 4e6;
        uint256 expectedBuyer1Price = (totalPrice * buyer1RiskAmount) / totalRiskAmount; // 40 USDC

        vm.startPrank(buyer);
        token.approve(address(market), expectedBuyer1Price);
        uint256 buyer1BalBefore = token.balanceOf(buyer);
        market.buyPosition(speculationId, seller, positionType, buyer1RiskAmount);
        uint256 buyer1Paid = buyer1BalBefore - token.balanceOf(buyer);
        vm.stopPrank();

        assertEq(buyer1Paid, expectedBuyer1Price, "Buyer 1 should pay 40 USDC for 4 riskAmount");

        // Verify buyer1 position after purchase
        // profitAmount = (1e6 * 4e6) / 10e6 = 400000
        Position memory buyer1Pos = positionModule.getPosition(speculationId, buyer, positionType);
        assertEq(buyer1Pos.riskAmount, 4e6, "Buyer 1 should receive risk");
        assertEq(buyer1Pos.profitAmount, 400000, "Buyer 1 should receive profit");

        // Verify seller position after first buy
        Position memory sellerPosAfter1 = positionModule.getPosition(speculationId, seller, positionType);
        assertEq(sellerPosAfter1.riskAmount, 6e6, "Seller risk should decrease after buy 1");
        assertEq(sellerPosAfter1.profitAmount, 600000, "Seller profit should decrease after buy 1");

        // Check listing state after first buy
        SaleListing memory listingAfter1 = market.getSaleListing(speculationId, seller, positionType);
        assertEq(listingAfter1.riskAmount, 6e6, "Listing should have 6 riskAmount remaining");
        assertEq(listingAfter1.price, 60e6, "Listing price should be 60 USDC remaining");

        // Buyer 2 buys 3 riskAmount - should pay 30 USDC (not 50 which would happen without fix)
        uint256 buyer2RiskAmount = 3e6;
        uint256 expectedBuyer2Price = (listingAfter1.price * buyer2RiskAmount) / listingAfter1.riskAmount; // 30 USDC

        vm.startPrank(buyer2);
        token.approve(address(market), expectedBuyer2Price);
        uint256 buyer2BalBefore = token.balanceOf(buyer2);
        market.buyPosition(speculationId, seller, positionType, buyer2RiskAmount);
        uint256 buyer2Paid = buyer2BalBefore - token.balanceOf(buyer2);
        vm.stopPrank();

        assertEq(buyer2Paid, expectedBuyer2Price, "Buyer 2 should pay 30 USDC for 3 riskAmount");
        assertEq(buyer2Paid, 3e6 * pricePerUnit, "Buyer 2 price should match original per-unit price");

        // Verify buyer2 position after purchase
        // profitAmount = (600000 * 3e6) / 6e6 = 300000
        Position memory buyer2Pos = positionModule.getPosition(speculationId, buyer2, positionType);
        assertEq(buyer2Pos.riskAmount, 3e6, "Buyer 2 should receive risk");
        assertEq(buyer2Pos.profitAmount, 300000, "Buyer 2 should receive profit");

        // Verify seller position after second buy
        Position memory sellerPosAfter2 = positionModule.getPosition(speculationId, seller, positionType);
        assertEq(sellerPosAfter2.riskAmount, 3e6, "Seller risk should decrease after buy 2");
        assertEq(sellerPosAfter2.profitAmount, 300000, "Seller profit should decrease after buy 2");

        // Check listing state after second buy
        SaleListing memory listingAfter2 = market.getSaleListing(speculationId, seller, positionType);
        assertEq(listingAfter2.riskAmount, 3e6, "Listing should have 3 riskAmount remaining");
        assertEq(listingAfter2.price, 30e6, "Listing price should be 30 USDC remaining");

        // Buyer 3 buys remaining 3 riskAmount
        uint256 buyer3RiskAmount = 3e6;
        uint256 expectedBuyer3Price = listingAfter2.price; // All remaining = 30 USDC

        vm.startPrank(buyer3);
        token.approve(address(market), expectedBuyer3Price);
        uint256 buyer3BalBefore = token.balanceOf(buyer3);
        market.buyPosition(speculationId, seller, positionType, buyer3RiskAmount);
        uint256 buyer3Paid = buyer3BalBefore - token.balanceOf(buyer3);
        vm.stopPrank();

        assertEq(buyer3Paid, expectedBuyer3Price, "Buyer 3 should pay 30 USDC for 3 riskAmount");

        // Verify buyer3 position after purchase
        // profitAmount = (300000 * 3e6) / 3e6 = 300000
        Position memory buyer3Pos = positionModule.getPosition(speculationId, buyer3, positionType);
        assertEq(buyer3Pos.riskAmount, 3e6, "Buyer 3 should receive risk");
        assertEq(buyer3Pos.profitAmount, 300000, "Buyer 3 should receive profit");

        // Verify seller position fully depleted
        Position memory sellerPosFinal = positionModule.getPosition(speculationId, seller, positionType);
        assertEq(sellerPosFinal.riskAmount, 0, "Seller risk should be zero after all buys");
        assertEq(sellerPosFinal.profitAmount, 0, "Seller profit should be zero after all buys");

        // Verify listing is now empty (deleted)
        SaleListing memory finalListing = market.getSaleListing(speculationId, seller, positionType);
        assertEq(finalListing.riskAmount, 0, "Listing should be deleted after full sale");
        assertEq(finalListing.price, 0, "Listing price should be 0 after full sale");

        // Verify total paid equals original listing price
        uint256 totalPaid = buyer1Paid + buyer2Paid + buyer3Paid;
        assertEq(totalPaid, totalPrice, "Total paid by all buyers should equal original listing price");

        // Verify seller received all proceeds
        assertEq(
            market.getPendingSaleProceeds(seller),
            totalPrice,
            "Seller should have total price as pending proceeds"
        );
    }

    /**
     * @notice Test that price-per-unit remains consistent across partial buys
     * @dev Verifies the fix by checking that each buyer pays the same rate per unit
     *      Uses seller's actual matched position of 10e6 riskAmount
     */
    function testBuyPosition_PartialBuys_ConsistentPricePerUnit() public {
        // Setup: seller lists 10 riskAmount for 20 USDC (2 USDC per unit), profitAmount=1e6
        // Note: seller's matched position is 10e6 riskAmount from setup
        uint256 totalPrice = 20e6;
        uint256 totalRiskAmount = 10e6;
        uint256 totalProfitAmount = 1e6;

        vm.startPrank(seller);
        market.listPositionForSale(
            speculationId,
            positionType,
            totalPrice,
            totalRiskAmount,
            totalProfitAmount
        );
        vm.stopPrank();

        // Buyer buys 4 riskAmount - should pay 8 USDC (4 * 2 USDC per unit)
        vm.startPrank(buyer);
        token.approve(address(market), 8e6);
        market.buyPosition(speculationId, seller, positionType, 4e6);
        vm.stopPrank();

        SaleListing memory listingAfter = market.getSaleListing(speculationId, seller, positionType);

        // Verify price per unit is still 2 USDC
        // Remaining: 6 riskAmount for 12 USDC = 2 USDC per unit
        uint256 remainingPricePerUnit = listingAfter.price / listingAfter.riskAmount;
        assertEq(remainingPricePerUnit, 2, "Price per unit should remain 2 USDC after partial buy");
        assertEq(listingAfter.riskAmount, 6e6, "Should have 6 riskAmount remaining");
        assertEq(listingAfter.price, 12e6, "Should have 12 USDC price remaining");

        // Verify buyer position after partial purchase
        // profitAmount = (1e6 * 4e6) / 10e6 = 400000
        Position memory buyerPosConsistent = positionModule.getPosition(speculationId, buyer, positionType);
        assertEq(buyerPosConsistent.riskAmount, 4e6, "Buyer should receive risk");
        assertEq(buyerPosConsistent.profitAmount, 400000, "Buyer should receive profit");

        // Verify seller position decreased
        Position memory sellerPosConsistent = positionModule.getPosition(speculationId, seller, positionType);
        assertEq(sellerPosConsistent.riskAmount, 6e6, "Seller risk should decrease");
        assertEq(sellerPosConsistent.profitAmount, 600000, "Seller profit should decrease");
    }

    // =========================================================================
    // DUST BUY PROTECTION
    // =========================================================================

    /// @notice buyRiskAmount that rounds purchasePrice to zero reverts
    function testBuyPosition_RevertsIfPurchasePriceZero() public {
        // List 10 USDC risk at price 1 (1 raw unit = 0.000001 USDC)
        vm.startPrank(seller);
        market.listPositionForSale(speculationId, positionType, 1, 10e6, 1e6);
        vm.stopPrank();

        // Buy 1 raw unit of risk: purchasePrice = (1 * 1) / 10e6 = 0
        vm.startPrank(buyer);
        token.approve(address(market), type(uint256).max);
        vm.expectRevert(SecondaryMarketModule.SecondaryMarketModule__PurchasePriceZero.selector);
        market.buyPosition(speculationId, seller, positionType, 1);
        vm.stopPrank();
    }

    /// @notice Full buy (exact listing amount) succeeds and deletes listing
    function testBuyPosition_FullBuySucceeds() public {
        // List 5 USDC risk at 3 USDC price
        vm.startPrank(seller);
        market.listPositionForSale(speculationId, positionType, 3e6, 5e6, 1e6);
        vm.stopPrank();

        // Buy the full amount
        vm.startPrank(buyer);
        token.approve(address(market), type(uint256).max);
        market.buyPosition(speculationId, seller, positionType, 5e6);
        vm.stopPrank();

        // Listing should be deleted
        SaleListing memory listing = market.getSaleListing(speculationId, seller, positionType);
        assertEq(listing.riskAmount, 0, "listing deleted");
        assertEq(listing.price, 0, "listing price zero");

        // Buyer has the full position
        Position memory buyerPos = positionModule.getPosition(speculationId, buyer, positionType);
        assertEq(buyerPos.riskAmount, 5e6, "buyer got full risk");
    }

    // =========================================================================
    // Branch Coverage Tests
    // =========================================================================

    // --- listPositionForSale: profitAmount > position.profitAmount ---
    function testListPositionForSale_RevertsIfProfitAmountAbovePosition() public {
        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(
                SecondaryMarketModule.SecondaryMarketModule__AmountAboveMaximum.selector,
                999e6 // profitAmount exceeding position
            )
        );
        // seller has riskAmount=10e6, profitAmount=1e6
        market.listPositionForSale(speculationId, positionType, 5e6, 10e6, 999e6);
    }

    // --- listPositionForSale: position already claimed (mock position as claimed while spec is Open) ---
    function testListPositionForSale_RevertsIfPositionClaimedWhileSpecOpen() public {
        // Mock getPosition to return a claimed position while speculation stays Open
        vm.mockCall(
            address(positionModule),
            abi.encodeWithSignature("getPosition(uint256,address,uint8)", speculationId, seller, uint8(positionType)),
            abi.encode(Position({riskAmount: 10e6, profitAmount: 1e6, positionType: positionType, claimed: true}))
        );
        vm.prank(seller);
        vm.expectRevert(SecondaryMarketModule.SecondaryMarketModule__PositionAlreadyClaimed.selector);
        market.listPositionForSale(speculationId, positionType, 5e6, 10e6, 1e6);
    }

    // --- buyPosition: listing not active (no listing exists) ---
    function testBuyPosition_RevertsIfListingNotActive() public {
        // No listing created — try to buy directly
        vm.prank(buyer);
        vm.expectRevert(SecondaryMarketModule.SecondaryMarketModule__ListingNotActive.selector);
        market.buyPosition(speculationId, seller, positionType, 5e6);
    }

    // --- buyPosition: position claimed while spec Open ---
    function testBuyPosition_RevertsIfPositionClaimedWhileSpecOpen() public {
        // Create listing
        vm.prank(seller);
        market.listPositionForSale(speculationId, positionType, 5e6, 10e6, 1e6);

        // Mock getPosition to return claimed=true
        vm.mockCall(
            address(positionModule),
            abi.encodeWithSignature("getPosition(uint256,address,uint8)", speculationId, seller, uint8(positionType)),
            abi.encode(Position({riskAmount: 10e6, profitAmount: 1e6, positionType: positionType, claimed: true}))
        );

        vm.prank(buyer);
        token.approve(address(market), 5e6);
        vm.prank(buyer);
        vm.expectRevert(SecondaryMarketModule.SecondaryMarketModule__PositionAlreadyClaimed.selector);
        market.buyPosition(speculationId, seller, positionType, 5e6);
    }

    // --- updateListing: position claimed while spec Open ---
    function testUpdateListing_RevertsIfPositionClaimedWhileSpecOpen() public {
        // Create listing
        vm.prank(seller);
        market.listPositionForSale(speculationId, positionType, 5e6, 10e6, 1e6);

        // Mock getPosition to return claimed=true
        vm.mockCall(
            address(positionModule),
            abi.encodeWithSignature("getPosition(uint256,address,uint8)", speculationId, seller, uint8(positionType)),
            abi.encode(Position({riskAmount: 10e6, profitAmount: 1e6, positionType: positionType, claimed: true}))
        );

        vm.prank(seller);
        vm.expectRevert(SecondaryMarketModule.SecondaryMarketModule__PositionAlreadyClaimed.selector);
        market.updateListing(speculationId, positionType, 6e6, 0, 0);
    }

    // --- updateListing: newProfitAmount > position.profitAmount ---
    function testUpdateListing_RevertsIfNewProfitAmountAbovePosition() public {
        // Create listing first
        vm.prank(seller);
        market.listPositionForSale(speculationId, positionType, 5e6, 10e6, 1e6);

        // Try to update profit to exceed position (seller's profitAmount is 1e6)
        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(
                SecondaryMarketModule.SecondaryMarketModule__AmountAboveMaximum.selector,
                999e6
            )
        );
        market.updateListing(speculationId, positionType, 0, 0, 999e6);
    }
}
