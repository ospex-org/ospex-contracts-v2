// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {OracleModule} from "../../src/modules/OracleModule.sol";
import {ContestModule} from "../../src/modules/ContestModule.sol";
import {TreasuryModule} from "../../src/modules/TreasuryModule.sol";
import {SpeculationModule} from "../../src/modules/SpeculationModule.sol";
import {LeaderboardModule} from "../../src/modules/LeaderboardModule.sol";
import {PositionModule} from "../../src/modules/PositionModule.sol";
import {OspexCore} from "../../src/core/OspexCore.sol";
import {Contest, ContestStatus, LeagueId, OracleRequestType, OracleRequestContext, Speculation, SpeculationStatus, WinSide} from "../../src/core/OspexTypes.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockLinkToken} from "../mocks/MockLinkToken.sol";
import {MockFunctionsRouter} from "../mocks/MockFunctionsRouter.sol";

// --- FulfillRequest tests ---
// Helper contract to expose internal fulfillRequest for testing
contract OracleModuleTestHelper is OracleModule {
    constructor(
        address core,
        address router,
        address link,
        bytes32 donId
    ) OracleModule(core, router, link, donId) {}
    function testFulfillRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory err
    ) public {
        fulfillRequest(requestId, response, err);
    }
    function setLastRequestId(bytes32 requestId) public {
        s_lastRequestId = requestId;
    }
    function setRequestMapping(bytes32 requestId, uint256 contestId) public {
        s_requestMapping[requestId] = contestId;
    }
    function setRequestContext(
        bytes32 requestId,
        OracleRequestType requestType,
        uint256 contestId
    ) public {
        s_requestContext[requestId] = OracleRequestContext({
            requestType: requestType,
            contestId: contestId
        });
    }
}

contract OracleModuleExposed is OracleModule {
    constructor(
        address core,
        address router,
        address link,
        bytes32 donId
    ) OracleModule(core, router, link, donId) {}

    function exposed_bytesToUint32(
        bytes memory input
    ) public pure returns (uint32 output) {
        if (input.length < 4) {
            revert OracleModule__InputTooShort(input.length, 4);
        }

        assembly {
            output := mload(add(input, 32))
        }
    }

    function exposed_bytesToUint256(
        bytes memory input
    ) public pure returns (uint256 output) {
        if (input.length < 32) {
            revert OracleModule__InputTooShort(input.length, 32);
        }
        assembly {
            output := mload(add(input, 32))
        }
    }

    function exposed_extractSpeculationData(
        uint256 _uint
    )
        public
        pure
        returns (int32 theNumber, uint64 upperOdds, uint64 lowerOdds)
    {
        // NOTE: Test version - copied exactly from production OracleModule.sol
        theNumber = int32(int256((_uint / 1e10) % 1e4)) - 1000; // 4 digits, offset back to +1000 (TODO: check this)
        upperOdds = exposed_americanToScaledDecimalOdds((_uint / 1e5) % 1e5); // next 5 digits
        lowerOdds = exposed_americanToScaledDecimalOdds(_uint % 1e5); // rightmost 5 digits
        return (theNumber, upperOdds, lowerOdds);
    }

    /**
     * @notice Exposed version of americanToScaledDecimalOdds for testing
     * @dev Converts American odds to scaled decimal odds exactly like production code
     * @param americanOdds American odds format (e.g., +150, -110), offset by +10000 in the packed data
     * @return uint64 Scaled decimal odds (e.g., 1.50 = 1.5e7)
     */
    function exposed_americanToScaledDecimalOdds(
        uint256 americanOdds
    ) public pure returns (uint64) {
        // --- Fetch the odds precision ---
        // NOTE: Test version - hardcoded constant instead of fetching from PositionModule
        // Production code uses: uint64(IPositionModule(_getModule(keccak256("POSITION_MODULE"))).ODDS_PRECISION())
        // ODDS_PRECISION is a constant that should not change under normal circumstances
        uint64 oddsPrecision = 10_000_000; // 1e7 - matches PositionModule.ODDS_PRECISION

        // Remove the +10000 offset to get the actual American odds (which can be negative)
        int256 americanOddsReversedOffset = int256(americanOdds) - 10000;
        if (americanOddsReversedOffset > 0) {
            return
                uint64(
                    (oddsPrecision) +
                        (uint64(uint256(americanOddsReversedOffset)) *
                            oddsPrecision) /
                        100
                );
        } else {
            return
                uint64(
                    (oddsPrecision) +
                        (oddsPrecision * 100) /
                        uint64(uint256(-americanOddsReversedOffset))
                );
        }
    }

    function exposed_extractLeagueIdAndStartTime(
        uint256 _uint
    ) public pure returns (LeagueId leagueId, uint32 startTime) {
        leagueId = LeagueId(uint8(_uint / 1e18));
        // Get last 10 digits (event time)
        startTime = uint32(_uint % 1e10);
        return (leagueId, startTime);
    }

    function exposed_uintToResultScore(
        uint32 _uint
    ) public pure returns (uint32[2] memory) {
        uint32[2] memory scoreArr;
        scoreArr[1] = _uint % 1000;
        scoreArr[0] = (_uint - scoreArr[1]) / 1000;
        return scoreArr;
    }

    function exposed_extractContestMarketData(
        uint256 _uint
    )
        public
        view
        returns (
            uint64 moneylineAwayOdds,
            uint64 moneylineHomeOdds,
            int32 spreadNumber,
            uint64 spreadAwayOdds,
            uint64 spreadHomeOdds,
            int32 totalNumber,
            uint64 overOdds,
            uint64 underOdds
        )
    {
        return extractContestMarketData(_uint);
    }
}

