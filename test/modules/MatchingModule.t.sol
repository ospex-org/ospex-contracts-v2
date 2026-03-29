// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// [NOTE] All test amounts use 6 decimals (USDC-style): 1 USDC = 1_000_000
// [NOTE] oddsTick uses integer ticks: 1.91 = 191, 1.93 = 193, etc.
// [NOTE] ODDS_SCALE = 100, so riskAmount must be divisible by 100

import "forge-std/Test.sol";
import {MatchingModule} from "../../src/modules/MatchingModule.sol";
import {PositionType, Position, Contest, ContestStatus, LeagueId, Leaderboard} from "../../src/core/OspexTypes.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {PositionModule} from "../../src/modules/PositionModule.sol";
import {OspexCore} from "../../src/core/OspexCore.sol";
import {ContributionModule} from "../../src/modules/ContributionModule.sol";
import {SpeculationModule} from "../../src/modules/SpeculationModule.sol";
import {TreasuryModule} from "../../src/modules/TreasuryModule.sol";
import {MockContestModule} from "../mocks/MockContestModule.sol";

// =============================================================================
// Mock OspexCore -- returns module addresses by type key.
// =============================================================================
contract MockOspexCoreForMatching {
    mapping(bytes32 => address) private _modules;

    event CoreEventEmitted(bytes32 indexed eventType, bytes eventData);

    function setModule(bytes32 moduleType, address moduleAddress) external {
        _modules[moduleType] = moduleAddress;
    }

    function getModule(bytes32 moduleType) external view returns (address) {
        return _modules[moduleType];
    }

    function emitCoreEvent(bytes32 eventType, bytes calldata eventData) external {
        emit CoreEventEmitted(eventType, eventData);
    }
}

// =============================================================================
// Mock PositionModule -- implements recordFill with configurable return values
// and call tracking. This is the minimum surface MatchingModule calls.
// =============================================================================
contract MockPositionModuleForMatching {
    uint256 public returnSpeculationId = 1;

    uint256 public recordFillCallCount;
    uint256 public lastContestId;
    address public lastScorer;
    int32 public lastTheNumber;
    uint256 public lastLeaderboardId;
    PositionType public lastMakerPositionType;
    address public lastMaker;
    uint256 public lastMakerRisk;
    address public lastTaker;
    uint256 public lastTakerRisk;
    uint256 public lastMakerContributionAmount;
    uint256 public lastTakerContributionAmount;

    function setReturnSpeculationId(uint256 id) external {
        returnSpeculationId = id;
    }

    function recordFill(
        uint256 contestId,
        address scorer,
        int32 theNumber,
        uint256 leaderboardId,
        PositionType makerPositionType,
        address maker,
        uint256 makerRisk,
        address taker,
        uint256 takerRisk,
        uint256 makerContributionAmount,
        uint256 takerContributionAmount
    ) external returns (uint256) {
        recordFillCallCount++;
        lastContestId = contestId;
        lastScorer = scorer;
        lastTheNumber = theNumber;
        lastLeaderboardId = leaderboardId;
        lastMakerPositionType = makerPositionType;
        lastMaker = maker;
        lastMakerRisk = makerRisk;
        lastTaker = taker;
        lastTakerRisk = takerRisk;
        lastMakerContributionAmount = makerContributionAmount;
        lastTakerContributionAmount = takerContributionAmount;
        return returnSpeculationId;
    }
}

// =============================================================================
// Reentrant Mock -- attempts to call matchCommitment from within
// recordFill to verify nonReentrant protection.
// =============================================================================
contract ReentrantMockPositionModule {
    address public matchingModuleAddr;
    bool public shouldReenter;

    function setTarget(address _target) external {
        matchingModuleAddr = _target;
    }

    function setShouldReenter(bool _val) external {
        shouldReenter = _val;
    }

    function recordFill(
        uint256, address, int32, uint256, PositionType, address, uint256, address, uint256, uint256, uint256
    ) external returns (uint256) {
        if (shouldReenter) {
            MatchingModule.OspexCommitment memory c = MatchingModule.OspexCommitment({
                maker: address(1),
                contestId: 1,
                scorer: address(2),
                theNumber: 0,
                positionType: PositionType.Upper,
                oddsTick: 191,
                riskAmount: 1_000_000,
                contributionAmount: 0,
                nonce: 1,
                expiry: block.timestamp + 1 hours
            });
            MatchingModule(matchingModuleAddr).matchCommitment(c, "", 1_000_000, 0, 0);
        }
        return 0;
    }
}

