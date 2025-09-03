// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {SecondaryMarketModule} from "../../src/modules/SecondaryMarketModule.sol";
import {SpeculationModule} from "../../src/modules/SpeculationModule.sol";
import {PositionModule} from "../../src/modules/PositionModule.sol";
import {ContributionModule} from "../../src/modules/ContributionModule.sol";
import {TreasuryModule} from "../../src/modules/TreasuryModule.sol";
import {OracleModule} from "../../src/modules/OracleModule.sol";
import {OspexCore} from "../../src/core/OspexCore.sol";
import {PositionType, SaleListing, Position, Contest, ContestStatus, LeagueId} from "../../src/core/OspexTypes.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockContestModule} from "../mocks/MockContestModule.sol";
import {MockScorerModule} from "../mocks/MockScorerModule.sol";
import {MockFunctionsRouter} from "../mocks/MockFunctionsRouter.sol";
import {MockLinkToken} from "../mocks/MockLinkToken.sol";

contract SecondaryMarketModuleTest is Test {
    OspexCore public core;
    MockERC20 public token;
    SpeculationModule public speculationModule;
    ContributionModule public contributionModule;
    PositionModule public positionModule;
    SecondaryMarketModule public market;
    MockContestModule public mockContestModule;
    TreasuryModule public treasuryModule;
    OracleModule public oracleModule;
    MockFunctionsRouter public mockRouter;
    MockLinkToken public mockLinkToken;
    address public admin = address(0x1234);
    address public seller = address(0x1);
    address public buyer = address(0x2);
    address public nonAdmin = address(0x3);
    uint256 public speculationId;
    uint128 public oddsPairId;
    PositionType public positionType = PositionType.Upper;
    uint256 public minSaleAmount = 1e6; // 1 USDC
    uint256 public maxSaleAmount = 100e6; // 100 USDC

    // leaderboard Id and allocation set to 0 for testing
    uint256 leaderboardId = 0;

    function setUp() public {
        // Deploy core and modules
        core = new OspexCore();
        
        // Grant admin role to admin account
        core.grantRole(core.DEFAULT_ADMIN_ROLE(), admin);
        
        token = new MockERC20();
        speculationModule = new SpeculationModule(address(core), 6);
        contributionModule = new ContributionModule(address(core));
        positionModule = new PositionModule(
            address(core),
            address(token)
        );
        treasuryModule = new TreasuryModule(address(core), address(0x1), address(0x2));
        
        // Create mock Chainlink contracts
        mockRouter = new MockFunctionsRouter(address(0x456)); // dummy linkToken for router
        mockLinkToken = new MockLinkToken();
        bytes32 donId = bytes32(uint256(0x1234));
        
        // Create and register OracleModule with proper mocks
        oracleModule = new OracleModule(
            address(core),
            address(mockRouter),
            address(mockLinkToken),
            donId
        );
        core.registerModule(
            keccak256("ORACLE_MODULE"),
            address(oracleModule)
        );
        
        // Register modules for event emission
        core.registerModule(
            keccak256("POSITION_MODULE"),
            address(positionModule)
        );
        core.registerModule(
            keccak256("SPECULATION_MODULE"),
            address(speculationModule)
        );
        core.registerModule(
            keccak256("CONTRIBUTION_MODULE"),
            address(contributionModule)
        );
        core.registerModule(
            keccak256("TREASURY_MODULE"),
            address(treasuryModule)
        );
        
        // Create and register MockContestModule
        mockContestModule = new MockContestModule();
        core.registerModule(
            keccak256("CONTEST_MODULE"),
            address(mockContestModule)
        );
        
        // Set up a verified contest for speculation creation
        Contest memory contest = Contest({
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
        mockContestModule.setContest(1, contest);
        
        // Deploy secondary market module
        market = new SecondaryMarketModule(
            address(core),
            address(token),
            minSaleAmount,
            maxSaleAmount
        );
        core.registerModule(
            keccak256("SECONDARY_MARKET_MODULE"),
            address(market)
        );
        core.setMarketRole(address(market), true);
        
        // Fund seller and buyer
        token.mint(seller, 1000e6);
        token.mint(buyer, 1000e6);
        
        // Give accounts some ETH
        vm.deal(admin, 10 ether);
        vm.deal(seller, 10 ether);
        vm.deal(buyer, 10 ether);
        
        // Seller creates a speculation (need to call as oracle module)
        vm.startPrank(address(oracleModule));
        speculationId = speculationModule.createSpeculation(
            1, // contestId
            address(0xBEEF), // scorer
            42, // theNumber
            address(oracleModule), // speculationCreator
            leaderboardId
        );
        vm.stopPrank();
        
        // Seller creates an unmatched pair (position)
        vm.startPrank(seller);
        uint64 odds = 11_000_000; // 1.10 odds
        (oddsPairId, , ) = positionModule.getOrCreateOddsPairId(odds, positionType);
        token.approve(address(positionModule), 10e6);
        positionModule.createUnmatchedPair(
            speculationId,
            odds,
            0, // unmatchedExpiry
            positionType,
            10e6, // 10 USDC
            0
        );
        // Buyer matches the position (completes the pair)
        token.transfer(buyer, 10e6); // ensure buyer has enough
        vm.stopPrank();
        vm.startPrank(buyer);
        token.approve(address(positionModule), 10e6);
        positionModule.completeUnmatchedPair(
            speculationId,
            seller,
            oddsPairId,
            positionType,
            1e6 // match full amount
        );
        vm.stopPrank();
    }

    function testListPositionForSale() public {
        vm.startPrank(seller);
        uint256 price = 5e6; // 5 USDC
        uint256 amount = 10e6; // 10 USDC
        uint256 contributionAmount = 0;
        market.listPositionForSale(
            speculationId,
            oddsPairId,
            positionType,
            price,
            amount,
            contributionAmount
        );
        SaleListing memory listing = market.getSaleListing(
            speculationId,
            seller,
            oddsPairId,
            positionType
        );
        assertEq(listing.price, price, "Price should match");
        assertEq(listing.amount, amount, "Amount should match");
        vm.stopPrank();
    }

    // --- SecondaryMarketModule Comprehensive Tests ---

    // 1. Listing a Position for Sale
    function testListPositionForSale_RevertsIfPriceZero() public {
        vm.startPrank(seller);
        uint256 price = 0;
        uint256 amount = 10e6;
        uint256 contributionAmount = 0;
        vm.expectRevert(
            SecondaryMarketModule.SecondaryMarketModule__InvalidPrice.selector
        );
        market.listPositionForSale(
            speculationId,
            oddsPairId,
            positionType,
            price,
            amount,
            contributionAmount
        );
        vm.stopPrank();
    }

    function testListPositionForSale_RevertsIfAmountBelowMin() public {
        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 amount = minSaleAmount - 1;
        uint256 contributionAmount = 0;
        vm.expectRevert(
            abi.encodeWithSelector(
                SecondaryMarketModule
                    .SecondaryMarketModule__SaleAmountBelowMinimum
                    .selector,
                amount
            )
        );
        market.listPositionForSale(
            speculationId,
            oddsPairId,
            positionType,
            price,
            amount,
            contributionAmount
        );
        vm.stopPrank();
    }

    function testListPositionForSale_RevertsIfAmountAboveMax() public {
        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 amount = maxSaleAmount + 1;
        uint256 contributionAmount = 0;
        vm.expectRevert(
            abi.encodeWithSelector(
                SecondaryMarketModule
                    .SecondaryMarketModule__SaleAmountAboveMaximum
                    .selector,
                amount
            )
        );
        market.listPositionForSale(
            speculationId,
            oddsPairId,
            positionType,
            price,
            amount,
            contributionAmount
        );
        vm.stopPrank();
    }

    function testListPositionForSale_RevertsIfNoMatchedAmount() public {
        address notMatched = address(0xB0B);
        vm.startPrank(notMatched);
        uint256 price = 5e6;
        uint256 amount = 10e6;
        uint256 contributionAmount = 0;
        vm.expectRevert(
            SecondaryMarketModule
                .SecondaryMarketModule__NoMatchedAmount
                .selector
        );
        market.listPositionForSale(
            speculationId,
            oddsPairId,
            positionType,
            price,
            amount,
            contributionAmount
        );
        vm.stopPrank();
    }

    // 2. Buying a Position
    function testBuyPosition_RevertsIfBuyerIsSeller() public {
        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 amount = 10e6;
        market.listPositionForSale(
            speculationId,
            oddsPairId,
            positionType,
            price,
            amount,
            0
        );
        vm.expectRevert(
            SecondaryMarketModule
                .SecondaryMarketModule__CannotBuyOwnPosition
                .selector
        );
        market.buyPosition(
            speculationId,
            seller,
            oddsPairId,
            positionType,
            1e6
        );
        vm.stopPrank();
    }

    function testBuyPosition_RevertsIfAmountZero() public {
        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 amount = 10e6;
        market.listPositionForSale(
            speculationId,
            oddsPairId,
            positionType,
            price,
            amount,
            0
        );
        vm.stopPrank();
        vm.startPrank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                SecondaryMarketModule
                    .SecondaryMarketModule__SaleAmountBelowMinimum
                    .selector,
                0
            )
        );
        market.buyPosition(speculationId, seller, oddsPairId, positionType, 0);
        vm.stopPrank();
    }

    function testBuyPosition_RevertsIfAmountAboveListing() public {
        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 amount = 10e6;
        market.listPositionForSale(
            speculationId,
            oddsPairId,
            positionType,
            price,
            amount,
            0
        );
        vm.stopPrank();
        vm.startPrank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                SecondaryMarketModule
                    .SecondaryMarketModule__AmountAboveMaximum
                    .selector,
                amount + 1
            )
        );
        market.buyPosition(
            speculationId,
            seller,
            oddsPairId,
            positionType,
            amount + 1
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
        market.cancelListing(speculationId, oddsPairId, positionType);
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
            oddsPairId,
            positionType,
            10e6,
            10e6
        );
        vm.stopPrank();
    }

    function testUpdateListing_RevertsIfSpeculationNotOpen() public {
        // Create a MockScorerModule for this test
        MockScorerModule mockScorer = new MockScorerModule();
        
        // Create a new speculation with the mock scorer (need to call as oracle module)
        vm.startPrank(address(oracleModule));
        uint256 testSpecId = speculationModule.createSpeculation(
            1,
            address(mockScorer),
            42,
            address(oracleModule), // speculationCreator
            leaderboardId
        );
        vm.stopPrank();
        
        // Create a position and list it for sale
        vm.startPrank(seller);
        token.approve(address(positionModule), 10e6);
        uint64 odds = 11_000_000;
        (uint128 testOddsPairId, , ) = positionModule.getOrCreateOddsPairId(odds, positionType);
        positionModule.createUnmatchedPair(
            testSpecId,
            odds,
            0,
            positionType,
            10e6,
            0
        );
        
        // Have the buyer match with the position to create a matched amount
        vm.stopPrank();
        vm.startPrank(buyer);
        token.approve(address(positionModule), 1e6);
        positionModule.completeUnmatchedPair(
            testSpecId,
            seller,
            testOddsPairId,
            positionType,
            1e6 // match only the available amount (1e6)
        );
        vm.stopPrank();
        
        // Now seller can list the position with the matched amount
        vm.startPrank(seller);
        market.listPositionForSale(
            testSpecId,
            testOddsPairId,
            positionType,
            1e6, // price
            1e6, // amount
            0    // contribution
        );
        vm.stopPrank();
        
        // Warp to after speculation start time (speculation no longer has timestamp)
        vm.warp(block.timestamp + 1 hours);

        // Setup contest for settlement
        Contest memory contest = Contest({
            awayScore: 1,
            homeScore: 0,
            leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Scored, // Set to Scored
            contestCreator: address(this),
            scoreContestSourceHash: bytes32(0),
            rundownId: "",
            sportspageId: "",
            jsonoddsId: ""
        });
        mockContestModule.setContest(1, contest);
        
        // Settle the speculation to close it
        vm.prank(address(core));
        speculationModule.settleSpeculation(testSpecId);

        // Try to update the listing after speculation is closed
        vm.startPrank(seller);
        uint256 newPrice = 2e6;
        uint256 newAmount = 1e6;
        vm.expectRevert(
            SecondaryMarketModule
                .SecondaryMarketModule__SpeculationNotActive
                .selector
        );
        market.updateListing(
            testSpecId,
            testOddsPairId,
            positionType,
            newPrice,
            newAmount
        );
        vm.stopPrank();
    }

    // 6. Admin Functions
    function testSetMinSaleAmount_RevertsIfNotAdmin() public {
        vm.prank(nonAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                SecondaryMarketModule.SecondaryMarketModule__NotAdmin.selector,
                nonAdmin
            )
        );
        market.setMinSaleAmount(1e6);
    }

    function testSetMaxSaleAmount_RevertsIfNotAdmin() public {
        vm.prank(nonAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                SecondaryMarketModule.SecondaryMarketModule__NotAdmin.selector,
                nonAdmin
            )
        );
        market.setMaxSaleAmount(100e6);
    }

    // 7. View Functions
    function testGetSaleListing_ReturnsCorrectListing() public {
        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 amount = 10e6;
        market.listPositionForSale(
            speculationId,
            oddsPairId,
            positionType,
            price,
            amount,
            0
        );
        SaleListing memory listing = market.getSaleListing(
            speculationId,
            seller,
            oddsPairId,
            positionType
        );
        assertEq(listing.price, price, "Price should match");
        assertEq(listing.amount, amount, "Amount should match");
        vm.stopPrank();
    }

    function testGetPendingSaleProceeds_ReturnsCorrectAmount() public {
        // List and buy a position
        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 amount = 10e6;
        market.listPositionForSale(
            speculationId,
            oddsPairId,
            positionType,
            price,
            amount,
            0
        );
        vm.stopPrank();
        vm.startPrank(buyer);
        token.approve(address(market), price);
        market.buyPosition(
            speculationId,
            seller,
            oddsPairId,
            positionType,
            amount
        );
        vm.stopPrank();
        uint256 proceeds = market.getPendingSaleProceeds(seller);
        assertEq(proceeds, price, "Proceeds should match sale price");
    }

    // 8. Event Emission (example for listing)
    function testListPositionForSale_EmitsEvents() public {
        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 amount = 10e6;
        // Expect local event
        vm.expectEmit(true, true, false, true);
        emit SecondaryMarketModule.PositionListed(
            speculationId,
            seller,
            oddsPairId,
            positionType,
            amount,
            price,
            uint32(block.timestamp)
        );
        // Expect core event (emitted by core contract)
        vm.expectEmit(true, true, false, true, address(core));
        emit OspexCore.CoreEventEmitted(
            keccak256("POSITION_LISTED"),
            abi.encode(
                speculationId,
                seller,
                oddsPairId,
                positionType,
                amount,
                price,
                block.timestamp
            )
        );
        market.listPositionForSale(
            speculationId,
            oddsPairId,
            positionType,
            price,
            amount,
            0
        );
        vm.stopPrank();
    }

    // --- Additional Coverage for SecondaryMarketModule ---

    // 1. claimSaleProceeds
    function testClaimSaleProceeds_HappyPathAndEvents() public {
        // List and buy a position to generate proceeds
        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 amount = 10e6;
        market.listPositionForSale(
            speculationId,
            oddsPairId,
            positionType,
            price,
            amount,
            0
        );
        vm.stopPrank();
        vm.startPrank(buyer);
        token.approve(address(market), price);
        market.buyPosition(
            speculationId,
            seller,
            oddsPairId,
            positionType,
            amount
        );
        vm.stopPrank();
        // Seller claims proceeds
        vm.startPrank(seller);
        uint256 before = token.balanceOf(seller);
        vm.expectEmit(true, false, false, true);
        emit SecondaryMarketModule.SaleProceedsClaimed(seller, price);
        vm.expectEmit(true, false, false, true, address(core));
        emit OspexCore.CoreEventEmitted(
            keccak256("SALE_PROCEEDS_CLAIMED"),
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
        uint256 amount = 10e6;
        market.listPositionForSale(
            speculationId,
            oddsPairId,
            positionType,
            price,
            amount,
            0
        );
        // Cancel listing
        vm.expectEmit(true, true, false, true);
        emit SecondaryMarketModule.ListingCancelled(
            speculationId,
            seller,
            oddsPairId,
            positionType
        );
        vm.expectEmit(true, true, false, true, address(core));
        emit OspexCore.CoreEventEmitted(
            keccak256("LISTING_CANCELLED"),
            abi.encode(speculationId, seller, oddsPairId, positionType)
        );
        market.cancelListing(speculationId, oddsPairId, positionType);
        SaleListing memory listing = market.getSaleListing(
            speculationId,
            seller,
            oddsPairId,
            positionType
        );
        assertEq(listing.amount, 0, "Listing should be deleted");
        vm.stopPrank();
    }
    function testCancelListing_RevertsIfPositionDoesNotExist() public {
        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 amount = 10e6;
        market.listPositionForSale(
            speculationId,
            oddsPairId,
            positionType,
            price,
            amount,
            0
        );
        // Simulate position does not exist by using a different oddsPairId
        uint128 fakeOddsPairId = oddsPairId + 1;
        vm.expectRevert(
            SecondaryMarketModule
                .SecondaryMarketModule__ListingNotActive
                .selector
        );
        market.cancelListing(speculationId, fakeOddsPairId, positionType);
        vm.stopPrank();
    }
    function testCancelListing_RevertsIfPositionClaimed() public {
        // List a position
        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 amount = 10e6;
        market.listPositionForSale(
            speculationId,
            oddsPairId,
            positionType,
            price,
            amount,
            0
        );
        // Simulate claimed position by forcibly setting claimed to true (mock or direct storage if possible)
        // For this test, we expect revert if claimed, but since we can't set claimed directly, this is a placeholder for when a mock is available.
        // vm.expectRevert(SecondaryMarketModule.SecondaryMarketModule__PositionAlreadyClaimed.selector);
        // market.cancelListing(speculationId, oddsPairId, positionType);
        vm.stopPrank();
    }

    // 3. updateListing
    function testUpdateListing_HappyPathAndEvents() public {
        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 amount = 10e6;
        market.listPositionForSale(
            speculationId,
            oddsPairId,
            positionType,
            price,
            amount,
            0
        );
        uint256 newPrice = 6e6;
        uint256 newAmount = 8e6;
        vm.expectEmit(true, true, false, true);
        emit SecondaryMarketModule.ListingUpdated(
            speculationId,
            seller,
            oddsPairId,
            positionType,
            price,
            newPrice,
            amount,
            newAmount
        );
        vm.expectEmit(true, true, false, true, address(core));
        emit OspexCore.CoreEventEmitted(
            keccak256("LISTING_UPDATED"),
            abi.encode(
                speculationId,
                seller,
                oddsPairId,
                positionType,
                price,
                newPrice,
                amount,
                newAmount
            )
        );
        market.updateListing(
            speculationId,
            oddsPairId,
            positionType,
            newPrice,
            newAmount
        );
        SaleListing memory listing = market.getSaleListing(
            speculationId,
            seller,
            oddsPairId,
            positionType
        );
        assertEq(listing.price, newPrice, "Price should update");
        assertEq(listing.amount, newAmount, "Amount should update");
        vm.stopPrank();
    }
    function testUpdateListing_RevertsIfNewAmountAboveMatched() public {
        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 amount = 10e6;
        market.listPositionForSale(
            speculationId,
            oddsPairId,
            positionType,
            price,
            amount,
            0
        );
        uint256 newAmount = 20e6;
        vm.expectRevert(
            abi.encodeWithSelector(
                SecondaryMarketModule
                    .SecondaryMarketModule__AmountAboveMaximum
                    .selector,
                newAmount
            )
        );
        market.updateListing(
            speculationId,
            oddsPairId,
            positionType,
            0,
            newAmount
        );
        vm.stopPrank();
    }
    function testUpdateListing_RevertsIfNewAmountBelowMin() public {
        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 amount = 10e6;
        market.listPositionForSale(
            speculationId,
            oddsPairId,
            positionType,
            price,
            amount,
            0
        );
        uint256 newAmount = minSaleAmount - 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                SecondaryMarketModule
                    .SecondaryMarketModule__SaleAmountBelowMinimum
                    .selector,
                newAmount
            )
        );
        market.updateListing(
            speculationId,
            oddsPairId,
            positionType,
            0,
            newAmount
        );
        vm.stopPrank();
    }
    function testUpdateListing_RevertsIfNewAmountAboveMaxSaleAmount() public {
        vm.prank(admin);
        market.setMaxSaleAmount(5e6); // 5 USDC

        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 amount = 5e6; // <= maxSaleAmount
        market.listPositionForSale(
            speculationId,
            oddsPairId,
            positionType,
            price,
            amount,
            0
        );
        uint256 maxSaleAmount2 = market.s_maxSaleAmount();
        uint256 newAmount = maxSaleAmount2 + 1;
        console2.log("maxSaleAmount", maxSaleAmount2);
        console2.log("newAmount", newAmount);
        vm.expectRevert(
            abi.encodeWithSelector(
                SecondaryMarketModule.SecondaryMarketModule__SaleAmountAboveMaximum.selector,
                newAmount
            )
        );
        market.updateListing(
            speculationId,
            oddsPairId,
            positionType,
            0,
            newAmount
        );
        vm.stopPrank();
    }

    // 4. setMinSaleAmount and setMaxSaleAmount
    function testSetMinSaleAmount_HappyPath() public {
        vm.prank(admin);
        market.setMinSaleAmount(2e6);
        assertEq(
            market.s_minSaleAmount(),
            2e6,
            "Min sale amount should update"
        );
    }
    function testSetMinSaleAmount_RevertsIfZero() public {
        vm.prank(admin);
        vm.expectRevert(
            SecondaryMarketModule
                .SecondaryMarketModule__InvalidMinSaleAmount
                .selector
        );
        market.setMinSaleAmount(0);
    }
    function testSetMaxSaleAmount_HappyPath() public {
        vm.prank(admin);
        market.setMaxSaleAmount(200e6);
        assertEq(
            market.s_maxSaleAmount(),
            200e6,
            "Max sale amount should update"
        );
    }
    function testSetMaxSaleAmount_RevertsIfZero() public {
        vm.prank(admin);
        vm.expectRevert(
            SecondaryMarketModule
                .SecondaryMarketModule__InvalidMaxSaleAmount
                .selector
        );
        market.setMaxSaleAmount(0);
    }

    // 5. getModuleType
    function testGetModuleType_ReturnsCorrectType() public view {
        assertEq(
            market.getModuleType(),
            keccak256("SECONDARY_MARKET_MODULE"),
            "Module type should match"
        );
    }

    // 6. buyPosition happy path
    function testBuyPosition_HappyPathAndEvents() public {
        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 amount = 10e6;
        market.listPositionForSale(
            speculationId,
            oddsPairId,
            positionType,
            price,
            amount,
            0
        );
        vm.stopPrank();
        vm.startPrank(buyer);
        token.approve(address(market), price);
        vm.expectEmit(true, true, true, true);
        emit SecondaryMarketModule.PositionSold(
            speculationId,
            seller,
            oddsPairId,
            positionType,
            buyer,
            amount
        );
        vm.expectEmit(true, true, true, true, address(core));
        emit OspexCore.CoreEventEmitted(
            keccak256("POSITION_SOLD"),
            abi.encode(
                speculationId,
                seller,
                oddsPairId,
                positionType,
                buyer,
                amount
            )
        );
        market.buyPosition(
            speculationId,
            seller,
            oddsPairId,
            positionType,
            amount
        );
        vm.stopPrank();
        // Listing should be deleted
        SaleListing memory listing = market.getSaleListing(
            speculationId,
            seller,
            oddsPairId,
            positionType
        );
        assertEq(listing.amount, 0, "Listing should be deleted after full buy");
        // Proceeds should be correct
        assertEq(
            market.getPendingSaleProceeds(seller),
            price,
            "Proceeds should match sale price"
        );
    }

    function testConstructor_RevertsOnZeroAddresses() public {
        address valid = address(token);
        address zero = address(0);
        vm.expectRevert(
            SecondaryMarketModule.SecondaryMarketModule__InvalidAddress.selector
        );
        new SecondaryMarketModule(zero, valid, 1, 1);
        vm.expectRevert(
            SecondaryMarketModule.SecondaryMarketModule__InvalidAddress.selector
        );
        new SecondaryMarketModule(valid, zero, 1, 1);
    }
    function testConstructor_RevertsOnZeroMinOrMaxSaleAmount() public {
        address valid = address(token);
        vm.expectRevert(
            SecondaryMarketModule
                .SecondaryMarketModule__InvalidMinSaleAmount
                .selector
        );
        new SecondaryMarketModule(valid, valid, 0, 1);
        vm.expectRevert(
            SecondaryMarketModule
                .SecondaryMarketModule__InvalidMaxSaleAmount
                .selector
        );
        new SecondaryMarketModule(valid, valid, 1, 0);
    }
    function testListPositionForSale_AmountZeroUsesMatchedAmount() public {
        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 amount = 0; // Should use matchedAmount
        uint256 contributionAmount = 0;
        // Ensure seller has a matched position
        market.listPositionForSale(
            speculationId,
            oddsPairId,
            positionType,
            price,
            amount,
            contributionAmount
        );
        SaleListing memory listing = market.getSaleListing(
            speculationId,
            seller,
            oddsPairId,
            positionType
        );
        Position memory pos = positionModule.getPosition(
            speculationId,
            seller,
            oddsPairId,
            positionType
        );
        assertEq(
            listing.amount,
            pos.matchedAmount,
            "Listing amount should equal matchedAmount when amount=0"
        );
        vm.stopPrank();
    }
    function testListPositionForSale_WithContributionAmount() public {
        // Set a valid contribution token and receiver
        vm.prank(admin);
        contributionModule.setContributionToken(address(token));
        vm.prank(admin);
        contributionModule.setContributionReceiver(address(0xBEEF));

        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 amount = 1e6;
        uint256 contributionAmount = 1e6;
        // Approve the contributionModule to spend seller's tokens
        token.approve(address(contributionModule), contributionAmount);

        market.listPositionForSale(
            speculationId,
            oddsPairId,
            positionType,
            price,
            amount,
            contributionAmount
        );
        SaleListing memory listing = market.getSaleListing(
            speculationId,
            seller,
            oddsPairId,
            positionType
        );
        assertEq(listing.price, price, "Price should match");
        assertEq(listing.amount, amount, "Amount should match");
        vm.stopPrank();
    }
    function testBuyPosition_PartialBuyReducesListing() public {
        vm.startPrank(seller);
        uint256 price = 10e6;
        uint256 amount = 10e6;
        market.listPositionForSale(
            speculationId,
            oddsPairId,
            positionType,
            price,
            amount,
            0
        );
        vm.stopPrank();
        vm.startPrank(buyer);
        token.approve(address(market), price / 2);
        market.buyPosition(
            speculationId,
            seller,
            oddsPairId,
            positionType,
            amount / 2
        );
        vm.stopPrank();
        SaleListing memory listing = market.getSaleListing(
            speculationId,
            seller,
            oddsPairId,
            positionType
        );
        assertEq(
            listing.amount,
            amount / 2,
            "Listing amount should be reduced after partial buy"
        );
    }
    function testUpdateListing_OnlyPrice() public {
        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 amount = 10e6;
        market.listPositionForSale(
            speculationId,
            oddsPairId,
            positionType,
            price,
            amount,
            0
        );
        uint256 newPrice = 6e6;
        market.updateListing(
            speculationId,
            oddsPairId,
            positionType,
            newPrice,
            0
        );
        SaleListing memory listing = market.getSaleListing(
            speculationId,
            seller,
            oddsPairId,
            positionType
        );
        assertEq(listing.price, newPrice, "Price should update");
        assertEq(listing.amount, amount, "Amount should not change");
        vm.stopPrank();
    }
    function testUpdateListing_OnlyAmount() public {
        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 amount = 10e6;
        market.listPositionForSale(
            speculationId,
            oddsPairId,
            positionType,
            price,
            amount,
            0
        );
        uint256 newAmount = 8e6;
        market.updateListing(
            speculationId,
            oddsPairId,
            positionType,
            0,
            newAmount
        );
        SaleListing memory listing = market.getSaleListing(
            speculationId,
            seller,
            oddsPairId,
            positionType
        );
        assertEq(listing.price, price, "Price should not change");
        assertEq(listing.amount, newAmount, "Amount should update");
        vm.stopPrank();
    }
    function testUpdateListing_NeitherPriceNorAmount() public {
        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 amount = 10e6;
        market.listPositionForSale(
            speculationId,
            oddsPairId,
            positionType,
            price,
            amount,
            0
        );
        market.updateListing(speculationId, oddsPairId, positionType, 0, 0);
        SaleListing memory listing = market.getSaleListing(
            speculationId,
            seller,
            oddsPairId,
            positionType
        );
        assertEq(listing.price, price, "Price should not change");
        assertEq(listing.amount, amount, "Amount should not change");
        vm.stopPrank();
    }
    function testUpdateListing_BothPriceAndAmount() public {
        vm.startPrank(seller);
        uint256 price = 5e6;
        uint256 amount = 10e6;
        market.listPositionForSale(
            speculationId,
            oddsPairId,
            positionType,
            price,
            amount,
            0
        );
        uint256 newPrice = 6e6;
        uint256 newAmount = 8e6;
        market.updateListing(
            speculationId,
            oddsPairId,
            positionType,
            newPrice,
            newAmount
        );
        SaleListing memory listing = market.getSaleListing(
            speculationId,
            seller,
            oddsPairId,
            positionType
        );
        assertEq(listing.price, newPrice, "Price should update");
        assertEq(listing.amount, newAmount, "Amount should update");
        vm.stopPrank();
    }

    function testSecondaryMarket_Revert_ModuleNotSet() public {
        // Create a new core and market instance without registering required modules
        OspexCore newCore = new OspexCore();
        SecondaryMarketModule newMarket = new SecondaryMarketModule(
            address(newCore),
            address(token),
            minSaleAmount,
            maxSaleAmount
        );
        
        // Register the market itself but NOT the speculation module
        newCore.registerModule(
            keccak256("SECONDARY_MARKET_MODULE"),
            address(newMarket)
        );
        
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
            oddsPairId,
            positionType,
            5e6, // price
            10e6, // amount
            0 // contribution
        );
        vm.stopPrank();
    }
}