contract OracleModuleTest is Test {
    OracleModule oracleModule;
    ContestModule contestModule;
    TreasuryModule treasuryModule;
    SpeculationModule speculationModule;
    LeaderboardModule leaderboardModule;
    PositionModule positionModule;
    OspexCore core;
    MockLinkToken linkToken;
    MockFunctionsRouter router;
    MockERC20 usdc;
    bytes32 donId = bytes32(uint256(0x1234));
    address admin = address(0x1234);
    address user = address(0xBEEF);
    address notAdmin = address(0xBAD);

    // replicating internal var from OracleModule, the following should not change:
    uint256 LINK_DIVISIBILITY = 10 ** 18;

    OracleModuleTestHelper oracleHelper;
    OracleModuleExposed oracleExposed;

    // Leaderboard Ids and allocations set to 0 for testing
    uint256 leaderboardId = 0;

    function setUp() public virtual {
        // Deploy core, LINK, router
        core = new OspexCore();
        linkToken = new MockLinkToken();
        router = new MockFunctionsRouter(address(linkToken));
        usdc = new MockERC20();

        // Grant admin role to admin account
        core.grantRole(core.DEFAULT_ADMIN_ROLE(), admin);

        // Deploy OracleModule
        oracleModule = new OracleModule(
            address(core),
            address(router),
            address(linkToken),
            donId
        );
        // Deploy modules with proper addresses (not zero)
        treasuryModule = new TreasuryModule(
            address(core),
            address(0x1),
            address(0x2)
        );
        contestModule = new ContestModule(
            address(core),
            keccak256(abi.encodePacked("createContestSourceHash")),
            keccak256(abi.encodePacked("updateContestMarketsSourceHash"))
        );
        speculationModule = new SpeculationModule(address(core), 6);
        leaderboardModule = new LeaderboardModule(address(core));
        positionModule = new PositionModule(address(core), address(usdc));

        // Register modules - IMPORTANT: Register OracleModule FIRST so other modules can reference it
        core.registerModule(keccak256("ORACLE_MODULE"), address(oracleModule));
        core.registerModule(
            keccak256("TREASURY_MODULE"),
            address(treasuryModule)
        );
        core.registerModule(
            keccak256("CONTEST_MODULE"),
            address(contestModule)
        );
        core.registerModule(
            keccak256("SPECULATION_MODULE"),
            address(speculationModule)
        );
        core.registerModule(
            keccak256("LEADERBOARD_MODULE"),
            address(leaderboardModule)
        );
        core.registerModule(
            keccak256("POSITION_MODULE"),
            address(positionModule)
        );

        // Deploy helper for fulfillRequest and utility function tests
        oracleHelper = new OracleModuleTestHelper(
            address(core),
            address(router),
            address(linkToken),
            donId
        );

        // Initialize oracleExposed for utility tests
        oracleExposed = new OracleModuleExposed(
            address(core),
            address(router),
            address(linkToken),
            donId
        );

        // Give accounts some ETH
        vm.deal(admin, 10 ether);
        vm.deal(user, 10 ether);
    }

  function testConstructor_SetsStateCorrectly() public view {
      assertEq(address(oracleModule.i_ospexCore()), address(core));
      // s_router is now internal (managed by FunctionsClient), cannot check directly
      assertEq(oracleModule.i_donId(), donId);
      // i_linkAddress is internal, cannot check directly
      // assertEq(address(oracleModule.i_linkAddress()), address(linkToken));
  }

    function testCreateContestFromOracle_HappyPath() public {
        // Arrange: set up contest source hash to match what OracleModule expects
        bytes32 createContestSourceHash = contestModule
            .s_createContestSourceHash();
        console.log("ContestModule source hash:");
        console.logBytes32(createContestSourceHash);

        string memory rundownId = "rd";
        string memory sportspageId = "sp";
        string memory jsonoddsId = "jo";

        // Use the string that will generate the right hash when passed to keccak256
        string memory createContestSourceJS = "createContestSourceHash";
        console.log("Our source string:", createContestSourceJS);
        console.log("Our string hashed:");
        console.logBytes32(keccak256(abi.encodePacked(createContestSourceJS)));

        bytes32 scoreContestSourceHash = bytes32("scoreHash");
        bytes memory encryptedSecretsUrls = hex"";
        uint64 subscriptionId = 1;
        uint32 gasLimit = 500_000;
        // address contestCreator = user; // unused

        // User approves LINK payment to OracleModule
        uint256 payment = LINK_DIVISIBILITY / oracleModule.s_linkDenominator();
        linkToken.mint(user, payment);
        vm.prank(user);
        linkToken.approve(address(oracleModule), payment);

        // Expect ContestCreated event from ContestModule
        vm.expectEmit(true, false, false, true, address(contestModule));
        emit ContestModule.ContestCreated(
            1, // contestId (first contest)
            rundownId,
            sportspageId,
            jsonoddsId,
            user,
            scoreContestSourceHash
        );

        // Act: call createContestFromOracle as user
        vm.prank(user);
        oracleModule.createContestFromOracle(
            rundownId,
            sportspageId,
            jsonoddsId,
            createContestSourceJS,
            scoreContestSourceHash,
            leaderboardId,
            encryptedSecretsUrls,
            subscriptionId,
            gasLimit
        );

        // Assert: contest should be created in ContestModule
        uint256 contestId = contestModule.s_contestIdCounter();
        Contest memory c = contestModule.getContest(contestId);
        assertEq(c.rundownId, rundownId);
        assertEq(c.sportspageId, sportspageId);
        assertEq(c.jsonoddsId, jsonoddsId);
        assertEq(c.scoreContestSourceHash, scoreContestSourceHash);
        assertEq(c.contestCreator, user);
        // LeagueId should still be default (0) since oracle hasn't fulfilled request yet
        assertEq(uint(c.leagueId), 0);
        assertEq(uint(c.contestStatus), uint(ContestStatus.Unverified));
    }

    function testCreateContestFromOracle_RevertsIfIncorrectSourceHash() public {
        // Arrange: use a source string that does NOT match the hash in ContestModule
        string memory rundownId = "rd";
        string memory sportspageId = "sp";
        string memory jsonoddsId = "jo";
        string memory createContestSourceJS = "wrongSource"; // wrong source, will not match hash
        bytes32 scoreContestSourceHash = bytes32("scoreHash");
        bytes memory encryptedSecretsUrls = hex"";
        uint64 subscriptionId = 1;
        uint32 gasLimit = 500_000;

        // User approves LINK payment to OracleModule
        uint256 payment = LINK_DIVISIBILITY / oracleModule.s_linkDenominator();
        linkToken.mint(user, payment);
        vm.prank(user);
        linkToken.approve(address(oracleModule), payment);

        // Expect revert for incorrect source hash
        vm.prank(user);
        vm.expectRevert(
            OracleModule.OracleModule__IncorrectSourceHash.selector
        );
        oracleModule.createContestFromOracle(
            rundownId,
            sportspageId,
            jsonoddsId,
            createContestSourceJS,
            scoreContestSourceHash,
            leaderboardId,
            encryptedSecretsUrls,
            subscriptionId,
            gasLimit
        );
    }

    function testCreateContestFromOracle_RevertsIfContestModuleNotSet() public {
        // Create a new core instance without any modules registered
        OspexCore newCore = new OspexCore();
        newCore.grantRole(newCore.DEFAULT_ADMIN_ROLE(), admin);

        // Create a new OracleModule instance with the new core
        OracleModule newOracleModule = new OracleModule(
            address(newCore),
            address(router),
            address(linkToken),
            donId
        );
        // Register the new oracle module in the new core
        newCore.registerModule(
            keccak256("ORACLE_MODULE"),
            address(newOracleModule)
        );
        // Note: we intentionally DON'T register the CONTEST_MODULE

        string memory rundownId = "rd";
        string memory sportspageId = "sp";
        string memory jsonoddsId = "jo";
        string memory createContestSourceJS = "createContestSourceHash";
        bytes32 scoreContestSourceHash = bytes32("scoreHash");
        bytes memory encryptedSecretsUrls = hex"";
        uint64 subscriptionId = 1;
        uint32 gasLimit = 500_000;

        // User approves LINK payment to the new OracleModule
        uint256 payment = LINK_DIVISIBILITY /
            newOracleModule.s_linkDenominator();
        linkToken.mint(user, payment);
        vm.prank(user);
        linkToken.approve(address(newOracleModule), payment);

        // Expect revert for contest module not set
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                OracleModule.OracleModule__ModuleNotSet.selector,
                keccak256("CONTEST_MODULE")
            )
        );
        newOracleModule.createContestFromOracle(
            rundownId,
            sportspageId,
            jsonoddsId,
            createContestSourceJS,
            scoreContestSourceHash,
            leaderboardId,
            encryptedSecretsUrls,
            subscriptionId,
            gasLimit
        );
    }

    function testCreateContestFromOracle_RevertsIfLinkPaymentFails() public {
        // Arrange: do NOT approve enough LINK for payment
        string memory rundownId = "rd";
        string memory sportspageId = "sp";
        string memory jsonoddsId = "jo";
        string memory createContestSourceJS = "createContestSourceHash";
        bytes32 scoreContestSourceHash = bytes32("scoreHash");
        bytes memory encryptedSecretsUrls = hex"";
        uint64 subscriptionId = 1;
        uint32 gasLimit = 500_000;

        // User does NOT approve LINK (or approves less than required)
        linkToken.mint(user, 1); // much less than needed
        vm.prank(user);
        linkToken.approve(address(oracleModule), 1);

        // Expect revert for failed LINK transferFrom
        vm.prank(user);
        vm.expectRevert(); // Will revert on SafeERC20: transfer amount exceeds balance or allowance
        oracleModule.createContestFromOracle(
            rundownId,
            sportspageId,
            jsonoddsId,
            createContestSourceJS,
            scoreContestSourceHash,
            leaderboardId,
            encryptedSecretsUrls,
            subscriptionId,
            gasLimit
        );
    }

    function testCreateContestFromOracle_RevertsIfSubscriptionPaymentFails()
        public
    {
        // Arrange: set up contest source hash to match what OracleModule expects
        string memory rundownId = "rd";
        string memory sportspageId = "sp";
        string memory jsonoddsId = "jo";
        string memory createContestSourceJS = "createContestSourceHash";
        bytes32 scoreContestSourceHash = bytes32("scoreHash");
        bytes memory encryptedSecretsUrls = hex"";
        uint64 subscriptionId = 1;
        uint32 gasLimit = 500_000;
        uint256 payment = LINK_DIVISIBILITY / oracleModule.s_linkDenominator();
        linkToken.mint(user, payment);
        vm.prank(user);
        linkToken.approve(address(oracleModule), payment);
        // Make the LINK token return false on transferAndCall
        linkToken.setForceTransferAndCallReturnFalse(true);
        // Expect revert for subscription payment failed
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                OracleModule.OracleModule__SubscriptionPaymentFailed.selector,
                payment
            )
        );
        oracleModule.createContestFromOracle(
            rundownId,
            sportspageId,
            jsonoddsId,
            createContestSourceJS,
            scoreContestSourceHash,
            leaderboardId,
            encryptedSecretsUrls,
            subscriptionId,
            gasLimit
        );
    }

    function testScoreContestFromOracle_HappyPath() public {
        // Arrange: create and verify a contest
        string memory rundownId = "rd";
        string memory sportspageId = "sp";
        string memory jsonoddsId = "jo";
        string memory createContestSourceJS = "createContestSourceHash";
        bytes32 scoreContestSourceHash = keccak256(
            abi.encodePacked("scoreHash")
        );
        bytes memory encryptedSecretsUrls = hex"";
        uint64 subscriptionId = 1;
        uint32 gasLimit = 500_000;
        // address contestCreator = user; // unused

        // User approves LINK payment to OracleModule for creation
        uint256 payment = LINK_DIVISIBILITY / oracleModule.s_linkDenominator();
        linkToken.mint(user, payment * 2); // enough for both create and score
        vm.prank(user);
        linkToken.approve(address(oracleModule), payment * 2);

        // Create contest (as user)
        vm.prank(user);
        oracleModule.createContestFromOracle(
            rundownId,
            sportspageId,
            jsonoddsId,
            createContestSourceJS,
            scoreContestSourceHash,
            leaderboardId,
            encryptedSecretsUrls,
            subscriptionId,
            gasLimit
        );
        uint256 contestId = contestModule.s_contestIdCounter();

        // Set contest as verified and set start time in the past
        vm.prank(address(oracleModule));
        contestModule.setContestLeagueIdAndStartTime(
            contestId,
            LeagueId.NBA,
            uint32(block.timestamp - 1)
        );

        // Act: call scoreContestFromOracle as user
        string memory scoreContestSourceJS = "scoreHash";
        vm.prank(user);
        oracleModule.scoreContestFromOracle(
            contestId,
            scoreContestSourceJS,
            encryptedSecretsUrls,
            subscriptionId,
            gasLimit
        );
    }

    function testScoreContestFromOracle_RevertsIfNotVerified() public {
        // Arrange: create a contest (unverified)
        string memory rundownId = "rd";
        string memory sportspageId = "sp";
        string memory jsonoddsId = "jo";
        string memory createContestSourceJS = "createContestSourceHash";
        bytes32 scoreContestSourceHash = bytes32("scoreHash");
        bytes memory encryptedSecretsUrls = hex"";
        uint64 subscriptionId = 1;
        uint32 gasLimit = 500_000;

        uint256 payment = LINK_DIVISIBILITY / oracleModule.s_linkDenominator();
        linkToken.mint(user, payment * 2);
        vm.prank(user);
        linkToken.approve(address(oracleModule), payment * 2);

        vm.prank(user);
        oracleModule.createContestFromOracle(
            rundownId,
            sportspageId,
            jsonoddsId,
            createContestSourceJS,
            scoreContestSourceHash,
            leaderboardId,
            encryptedSecretsUrls,
            subscriptionId,
            gasLimit
        );
        uint256 contestId = contestModule.s_contestIdCounter();

        // Act & Assert: should revert because contest is not verified
        string memory scoreContestSourceJS = "scoreHash";
        vm.prank(user);
        vm.expectRevert(OracleModule.OracleModule__ContestNotVerified.selector);
        oracleModule.scoreContestFromOracle(
            contestId,
            scoreContestSourceJS,
            encryptedSecretsUrls,
            subscriptionId,
            gasLimit
        );
    }

    function testScoreContestFromOracle_RevertsIfIncorrectScoreSourceHash()
        public
    {
        // Arrange: create and verify a contest
        string memory rundownId = "rd";
        string memory sportspageId = "sp";
        string memory jsonoddsId = "jo";
        string memory createContestSourceJS = "createContestSourceHash";
        bytes32 scoreContestSourceHash = bytes32("scoreHash");
        bytes memory encryptedSecretsUrls = hex"";
        uint64 subscriptionId = 1;
        uint32 gasLimit = 500_000;

        uint256 payment = LINK_DIVISIBILITY / oracleModule.s_linkDenominator();
        linkToken.mint(user, payment * 2);
        vm.prank(user);
        linkToken.approve(address(oracleModule), payment * 2);

        vm.prank(user);
        oracleModule.createContestFromOracle(
            rundownId,
            sportspageId,
            jsonoddsId,
            createContestSourceJS,
            scoreContestSourceHash,
            leaderboardId,
            encryptedSecretsUrls,
            subscriptionId,
            gasLimit
        );
        uint256 contestId = contestModule.s_contestIdCounter();
        vm.prank(address(oracleModule));
        contestModule.setContestLeagueIdAndStartTime(
            contestId,
            LeagueId.NBA,
            uint32(block.timestamp - 1)
        );

        // Act & Assert: should revert due to incorrect score source hash
        string memory wrongScoreContestSourceJS = "notTheHash";
        vm.prank(user);
        vm.expectRevert(
            OracleModule.OracleModule__IncorrectScoreSourceHash.selector
        );
        oracleModule.scoreContestFromOracle(
            contestId,
            wrongScoreContestSourceJS,
            encryptedSecretsUrls,
            subscriptionId,
            gasLimit
        );
    }

    function testScoreContestFromOracle_RevertsIfContestNotStarted() public {
        // Arrange: create and verify a contest, but set start time in the future
        string memory rundownId = "rd";
        string memory sportspageId = "sp";
        string memory jsonoddsId = "jo";
        string memory scoreContestSourceJS = "scoreHash";
        bytes32 scoreContestSourceHash = keccak256(
            abi.encodePacked(scoreContestSourceJS)
        );
        bytes memory encryptedSecretsUrls = hex"";
        uint64 subscriptionId = 1;
        uint32 gasLimit = 500_000;

        uint256 payment = LINK_DIVISIBILITY / oracleModule.s_linkDenominator();
        linkToken.mint(user, payment * 2);
        vm.prank(user);
        linkToken.approve(address(oracleModule), payment * 2);

        // Create contest with correct hash
        vm.prank(user);
        oracleModule.createContestFromOracle(
            rundownId,
            sportspageId,
            jsonoddsId,
            "createContestSourceHash",
            scoreContestSourceHash,
            leaderboardId,
            encryptedSecretsUrls,
            subscriptionId,
            gasLimit
        );
        uint256 contestId = contestModule.s_contestIdCounter();
        // Set contest as verified but with a start time in the future
        vm.prank(address(oracleModule));
        contestModule.setContestLeagueIdAndStartTime(
            contestId,
            LeagueId.NBA,
            uint32(block.timestamp + 1000)
        ); // future

        // Act & Assert: should revert because contest has not started
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                OracleModule.OracleModule__ContestNotStarted.selector,
                contestId
            )
        );
        oracleModule.scoreContestFromOracle(
            contestId,
            scoreContestSourceJS,
            encryptedSecretsUrls,
            subscriptionId,
            gasLimit
        );
    }

    function testFulfillRequest_UnverifiedContest_SetsStartTime() public {
        // Create a separate contest module that recognizes the helper as the oracle module
        ContestModule testContestModule = new ContestModule(
            address(core),
            keccak256(abi.encodePacked("createContestSourceHash")),
            keccak256(abi.encodePacked("updateContestMarketsSourceHash"))
        );

        // First register the oracle helper as the ORACLE_MODULE
        core.registerModule(keccak256("ORACLE_MODULE"), address(oracleHelper));

        // Register the test contest module with the same key the oracle will look for
        core.registerModule(
            keccak256("CONTEST_MODULE"),
            address(testContestModule)
        );

        // Arrange: create contest (unverified)
        string memory rundownId = "rd";
        string memory sportspageId = "sp";
        string memory jsonoddsId = "jo";
        bytes32 scoreContestSourceHash = bytes32("scoreHash");
        address contestCreator = user;

        // Use vm.prank to have the call come from the oracleHelper
        vm.prank(address(oracleHelper));
        uint256 contestId = testContestModule.createContest(
            rundownId,
            sportspageId,
            jsonoddsId,
            scoreContestSourceHash,
            contestCreator,
            leaderboardId
        );

        // Simulate oracle request mapping
        bytes32 requestId = bytes32(uint256(0xAABB));
        oracleHelper.setLastRequestId(requestId);
        oracleHelper.setRequestMapping(requestId, contestId);

        // Set up the request context to simulate a ContestCreate request
        oracleHelper.setRequestContext(
            requestId,
            OracleRequestType.ContestCreate,
            contestId
        );

        // Simulate response: encode a uint256 with a start time in the last 10 digits
        // Use LeagueId.NBA (4) instead of 33 which is out of range
        uint256 contestData = 4000000000000000000000001234; // LeagueId.NBA (4) at position 1e18, startTime 1234 at end
        bytes memory response = abi.encodePacked(contestData);
        bytes memory err = hex"";
        // Expect Response event
        vm.expectEmit(true, true, true, true, address(oracleHelper));
        emit OracleModule.Response(requestId, response, err);
        // Act
        vm.prank(address(this));
        oracleHelper.testFulfillRequest(requestId, response, err);
        // Assert: start time should be set in ContestModule
        uint256 startTime = testContestModule.s_contestStartTimes(contestId);
        assertEq(startTime, 1234);
    }

    function testFulfillRequest_VerifiedContest_SetsScores() public {
        // Create a separate contest module that recognizes the helper as the oracle module
        ContestModule testContestModule = new ContestModule(
            address(core),
            keccak256(abi.encodePacked("createContestSourceHash")),
            keccak256(abi.encodePacked("updateContestMarketsSourceHash"))
        );

        // First register the oracle helper as the ORACLE_MODULE
        core.registerModule(keccak256("ORACLE_MODULE"), address(oracleHelper));

        // Register the test contest module with the same key the oracle will look for
        core.registerModule(
            keccak256("CONTEST_MODULE"),
            address(testContestModule)
        );

        // Arrange: create and verify contest
        string memory rundownId = "rd";
        string memory sportspageId = "sp";
        string memory jsonoddsId = "jo";
        bytes32 scoreContestSourceHash = bytes32("scoreHash");
        address contestCreator = user;

        // Use vm.prank to have the call come from the oracleHelper
        vm.prank(address(oracleHelper));
        uint256 contestId = testContestModule.createContest(
            rundownId,
            sportspageId,
            jsonoddsId,
            scoreContestSourceHash,
            contestCreator,
            leaderboardId
        );

        // Set contest as verified - use vm.prank here too
        vm.prank(address(oracleHelper));
        testContestModule.setContestLeagueIdAndStartTime(
            contestId,
            LeagueId.NBA,
            uint32(block.timestamp - 1)
        );

        // Simulate oracle request mapping
        bytes32 requestId = bytes32(uint256(0xBEEF));
        oracleHelper.setLastRequestId(requestId);
        oracleHelper.setRequestMapping(requestId, contestId);

        // Set up the request context to simulate a ContestScore request
        oracleHelper.setRequestContext(
            requestId,
            OracleRequestType.ContestScore,
            contestId
        );

        // Simulate response: encode a uint32 with scores (e.g., away=12, home=34 => 12*1000+34=12034)
        bytes memory response = abi.encode(uint32(12034));
        bytes memory err = hex"";

        // Expect Response event
        vm.expectEmit(true, true, true, true, address(oracleHelper));
        emit OracleModule.Response(requestId, response, err);
        // Act
        vm.prank(address(this));
        oracleHelper.testFulfillRequest(requestId, response, err);
        // Assert: scores should be set in ContestModule
        Contest memory c = testContestModule.getContest(contestId);
        assertEq(c.awayScore, 12);
        assertEq(c.homeScore, 34);
    }

    function testFulfillRequest_RevertsOnError() public {
        // Create a separate contest module that recognizes the helper as the oracle module
        ContestModule testContestModule = new ContestModule(
            address(core),
            keccak256(abi.encodePacked("createContestSourceHash")),
            keccak256(abi.encodePacked("updateContestMarketsSourceHash"))
        );

        // First register the oracle helper as the ORACLE_MODULE
        core.registerModule(keccak256("ORACLE_MODULE"), address(oracleHelper));

        // Then register the contest module
        core.registerModule(
            keccak256("TEST_CONTEST_MODULE"),
            address(testContestModule)
        );

        // Arrange: create contest
        string memory rundownId = "rd";
        string memory sportspageId = "sp";
        string memory jsonoddsId = "jo";
        bytes32 scoreContestSourceHash = bytes32("scoreHash");
        address contestCreator = user;

        // Use vm.prank to have the call come from the oracleHelper
        vm.prank(address(oracleHelper));
        uint256 contestId = testContestModule.createContest(
            rundownId,
            sportspageId,
            jsonoddsId,
            scoreContestSourceHash,
            contestCreator,
            leaderboardId
        );

        // Simulate oracle request mapping
        bytes32 requestId = bytes32(uint256(0xDEAD));
        oracleHelper.setLastRequestId(requestId);
        oracleHelper.setRequestMapping(requestId, contestId);
        bytes memory response = hex"";
        bytes memory err = hex"deadbeef";
        // Expect Response event
        vm.expectEmit(true, true, true, true, address(oracleHelper));
        emit OracleModule.Response(requestId, response, err);
        // Act & Assert - use a generic expectRevert without specifying the error
        vm.expectRevert();
        vm.prank(address(this));
        oracleHelper.testFulfillRequest(requestId, response, err);
    }

    function testFulfillRequest_RevertsOnUnexpectedRequestId() public {
        // Create a separate contest module that recognizes the helper as the oracle module
        ContestModule testContestModule = new ContestModule(
            address(core),
            keccak256(abi.encodePacked("createContestSourceHash")),
            keccak256(abi.encodePacked("updateContestMarketsSourceHash"))
        );

        // First register the oracle helper as the ORACLE_MODULE
        core.registerModule(keccak256("ORACLE_MODULE"), address(oracleHelper));

        // Then register the contest module
        core.registerModule(
            keccak256("TEST_CONTEST_MODULE"),
            address(testContestModule)
        );

        // Arrange: create contest
        string memory rundownId = "rd";
        string memory sportspageId = "sp";
        string memory jsonoddsId = "jo";
        bytes32 scoreContestSourceHash = bytes32("scoreHash");
        address contestCreator = user;

        // Use vm.prank to have the call come from the oracleHelper
        vm.prank(address(oracleHelper));
        uint256 contestId = testContestModule.createContest(
            rundownId,
            sportspageId,
            jsonoddsId,
            scoreContestSourceHash,
            contestCreator,
            leaderboardId
        );

        // Simulate oracle request mapping with a different requestId
        bytes32 requestId = bytes32(uint256(0x1111));
        oracleHelper.setLastRequestId(bytes32(uint256(0x2222))); // mismatch
        oracleHelper.setRequestMapping(requestId, contestId);
        bytes memory response = hex"";
        bytes memory err = hex"";
        // Act & Assert
        vm.expectRevert(
            abi.encodeWithSelector(
                OracleModule.OracleModule__UnexpectedRequestId.selector,
                requestId
            )
        );
        vm.prank(address(this));
        oracleHelper.testFulfillRequest(requestId, response, err);
    }

    // --- Utility/edge case tests ---
    function testBytesToUint32_RevertsIfInputTooShort() public {
        bytes memory input = hex"0102"; // only 2 bytes
        vm.expectRevert(
            abi.encodeWithSelector(
                OracleModule.OracleModule__InputTooShort.selector,
                2,
                4
            )
        );
        oracleExposed.exposed_bytesToUint32(input);
    }

    function testBytesToUint256_RevertsIfInputTooShort() public {
        bytes memory input = hex"0102"; // only 2 bytes
        vm.expectRevert(
            abi.encodeWithSelector(
                OracleModule.OracleModule__InputTooShort.selector,
                2,
                32
            )
        );
        oracleExposed.exposed_bytesToUint256(input);
    }

    function testSetLinkDenominator_HappyPath() public {
        uint256 newDenominator = 251;
        vm.prank(admin);
        oracleModule.setLinkDenominator(newDenominator);
        assertEq(oracleModule.s_linkDenominator(), newDenominator);
    }

    function testSetLinkDenominator_RevertsIfNotAdmin() public {
        uint256 newDenominator = 252;
        vm.prank(notAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                OracleModule.OracleModule__NotAdmin.selector,
                notAdmin
            )
        );
        oracleModule.setLinkDenominator(newDenominator);
    }

    // --- Utility Function Tests ---
    /**
     * @notice Tests unpacking of speculation data from oracle response
     * @dev The oracle returns a packed uint256 containing:
     *      - theNumber (4 digits, +1000 offset to allow negative values)
     *      - upperOdds (5 digits, +10000 offset American odds format)
     *      - lowerOdds (5 digits, +10000 offset American odds format)
     *      This test verifies the unpacking logic works correctly.
     */
    function testExtractSpeculationData() public view {
        // Pack test data: theNumber=150 (+1000 offset = 1150), upperOdds=+150 (+10000 offset = 10150), lowerOdds=-110 (+10000 offset = 9890)
        // Format: [theNumber (4 digits)][upperOdds (5 digits)][lowerOdds (5 digits)]
        uint256 packedData = 1150 * 1e10 + 10150 * 1e5 + 9890; // theNumber offset, upperOdds offset, lowerOdds offset

        (int32 theNumber, uint64 upperOdds, uint64 lowerOdds) = oracleExposed
            .exposed_extractSpeculationData(packedData);

        assertEq(theNumber, 150); // Should be 1150 - 1000 = 150
        // upperOdds and lowerOdds should be converted from American odds to scaled decimal odds
        assertTrue(upperOdds > 0);
        assertTrue(lowerOdds > 0);
    }

    /**
     * @notice Tests conversion of positive American odds to scaled decimal odds
     * @dev Positive American odds show profit per $100 bet. +150 means $150 profit on $100 bet.
     *      Decimal odds = 1 + (American odds / 100) = 1 + (150/100) = 2.5
     */
    function testAmericanToScaledDecimalOdds_PositiveOdds() public view {
        // Test positive American odds (+150) with +10000 offset = 10150
        uint256 americanOdds = 10150;
        uint64 result = oracleExposed.exposed_americanToScaledDecimalOdds(
            americanOdds
        );

        // For +150 American odds: decimal = 1 + (150/100) = 2.5
        // With ODDS_PRECISION = 1e7: 2.5 * 1e7 = 25000000
        uint64 expected = 25000000;
        assertEq(result, expected);
    }

    /**
     * @notice Tests conversion of negative American odds to scaled decimal odds
     * @dev Negative American odds show bet amount needed to win $100. -110 means bet $110 to win $100.
     *      Decimal odds = 1 + (100 / abs(American odds)) = 1 + (100/110) = 1.909...
     */
    function testAmericanToScaledDecimalOdds_NegativeOdds() public view {
        // Test negative American odds (-110) with +10000 offset = 9890
        uint256 americanOdds = 9890;
        uint64 result = oracleExposed.exposed_americanToScaledDecimalOdds(
            americanOdds
        );

        // For -110 American odds: decimal = 1 + (100/110) = 1.909...
        // With ODDS_PRECISION = 1e7: approximately 19090909
        uint64 expected = 19090909;
        assertEq(result, expected);
    }

    function testExtractLeagueIdAndStartTime() public view {
        // Test data: LeagueId.NBA (4) at position 1e18, startTime 1234567890 at end
        uint256 contestData = 4 * 1e18 + 1234567890;

        (LeagueId leagueId, uint32 startTime) = oracleExposed
            .exposed_extractLeagueIdAndStartTime(contestData);

        assertEq(uint(leagueId), 4); // LeagueId.NBA
        assertEq(startTime, 1234567890);
    }

    function testUintToResultScore() public view {
        // Test score: away=12, home=34 => 12*1000+34=12034
        uint32 packedScore = 12034;
        uint32[2] memory scores = oracleExposed.exposed_uintToResultScore(
            packedScore
        );

        assertEq(scores[0], 12); // away score
        assertEq(scores[1], 34); // home score
    }

    /**
     * @notice Tests that fulfillRequest reverts on invalid request type
     * @dev This test covers the final else branch that handles invalid request types
     */
    function testFulfillRequest_RevertsOnInvalidRequestType() public {
        // Arrange - create a minimal setup
        bytes32 requestId = bytes32(uint256(0xDEAD));
        oracleHelper.setLastRequestId(requestId);

        // Set an invalid request type (cast from a high number that's not in the enum)
        // We need to use the setRequestContext function, but OracleRequestType is an enum
        // Let's look at what values exist and use an invalid one

        // From OspexTypes.sol: ContestCreate=0, ContestMarketsUpdate=1, ContestScore=2
        // So we'll manually set the storage to an invalid value (e.g., 99)

        // First set a valid context, then manually override the requestType in storage
        oracleHelper.setRequestContext(
            requestId,
            OracleRequestType.ContestCreate,
            1
        );

        // Now manually override the requestType storage slot to an invalid value
        // The requestType is the first field in OracleRequestContext struct
        bytes32 contextSlot = keccak256(abi.encode(requestId, uint256(6))); // slot 6 is s_requestContext mapping
        vm.store(address(oracleHelper), contextSlot, bytes32(uint256(99))); // Invalid request type

        bytes memory response = hex"1234";
        bytes memory err = hex"";

        // Expect the InvalidRequestType revert
        // Note: We can't encode the exact error with an invalid enum value, so just expect any revert
        vm.expectRevert();

        // Act
        vm.prank(address(this));
        oracleHelper.testFulfillRequest(requestId, response, err);
    }

    // --- Contest Markets Update Tests ---
    function testUpdateContestMarketsFromOracle_HappyPath() public {
        // Arrange: create and verify a contest first
        string memory rundownId = "rd";
        string memory sportspageId = "sp";
        string memory jsonoddsId = "jo";
        string memory createContestSourceJS = "createContestSourceHash";
        bytes32 scoreContestSourceHash = bytes32("scoreHash");
        bytes memory encryptedSecretsUrls = hex"";
        uint64 subscriptionId = 1;
        uint32 gasLimit = 500_000;

        // User approves LINK payment for both create and update
        uint256 payment = LINK_DIVISIBILITY / oracleModule.s_linkDenominator();
        linkToken.mint(user, payment * 2);
        vm.prank(user);
        linkToken.approve(address(oracleModule), payment * 2);

        // Create contest
        vm.prank(user);
        oracleModule.createContestFromOracle(
            rundownId,
            sportspageId,
            jsonoddsId,
            createContestSourceJS,
            scoreContestSourceHash,
            leaderboardId,
            encryptedSecretsUrls,
            subscriptionId,
            gasLimit
        );
        uint256 contestId = contestModule.s_contestIdCounter();

        // Verify contest
        vm.prank(address(oracleModule));
        contestModule.setContestLeagueIdAndStartTime(
            contestId,
            LeagueId.NBA,
            uint32(block.timestamp - 1)
        );

        // Act: call updateContestMarketsFromOracle
        string memory contestMarketsUpdateSourceJS = "updateContestMarketsSourceHash";
        vm.prank(user);
        oracleModule.updateContestMarketsFromOracle(
            contestId,
            contestMarketsUpdateSourceJS,
            encryptedSecretsUrls,
            subscriptionId,
            gasLimit
        );

        // Assert: oracle request should be sent (we can't easily verify the exact request without more mocking)
        // The main validation is that it doesn't revert, which means all validations passed
    }

    function testUpdateContestMarketsFromOracle_RevertsIfIncorrectSourceHash() public {
        // Arrange: create and verify contest
        string memory rundownId = "rd";
        string memory sportspageId = "sp"; 
        string memory jsonoddsId = "jo";
        string memory createContestSourceJS = "createContestSourceHash";
        bytes32 scoreContestSourceHash = bytes32("scoreHash");
        bytes memory encryptedSecretsUrls = hex"";
        uint64 subscriptionId = 1;
        uint32 gasLimit = 500_000;

        uint256 payment = LINK_DIVISIBILITY / oracleModule.s_linkDenominator();
        linkToken.mint(user, payment * 2);
        vm.prank(user);
        linkToken.approve(address(oracleModule), payment * 2);

        vm.prank(user);
        oracleModule.createContestFromOracle(
            rundownId,
            sportspageId,
            jsonoddsId,
            createContestSourceJS,
            scoreContestSourceHash,
            leaderboardId,
            encryptedSecretsUrls,
            subscriptionId,
            gasLimit
        );
        uint256 contestId = contestModule.s_contestIdCounter();

        // Verify contest
        vm.prank(address(oracleModule));
        contestModule.setContestLeagueIdAndStartTime(
            contestId,
            LeagueId.NBA,
            uint32(block.timestamp - 1)
        );

        // Act & Assert: should revert due to incorrect source hash
        string memory wrongSourceJS = "wrongSource";
        vm.prank(user);
        vm.expectRevert(OracleModule.OracleModule__IncorrectUpdateSourceHash.selector);
        oracleModule.updateContestMarketsFromOracle(
            contestId,
            wrongSourceJS,
            encryptedSecretsUrls,
            subscriptionId,
            gasLimit
        );
    }

    function testUpdateContestMarketsFromOracle_RevertsIfContestNotVerified() public {
        // Arrange: create contest but DON'T verify it
        string memory rundownId = "rd";
        string memory sportspageId = "sp";
        string memory jsonoddsId = "jo";
        string memory createContestSourceJS = "createContestSourceHash";
        bytes32 scoreContestSourceHash = bytes32("scoreHash");
        bytes memory encryptedSecretsUrls = hex"";
        uint64 subscriptionId = 1;
        uint32 gasLimit = 500_000;

        uint256 payment = LINK_DIVISIBILITY / oracleModule.s_linkDenominator();
        linkToken.mint(user, payment * 2);
        vm.prank(user);
        linkToken.approve(address(oracleModule), payment * 2);

        vm.prank(user);
        oracleModule.createContestFromOracle(
            rundownId,
            sportspageId,
            jsonoddsId,
            createContestSourceJS,
            scoreContestSourceHash,
            leaderboardId,
            encryptedSecretsUrls,
            subscriptionId,
            gasLimit
        );
        uint256 contestId = contestModule.s_contestIdCounter();

        // DON'T verify contest - leave it as Unverified

        // Act & Assert: should revert because contest is not verified
        string memory contestMarketsUpdateSourceJS = "updateContestMarketsSourceHash";
        vm.prank(user);
        vm.expectRevert(OracleModule.OracleModule__ContestNotVerified.selector);
        oracleModule.updateContestMarketsFromOracle(
            contestId,
            contestMarketsUpdateSourceJS,
            encryptedSecretsUrls,
            subscriptionId,
            gasLimit
        );
    }

    function testUpdateContestMarketsFromOracle_RevertsIfLinkPaymentFails() public {
        // Arrange: create and verify contest
        string memory rundownId = "rd";
        string memory sportspageId = "sp";
        string memory jsonoddsId = "jo";
        string memory createContestSourceJS = "createContestSourceHash";
        bytes32 scoreContestSourceHash = bytes32("scoreHash");
        bytes memory encryptedSecretsUrls = hex"";
        uint64 subscriptionId = 1;
        uint32 gasLimit = 500_000;

        uint256 payment = LINK_DIVISIBILITY / oracleModule.s_linkDenominator();
        linkToken.mint(user, payment);
        vm.prank(user);
        linkToken.approve(address(oracleModule), payment);

        vm.prank(user);
        oracleModule.createContestFromOracle(
            rundownId,
            sportspageId,
            jsonoddsId,
            createContestSourceJS,
            scoreContestSourceHash,
            leaderboardId,
            encryptedSecretsUrls,
            subscriptionId,
            gasLimit
        );
        uint256 contestId = contestModule.s_contestIdCounter();

        vm.prank(address(oracleModule));
        contestModule.setContestLeagueIdAndStartTime(
            contestId,
            LeagueId.NBA,
            uint32(block.timestamp - 1)
        );

        // User has no more LINK for the update call
        assertEq(linkToken.balanceOf(user), 0);

        // Act & Assert: should revert due to insufficient LINK
        string memory contestMarketsUpdateSourceJS = "updateContestMarketsSourceHash";
        vm.prank(user);
        vm.expectRevert(); // Will revert on SafeERC20: transfer amount exceeds balance
        oracleModule.updateContestMarketsFromOracle(
            contestId,
            contestMarketsUpdateSourceJS,
            encryptedSecretsUrls,
            subscriptionId,
            gasLimit
        );
    }

    function testFulfillRequest_ContestMarketsUpdate_UpdatesMarkets() public {
        // Create a separate contest module that recognizes the helper as the oracle module
        ContestModule testContestModule = new ContestModule(
            address(core),
            keccak256(abi.encodePacked("createContestSourceHash")),
            keccak256(abi.encodePacked("updateContestMarketsSourceHash"))
        );

        // Register the oracle helper as the ORACLE_MODULE
        core.registerModule(keccak256("ORACLE_MODULE"), address(oracleHelper));

        // Register the test contest module
        core.registerModule(
            keccak256("CONTEST_MODULE"),
            address(testContestModule)
        );

        // Register mock scorer modules for the market updates
        address moneylineScorer = address(0xAAA1);
        address spreadScorer = address(0xAAA2);
        address totalScorer = address(0xAAA3);
        core.registerModule(keccak256("MONEYLINE_SCORER"), moneylineScorer);
        core.registerModule(keccak256("SPREAD_SCORER"), spreadScorer);
        core.registerModule(keccak256("TOTAL_SCORER"), totalScorer);

        // Arrange: create and verify contest
        string memory rundownId = "rd";
        string memory sportspageId = "sp";
        string memory jsonoddsId = "jo";
        bytes32 scoreContestSourceHash = bytes32("scoreHash");
        address contestCreator = user;

        vm.prank(address(oracleHelper));
        uint256 contestId = testContestModule.createContest(
            rundownId,
            sportspageId,
            jsonoddsId,
            scoreContestSourceHash,
            contestCreator,
            leaderboardId
        );

        // Verify contest
        vm.prank(address(oracleHelper));
        testContestModule.setContestLeagueIdAndStartTime(
            contestId,
            LeagueId.NBA,
            uint32(block.timestamp - 1)
        );

        // Simulate oracle request mapping
        bytes32 requestId = bytes32(uint256(0x4D41524B4554)); // "MARKET" in hex
        oracleHelper.setLastRequestId(requestId);
        oracleHelper.setRequestMapping(requestId, contestId);

        // Set up the request context for ContestMarketsUpdate
        oracleHelper.setRequestContext(
            requestId,
            OracleRequestType.ContestMarketsUpdate,
            contestId
        );

        // Create test market data using realistic betting odds
        // Format: [moneylineAway(5)][moneylineHome(5)][spread(4)][spreadAwayLine(5)][spreadHomeLine(5)][total(4)][overLine(5)][underLine(5)]
        // Using standard betting odds with proper +10000 offset for negative values
        uint256 marketData = 
            10150 * 1e33 + // moneylineAway: +150 -> 10150 (after +10000 offset)
            9890 * 1e28 +  // moneylineHome: -110 -> 9890 (after +10000 offset)
            965 * 1e24 +   // spread: -3.5 -> -35 -> 965 (1000-35)
            10105 * 1e19 + // spreadAwayOdds: +105 -> 10105 (after +10000 offset)
            9875 * 1e14 +  // spreadHomeOdds: -125 -> 9875 (after +10000 offset)
            1220 * 1e10 +  // total: 22.0 -> 220 -> 1220 (1000+220)
            9890 * 1e5 +   // overOdds: -110 -> 9890 (after +10000 offset)
            9890;          // underOdds: -110 -> 9890 (after +10000 offset)

        bytes memory response = abi.encode(marketData);
        bytes memory err = hex"";

        // Expect Response event
        vm.expectEmit(true, true, true, true, address(oracleHelper));
        emit OracleModule.Response(requestId, response, err);

        // Act
        vm.prank(address(this));
        oracleHelper.testFulfillRequest(requestId, response, err);

        // Assert: verify that markets were updated (we can check one of them)
        // Note: We can't easily verify the exact odds without knowing the ODDS_PRECISION,
        // but we can verify the market structure was updated
        // The main assertion is that the call succeeded without reverting
    }

    // --- Utility Function Tests ---
    function testExtractContestMarketData_ValidData() public view {
        // Test with realistic packed data - bug is now fixed!
        // Format: [moneylineAway(5)][moneylineHome(5)][spread(4)][spreadAwayLine(5)][spreadHomeLine(5)][total(4)][overLine(5)][underLine(5)]
        // Using standard betting odds: +120/-110, spread -3.5 with +105/-125, total 21.0 with -110/-110
        uint256 packedData = 
            10120 * 1e33 + // moneylineAway: +120 -> 10120 (after +10000 offset)
            9890 * 1e28 +  // moneylineHome: -110 -> 9890 (after +10000 offset)
            965 * 1e24 +   // spread: -3.5 -> -35 -> 965 (1000-35)
            10105 * 1e19 + // spreadAwayOdds: +105 -> 10105 (after +10000 offset)
            9875 * 1e14 +  // spreadHomeOdds: -125 -> 9875 (after +10000 offset)
            1210 * 1e10 +  // total: 21.0 -> 210 -> 1210 (1000+210)
            9890 * 1e5 +   // overOdds: -110 -> 9890 (after +10000 offset)
            9890;          // underOdds: -110 -> 9890 (after +10000 offset)

        (
            uint64 moneylineAwayOdds,
            uint64 moneylineHomeOdds,
            int32 spreadNumber,
            uint64 spreadAwayOdds,
            uint64 spreadHomeOdds,
            int32 totalNumber,
            uint64 overOdds,
            uint64 underOdds
        ) = oracleExposed.exposed_extractContestMarketData(packedData);

        // Verify that numbers are extracted correctly
        assertEq(spreadNumber, -35); // -3.5 points -> -35 (scaled by 10)
        assertEq(totalNumber, 210);  // 21.0 points -> 210 (scaled by 10)

        // Verify that odds conversion produces non-zero results
        assertTrue(moneylineAwayOdds > 0);
        assertTrue(moneylineHomeOdds > 0);
        assertTrue(spreadAwayOdds > 0);
        assertTrue(spreadHomeOdds > 0);
        assertTrue(overOdds > 0);
        assertTrue(underOdds > 0);
    }

    function testExtractContestMarketData_EdgeCaseValues() public view {
        // Test with edge case values that are still realistic
        uint256 packedData = 
            15000 * 1e33 + // High positive odds: +5000 -> 15000 (after +10000 offset)
            10001 * 1e28 + // Very low positive odds: +1 -> 10001 (after +10000 offset)
            1100 * 1e24 +  // Positive spread: +10.0 -> 100 -> 1100 (1000+100)
            10001 * 1e19 + // Very low positive odds: +1 -> 10001 (after +10000 offset)
            15000 * 1e14 + // High positive odds: +5000 -> 15000 (after +10000 offset)
            1005 * 1e10 +  // Low total: 0.5 -> 5 -> 1005 (1000+5)
            10001 * 1e5 +  // Very low positive odds: +1 -> 10001 (after +10000 offset)
            15000;         // High positive odds: +5000 -> 15000 (after +10000 offset)

        (
            uint64 moneylineAwayOdds,
            uint64 moneylineHomeOdds,
            int32 spreadNumber,
            uint64 spreadAwayOdds,
            uint64 spreadHomeOdds,
            int32 totalNumber,
            uint64 overOdds,
            uint64 underOdds
        ) = oracleExposed.exposed_extractContestMarketData(packedData);

        // Verify edge case number extraction
        assertEq(spreadNumber, 100);  // +10.0 points
        assertEq(totalNumber, 5);     // 0.5 points

        // All odds should still be positive after conversion
        assertTrue(moneylineAwayOdds > 0);
        assertTrue(moneylineHomeOdds > 0);
        assertTrue(spreadAwayOdds > 0);
        assertTrue(spreadHomeOdds > 0);
        assertTrue(overOdds > 0);
        assertTrue(underOdds > 0);
    }

    function testAmericanToScaledDecimalOdds_EdgeCases() public view {
        // Test moderate positive odds (+500)
        uint256 moderateHighOdds = 10500; // +500 with +10000 offset
        uint64 result = oracleExposed.exposed_americanToScaledDecimalOdds(moderateHighOdds);
        assertTrue(result > 0);

        // Test very low positive odds (+1)  
        uint256 veryLowOdds = 10001; // +1 with +10000 offset
        uint64 result2 = oracleExposed.exposed_americanToScaledDecimalOdds(veryLowOdds);
        assertTrue(result2 > 0);

        // Test moderate negative odds (-500)
        uint256 moderateNegative = 9500; // -500 with +10000 offset  
        uint64 result3 = oracleExposed.exposed_americanToScaledDecimalOdds(moderateNegative);
        assertTrue(result3 > 0);
        
        // Test very negative odds (-1000) 
        uint256 highNegative = 9000; // -1000 with +10000 offset
        uint64 result4 = oracleExposed.exposed_americanToScaledDecimalOdds(highNegative);
        assertTrue(result4 > 0);
    }
}