// =============================================================================
// Test Contract
// =============================================================================
contract MatchingModuleTest is Test {
    MatchingModule matchingModule;
    MockOspexCoreForMatching mockCore;
    MockPositionModuleForMatching mockPosition;

    uint256 constant MAKER_PK = 0xA11CE;
    address maker;
    uint256 constant OTHER_PK = 0xB0B;
    address otherSigner;

    address taker = address(0xBBBB);
    address taker2 = address(0xCCCC);
    address defaultScorer = address(0xDDDD);

    uint256 constant DEFAULT_RISK_AMOUNT = 100_000_000; // 100 USDC
    uint256 constant DEFAULT_TAKER_DESIRED_RISK = 10_000_000; // 10 USDC
    uint16 constant DEFAULT_ODDS_TICK = 191; // 1.91
    uint256 constant DEFAULT_CONTEST_ID = 1;
    int32 constant DEFAULT_THE_NUMBER = 0;
    uint16 constant ODDS_SCALE = 100;

    function setUp() public {
        maker = vm.addr(MAKER_PK);
        otherSigner = vm.addr(OTHER_PK);

        mockCore = new MockOspexCoreForMatching();
        mockPosition = new MockPositionModuleForMatching();

        mockCore.setModule(keccak256("POSITION_MODULE"), address(mockPosition));

        matchingModule = new MatchingModule(address(mockCore));

        mockPosition.setReturnSpeculationId(1);
    }

    // ===================== HELPERS =====================

    function _defaultCommitment() internal view returns (MatchingModule.OspexCommitment memory) {
        return MatchingModule.OspexCommitment({
            maker: maker,
            contestId: DEFAULT_CONTEST_ID,
            scorer: defaultScorer,
            theNumber: DEFAULT_THE_NUMBER,
            positionType: PositionType.Upper,
            oddsTick: DEFAULT_ODDS_TICK,
            riskAmount: DEFAULT_RISK_AMOUNT,
            contributionAmount: 0,
            nonce: 1,
            expiry: block.timestamp + 1 hours
        });
    }

    function _signCommitment(
        MatchingModule.OspexCommitment memory c,
        uint256 pk
    ) internal view returns (bytes memory) {
        bytes32 digest = matchingModule.getCommitmentHash(c);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signedDefault() internal view returns (
        MatchingModule.OspexCommitment memory c,
        bytes memory sig
    ) {
        c = _defaultCommitment();
        sig = _signCommitment(c, MAKER_PK);
    }

    function _matchDefault() internal returns (
        MatchingModule.OspexCommitment memory c,
        bytes memory sig
    ) {
        (c, sig) = _signedDefault();
        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_DESIRED_RISK, 0, 0);
    }

    function _expectSignatureRevert(
        MatchingModule.OspexCommitment memory tampered,
        bytes memory validSig
    ) internal {
        vm.prank(taker);
        vm.expectRevert(MatchingModule.MatchingModule__InvalidSignature.selector);
        matchingModule.matchCommitment(tampered, validSig, DEFAULT_TAKER_DESIRED_RISK, 0, 0);
    }

    // ===================== CONSTRUCTOR TESTS =====================

    function test_ConstructorRejectsZeroOspexCore() public {
        vm.expectRevert(MatchingModule.MatchingModule__InvalidAddress.selector);
        new MatchingModule(address(0));
    }

    function test_ConstructorSetsImmutables() public view {
        assertEq(address(matchingModule.i_ospexCore()), address(mockCore));
    }

    // ===================== SIGNATURE SECURITY =====================

    function test_ValidSignatureAccepted() public {
        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedDefault();
        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_DESIRED_RISK, 0, 0);
        assertEq(mockPosition.recordFillCallCount(), 1);
    }

    function test_WrongSignerReverts() public {
        MatchingModule.OspexCommitment memory c = _defaultCommitment();
        bytes memory wrongSig = _signCommitment(c, OTHER_PK);
        _expectSignatureRevert(c, wrongSig);
    }

    function test_TamperedField_OddsTick() public {
        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedDefault();
        c.oddsTick = 200;
        _expectSignatureRevert(c, sig);
    }

    function test_TamperedField_RiskAmount() public {
        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedDefault();
        c.riskAmount = 200_000_000;
        _expectSignatureRevert(c, sig);
    }

    function test_TamperedField_ContestId() public {
        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedDefault();
        c.contestId = 999;
        _expectSignatureRevert(c, sig);
    }

    function test_TamperedField_Scorer() public {
        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedDefault();
        c.scorer = address(0x9999);
        _expectSignatureRevert(c, sig);
    }

    function test_TamperedField_TheNumber() public {
        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedDefault();
        c.theNumber = 5;
        _expectSignatureRevert(c, sig);
    }

    function test_TamperedField_PositionType() public {
        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedDefault();
        c.positionType = PositionType.Lower;
        _expectSignatureRevert(c, sig);
    }

    function test_TamperedField_Nonce() public {
        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedDefault();
        c.nonce = 999;
        _expectSignatureRevert(c, sig);
    }

    function test_TamperedField_Expiry() public {
        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedDefault();
        c.expiry = block.timestamp + 2 hours;
        _expectSignatureRevert(c, sig);
    }

    function test_TamperedField_ContributionAmount() public {
        MatchingModule.OspexCommitment memory c = _defaultCommitment();
        c.contributionAmount = 500;
        bytes memory sig = _signCommitment(c, MAKER_PK);
        c.contributionAmount = 999_999;
        _expectSignatureRevert(c, sig);
    }

    function test_TamperedField_Maker() public {
        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedDefault();
        c.maker = otherSigner;
        _expectSignatureRevert(c, sig);
    }

    function test_ZeroAddressMakerReverts() public {
        MatchingModule.OspexCommitment memory c = _defaultCommitment();
        c.maker = address(0);
        vm.prank(taker);
        vm.expectRevert(MatchingModule.MatchingModule__InvalidMakerAddress.selector);
        matchingModule.matchCommitment(c, "", DEFAULT_TAKER_DESIRED_RISK, 0, 0);
    }

    function test_ReplayAfterFullFillReverts() public {
        // Independent calc: oddsTick=191, takerDesiredRisk=10_000_000
        // profitTicks = 191 - 100 = 91
        // rawFillMakerRisk = ceil(10_000_000 * 100 / 91) = ceil(1_000_000_000 / 91) = 10_989_011
        // fillMakerRisk = 10_989_011 - (10_989_011 % 100) = 10_989_011 - 11 = 10_989_000
        uint256 fillMakerRisk = 10_989_000;

        MatchingModule.OspexCommitment memory c = _defaultCommitment();
        c.riskAmount = fillMakerRisk;
        bytes memory sig = _signCommitment(c, MAKER_PK);

        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_DESIRED_RISK, 0, 0);

        vm.prank(taker);
        vm.expectRevert(MatchingModule.MatchingModule__CommitmentFullyFilled.selector);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_DESIRED_RISK, 0, 0);
    }

    function test_ReplayAfterCancellationReverts() public {
        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedDefault();
        vm.prank(maker);
        matchingModule.cancelCommitment(c);
        vm.prank(taker);
        vm.expectRevert(MatchingModule.MatchingModule__CommitmentCancelled.selector);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_DESIRED_RISK, 0, 0);
    }

    // ===================== PARTIAL FILL ACCOUNTING =====================

    function test_PartialFillRecordsCorrectAmount() public {
        // Independent calc: oddsTick=191, takerDesiredRisk=10_000_000
        // profitTicks = 91
        // rawFillMakerRisk = ceil(1_000_000_000 / 91) = 10_989_011
        // fillMakerRisk = 10_989_011 - 11 = 10_989_000
        uint256 fillMakerRisk = 10_989_000;

        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedDefault();
        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_DESIRED_RISK, 0, 0);

        bytes32 commitmentHash = matchingModule.getCommitmentHash(c);
        assertEq(matchingModule.s_filledRisk(commitmentHash), fillMakerRisk);
        // remaining = 100_000_000 - 10_989_000 = 89_011_000
        assertEq(matchingModule.getRemainingRisk(c), 89_011_000);
    }

    function test_PartialFillAllowsSecondFillForRemainder() public {
        // Independent calc: oddsTick=191, takerDesiredRisk=10_000_000
        // profitTicks = 91, fillMakerRisk = 10_989_000
        uint256 fillMakerRisk = 10_989_000;

        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedDefault();

        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_DESIRED_RISK, 0, 0);
        // remaining = 100_000_000 - 10_989_000 = 89_011_000
        assertEq(matchingModule.getRemainingRisk(c), 89_011_000);

        vm.prank(taker2);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_DESIRED_RISK, 0, 0);
        // remaining = 89_011_000 - 10_989_000 = 78_022_000
        assertEq(matchingModule.getRemainingRisk(c), 78_022_000);

        assertEq(mockPosition.lastMakerRisk(), fillMakerRisk);
    }

    function test_MultipleTakersPartialFill() public {
        // Independent calc: oddsTick=191, takerDesiredRisk=10_000_000
        // profitTicks = 91, fillMakerRisk = 10_989_000

        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedDefault();

        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_DESIRED_RISK, 0, 0);
        // remaining = 100_000_000 - 10_989_000 = 89_011_000
        assertEq(matchingModule.getRemainingRisk(c), 89_011_000);

        vm.prank(taker2);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_DESIRED_RISK, 0, 0);
        // remaining = 100_000_000 - 2 * 10_989_000 = 78_022_000
        assertEq(matchingModule.getRemainingRisk(c), 78_022_000);

        vm.prank(address(0xEEEE));
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_DESIRED_RISK, 0, 0);
        // remaining = 100_000_000 - 3 * 10_989_000 = 67_033_000
        assertEq(matchingModule.getRemainingRisk(c), 67_033_000);
    }

    function test_FullyFilledReverts() public {
        // Independent calc: oddsTick=191, takerDesiredRisk=10_000_000
        // fillMakerRisk = 10_989_000 (see above)
        uint256 fillMakerRisk = 10_989_000;

        MatchingModule.OspexCommitment memory c = _defaultCommitment();
        c.riskAmount = fillMakerRisk;
        bytes memory sig = _signCommitment(c, MAKER_PK);

        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_DESIRED_RISK, 0, 0);

        vm.prank(taker);
        vm.expectRevert(MatchingModule.MatchingModule__CommitmentFullyFilled.selector);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_DESIRED_RISK, 0, 0);
    }

    function test_FillRecordsCalculatedMakerRisk() public {
        // Independent calc: oddsTick=191, takerDesiredRisk=10_000_000
        // fillMakerRisk = 10_989_000
        uint256 fillMakerRisk = 10_989_000;

        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedDefault();

        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_DESIRED_RISK, 0, 0);

        bytes32 commitmentHash = matchingModule.getCommitmentHash(c);
        assertEq(matchingModule.s_filledRisk(commitmentHash), fillMakerRisk);
        // remaining = 100_000_000 - 10_989_000 = 89_011_000
        assertEq(matchingModule.getRemainingRisk(c), 89_011_000);

        vm.prank(taker2);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_DESIRED_RISK, 0, 0);
        // 2 * 10_989_000 = 21_978_000
        assertEq(matchingModule.s_filledRisk(commitmentHash), 21_978_000);
    }

    function test_FillsAccumulateToRiskAmount() public {
        // Independent calc: oddsTick=191, takerDesiredRisk=10_000_000
        // fillMakerRisk = 10_989_000
        // totalRisk = 10_989_000 * 10 = 109_890_000
        uint256 totalRisk = 109_890_000;

        MatchingModule.OspexCommitment memory c = _defaultCommitment();
        c.riskAmount = totalRisk;
        bytes memory sig = _signCommitment(c, MAKER_PK);

        for (uint256 i = 0; i < 10; i++) {
            vm.prank(address(uint160(0xF000 + i)));
            matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_DESIRED_RISK, 0, 0);
        }

        assertEq(matchingModule.getRemainingRisk(c), 0);

        vm.prank(taker);
        vm.expectRevert(MatchingModule.MatchingModule__CommitmentFullyFilled.selector);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_DESIRED_RISK, 0, 0);
    }

    // ===================== LOT SIZE VALIDATION =====================

    function test_InvalidLotSizeReverts() public {
        MatchingModule.OspexCommitment memory c = _defaultCommitment();
        c.riskAmount = 100_000_001;
        bytes memory sig = _signCommitment(c, MAKER_PK);

        vm.prank(taker);
        vm.expectRevert(MatchingModule.MatchingModule__InvalidLotSize.selector);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_DESIRED_RISK, 0, 0);
    }

    /// @notice Task 4 (#22): Various riskAmounts not divisible by ODDS_SCALE all revert
    function test_InvalidLotSize_VariousAmounts() public {
        uint256[5] memory badAmounts = [
            uint256(100_000_001),
            uint256(100_000_050),
            uint256(100_000_099),
            uint256(1),
            uint256(99)
        ];

        for (uint256 i = 0; i < badAmounts.length; i++) {
            MatchingModule.OspexCommitment memory c = _defaultCommitment();
            c.riskAmount = badAmounts[i];
            c.nonce = 1 + i;
            bytes memory sig = _signCommitment(c, MAKER_PK);

            vm.prank(taker);
            vm.expectRevert(MatchingModule.MatchingModule__InvalidLotSize.selector);
            matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_DESIRED_RISK, 0, 0);
        }
    }

    /// @notice Task 4 (#22): Verify exact economics at common oddsTick values
    function test_LotSizeEconomics_CommonOddsTicks() public {
        // oddsTick=150: profitTicks=50
        // rawFillMakerRisk = ceil(10_000_000 * 100 / 50) = 20_000_000
        // fillMakerRisk = 20_000_000, makerProfit = 20_000_000 * 50 / 100 = 10_000_000
        {
            MatchingModule.OspexCommitment memory c = _defaultCommitment();
            c.oddsTick = 150;
            c.riskAmount = 100_000_000;
            bytes memory sig = _signCommitment(c, MAKER_PK);
            vm.prank(taker);
            matchingModule.matchCommitment(c, sig, 10_000_000, 0, 0);
            assertEq(mockPosition.lastMakerRisk(), 20_000_000, "150 makerRisk");
            assertEq(mockPosition.lastTakerRisk(), 10_000_000, "150 takerRisk");
        }

        // oddsTick=191: profitTicks=91
        // rawFillMakerRisk = ceil(1_000_000_000 / 91) = 10_989_011
        // fillMakerRisk = 10_989_000, makerProfit = 10_989_000 * 91 / 100 = 9_999_990
        {
            MatchingModule.OspexCommitment memory c = _defaultCommitment();
            c.oddsTick = 191;
            c.riskAmount = 100_000_000;
            c.nonce = 2;
            bytes memory sig = _signCommitment(c, MAKER_PK);
            vm.prank(taker);
            matchingModule.matchCommitment(c, sig, 10_000_000, 0, 0);
            assertEq(mockPosition.lastMakerRisk(), 10_989_000, "191 makerRisk");
            assertEq(mockPosition.lastTakerRisk(), 9_999_990, "191 takerRisk");
        }

        // oddsTick=200: profitTicks=100 (even money)
        // rawFillMakerRisk = ceil(1_000_000_000 / 100) = 10_000_000
        // fillMakerRisk = 10_000_000, makerProfit = 10_000_000
        {
            MatchingModule.OspexCommitment memory c = _defaultCommitment();
            c.oddsTick = 200;
            c.riskAmount = 100_000_000;
            c.nonce = 3;
            bytes memory sig = _signCommitment(c, MAKER_PK);
            vm.prank(taker);
            matchingModule.matchCommitment(c, sig, 10_000_000, 0, 0);
            assertEq(mockPosition.lastMakerRisk(), 10_000_000, "200 makerRisk");
            assertEq(mockPosition.lastTakerRisk(), 10_000_000, "200 takerRisk");
        }

        // oddsTick=250: profitTicks=150
        // rawFillMakerRisk = ceil(1_000_000_000 / 150) = 6_666_667
        // fillMakerRisk = 6_666_667 - 67 = 6_666_600
        // makerProfit = 6_666_600 * 150 / 100 = 9_999_900
        {
            MatchingModule.OspexCommitment memory c = _defaultCommitment();
            c.oddsTick = 250;
            c.riskAmount = 100_000_000;
            c.nonce = 4;
            bytes memory sig = _signCommitment(c, MAKER_PK);
            vm.prank(taker);
            matchingModule.matchCommitment(c, sig, 10_000_000, 0, 0);
            assertEq(mockPosition.lastMakerRisk(), 6_666_600, "250 makerRisk");
            assertEq(mockPosition.lastTakerRisk(), 9_999_900, "250 takerRisk");
        }

        // oddsTick=300: profitTicks=200
        // rawFillMakerRisk = ceil(1_000_000_000 / 200) = 5_000_000
        // fillMakerRisk = 5_000_000, makerProfit = 5_000_000 * 200 / 100 = 10_000_000
        {
            MatchingModule.OspexCommitment memory c = _defaultCommitment();
            c.oddsTick = 300;
            c.riskAmount = 100_000_000;
            c.nonce = 5;
            bytes memory sig = _signCommitment(c, MAKER_PK);
            vm.prank(taker);
            matchingModule.matchCommitment(c, sig, 10_000_000, 0, 0);
            assertEq(mockPosition.lastMakerRisk(), 5_000_000, "300 makerRisk");
            assertEq(mockPosition.lastTakerRisk(), 10_000_000, "300 takerRisk");
        }
    }

    // ===================== NONCE / CANCELLATION =====================

    function test_RaiseMinNonceInvalidatesLowerNonces() public {
        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedDefault();
        vm.prank(maker);
        matchingModule.raiseMinNonce(DEFAULT_CONTEST_ID, defaultScorer, DEFAULT_THE_NUMBER, 5);
        vm.prank(taker);
        vm.expectRevert(MatchingModule.MatchingModule__NonceTooLow.selector);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_DESIRED_RISK, 0, 0);
    }

    function test_RaiseMinNoncePerMakerPerSpeculation() public {
        vm.prank(maker);
        matchingModule.raiseMinNonce(DEFAULT_CONTEST_ID, defaultScorer, DEFAULT_THE_NUMBER, 5);

        MatchingModule.OspexCommitment memory c = _defaultCommitment();
        c.maker = otherSigner;
        c.nonce = 1;
        bytes memory sig = _signCommitment(c, OTHER_PK);

        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_DESIRED_RISK, 0, 0);
        assertEq(mockPosition.recordFillCallCount(), 1);
    }

    function test_RaiseMinNoncePerSpeculation() public {
        vm.prank(maker);
        matchingModule.raiseMinNonce(DEFAULT_CONTEST_ID, defaultScorer, DEFAULT_THE_NUMBER, 5);

        MatchingModule.OspexCommitment memory c = _defaultCommitment();
        c.theNumber = 99;
        c.nonce = 1;
        bytes memory sig = _signCommitment(c, MAKER_PK);

        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_DESIRED_RISK, 0, 0);
        assertEq(mockPosition.recordFillCallCount(), 1);
    }

    function test_CancelCommitmentOnlyByMaker() public {
        MatchingModule.OspexCommitment memory c = _defaultCommitment();

        vm.prank(taker);
        vm.expectRevert(MatchingModule.MatchingModule__NotCommitmentMaker.selector);
        matchingModule.cancelCommitment(c);

        vm.prank(maker);
        matchingModule.cancelCommitment(c);

        bytes32 commitmentHash = matchingModule.getCommitmentHash(c);
        assertTrue(matchingModule.isCancelled(commitmentHash));
    }

    function test_CancelledCommitmentCannotBeMatched() public {
        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedDefault();

        vm.prank(maker);
        matchingModule.cancelCommitment(c);

        vm.prank(taker);
        vm.expectRevert(MatchingModule.MatchingModule__CommitmentCancelled.selector);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_DESIRED_RISK, 0, 0);
    }

    function test_NonceMustStrictlyIncrease() public {
        vm.prank(maker);
        matchingModule.raiseMinNonce(DEFAULT_CONTEST_ID, defaultScorer, DEFAULT_THE_NUMBER, 5);

        vm.prank(maker);
        vm.expectRevert(MatchingModule.MatchingModule__NonceMustIncrease.selector);
        matchingModule.raiseMinNonce(DEFAULT_CONTEST_ID, defaultScorer, DEFAULT_THE_NUMBER, 5);

        vm.prank(maker);
        vm.expectRevert(MatchingModule.MatchingModule__NonceMustIncrease.selector);
        matchingModule.raiseMinNonce(DEFAULT_CONTEST_ID, defaultScorer, DEFAULT_THE_NUMBER, 4);

        vm.prank(maker);
        matchingModule.raiseMinNonce(DEFAULT_CONTEST_ID, defaultScorer, DEFAULT_THE_NUMBER, 6);
        assertEq(
            matchingModule.getMinNonce(maker, DEFAULT_CONTEST_ID, defaultScorer, DEFAULT_THE_NUMBER),
            6
        );
    }

    // ===================== RECORDFILL PATH =====================

    function test_MatchCallsRecordFill() public {
        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedDefault();

        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_DESIRED_RISK, 0, 0);

        assertEq(mockPosition.recordFillCallCount(), 1);
        assertEq(mockPosition.lastMaker(), maker);
        assertEq(mockPosition.lastTaker(), taker);
        assertEq(uint(mockPosition.lastMakerPositionType()), uint(PositionType.Upper));

        // Independent calc: oddsTick=191, takerDesiredRisk=10_000_000
        // profitTicks = 91
        // rawFillMakerRisk = ceil(1_000_000_000 / 91) = 10_989_011
        // fillMakerRisk = 10_989_011 - 11 = 10_989_000
        // makerProfit = 10_989_000 * 91 / 100 = 9_999_990
        assertEq(mockPosition.lastMakerRisk(), 10_989_000);
        assertEq(mockPosition.lastTakerRisk(), 9_999_990);
    }

    function test_CorrectParamsFlowToRecordFill() public {
        uint256 contestId = 77;
        address scorer = address(0x7777);
        int32 theNumber = -3;
        uint16 oddsTick = 250;
        uint256 riskAmount = 50_000_000;

        uint256 takerContrib = 100;
        uint256 makerContrib = 200;

        MatchingModule.OspexCommitment memory c = MatchingModule.OspexCommitment({
            maker: maker,
            contestId: contestId,
            scorer: scorer,
            theNumber: theNumber,
            positionType: PositionType.Lower,
            oddsTick: oddsTick,
            riskAmount: riskAmount,
            contributionAmount: makerContrib,
            nonce: 1,
            expiry: block.timestamp + 1 hours
        });
        bytes memory sig = _signCommitment(c, MAKER_PK);

        uint256 takerDesiredRisk = 5_000_000;
        uint256 leaderboardId = 3;

        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, takerDesiredRisk, leaderboardId, takerContrib);

        assertEq(mockPosition.recordFillCallCount(), 1);
        assertEq(uint(mockPosition.lastMakerPositionType()), uint(PositionType.Lower));
        assertEq(mockPosition.lastMaker(), maker);
        assertEq(mockPosition.lastTaker(), taker);
        assertEq(mockPosition.lastContestId(), contestId);
        assertEq(mockPosition.lastScorer(), scorer);
        assertEq(mockPosition.lastTheNumber(), theNumber);
        assertEq(mockPosition.lastLeaderboardId(), leaderboardId);

        // Independent calc: oddsTick=250, takerDesiredRisk=5_000_000
        // profitTicks = 150
        // rawFillMakerRisk = ceil(500_000_000 / 150) = 3_333_334
        // fillMakerRisk = 3_333_334 - 34 = 3_333_300
        // makerProfit = 3_333_300 * 150 / 100 = 4_999_950
        assertEq(mockPosition.lastMakerRisk(), 3_333_300);
        assertEq(mockPosition.lastTakerRisk(), 4_999_950);
    }

    function test_ContributionAmountsFlowToPositionModule() public {
        uint256 makerContrib = 500;
        uint256 takerContrib = 300;

        MatchingModule.OspexCommitment memory c = _defaultCommitment();
        c.contributionAmount = makerContrib;
        bytes memory sig = _signCommitment(c, MAKER_PK);

        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_DESIRED_RISK, 0, takerContrib);

        assertEq(mockPosition.lastMakerContributionAmount(), makerContrib);
        assertEq(mockPosition.lastTakerContributionAmount(), takerContrib);
    }

    function test_ContributionAmountsFlowViaRecordFill() public {
        uint256 makerContrib = 1000;
        uint256 takerContrib = 750;

        uint256 newContestId = 99;
        address newScorer = address(0xBBBB);
        int32 newTheNumber = 10;

        MatchingModule.OspexCommitment memory c = MatchingModule.OspexCommitment({
            maker: maker,
            contestId: newContestId,
            scorer: newScorer,
            theNumber: newTheNumber,
            positionType: PositionType.Upper,
            oddsTick: DEFAULT_ODDS_TICK,
            riskAmount: DEFAULT_RISK_AMOUNT,
            contributionAmount: makerContrib,
            nonce: 1,
            expiry: block.timestamp + 1 hours
        });
        bytes memory sig = _signCommitment(c, MAKER_PK);

        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_DESIRED_RISK, 0, takerContrib);

        assertEq(mockPosition.recordFillCallCount(), 1);
        assertEq(mockPosition.lastMakerContributionAmount(), makerContrib);
        assertEq(mockPosition.lastTakerContributionAmount(), takerContrib);
    }

    // ===================== EDGE CASES =====================

    function test_ExpiredCommitmentReverts() public {
        MatchingModule.OspexCommitment memory c = _defaultCommitment();
        c.expiry = block.timestamp + 1 hours;
        bytes memory sig = _signCommitment(c, MAKER_PK);
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(taker);
        vm.expectRevert(MatchingModule.MatchingModule__CommitmentExpired.selector);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_DESIRED_RISK, 0, 0);
    }

    function test_ExpiryBoundaryAccepted() public {
        MatchingModule.OspexCommitment memory c = _defaultCommitment();
        c.expiry = block.timestamp + 1 hours;
        bytes memory sig = _signCommitment(c, MAKER_PK);
        vm.warp(c.expiry);
        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_DESIRED_RISK, 0, 0);
        assertEq(mockPosition.recordFillCallCount(), 1);
    }

    function test_TakerDesiredRiskZeroReverts() public {
        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedDefault();
        vm.prank(taker);
        vm.expectRevert(MatchingModule.MatchingModule__InvalidTakerDesiredRisk.selector);
        matchingModule.matchCommitment(c, sig, 0, 0, 0);
    }

    function test_CommitmentMatchedEventEmitted() public {
        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedDefault();
        bytes32 expectedHash = matchingModule.getCommitmentHash(c);

        // Independent calc: oddsTick=191, takerDesiredRisk=10_000_000
        // fillMakerRisk = 10_989_000, makerProfit = 9_999_990
        uint256 fillMakerRisk = 10_989_000;
        uint256 expectedMakerProfit = 9_999_990;

        vm.expectEmit(true, true, true, true);
        emit MatchingModule.CommitmentMatched(
            expectedHash,
            maker,
            taker,
            DEFAULT_CONTEST_ID,
            1,
            PositionType.Upper,
            DEFAULT_ODDS_TICK,
            expectedMakerProfit,
            fillMakerRisk
        );

        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_DESIRED_RISK, 0, 0);
    }

    function test_CommitmentCancelledEventEmitted() public {
        MatchingModule.OspexCommitment memory c = _defaultCommitment();
        bytes32 expectedHash = matchingModule.getCommitmentHash(c);

        vm.expectEmit(true, true, false, true);
        emit MatchingModule.CommitmentCancelled(expectedHash, maker);

        vm.prank(maker);
        matchingModule.cancelCommitment(c);
    }

    function test_MinNonceUpdatedEventEmitted() public {
        bytes32 expectedKey = keccak256(
            abi.encode(DEFAULT_CONTEST_ID, defaultScorer, DEFAULT_THE_NUMBER)
        );

        vm.expectEmit(true, true, false, true);
        emit MatchingModule.MinNonceUpdated(maker, expectedKey, 5);

        vm.prank(maker);
        matchingModule.raiseMinNonce(DEFAULT_CONTEST_ID, defaultScorer, DEFAULT_THE_NUMBER, 5);
    }

    function test_ReentrancyProtection() public {
        MockOspexCoreForMatching reentrCore = new MockOspexCoreForMatching();
        ReentrantMockPositionModule reentrPos = new ReentrantMockPositionModule();
        reentrCore.setModule(keccak256("POSITION_MODULE"), address(reentrPos));
        MatchingModule mmReentrant = new MatchingModule(address(reentrCore));
        reentrPos.setTarget(address(mmReentrant));
        reentrPos.setShouldReenter(true);

        MatchingModule.OspexCommitment memory c = MatchingModule.OspexCommitment({
            maker: maker,
            contestId: DEFAULT_CONTEST_ID,
            scorer: defaultScorer,
            theNumber: DEFAULT_THE_NUMBER,
            positionType: PositionType.Upper,
            oddsTick: DEFAULT_ODDS_TICK,
            riskAmount: DEFAULT_RISK_AMOUNT,
            contributionAmount: 0,
            nonce: 1,
            expiry: block.timestamp + 1 hours
        });
        bytes32 digest = mmReentrant.getCommitmentHash(c);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MAKER_PK, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        mmReentrant.matchCommitment(c, sig, DEFAULT_TAKER_DESIRED_RISK, 0, 0);
    }

    // ===================== ODDS RANGE =====================

    function test_OddsBelowMinReverts() public {
        MatchingModule.OspexCommitment memory c = _defaultCommitment();
        c.oddsTick = 100;
        bytes memory sig = _signCommitment(c, MAKER_PK);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(MatchingModule.MatchingModule__OddsOutOfRange.selector, uint16(100)));
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_DESIRED_RISK, 0, 0);
    }

    function test_OddsAboveMaxReverts() public {
        MatchingModule.OspexCommitment memory c = _defaultCommitment();
        c.oddsTick = 10101;
        bytes memory sig = _signCommitment(c, MAKER_PK);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(MatchingModule.MatchingModule__OddsOutOfRange.selector, uint16(10101)));
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_DESIRED_RISK, 0, 0);
    }

    // ===================== INVALID FILL MAKER RISK (#16) =====================

    /// @notice fillMakerRisk rounds to zero at extreme odds with tiny takerDesiredRisk
    function test_InvalidFillMakerRisk_ZeroAfterLotRounding() public {
        // Independent calc: oddsTick=10100 (101x odds), takerDesiredRisk=1
        // profitTicks = 10100 - 100 = 10000
        // rawFillMakerRisk = ceil(1 * 100 / 10000) = ceil(100 / 10000) = 1
        // fillMakerRisk = 1 - (1 % 100) = 1 - 1 = 0 --> revert InvalidFillMakerRisk
        MatchingModule.OspexCommitment memory c = _defaultCommitment();
        c.oddsTick = 10100;
        bytes memory sig = _signCommitment(c, MAKER_PK);
        vm.prank(taker);
        vm.expectRevert(MatchingModule.MatchingModule__InvalidFillMakerRisk.selector);
        matchingModule.matchCommitment(c, sig, 1, 0, 0);
    }

    /// @notice fillMakerRisk exceeds makerRiskRemaining
    function test_InvalidFillMakerRisk_ExceedsRemaining() public {
        // Independent calc: oddsTick=150, takerDesiredRisk=1_000_000
        // profitTicks = 50
        // rawFillMakerRisk = ceil(1_000_000 * 100 / 50) = 2_000_000
        // fillMakerRisk = 2_000_000, but riskAmount = 1_000 --> revert
        MatchingModule.OspexCommitment memory c = _defaultCommitment();
        c.oddsTick = 150;
        c.riskAmount = 1_000;
        bytes memory sig = _signCommitment(c, MAKER_PK);
        vm.prank(taker);
        vm.expectRevert(MatchingModule.MatchingModule__InvalidFillMakerRisk.selector);
        matchingModule.matchCommitment(c, sig, 1_000_000, 0, 0);
    }

    // ===================== FILL BOUNDARY TESTS (#18) =====================

    /// @notice Full fill: takerDesiredRisk exactly consumes all remaining maker risk
    function test_FullFill_ExactConsumption() public {
        // Independent calc: oddsTick=200, takerDesiredRisk=50_000_000
        // profitTicks = 100
        // rawFillMakerRisk = ceil(50_000_000 * 100 / 100) = 50_000_000
        // fillMakerRisk = 50_000_000, makerProfit = 50_000_000
        MatchingModule.OspexCommitment memory c = _defaultCommitment();
        c.oddsTick = 200;
        c.riskAmount = 50_000_000;
        bytes memory sig = _signCommitment(c, MAKER_PK);

        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, 50_000_000, 0, 0);

        assertEq(matchingModule.getRemainingRisk(c), 0, "fully consumed");
        assertEq(mockPosition.lastMakerRisk(), 50_000_000, "makerRisk");
        assertEq(mockPosition.lastTakerRisk(), 50_000_000, "takerRisk");
    }

    /// @notice Multiple partial fills that sum to exactly riskAmount (no dust)
    function test_MultiplePartialFills_ExactSum_NoDust() public {
        // Independent calc: oddsTick=200, takerDesiredRisk=20_000_000
        // profitTicks = 100
        // rawFillMakerRisk = ceil(20_000_000 * 100 / 100) = 20_000_000
        // fillMakerRisk = 20_000_000
        // 5 fills * 20_000_000 = 100_000_000 = riskAmount exactly
        MatchingModule.OspexCommitment memory c = _defaultCommitment();
        c.oddsTick = 200;
        c.riskAmount = 100_000_000;
        bytes memory sig = _signCommitment(c, MAKER_PK);

        for (uint256 i = 0; i < 5; i++) {
            vm.prank(address(uint160(0xF000 + i)));
            matchingModule.matchCommitment(c, sig, 20_000_000, 0, 0);
        }

        assertEq(matchingModule.getRemainingRisk(c), 0, "no dust remaining");

        vm.prank(taker);
        vm.expectRevert(MatchingModule.MatchingModule__CommitmentFullyFilled.selector);
        matchingModule.matchCommitment(c, sig, 20_000_000, 0, 0);
    }

    /// @notice Fill after full fill reverts with CommitmentFullyFilled
    function test_FillAfterFullFill_Reverts() public {
        // Independent calc: oddsTick=191, takerDesiredRisk=10_000_000
        // fillMakerRisk = 10_989_000
        MatchingModule.OspexCommitment memory c = _defaultCommitment();
        c.riskAmount = 10_989_000;
        bytes memory sig = _signCommitment(c, MAKER_PK);

        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_DESIRED_RISK, 0, 0);
        assertEq(matchingModule.getRemainingRisk(c), 0, "fully filled");

        vm.prank(taker2);
        vm.expectRevert(MatchingModule.MatchingModule__CommitmentFullyFilled.selector);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_DESIRED_RISK, 0, 0);

        vm.prank(taker);
        vm.expectRevert(MatchingModule.MatchingModule__CommitmentFullyFilled.selector);
        matchingModule.matchCommitment(c, sig, 1_000_000, 0, 0);
    }

    // ===================== VIEW FUNCTIONS =====================

    function test_GetDomainSeparator() public view {
        bytes32 ds = matchingModule.getDomainSeparator();
        assertTrue(ds != bytes32(0));
    }

    function test_GetCommitmentHash_Deterministic() public view {
        MatchingModule.OspexCommitment memory c = _defaultCommitment();
        bytes32 hash1 = matchingModule.getCommitmentHash(c);
        bytes32 hash2 = matchingModule.getCommitmentHash(c);
        assertEq(hash1, hash2);
    }

    function test_GetCommitmentHash_DifferentFields_DifferentHash() public view {
        MatchingModule.OspexCommitment memory c1 = _defaultCommitment();
        MatchingModule.OspexCommitment memory c2 = _defaultCommitment();
        c2.oddsTick = 200;
        assertTrue(matchingModule.getCommitmentHash(c1) != matchingModule.getCommitmentHash(c2));
    }

    function test_COMMITMENT_TYPEHASH() public view {
        bytes32 expected = keccak256(
            "OspexCommitment("
            "address maker,"
            "uint256 contestId,"
            "address scorer,"
            "int32 theNumber,"
            "uint8 positionType,"
            "uint16 oddsTick,"
            "uint256 riskAmount,"
            "uint256 contributionAmount,"
            "uint256 nonce,"
            "uint256 expiry"
            ")"
        );
        assertEq(matchingModule.COMMITMENT_TYPEHASH(), expected);
    }
}

