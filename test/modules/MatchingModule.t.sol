// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// [NOTE] All test amounts use 6 decimals (USDC-style): 1 USDC = 1_000_000
// [NOTE] All odds use 1e7 precision: 1.91 = 19_100_000

import "forge-std/Test.sol";
import {MatchingModule} from "../../src/modules/MatchingModule.sol";
import {PositionType} from "../../src/core/OspexTypes.sol";

// =============================================================================
// Mock OspexCore — returns module addresses by type key.
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
// Mock SpeculationModule — only implements getSpeculationId (the sole function
// MatchingModule calls on ISpeculationModule).
// =============================================================================
contract MockSpeculationModuleForMatching {
    mapping(bytes32 => uint256) private _ids;
    uint256 public nextId = 1;

    function getSpeculationId(
        uint256 contestId,
        address scorer,
        int32 theNumber
    ) external view returns (uint256) {
        return _ids[keccak256(abi.encode(contestId, scorer, theNumber))];
    }

    function setSpeculationId(
        uint256 contestId,
        address scorer,
        int32 theNumber,
        uint256 id
    ) external {
        _ids[keccak256(abi.encode(contestId, scorer, theNumber))] = id;
    }

    /// @notice Called by MockPositionModule during createMatchedPairWithSpeculation
    ///         to simulate PositionModule creating a new speculation.
    function registerSpeculation(
        uint256 contestId,
        address scorer,
        int32 theNumber
    ) external returns (uint256) {
        bytes32 key = keccak256(abi.encode(contestId, scorer, theNumber));
        if (_ids[key] == 0) {
            _ids[key] = nextId++;
        }
        return _ids[key];
    }
}

// =============================================================================
// Mock PositionModule — implements createMatchedPair and
// createMatchedPairWithSpeculation with configurable return values and call
// tracking. This is the minimum surface MatchingModule calls.
// =============================================================================
contract MockPositionModuleForMatching {
    MockSpeculationModuleForMatching public specModule;

    /// @notice Configurable return value for makerAmountConsumed
    uint256 public fillReturnAmount;

    // --- Call tracking ---
    uint256 public createMatchedPairCallCount;
    uint256 public createWithSpecCallCount;
    uint256 public lastMakerAmountRemaining;
    uint256 public lastTakerAmount;
    address public lastMaker;
    address public lastTaker;
    uint64 public lastOdds;
    PositionType public lastMakerPositionType;

    constructor(address _specModule) {
        specModule = MockSpeculationModuleForMatching(_specModule);
    }

    function setFillReturnAmount(uint256 amount) external {
        fillReturnAmount = amount;
    }

    function createMatchedPair(
        uint256,
        uint64 odds,
        PositionType makerPositionType,
        address maker,
        uint256 makerAmountRemaining,
        address taker,
        uint256 takerAmount,
        uint256,
        uint256
    ) external returns (uint256) {
        createMatchedPairCallCount++;
        lastOdds = odds;
        lastMakerPositionType = makerPositionType;
        lastMaker = maker;
        lastMakerAmountRemaining = makerAmountRemaining;
        lastTaker = taker;
        lastTakerAmount = takerAmount;
        return fillReturnAmount;
    }

    function createMatchedPairWithSpeculation(
        uint256 contestId,
        address scorer,
        int32 theNumber,
        uint256,
        uint64 odds,
        PositionType makerPositionType,
        address maker,
        uint256 makerAmountRemaining,
        address taker,
        uint256 takerAmount,
        uint256,
        uint256
    ) external returns (uint256) {
        createWithSpecCallCount++;
        lastOdds = odds;
        lastMakerPositionType = makerPositionType;
        lastMaker = maker;
        lastMakerAmountRemaining = makerAmountRemaining;
        lastTaker = taker;
        lastTakerAmount = takerAmount;
        specModule.registerSpeculation(contestId, scorer, theNumber);
        return fillReturnAmount;
    }
}

// =============================================================================
// Reentrant Mock — attempts to call matchCommitment from within
// createMatchedPair to verify nonReentrant protection.
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

    function createMatchedPair(
        uint256, uint64, PositionType, address, uint256, address, uint256, uint256, uint256
    ) external returns (uint256) {
        if (shouldReenter) {
            // Build a minimal commitment — the reentrancy guard fires before validation
            MatchingModule.OspexCommitment memory c = MatchingModule.OspexCommitment({
                maker: address(1),
                contestId: 1,
                scorer: address(2),
                theNumber: 0,
                positionType: PositionType.Upper,
                odds: 19_100_000,
                maxAmount: 1_000_000,
                nonce: 1,
                expiry: block.timestamp + 1 hours
            });
            MatchingModule(matchingModuleAddr).matchCommitment(c, "", 1_000_000, 0, 0, 0);
        }
        return 0;
    }

    // Needed so the "new speculation" path can also be tested, but not used here
    function createMatchedPairWithSpeculation(
        uint256, address, int32, uint256, uint64, PositionType, address, uint256, address, uint256, uint256, uint256
    ) external pure returns (uint256) {
        return 0;
    }
}

// =============================================================================
// Test Contract
// =============================================================================
contract MatchingModuleTest is Test {
    MatchingModule matchingModule;
    MockOspexCoreForMatching mockCore;
    MockSpeculationModuleForMatching mockSpeculation;
    MockPositionModuleForMatching mockPosition;

    // --- Maker uses a known private key so we can produce real EIP-712 signatures ---
    uint256 constant MAKER_PK = 0xA11CE;
    address maker;
    uint256 constant OTHER_PK = 0xB0B;
    address otherSigner;

    address taker = address(0xBBBB);
    address taker2 = address(0xCCCC);
    address defaultScorer = address(0xDDDD);

    uint256 constant DEFAULT_MAX_AMOUNT = 100_000_000; // 100 USDC
    uint256 constant DEFAULT_TAKER_AMOUNT = 10_000_000; // 10 USDC
    uint64 constant DEFAULT_ODDS = 19_100_000; // 1.91
    uint256 constant DEFAULT_CONTEST_ID = 1;
    int32 constant DEFAULT_THE_NUMBER = 0;

    function setUp() public {
        maker = vm.addr(MAKER_PK);
        otherSigner = vm.addr(OTHER_PK);

        mockCore = new MockOspexCoreForMatching();
        mockSpeculation = new MockSpeculationModuleForMatching();
        mockPosition = new MockPositionModuleForMatching(address(mockSpeculation));

        mockCore.setModule(keccak256("SPECULATION_MODULE"), address(mockSpeculation));
        mockCore.setModule(keccak256("POSITION_MODULE"), address(mockPosition));

        matchingModule = new MatchingModule(address(mockCore));

        // Pre-set speculation ID = 1 so default tests use "existing speculation" path
        mockSpeculation.setSpeculationId(DEFAULT_CONTEST_ID, defaultScorer, DEFAULT_THE_NUMBER, 1);

        // Default: mock returns full fill
        mockPosition.setFillReturnAmount(DEFAULT_MAX_AMOUNT);
    }

    // ===================== HELPERS =====================

    function _defaultCommitment() internal view returns (MatchingModule.OspexCommitment memory) {
        return MatchingModule.OspexCommitment({
            maker: maker,
            contestId: DEFAULT_CONTEST_ID,
            scorer: defaultScorer,
            theNumber: DEFAULT_THE_NUMBER,
            positionType: PositionType.Upper,
            odds: DEFAULT_ODDS,
            maxAmount: DEFAULT_MAX_AMOUNT,
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

    /// @notice Returns a signed default commitment
    function _signedDefault() internal view returns (
        MatchingModule.OspexCommitment memory c,
        bytes memory sig
    ) {
        c = _defaultCommitment();
        sig = _signCommitment(c, MAKER_PK);
    }

    /// @notice Matches a signed default commitment as taker, returns the commitment
    function _matchDefault() internal returns (
        MatchingModule.OspexCommitment memory c,
        bytes memory sig
    ) {
        (c, sig) = _signedDefault();
        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_AMOUNT, 0, 0, 0);
    }

    /// @notice Expects InvalidSignature revert when matching tampered commitment with original sig
    function _expectSignatureRevert(
        MatchingModule.OspexCommitment memory tampered,
        bytes memory validSig
    ) internal {
        vm.prank(taker);
        vm.expectRevert(MatchingModule.MatchingModule__InvalidSignature.selector);
        matchingModule.matchCommitment(tampered, validSig, DEFAULT_TAKER_AMOUNT, 0, 0, 0);
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
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_AMOUNT, 0, 0, 0);

        // Verify the match was routed to createMatchedPair (existing speculation path)
        assertEq(mockPosition.createMatchedPairCallCount(), 1);
    }

    function test_WrongSignerReverts() public {
        MatchingModule.OspexCommitment memory c = _defaultCommitment();
        // Sign with OTHER_PK but commitment.maker is still `maker`
        bytes memory wrongSig = _signCommitment(c, OTHER_PK);
        _expectSignatureRevert(c, wrongSig);
    }

    function test_TamperedField_Odds() public {
        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedDefault();
        c.odds = 20_000_000;
        _expectSignatureRevert(c, sig);
    }

    function test_TamperedField_MaxAmount() public {
        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedDefault();
        c.maxAmount = 200_000_000;
        _expectSignatureRevert(c, sig);
    }

    function test_TamperedField_ContestId() public {
        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedDefault();
        c.contestId = 999;
        // Need a speculation for this contest to avoid other errors
        mockSpeculation.setSpeculationId(999, defaultScorer, DEFAULT_THE_NUMBER, 2);
        _expectSignatureRevert(c, sig);
    }

    function test_TamperedField_Scorer() public {
        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedDefault();
        c.scorer = address(0x9999);
        mockSpeculation.setSpeculationId(DEFAULT_CONTEST_ID, address(0x9999), DEFAULT_THE_NUMBER, 3);
        _expectSignatureRevert(c, sig);
    }

    function test_TamperedField_TheNumber() public {
        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedDefault();
        c.theNumber = 5;
        mockSpeculation.setSpeculationId(DEFAULT_CONTEST_ID, defaultScorer, 5, 4);
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

    function test_TamperedField_Maker() public {
        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedDefault();
        c.maker = otherSigner; // Change maker but keep original sig signed by MAKER_PK
        _expectSignatureRevert(c, sig);
    }

    function test_ZeroAddressMakerReverts() public {
        MatchingModule.OspexCommitment memory c = _defaultCommitment();
        c.maker = address(0);
        // Sign doesn't matter — InvalidMakerAddress fires first
        vm.prank(taker);
        vm.expectRevert(MatchingModule.MatchingModule__InvalidMakerAddress.selector);
        matchingModule.matchCommitment(c, "", DEFAULT_TAKER_AMOUNT, 0, 0, 0);
    }

    function test_ReplayAfterFullFillReverts() public {
        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _matchDefault();

        // Same commitment+sig should now be fully filled
        vm.prank(taker);
        vm.expectRevert(MatchingModule.MatchingModule__CommitmentFullyFilled.selector);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_AMOUNT, 0, 0, 0);
    }

    function test_ReplayAfterCancellationReverts() public {
        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedDefault();

        // Maker cancels
        vm.prank(maker);
        matchingModule.cancelCommitment(c);

        // Attempt to match cancelled commitment
        vm.prank(taker);
        vm.expectRevert(MatchingModule.MatchingModule__CommitmentCancelled.selector);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_AMOUNT, 0, 0, 0);
    }

    // ===================== PARTIAL FILL ACCOUNTING =====================

    function test_PartialFillRecordsCorrectAmount() public {
        // Mock returns 30 USDC (partial fill of 100 USDC max)
        mockPosition.setFillReturnAmount(30_000_000);

        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedDefault();
        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_AMOUNT, 0, 0, 0);

        // Verify filled amount tracks the return value
        bytes32 commitmentHash = matchingModule.getCommitmentHash(c);
        assertEq(matchingModule.s_filledAmounts(commitmentHash), 30_000_000);

        // Remaining should be 70 USDC
        assertEq(matchingModule.getRemainingAmount(c), 70_000_000);
    }

    function test_PartialFillAllowsSecondFillForRemainder() public {
        mockPosition.setFillReturnAmount(50_000_000);

        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedDefault();

        // First fill — 50 USDC
        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_AMOUNT, 0, 0, 0);
        assertEq(matchingModule.getRemainingAmount(c), 50_000_000);

        // Second fill — another 50 USDC
        vm.prank(taker2);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_AMOUNT, 0, 0, 0);
        assertEq(matchingModule.getRemainingAmount(c), 0);

        // Verify makerAmountRemaining passed to mock was 50 on second call
        assertEq(mockPosition.lastMakerAmountRemaining(), 50_000_000);
    }

    function test_MultipleTakersPartialFill() public {
        // Three takers each fill 30 USDC of a 100 USDC commitment
        mockPosition.setFillReturnAmount(30_000_000);

        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedDefault();

        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_AMOUNT, 0, 0, 0);
        assertEq(matchingModule.getRemainingAmount(c), 70_000_000);

        vm.prank(taker2);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_AMOUNT, 0, 0, 0);
        assertEq(matchingModule.getRemainingAmount(c), 40_000_000);

        vm.prank(address(0xEEEE));
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_AMOUNT, 0, 0, 0);
        assertEq(matchingModule.getRemainingAmount(c), 10_000_000);
    }

    function test_FullyFilledReverts() public {
        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _matchDefault();

        vm.prank(taker);
        vm.expectRevert(MatchingModule.MatchingModule__CommitmentFullyFilled.selector);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_AMOUNT, 0, 0, 0);
    }

    /// @notice KEY TEST: Verifies s_filledAmounts tracks the return value from
    ///         PositionModule (makerAmountFilled), NOT the makerAmountRemaining
    ///         that was passed in. This is the accounting pattern flagged for review.
    function test_FillRecordsReturnValueNotRequestedAmount() public {
        // Mock returns only 10 USDC even though 100 USDC remaining was passed
        mockPosition.setFillReturnAmount(10_000_000);

        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedDefault();

        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_AMOUNT, 0, 0, 0);

        // makerAmountRemaining passed to mock should be full maxAmount
        assertEq(mockPosition.lastMakerAmountRemaining(), DEFAULT_MAX_AMOUNT);

        // But s_filledAmounts should be the RETURN VALUE (10), not the remaining (100)
        bytes32 commitmentHash = matchingModule.getCommitmentHash(c);
        assertEq(matchingModule.s_filledAmounts(commitmentHash), 10_000_000);

        // Commitment is NOT fully filled — 90 USDC remaining
        assertEq(matchingModule.getRemainingAmount(c), 90_000_000);

        // Second fill should pass and makerAmountRemaining should be 90
        vm.prank(taker2);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_AMOUNT, 0, 0, 0);
        assertEq(mockPosition.lastMakerAmountRemaining(), 90_000_000);
        assertEq(matchingModule.s_filledAmounts(commitmentHash), 20_000_000);
    }

    /// @notice Verifies that fills accumulate to exactly maxAmount and then block
    function test_FillsAccumulateToMaxAmount() public {
        // 10 fills of 10 USDC each = 100 USDC total = maxAmount
        mockPosition.setFillReturnAmount(10_000_000);

        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedDefault();

        for (uint256 i = 0; i < 10; i++) {
            vm.prank(address(uint160(0xF000 + i)));
            matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_AMOUNT, 0, 0, 0);
        }

        assertEq(matchingModule.getRemainingAmount(c), 0);

        // 11th fill should revert
        vm.prank(taker);
        vm.expectRevert(MatchingModule.MatchingModule__CommitmentFullyFilled.selector);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_AMOUNT, 0, 0, 0);
    }

    // ===================== NONCE / CANCELLATION =====================

    function test_RaiseMinNonceInvalidatesLowerNonces() public {
        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedDefault();
        // c.nonce is 1

        // Maker raises min nonce for this speculation to 5
        vm.prank(maker);
        matchingModule.raiseMinNonce(DEFAULT_CONTEST_ID, defaultScorer, DEFAULT_THE_NUMBER, 5);

        // Commitment with nonce=1 should be rejected
        vm.prank(taker);
        vm.expectRevert(MatchingModule.MatchingModule__NonceTooLow.selector);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_AMOUNT, 0, 0, 0);
    }

    function test_RaiseMinNoncePerMakerPerSpeculation() public {
        // Maker A raises nonce for speculation (1, scorer, 0)
        vm.prank(maker);
        matchingModule.raiseMinNonce(DEFAULT_CONTEST_ID, defaultScorer, DEFAULT_THE_NUMBER, 5);

        // Other signer on the SAME speculation should NOT be affected
        MatchingModule.OspexCommitment memory c = _defaultCommitment();
        c.maker = otherSigner;
        c.nonce = 1; // Below maker's minNonce but otherSigner has no minNonce set
        bytes memory sig = _signCommitment(c, OTHER_PK);

        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_AMOUNT, 0, 0, 0);
        assertEq(mockPosition.createMatchedPairCallCount(), 1); // Should succeed
    }

    function test_RaiseMinNoncePerSpeculation() public {
        // Maker raises nonce for speculation (1, scorer, 0)
        vm.prank(maker);
        matchingModule.raiseMinNonce(DEFAULT_CONTEST_ID, defaultScorer, DEFAULT_THE_NUMBER, 5);

        // Same maker on a DIFFERENT speculation (theNumber=99) should NOT be affected
        mockSpeculation.setSpeculationId(DEFAULT_CONTEST_ID, defaultScorer, 99, 5);
        MatchingModule.OspexCommitment memory c = _defaultCommitment();
        c.theNumber = 99;
        c.nonce = 1;
        bytes memory sig = _signCommitment(c, MAKER_PK);

        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_AMOUNT, 0, 0, 0);
        assertEq(mockPosition.createMatchedPairCallCount(), 1);
    }

    function test_CancelCommitmentOnlyByMaker() public {
        MatchingModule.OspexCommitment memory c = _defaultCommitment();

        // Non-maker cannot cancel
        vm.prank(taker);
        vm.expectRevert(MatchingModule.MatchingModule__NotCommitmentMaker.selector);
        matchingModule.cancelCommitment(c);

        // Maker can cancel
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
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_AMOUNT, 0, 0, 0);
    }

    function test_NonceMustStrictlyIncrease() public {
        // First raise to 5
        vm.prank(maker);
        matchingModule.raiseMinNonce(DEFAULT_CONTEST_ID, defaultScorer, DEFAULT_THE_NUMBER, 5);

        // Raise to 5 again (equal, not higher) — should revert
        vm.prank(maker);
        vm.expectRevert(MatchingModule.MatchingModule__NonceMustIncrease.selector);
        matchingModule.raiseMinNonce(DEFAULT_CONTEST_ID, defaultScorer, DEFAULT_THE_NUMBER, 5);

        // Raise to 4 (lower) — should revert
        vm.prank(maker);
        vm.expectRevert(MatchingModule.MatchingModule__NonceMustIncrease.selector);
        matchingModule.raiseMinNonce(DEFAULT_CONTEST_ID, defaultScorer, DEFAULT_THE_NUMBER, 4);

        // Raise to 6 (higher) — should succeed
        vm.prank(maker);
        matchingModule.raiseMinNonce(DEFAULT_CONTEST_ID, defaultScorer, DEFAULT_THE_NUMBER, 6);
        assertEq(
            matchingModule.getMinNonce(maker, DEFAULT_CONTEST_ID, defaultScorer, DEFAULT_THE_NUMBER),
            6
        );
    }

    // ===================== SPECULATION CREATION PATH =====================

    function test_NewSpeculationCallsCreateMatchedPairWithSpeculation() public {
        // Use contest params that have NO speculation yet
        uint256 newContestId = 42;
        address newScorer = address(0xAAAA);
        int32 newTheNumber = 7;
        // Do NOT pre-set speculation ID — getSpeculationId returns 0

        MatchingModule.OspexCommitment memory c = _defaultCommitment();
        c.contestId = newContestId;
        c.scorer = newScorer;
        c.theNumber = newTheNumber;
        bytes memory sig = _signCommitment(c, MAKER_PK);

        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_AMOUNT, 0, 0, 0);

        // Should have used createMatchedPairWithSpeculation, NOT createMatchedPair
        assertEq(mockPosition.createWithSpecCallCount(), 1);
        assertEq(mockPosition.createMatchedPairCallCount(), 0);

        // Verify correct params forwarded
        assertEq(mockPosition.lastMaker(), maker);
        assertEq(mockPosition.lastTaker(), taker);
        assertEq(mockPosition.lastOdds(), DEFAULT_ODDS);
        assertEq(uint(mockPosition.lastMakerPositionType()), uint(PositionType.Upper));
    }

    function test_ExistingSpeculationCallsCreateMatchedPair() public {
        // Default setUp already has speculation ID = 1
        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedDefault();

        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_AMOUNT, 0, 0, 0);

        // Should have used createMatchedPair, NOT createMatchedPairWithSpeculation
        assertEq(mockPosition.createMatchedPairCallCount(), 1);
        assertEq(mockPosition.createWithSpecCallCount(), 0);

        // Verify correct params forwarded
        assertEq(mockPosition.lastMaker(), maker);
        assertEq(mockPosition.lastTaker(), taker);
        assertEq(mockPosition.lastOdds(), DEFAULT_ODDS);
        assertEq(mockPosition.lastMakerAmountRemaining(), DEFAULT_MAX_AMOUNT);
        assertEq(mockPosition.lastTakerAmount(), DEFAULT_TAKER_AMOUNT);
    }

    function test_CorrectParamsFlowToCreateMatchedPairWithSpeculation() public {
        // Verify all commitment fields pass through correctly
        uint256 contestId = 77;
        address scorer = address(0x7777);
        int32 theNumber = -3;
        uint64 odds = 25_000_000; // 2.50
        uint256 maxAmount = 50_000_000;

        mockPosition.setFillReturnAmount(maxAmount);

        MatchingModule.OspexCommitment memory c = MatchingModule.OspexCommitment({
            maker: maker,
            contestId: contestId,
            scorer: scorer,
            theNumber: theNumber,
            positionType: PositionType.Lower,
            odds: odds,
            maxAmount: maxAmount,
            nonce: 1,
            expiry: block.timestamp + 1 hours
        });
        bytes memory sig = _signCommitment(c, MAKER_PK);

        uint256 takerAmount = 5_000_000;
        uint256 leaderboardId = 3;
        uint256 takerContrib = 100;
        uint256 makerContrib = 200;

        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, takerAmount, leaderboardId, takerContrib, makerContrib);

        // createMatchedPairWithSpeculation was called (new speculation path)
        assertEq(mockPosition.createWithSpecCallCount(), 1);
        assertEq(mockPosition.lastOdds(), odds);
        assertEq(uint(mockPosition.lastMakerPositionType()), uint(PositionType.Lower));
        assertEq(mockPosition.lastMaker(), maker);
        assertEq(mockPosition.lastMakerAmountRemaining(), maxAmount);
        assertEq(mockPosition.lastTaker(), taker);
        assertEq(mockPosition.lastTakerAmount(), takerAmount);
    }

    // ===================== EDGE CASES =====================

    function test_ExpiredCommitmentReverts() public {
        MatchingModule.OspexCommitment memory c = _defaultCommitment();
        c.expiry = block.timestamp + 1 hours;
        bytes memory sig = _signCommitment(c, MAKER_PK);

        // Advance time past expiry
        vm.warp(block.timestamp + 1 hours + 1);

        vm.prank(taker);
        vm.expectRevert(MatchingModule.MatchingModule__CommitmentExpired.selector);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_AMOUNT, 0, 0, 0);
    }

    function test_ExpiryBoundaryAccepted() public {
        MatchingModule.OspexCommitment memory c = _defaultCommitment();
        c.expiry = block.timestamp + 1 hours;
        bytes memory sig = _signCommitment(c, MAKER_PK);

        // Warp to exactly expiry — should PASS (contract uses > not >=)
        vm.warp(c.expiry);

        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_AMOUNT, 0, 0, 0);
        assertEq(mockPosition.createMatchedPairCallCount(), 1);
    }

    function test_TakerAmountZeroReverts() public {
        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedDefault();

        vm.prank(taker);
        vm.expectRevert(MatchingModule.MatchingModule__InvalidTakerAmount.selector);
        matchingModule.matchCommitment(c, sig, 0, 0, 0, 0);
    }

    function test_CommitmentMatchedEventEmitted() public {
        mockPosition.setFillReturnAmount(42_000_000);

        (MatchingModule.OspexCommitment memory c, bytes memory sig) = _signedDefault();
        bytes32 expectedHash = matchingModule.getCommitmentHash(c);

        vm.expectEmit(true, true, true, true);
        emit MatchingModule.CommitmentMatched(
            expectedHash,
            maker,
            taker,
            DEFAULT_CONTEST_ID,
            1, // speculationId
            PositionType.Upper,
            DEFAULT_ODDS,
            42_000_000, // makerFillAmount (mock return value)
            DEFAULT_TAKER_AMOUNT
        );

        vm.prank(taker);
        matchingModule.matchCommitment(c, sig, DEFAULT_TAKER_AMOUNT, 0, 0, 0);
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
        // Deploy a separate MatchingModule wired to the reentrant mock
        MockOspexCoreForMatching reentrCore = new MockOspexCoreForMatching();
        MockSpeculationModuleForMatching reentrSpec = new MockSpeculationModuleForMatching();
        reentrSpec.setSpeculationId(DEFAULT_CONTEST_ID, defaultScorer, DEFAULT_THE_NUMBER, 1);

        ReentrantMockPositionModule reentrPos = new ReentrantMockPositionModule();

        reentrCore.setModule(keccak256("SPECULATION_MODULE"), address(reentrSpec));
        reentrCore.setModule(keccak256("POSITION_MODULE"), address(reentrPos));

        MatchingModule mmReentrant = new MatchingModule(address(reentrCore));

        reentrPos.setTarget(address(mmReentrant));
        reentrPos.setShouldReenter(true);

        // Sign commitment for THIS MatchingModule's domain
        MatchingModule.OspexCommitment memory c = MatchingModule.OspexCommitment({
            maker: maker,
            contestId: DEFAULT_CONTEST_ID,
            scorer: defaultScorer,
            theNumber: DEFAULT_THE_NUMBER,
            positionType: PositionType.Upper,
            odds: DEFAULT_ODDS,
            maxAmount: DEFAULT_MAX_AMOUNT,
            nonce: 1,
            expiry: block.timestamp + 1 hours
        });
        bytes32 digest = mmReentrant.getCommitmentHash(c);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MAKER_PK, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        // The reentrant mock's inner call triggers ReentrancyGuardReentrantCall
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        mmReentrant.matchCommitment(c, sig, DEFAULT_TAKER_AMOUNT, 0, 0, 0);
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
        c2.odds = 20_000_000;
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
            "uint64 odds,"
            "uint256 maxAmount,"
            "uint256 nonce,"
            "uint256 expiry"
            ")"
        );
        assertEq(matchingModule.COMMITMENT_TYPEHASH(), expected);
    }
}