// =============================================================================
// Minimal Leaderboard mock for integration tests
// =============================================================================
contract MockLeaderboardModuleForIntegration {
    mapping(uint256 => Leaderboard) private leaderboards;

    function setLeaderboard(uint256 leaderboardId, Leaderboard memory leaderboard) external {
        leaderboards[leaderboardId] = leaderboard;
    }

    function getLeaderboard(uint256 leaderboardId) external view returns (Leaderboard memory) {
        return leaderboards[leaderboardId];
    }
}

// =============================================================================
// Integration Test
// =============================================================================
contract MatchingModuleIntegrationTest is Test {
    OspexCore core;
    MockERC20 token;
    MockERC20 contributionToken;
    SpeculationModule speculationModule;
    ContributionModule contributionModule;
    PositionModule positionModule;
    TreasuryModule treasuryModule;
    MatchingModule matchingModule;
    MockContestModule mockContestModule;

    uint256 constant MAKER_PK = 0xA11CE;
    address maker;
    address taker = address(0xBBBB);
    address contributionReceiver = address(0xCC01);
    address protocolReceiver = address(0xFEED);

    uint16 constant ODDS_SCALE = 100;

    function setUp() public {
        maker = vm.addr(MAKER_PK);
        core = new OspexCore();
        token = new MockERC20();
        contributionToken = new MockERC20();

        speculationModule = new SpeculationModule(address(core), 6);
        contributionModule = new ContributionModule(address(core));
        positionModule = new PositionModule(address(core), address(token));
        treasuryModule = new TreasuryModule(address(core), address(token), protocolReceiver);
        matchingModule = new MatchingModule(address(core));

        mockContestModule = new MockContestModule();
        MockLeaderboardModuleForIntegration mockLB = new MockLeaderboardModuleForIntegration();

        core.registerModule(keccak256("POSITION_MODULE"), address(positionModule));
        core.registerModule(keccak256("SPECULATION_MODULE"), address(speculationModule));
        core.registerModule(keccak256("CONTRIBUTION_MODULE"), address(contributionModule));
        core.registerModule(keccak256("TREASURY_MODULE"), address(treasuryModule));
        core.registerModule(keccak256("CONTEST_MODULE"), address(mockContestModule));
        core.registerModule(keccak256("LEADERBOARD_MODULE"), address(mockLB));
        core.registerModule(keccak256("ORACLE_MODULE"), address(this));

        core.setMarketRole(address(matchingModule), true);
        core.registerModule(keccak256("MATCHING_MODULE"), address(matchingModule));

        contributionModule.setContributionToken(address(contributionToken));
        contributionModule.setContributionReceiver(contributionReceiver);

        Contest memory defaultContest = Contest({
            awayScore: 0, homeScore: 0, leagueId: LeagueId.NBA,
            contestStatus: ContestStatus.Verified, contestCreator: address(this),
            scoreContestSourceHash: bytes32(0), rundownId: "", sportspageId: "", jsonoddsId: ""
        });
        mockContestModule.setContest(1, defaultContest);

        token.transfer(maker, 500_000_000);
        token.transfer(taker, 500_000_000);
        contributionToken.transfer(maker, 500_000_000);
        contributionToken.transfer(taker, 500_000_000);

        vm.prank(maker);
        token.approve(address(positionModule), type(uint256).max);
        vm.prank(taker);
        token.approve(address(positionModule), type(uint256).max);

        vm.prank(maker);
        contributionToken.approve(address(contributionModule), type(uint256).max);
        vm.prank(taker);
        contributionToken.approve(address(contributionModule), type(uint256).max);
    }

    // ===================== HELPERS =====================

    function _sign(MatchingModule.OspexCommitment memory c, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = matchingModule.getCommitmentHash(c);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _makeCommitment(uint16 oddsTick, int32 theNumber, uint256 riskAmount, uint256 contrib)
        internal view returns (MatchingModule.OspexCommitment memory)
    {
        return MatchingModule.OspexCommitment({
            maker: maker,
            contestId: 1,
            scorer: address(0x1234),
            theNumber: theNumber,
            positionType: PositionType.Upper,
            oddsTick: oddsTick,
            riskAmount: riskAmount,
            contributionAmount: contrib,
            nonce: 1,
            expiry: block.timestamp + 1 hours
        });
    }

    // ===================== REAL FILL MATH =====================

    function testIntegration_RealFillMath_193() public {
        uint16 oddsTick = 193;
        uint256 riskAmount = 10_000_000;
        MatchingModule.OspexCommitment memory c = _makeCommitment(oddsTick, 0, riskAmount, 0);
        bytes memory sig = _sign(c, MAKER_PK);

        uint256 takerDesiredRisk = 5_000_000;

        // Independent calc: oddsTick=193, takerDesiredRisk=5_000_000
        // profitTicks = 93
        // rawFillMakerRisk = ceil(500_000_000 / 93) = 5_376_345
        // fillMakerRisk = 5_376_345 - 45 = 5_376_300
        // makerProfit = 5_376_300 * 93 / 100 = 4_999_959
        uint256 fillMakerRisk = 5_376_300;
        uint256 takerRisk = 4_999_959;

        uint256 makerBal = token.balanceOf(maker);
        uint256 takerBal = token.balanceOf(taker);

        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, takerDesiredRisk, 0, 0);

        assertEq(token.balanceOf(maker), makerBal - fillMakerRisk, "maker balance");
        assertEq(token.balanceOf(taker), takerBal - takerRisk, "taker balance");

        uint256 specId = speculationModule.getSpeculationId(1, address(0x1234), 0);
        assertGt(specId, 0, "speculation created");

        Position memory mPos = positionModule.getPosition(specId, maker, PositionType.Upper);
        Position memory tPos = positionModule.getPosition(specId, taker, PositionType.Lower);

        assertEq(mPos.riskAmount, fillMakerRisk, "maker riskAmount");
        assertEq(mPos.profitAmount, takerRisk, "maker profitAmount");
        assertEq(tPos.riskAmount, takerRisk, "taker riskAmount");
        assertEq(tPos.profitAmount, fillMakerRisk, "taker profitAmount");

        // remaining = 10_000_000 - 5_376_300 = 4_623_700
        assertEq(matchingModule.getRemainingRisk(c), 4_623_700, "remaining");
    }

    function testIntegration_RealFillMath_AllRoundingOdds() public {
        uint16[4] memory oddsTickList = [uint16(193), uint16(187), uint16(208), uint16(215)];
        // Independent calcs for takerDesiredRisk=5_000_000:
        // 193: pt=93,  raw=ceil(500M/93)=5_376_345,  fill=5_376_300
        // 187: pt=87,  raw=ceil(500M/87)=5_747_127,  fill=5_747_100
        // 208: pt=108, raw=ceil(500M/108)=4_629_630, fill=4_629_600
        // 215: pt=115, raw=ceil(500M/115)=4_347_827, fill=4_347_800
        uint256[4] memory expectedFills = [uint256(5_376_300), uint256(5_747_100), uint256(4_629_600), uint256(4_347_800)];

        for (uint256 i = 0; i < oddsTickList.length; i++) {
            uint16 oddsTick = oddsTickList[i];
            MatchingModule.OspexCommitment memory c = _makeCommitment(oddsTick, int32(int256(100 + i)), 10_000_000, 0);
            bytes memory sig = _sign(c, MAKER_PK);

            uint256 makerBal = token.balanceOf(maker);

            vm.prank(taker);
            matchingModule.matchCommitment(c, sig, 5_000_000, 0, 0);

            assertEq(token.balanceOf(maker), makerBal - expectedFills[i],
                string.concat("fill math at odds index ", vm.toString(i)));
        }
    }

    // ===================== CONTRIBUTION PATH =====================

    function testIntegration_NonzeroMakerContribution() public {
        uint256 makerContrib = 500_000;
        MatchingModule.OspexCommitment memory c = _makeCommitment(193, 10, 10_000_000, makerContrib);
        bytes memory sig = _sign(c, MAKER_PK);

        uint256 receiverBefore = contributionToken.balanceOf(contributionReceiver);

        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, 5_000_000, 0, 0);

        assertEq(
            contributionToken.balanceOf(contributionReceiver),
            receiverBefore + makerContrib,
            "maker contrib reached receiver"
        );
    }

    function testIntegration_NonzeroTakerContribution() public {
        uint256 takerContrib = 300_000;
        MatchingModule.OspexCommitment memory c = _makeCommitment(187, 20, 10_000_000, 0);
        bytes memory sig = _sign(c, MAKER_PK);

        uint256 receiverBefore = contributionToken.balanceOf(contributionReceiver);

        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, 5_000_000, 0, takerContrib);

        assertEq(
            contributionToken.balanceOf(contributionReceiver),
            receiverBefore + takerContrib,
            "taker contrib reached receiver"
        );
    }

    function testIntegration_BothContributions() public {
        uint256 makerContrib = 200_000;
        uint256 takerContrib = 100_000;
        MatchingModule.OspexCommitment memory c = _makeCommitment(208, 30, 10_000_000, makerContrib);
        bytes memory sig = _sign(c, MAKER_PK);

        uint256 receiverBefore = contributionToken.balanceOf(contributionReceiver);

        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, 5_000_000, 0, takerContrib);

        assertEq(
            contributionToken.balanceOf(contributionReceiver),
            receiverBefore + makerContrib + takerContrib,
            "both contribs reached receiver"
        );
    }

    // ===================== FULL FILL AT ROUNDING BOUNDARY =====================

    function testIntegration_FullFillAtRoundingBoundary() public {
        uint16 oddsTick = 193;
        uint256 riskAmount = 10_000_000;
        // Independent calc: takerDesiredRisk = (10_000_000 * 93) / 100 = 9_300_000
        // rawFillMakerRisk = ceil(9_300_000 * 100 / 93) = ceil(930_000_000 / 93) = 10_000_000
        // fillMakerRisk = 10_000_000 = riskAmount exactly
        uint256 takerDesiredRisk = 9_300_000;

        MatchingModule.OspexCommitment memory c = _makeCommitment(oddsTick, 40, riskAmount, 0);
        bytes memory sig = _sign(c, MAKER_PK);

        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, takerDesiredRisk, 0, 0);

        assertEq(matchingModule.getRemainingRisk(c), 0, "fully filled");

        vm.prank(taker);
        vm.expectRevert(MatchingModule.MatchingModule__CommitmentFullyFilled.selector);
        matchingModule.matchCommitment(c, sig, 1_000_000, 0, 0);
    }

    // ===================== EXACT ALLOWANCE =====================

    function testIntegration_ExactAllowanceMakerApproval() public {
        uint16 oddsTick = 215;
        uint256 takerDesiredRisk = 5_000_000;
        // Independent calc: oddsTick=215
        // profitTicks = 115
        // rawFillMakerRisk = ceil(500_000_000 / 115) = 4_347_827
        // fillMakerRisk = 4_347_827 - 27 = 4_347_800
        uint256 fillMakerRisk = 4_347_800;

        vm.prank(maker);
        token.approve(address(positionModule), fillMakerRisk);

        MatchingModule.OspexCommitment memory c = _makeCommitment(oddsTick, 50, fillMakerRisk, 0);
        bytes memory sig = _sign(c, MAKER_PK);

        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, takerDesiredRisk, 0, 0);

        assertEq(token.allowance(maker, address(positionModule)), 0, "allowance fully consumed");
    }

    // ===================== PARTIAL FILL THEN REMAINDER =====================

    function testIntegration_PartialFillThenRemainder() public {
        uint16 oddsTick = 193;
        uint256 riskAmount = 10_000_000;
        MatchingModule.OspexCommitment memory c = _makeCommitment(oddsTick, 60, riskAmount, 0);
        bytes memory sig = _sign(c, MAKER_PK);

        // Independent calc: oddsTick=193, takerDesiredRisk=5_000_000
        // firstFillMakerRisk = 5_376_300 (see testIntegration_RealFillMath_193)

        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, 5_000_000, 0, 0);

        // remaining = 10_000_000 - 5_376_300 = 4_623_700
        uint256 remaining = 4_623_700;
        assertEq(matchingModule.getRemainingRisk(c), remaining, "remaining after first fill");

        // Second taker: takerDesiredRisk = (4_623_700 * 93) / 100 = 4_300_041
        // rawFill = ceil(4_300_041 * 100 / 93) = ceil(430_004_100 / 93) = 4_623_700
        // fillMakerRisk = 4_623_700 = remaining exactly, total = 10_000_000
        uint256 maxTaker2 = 4_300_041;

        address taker2 = address(0xDDDD);
        token.transfer(taker2, maxTaker2);
        vm.prank(taker2);
        token.approve(address(positionModule), maxTaker2);

        vm.prank(taker2);
        matchingModule.matchCommitment(c, sig, maxTaker2, 0, 0);

        assertEq(matchingModule.getRemainingRisk(c), 0, "fully filled after two takers");
    }

    // ===================== EXISTING SPECULATION PATH =====================

    function testIntegration_ExistingSpeculationPath() public {
        uint16 oddsTick = 193;
        MatchingModule.OspexCommitment memory c1 = _makeCommitment(oddsTick, 70, 10_000_000, 0);
        bytes memory sig1 = _sign(c1, MAKER_PK);

        vm.prank(taker);
        matchingModule.matchCommitment(c1, sig1, 3_000_000, 0, 0);

        uint256 specId = speculationModule.getSpeculationId(1, address(0x1234), 70);
        assertGt(specId, 0, "speculation exists after first match");

        MatchingModule.OspexCommitment memory c2 = MatchingModule.OspexCommitment({
            maker: maker,
            contestId: 1,
            scorer: address(0x1234),
            theNumber: 70,
            positionType: PositionType.Upper,
            oddsTick: oddsTick,
            riskAmount: 10_000_000,
            contributionAmount: 0,
            nonce: 2,
            expiry: block.timestamp + 1 hours
        });
        bytes memory sig2 = _sign(c2, MAKER_PK);

        // Independent calc: oddsTick=193, takerDesiredRisk=3_000_000
        // profitTicks = 93
        // rawFillMakerRisk = ceil(300_000_000 / 93) = 3_225_807
        // fillMakerRisk = 3_225_807 - 7 = 3_225_800
        uint256 fillMakerRisk = 3_225_800;
        uint256 makerBal = token.balanceOf(maker);

        vm.prank(taker);
        matchingModule.matchCommitment(c2, sig2, 3_000_000, 0, 0);

        assertEq(token.balanceOf(maker), makerBal - fillMakerRisk, "second match consumed correct amount");

        uint256 specId2 = speculationModule.getSpeculationId(1, address(0x1234), 70);
        assertEq(specId, specId2, "same speculation reused");
    }
}
