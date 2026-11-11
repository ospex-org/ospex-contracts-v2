// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {OspexBetting} from "../../src/betting/OspexBetting.sol";
import {OspexCourierRelay} from "../../src/betting/OspexCourierRelay.sol";
import {OspexMatching} from "../../src/betting/OspexMatching.sol";
import {IOspexPositions} from "../../src/betting/IOspexPositions.sol";
import {MarketStatus, Outcome, Side} from "../../src/betting/OspexBettingTypes.sol";
import {BettingBase} from "./BettingBase.sol";

/// @notice The betting set's interface freezes at deploy: the indexer, the courier, the SDK and every signer are
///         built against it. These tests pin each contract's functions, errors and events from the compiled
///         artifacts against signatures written out here, so any change to a name, a type, an order, an indexed
///         flag or the set of functions is a deliberate edit here. Nothing is hashed from the code under test.
contract OspexBettingInterfaceTest is BettingBase {
    /// Break: add any external function to a contract of the set, such as a setter on OspexMarkets.
    function test_theFunctionsAreExactlyThese() public view {
        _assertFunctions(
            "OspexBetting",
            "MARKET_MODULE();MATCHING_MODULE();MODULE_COUNT();MONEYLINE_SCORER_MODULE();POSITION_MODULE();"
            "SPREAD_SCORER_MODULE();TOTAL_SCORER_MODULE();bootstrapModules(bytes32[],address[]);"
            "emitCoreEvent(bytes32,bytes);finalize();getModule(bytes32);i_deployer();i_games();i_token();"
            "isApprovedScorer(address);isRegisteredModule(address);s_finalized();s_isModuleRegistered(address);"
            "s_moduleCount();s_moduleRegistry(bytes32)"
        );
        _assertFunctions(
            "OspexMarkets",
            "EVENT_MARKET_CREATED();EVENT_MARKET_SETTLED();MARKET_MODULE();MAX_LINE_TICKS();"
            "MONEYLINE_SCORER_MODULE();POSITION_MODULE();TOTAL_SCORER_MODULE();"
            "createMarket(uint256,address,int32,address,address);getMarket(uint256);"
            "getMarketId(uint256,address,int32);getModuleType();i_games();i_ospexCore();marketCount();"
            "requireBetsOpen(uint256);"
            "s_marketCount();s_marketLookup(uint256,address,int32);s_markets(uint256);settleMarket(uint256)"
        );
        _assertFunctions(
            "OspexPositions",
            "EVENT_HELD_CHANGED();EVENT_PAY_BACK_REFUSED();EVENT_POSITION_CLAIMED();EVENT_POSITION_MATCHED_PAIR();"
            "MARKET_MODULE();MATCHING_MODULE();POSITION_MODULE();claimPosition(uint256,uint8);"
            "claimPositionFor(uint256,address,uint8);finishFills(uint256,address,address[]);getModuleType();"
            "getPosition(uint256,address,uint8);i_ospexCore();i_token();"
            "previewFill(uint256,address,uint8,uint256,uint256);"
            "recordFill(uint256,address,int32,uint8,address,uint256,address,uint256);s_held(uint256,address);"
            "s_heldTotal(uint256);s_positions(uint256,address,uint8);sendPayBack(address,uint256)"
        );
        _assertFunctions(
            "OspexMatching",
            "EVENT_COURIER_REGISTERED();EVENT_COURIER_UNREGISTERED();EVENT_CROSSED();EVENT_MIN_NONCE_UPDATED();"
            "EVENT_ORDER_CANCELLED();EVENT_ORDER_MATCHED();EVENT_ORDER_SKIPPED();EVENT_TAKING_STAKE_CAP_LIFTED();"
            "LOT();MARKET_MODULE();MATCHING_MODULE();MAX_LINE_TICKS();MAX_ODDS();MAX_TAKING_LIFE();MIN_ODDS();"
            "ODDS_SCALE();ORDER_TYPEHASH();POSITION_MODULE();TAKING_STAKE_CAP();"
            "cancelOrder((address,uint256,address,int32,uint8,uint16,uint256,uint256,uint256,uint256));"
            "cross(((address,uint256,address,int32,uint8,uint16,uint256,uint256,uint256,uint256),bytes),"
            "((address,uint256,address,int32,uint8,uint16,uint256,uint256,uint256,uint256),bytes)[]);" "eip712Domain();"
            "getOrderHash((address,uint256,address,int32,uint8,uint16,uint256,uint256,uint256,uint256));"
            "getDomainSeparator();getModuleType();i_ospexCore();i_timelock();isCourier(address,address);"
            "liftTakingStakeCap();raiseMinNonce(uint256,address,int32,uint256);registerCourier(address);"
            "s_cancelledOrders(bytes32);s_filledRisk(bytes32);s_minNonces(address,bytes32);"
            "s_takingStakeCapLifted();unregisterCourier(address)"
        );
        _assertFunctions(
            "OspexMoneylineScorer",
            "MONEYLINE_SCORER_MODULE();getModuleType();i_games();outcome(uint32,uint32,int32);outcomeOf(uint256,int32)"
        );
        _assertFunctions(
            "OspexSpreadScorer",
            "SPREAD_SCORER_MODULE();getModuleType();i_games();outcome(uint32,uint32,int32);outcomeOf(uint256,int32)"
        );
        _assertFunctions(
            "OspexTotalScorer",
            "TOTAL_SCORER_MODULE();getModuleType();i_games();outcome(uint32,uint32,int32);outcomeOf(uint256,int32)"
        );
        // The courier relay, beside the set: its one path, its setter and its three reads. A function added to
        // it, whatever it does, is not in this list.
        _assertFunctions(
            "OspexCourierRelay",
            "cross(((address,uint256,address,int32,uint8,uint16,uint256,uint256,uint256,uint256),bytes),"
            "((address,uint256,address,int32,uint8,uint16,uint256,uint256,uint256,uint256),bytes)[]);"
            "i_matching();i_timelock();s_sender();setSender(address)"
        );
        // No contract of the set takes native money, and neither does the relay.
        string[8] memory names = [
            "OspexBetting",
            "OspexMarkets",
            "OspexPositions",
            "OspexMatching",
            "OspexMoneylineScorer",
            "OspexSpreadScorer",
            "OspexTotalScorer",
            "OspexCourierRelay"
        ];
        for (uint256 i; i < names.length; ++i) {
            string memory json = _artifact(names[i]);
            assertFalse(vm.keyExistsJson(json, "$.abi[?(@.type == 'receive')]"), "a receive function");
            assertFalse(vm.keyExistsJson(json, "$.abi[?(@.type == 'fallback')]"), "a fallback function");
            assertFalse(vm.keyExistsJson(json, "$.abi[?(@.stateMutability == 'payable')]"), "a payable function");
        }
    }

    /// Break: in OspexMarkets.sol, give `error OspexMarkets__ModuleNotSet(bytes32 moduleType);` a second argument,
    /// `address core`, with its one revert.
    function test_theErrorsAreExactlyThese() public view {
        _assertErrors(
            "OspexBetting",
            "OspexBetting__AlreadyFinalized();OspexBetting__ArrayLengthMismatch();"
            "OspexBetting__DuplicateModuleType(bytes32 moduleType);OspexBetting__GamesNotAContract(address games);"
            "OspexBetting__InvalidModuleAddress(address moduleAddress);"
            "OspexBetting__ModuleCoreMismatch(address moduleAddress,address found);"
            "OspexBetting__ModuleCountMismatch(uint256 registered,uint256 required);"
            "OspexBetting__ModuleGamesMismatch(address moduleAddress,address found);"
            "OspexBetting__ModuleNotRegistered(bytes32 moduleType);"
            "OspexBetting__ModuleTokenMismatch(address moduleAddress,address found);"
            "OspexBetting__ModuleTypeMismatch(address moduleAddress,bytes32 named,bytes32 found);"
            "OspexBetting__NotDeployer(address caller);OspexBetting__NotRegisteredModule(address moduleAddress);"
            "OspexBetting__TokenNotAContract(address token)"
        );
        _assertErrors(
            "OspexMarkets",
            "OspexMarkets__AlreadySettled(uint256 marketId);OspexMarkets__BetsClosed(uint256 gameId,uint256 closesAt);"
            "OspexMarkets__GameEnded(uint256 gameId,uint8 status);"
            "OspexMarkets__GameNotEnded(uint256 gameId,uint8 status);OspexMarkets__InvalidAddress();"
            "OspexMarkets__InvalidLineTicks(address scorer,int32 lineTicks);"
            "OspexMarkets__LineTicksOutOfRange(int32 lineTicks);OspexMarkets__MarketExists(uint256 marketId);"
            "OspexMarkets__MarketSettled(uint256 marketId);"
            "OspexMarkets__ModuleNotSet(bytes32 moduleType);OspexMarkets__NotAuthorized(address caller);"
            "OspexMarkets__ScorerNotApproved(address scorer);OspexMarkets__UnknownMarket(uint256 marketId)"
        );
        _assertErrors(
            "OspexPositions",
            "OspexPositions__AlreadyClaimed();OspexPositions__InvalidAddress();OspexPositions__InvalidAmount();"
            "OspexPositions__MakerPullRefused(address maker,uint256 makerRisk,uint256 pull);"
            "OspexPositions__MarketShort(uint256 marketId,uint256 asked,uint256 total);"
            "OspexPositions__ModuleNotSet(bytes32 moduleType);"
            "OspexPositions__NoPayout();OspexPositions__NotMatchingModule(address caller);"
            "OspexPositions__NotSelf(address caller);"
            "OspexPositions__NotSettled(uint256 marketId);OspexPositions__ShortReceipt(uint256 owed,uint256 held);"
            "OspexPositions__TakerPullRefused(address taker,uint256 pull);ReentrancyGuardReentrantCall();"
            "SafeERC20FailedOperation(address token)"
        );
        _assertErrors(
            "OspexMatching",
            "InvalidShortString();OspexMatching__BadSignature(bytes32 orderHash);OspexMatching__CapAlreadyLifted();"
            "OspexMatching__CourierNotRegistered(address account,address courier);OspexMatching__CrossInProgress();"
            "OspexMatching__GamesHasNoTimelock(address games);OspexMatching__GamesNotAContract(address games);"
            "OspexMatching__InvalidAddress();"
            "OspexMatching__MinFillAboveStake(bytes32 orderHash,uint256 minFill,uint256 riskAmount);"
            "OspexMatching__NonceMustIncrease();"
            "OspexMatching__NotOrderAccount();OspexMatching__NotTheTimelock(address caller);"
            "OspexMatching__NothingFilled(uint8[] reasons);"
            "OspexMatching__OtherGame(bytes32 orderHash);OspexMatching__OtherLine(bytes32 orderHash);"
            "OspexMatching__OtherScorer(bytes32 orderHash);OspexMatching__PriceOutOfRange(bytes32 orderHash);"
            "OspexMatching__PricesDoNotMeet(bytes32 orderHash);OspexMatching__SameSide(bytes32 orderHash);"
            "OspexMatching__SenderNotCourier(address account,address sender);"
            "OspexMatching__StakeNotInLots(bytes32 orderHash);OspexMatching__TakingOrderCancelled(bytes32 orderHash);"
            "OspexMatching__TakingOrderExpired(bytes32 orderHash);OspexMatching__TakingOrderFilled(bytes32 orderHash);"
            "OspexMatching__TakingOrderTooLong(bytes32 orderHash);"
            "OspexMatching__TakingOrderUnderMinFill(bytes32 takingHash,uint256 filledThisCross,uint256 minFill,"
            "uint256 roomLeft,(bytes32 orderHash,bool filled,uint8 reason,uint256 makerRisk,uint256 takerRisk)[] legs);"
            "OspexMatching__TakingStakeAboveCap(bytes32 orderHash);"
            "OspexMatching__ZeroCourier();StringTooLong(string str)"
        );
        _assertErrors("OspexMoneylineScorer", "OspexScorer__InvalidCore()");
        _assertErrors("OspexSpreadScorer", "OspexScorer__InvalidCore()");
        _assertErrors("OspexTotalScorer", "OspexScorer__InvalidCore()");
        _assertErrors(
            "OspexCourierRelay",
            "OspexCourierRelay__MatchingNotAContract(address matching);"
            "OspexCourierRelay__NotTheSender(address caller);OspexCourierRelay__NotTheTimelock(address caller);"
            "OspexCourierRelay__TimelockNotAContract(address timelock);OspexCourierRelay__ZeroSender()"
        );
    }

    /// Every deploy value a module holds behind a getter is one the core reads when it registers the module, or
    /// one derived from such a value. The list of each module's `i_` functions comes from its compiled artifact
    /// and is pinned here, whole: the markets module's games set and core, the positions module's coin and core,
    /// the matching module's core and its timelock, and each market contract's games set. Then the six, built
    /// from src/, are registered on a fresh core, and the core must be seen to call each of the read getters on
    /// the module that has it. The one derived value, the matching module's timelock, is not read by the core:
    /// it is read once by the module's own constructor from the core's games set, and is asserted here to be
    /// that games set's. So a module that gains a deploy value with a getter turns this red: the pinned list,
    /// and, unless it is listed as derived, the read the core does not make. A value with no getter is not seen
    /// here. The reads the core's own interface for a module's wiring declares are the three read getters; the
    /// type's read is IOspexModule's.
    /// Break: in OspexPositions.sol, add a second deploy value with a getter, `address public immutable i_payer
    /// = address(1);`.
    function test_theDeployValuesAreExactlyTheOnesTheCoreReads() public {
        string[6] memory names = [
            "OspexMarkets",
            "OspexPositions",
            "OspexMatching",
            "OspexMoneylineScorer",
            "OspexSpreadScorer",
            "OspexTotalScorer"
        ];
        // What the core reads of each at bootstrap.
        string[6] memory read = [
            "i_games();i_ospexCore()", "i_ospexCore();i_token()", "i_ospexCore()", "i_games()", "i_games()", "i_games()"
        ];
        // What is derived from one of those, and not read by the core: the matching module's timelock.
        string[6] memory derived = ["", "", "i_timelock()", "", "", ""];

        vm.startPrank(deployer, deployer);
        OspexBetting c = new OspexBetting(address(games), address(token));
        (bytes32[] memory types, address[] memory addrs) = _freshSet(c);
        uint256 reads;
        for (uint256 i; i < names.length; ++i) {
            string[] memory values = _deployValues(names[i]);
            string[] memory reads_ = vm.split(read[i], ";");
            _assertSameSet(values, _together(reads_, derived[i]), string.concat(names[i], " deploy value"));
            for (uint256 v; v < reads_.length; ++v) {
                // The call below must make this read of this module, or the test fails when it ends.
                vm.expectCall(addrs[i], abi.encodePacked(bytes4(keccak256(bytes(reads_[v])))));
                ++reads;
            }
        }
        c.bootstrapModules(types, addrs);
        vm.stopPrank();
        assertEq(reads, 8, "the reads expected of the six");
        // The derived value is its derivation: the timelock the core's games set answers to, which is the one
        // the test base deployed.
        assertEq(
            OspexMatching(addrs[2]).i_timelock(),
            games.i_timelock(),
            "the matching module's timelock is the games set's"
        );
        assertEq(
            OspexMatching(addrs[2]).i_timelock(),
            address(timelock),
            "the matching module's timelock is the stock timelock"
        );

        string memory wiring =
            vm.readFile(string.concat(vm.projectRoot(), "/out/OspexBetting.sol/IOspexModuleWiring.json"));
        _assertSameSet(
            vm.parseJsonKeys(wiring, "$.methodIdentifiers"),
            vm.split("i_games();i_ospexCore();i_token()", ";"),
            "wiring read"
        );
    }

    /// The events are exactly these, as the compiled artifacts declare them: each contract's set of events, and
    /// for each event its name and every parameter's type, name, order and indexed flag, written out here.
    /// Nothing here compares them with v2's events.
    /// Break: in IOspexPositions.sol, drop `indexed` from PositionFilled's `taker`.
    function test_theEventsAreExactlyThese() public view {
        _assertEvents(
            "OspexBetting",
            "CoreEventEmitted(indexed bytes32 eventType,indexed address emitter,bytes eventData);Finalized();"
            "GamesSet(indexed address games);ModulesBootstrapped(uint256 moduleCount);TokenSet(indexed address token)"
        );
        _assertEvents(
            "OspexMarkets",
            "MarketCreated(indexed uint256 marketId,indexed uint256 gameId,address scorer,int32 lineTicks,"
            "address maker,address taker);MarketSettled(indexed uint256 marketId,uint8 outcome,address scorer)"
        );
        _assertEvents(
            "OspexPositions",
            "HeldChanged(indexed uint256 marketId,indexed address account,uint256 pulled,uint256 paidBack,"
            "uint256 held);PayBackRefused(indexed uint256 marketId,indexed address account,uint256 amount,"
            "uint256 held);PositionClaimed(indexed uint256 marketId,indexed address user,uint8 side,uint256 payout);"
            "PositionFilled(indexed uint256 marketId,indexed address maker,indexed address taker,uint8 makerSide,"
            "uint8 takerSide,uint256 makerRisk,uint256 takerRisk)"
        );
        _assertEvents(
            "OspexMatching",
            "CourierRegistered(indexed address account,indexed address courier);"
            "CourierUnregistered(indexed address account,indexed address courier);"
            "Crossed(indexed address courier,indexed bytes32 takingOrderHash,indexed address taker,uint256 marketId,"
            "uint256 totalMakerRisk,uint256 totalTakerRisk);EIP712DomainChanged();"
            "MinNonceUpdated(indexed address account,uint256 gameId,"
            "address scorer,int32 lineTicks,uint256 newMinNonce,indexed bytes32 marketKey);"
            "OrderCancelled(indexed bytes32 orderHash,indexed address account,uint256 gameId,"
            "address scorer,int32 lineTicks,uint8 positionType,uint16 oddsTick,uint256 riskAmount,uint256 nonce,"
            "uint256 expiry,uint256 minFill);"
            "OrderMatched(indexed bytes32 orderHash,indexed address maker,indexed address taker,uint256 gameId,"
            "uint256 marketId,address scorer,int32 lineTicks,uint8 makerPositionType,uint16 oddsTick,"
            "uint256 makerRisk,uint256 takerRisk,uint256 orderRiskAmount,uint256 nonce,uint256 expiry,"
            "uint256 orderMinFill);"
            "OrderSkipped(indexed bytes32 orderHash,indexed address account,indexed bytes32 takingOrderHash,"
            "uint8 reason);TakingStakeCapLifted()"
        );
        _assertEvents("OspexMoneylineScorer", "");
        _assertEvents("OspexSpreadScorer", "");
        _assertEvents("OspexTotalScorer", "");
        _assertEvents("OspexCourierRelay", "SenderSet(indexed address previous,indexed address current)");
    }

    /// What the renames and the Cross put on the wire, each as a literal worked out outside the contracts: the
    /// selectors of the renamed and the new calls, the first topic of each of the matching module's events,
    /// its hub tags, and the selector of the one error the matching module reads from the positions module.
    /// A v2 name gives another value for each: `cancelCommitment`, `CommitmentCancelled`, `COMMITMENT_CANCELLED`.
    /// The three calls that take an order, and the two events that carry one, moved with the order's tenth field.
    /// Break: in OspexMatching.sol, give `OrderCancelled`'s price a wider type, `uint32 oddsTick`: its first
    /// topic moves.
    function test_theSelectorsTopicsAndTagsAreThese() public view {
        assertEq(OspexMatching.cancelOrder.selector, bytes4(0xd8de9de3), "cancelOrder");
        assertEq(OspexMatching.getOrderHash.selector, bytes4(0xd9791d83), "getOrderHash");
        assertEq(OspexMatching.cross.selector, bytes4(0x84075346), "cross");
        assertEq(matching.s_cancelledOrders.selector, bytes4(0xbb31a508), "s_cancelledOrders");
        assertEq(matching.s_filledRisk.selector, bytes4(0x0c67b3ca), "s_filledRisk");
        assertEq(matching.ORDER_TYPEHASH.selector, bytes4(0xf973a209), "ORDER_TYPEHASH");
        assertEq(matching.EVENT_ORDER_CANCELLED.selector, bytes4(0x896db280), "EVENT_ORDER_CANCELLED");
        assertEq(markets.requireBetsOpen.selector, bytes4(0xfd088e68), "requireBetsOpen");

        assertEq(
            OspexMatching.OrderCancelled.selector,
            0x599edd68a89f1a39aa2bdf45d6d629dcaaaf2d82083660caa69450354949a073,
            "OrderCancelled's first topic"
        );
        assertEq(
            OspexMatching.OrderMatched.selector,
            0x89d4fedbfa48ad640c600e7f6fca6be6f3b383f3fda4b764f9b1b113a1c63b22,
            "OrderMatched's first topic"
        );
        assertEq(
            OspexMatching.OrderSkipped.selector,
            0x42b88ad95f0ff22337a218edd256a98ffff608a3688fc0af8b50cefb361dad92,
            "OrderSkipped's first topic"
        );
        assertEq(
            OspexMatching.Crossed.selector,
            0x3f1220a2d8e3b575fafae8903189042bf84dccbab62fee8daeea03012f4794ce,
            "Crossed's first topic"
        );
        assertEq(
            OspexMatching.MinNonceUpdated.selector,
            0x0f7ff1d4c2299e0abe408168a40ea050f9cfb2fb7951b3c69685c0838e0d6420,
            "MinNonceUpdated's first topic, which no rename moved"
        );

        assertEq(
            matching.EVENT_ORDER_CANCELLED(),
            0x69d3d039f79879d241ea815c12015cedeca0cfad0556cdf56843bd9afd23e930,
            "the hub tag ORDER_CANCELLED"
        );
        assertEq(
            matching.EVENT_ORDER_MATCHED(),
            0xfa322e978a2adfc727435b82e5488c09e09c277b51c8b62e3ce9a85e2bba78ec,
            "the hub tag ORDER_MATCHED"
        );
        assertEq(
            matching.EVENT_ORDER_SKIPPED(),
            0xd9ee87ea103f803246394f2ae69781709fe90256e32b4dfbf61e28297ccf41a3,
            "the hub tag ORDER_SKIPPED"
        );
        assertEq(
            matching.EVENT_CROSSED(),
            0x1463f72f87d1265b9cefafa5540efab1350a6d3d6e2486dc2d46a16974521fdb,
            "the hub tag CROSSED"
        );

        // Shared collateral: the maker's refusal carries a third word, so its selector moved; the taker's kept
        // its two types under a renamed parameter, so its selector did not; the two new errors; the end call, the
        // claim for anyone, the pay-back entry, the two reads and the preview; the two events and their hub tags.
        assertEq(IOspexPositions.OspexPositions__MakerPullRefused.selector, bytes4(0x035fa92d), "MakerPullRefused");
        assertEq(IOspexPositions.OspexPositions__TakerPullRefused.selector, bytes4(0x56f4806f), "TakerPullRefused");
        assertEq(IOspexPositions.OspexPositions__MarketShort.selector, bytes4(0x8d232a84), "MarketShort");
        assertEq(IOspexPositions.OspexPositions__NotSelf.selector, bytes4(0x361e7a7e), "NotSelf");
        assertEq(IOspexPositions.recordFill.selector, bytes4(0xb714db69), "recordFill, as before");
        assertEq(IOspexPositions.finishFills.selector, bytes4(0x57c9a77a), "finishFills");
        assertEq(IOspexPositions.claimPosition.selector, bytes4(0x390bfff4), "claimPosition, as before");
        assertEq(IOspexPositions.claimPositionFor.selector, bytes4(0x78e49e98), "claimPositionFor");
        assertEq(IOspexPositions.sendPayBack.selector, bytes4(0xdf8a63c3), "sendPayBack");
        assertEq(positions.s_held.selector, bytes4(0x186d7cb1), "s_held");
        assertEq(positions.s_heldTotal.selector, bytes4(0xcb83160e), "s_heldTotal");
        assertEq(IOspexPositions.previewFill.selector, bytes4(0x74ae1876), "previewFill");
        assertEq(positions.EVENT_HELD_CHANGED.selector, bytes4(0xa387c6f8), "EVENT_HELD_CHANGED");
        assertEq(positions.EVENT_PAY_BACK_REFUSED.selector, bytes4(0xeeb327e3), "EVENT_PAY_BACK_REFUSED");
        assertEq(
            IOspexPositions.HeldChanged.selector,
            0xe0c3b81c7075d7192d889148bd51261c54cdb61c69c6ffaf222f11c024a4aeb2,
            "HeldChanged's first topic"
        );
        assertEq(
            IOspexPositions.PayBackRefused.selector,
            0x4087e7241a499c3ad935a1f0dfebacfcfd1e8289d430836f38dc84958de5e78f,
            "PayBackRefused's first topic"
        );
        assertEq(
            positions.EVENT_HELD_CHANGED(),
            0x4d9f77fa86fb1f893c471b724296e1015e520a6bc6a12677ace303b1eda049ef,
            "the hub tag HELD_CHANGED"
        );
        assertEq(
            positions.EVENT_PAY_BACK_REFUSED(),
            0x2acc6e4752da0c188407c8f48742422035635efa932160a0618e1bc020e147e9,
            "the hub tag PAY_BACK_REFUSED"
        );
        assertEq(OspexMatching.OspexMatching__CrossInProgress.selector, bytes4(0x5eabe743), "CrossInProgress");
        assertEq(OspexMatching.OspexMatching__NothingFilled.selector, bytes4(0x8240428c), "NothingFilled");

        // The cap and its switch.
        assertEq(OspexMatching.liftTakingStakeCap.selector, bytes4(0xefa465af), "liftTakingStakeCap");
        assertEq(matching.s_takingStakeCapLifted.selector, bytes4(0x95b3ff17), "s_takingStakeCapLifted");
        assertEq(matching.TAKING_STAKE_CAP.selector, bytes4(0xbf5bf23c), "TAKING_STAKE_CAP");
        assertEq(matching.i_timelock.selector, bytes4(0x4d9939ee), "i_timelock");
        assertEq(
            OspexMatching.TakingStakeCapLifted.selector,
            0xd83df7f0d15f92a8c607aaceb0537d8f43a1b3f6b1e37dc069f7ede6e80ffce8,
            "TakingStakeCapLifted's first topic"
        );
        assertEq(
            matching.EVENT_TAKING_STAKE_CAP_LIFTED(),
            0xc832d7a937dd65998090c171fdb041bc614b1b5245ff3a624d32391c4f58499a,
            "the hub tag TAKING_STAKE_CAP_LIFTED"
        );
        assertEq(OspexMatching.OspexMatching__TakingStakeAboveCap.selector, bytes4(0x17d791ff), "TakingStakeAboveCap");
        assertEq(OspexMatching.OspexMatching__NotTheTimelock.selector, bytes4(0x3b374a89), "NotTheTimelock");
        assertEq(OspexMatching.OspexMatching__CapAlreadyLifted.selector, bytes4(0xd648d5dd), "CapAlreadyLifted");
        assertEq(matching.EVENT_TAKING_STAKE_CAP_LIFTED.selector, bytes4(0xdb051412), "EVENT_TAKING_STAKE_CAP_LIFTED");
        assertEq(OspexMatching.OspexMatching__GamesNotAContract.selector, bytes4(0xdfa33803), "GamesNotAContract");
        assertEq(OspexMatching.OspexMatching__GamesHasNoTimelock.selector, bytes4(0x08d9f5ce), "GamesHasNoTimelock");
        assertEq(matching.TAKING_STAKE_CAP(), 10_000, "the cap: one cent of a six-decimal coin, 100 lots");

        // The minimum fill: its two refusals, and the typehash of the ten-field type.
        assertEq(OspexMatching.OspexMatching__MinFillAboveStake.selector, bytes4(0xec1cc7bd), "MinFillAboveStake");
        assertEq(
            OspexMatching.OspexMatching__TakingOrderUnderMinFill.selector, bytes4(0x18815210), "TakingOrderUnderMinFill"
        );
        assertEq(
            matching.ORDER_TYPEHASH(),
            0x9f84ebcb32dbe12642da2b9008bc0ec2e6332472ec69f27f13e8abebbb92934c,
            "the typehash of the ten-field type"
        );

        // The courier relay: its Cross under the matching module's own selector, its setter, its three reads, its
        // event's first topic and its five errors.
        OspexCourierRelay relay = OspexCourierRelay(payable(address(0)));
        assertEq(OspexCourierRelay.cross.selector, bytes4(0x84075346), "the relay's cross");
        assertEq(OspexCourierRelay.cross.selector, OspexMatching.cross.selector, "the relay's cross, the Cross's");
        assertEq(OspexCourierRelay.setSender.selector, bytes4(0xced32b0c), "setSender");
        assertEq(relay.i_matching.selector, bytes4(0xa15622a6), "the relay's i_matching");
        assertEq(relay.i_timelock.selector, bytes4(0x4d9939ee), "the relay's i_timelock");
        assertEq(relay.s_sender.selector, bytes4(0xf3a53fb0), "s_sender");
        assertEq(
            OspexCourierRelay.SenderSet.selector,
            0x2528c2c57a6310ea9ba962d28443563e7e32dd03dbf7cf8900230f5f845383f8,
            "SenderSet's first topic"
        );
        assertEq(
            OspexCourierRelay.OspexCourierRelay__MatchingNotAContract.selector,
            bytes4(0x5ba72116),
            "the relay's MatchingNotAContract"
        );
        assertEq(
            OspexCourierRelay.OspexCourierRelay__TimelockNotAContract.selector,
            bytes4(0x50871005),
            "the relay's TimelockNotAContract"
        );
        assertEq(OspexCourierRelay.OspexCourierRelay__ZeroSender.selector, bytes4(0xea571194), "ZeroSender");
        assertEq(OspexCourierRelay.OspexCourierRelay__NotTheSender.selector, bytes4(0xc77442be), "NotTheSender");
        assertEq(
            OspexCourierRelay.OspexCourierRelay__NotTheTimelock.selector,
            bytes4(0x94b41091),
            "the relay's NotTheTimelock"
        );
    }

    /// The enums the events and the reads carry, by number: a market's status, its outcome, a side, and the
    /// reason a resting order was skipped for.
    /// Break: in OspexBettingTypes.sol, swap Over and Under in Outcome.
    function test_theNumbersAreThese() public view {
        string memory json = _artifact("OspexMarkets");
        string memory settled = "$.abi[?(@.name == 'MarketSettled')].inputs";
        assertEq(vm.parseJsonString(json, string.concat(settled, "[1].internalType")), "enum Outcome");
        string memory market = "$.abi[?(@.name == 'getMarket')].outputs[0].components";
        _assertParams(json, market, "gameId;scorer;lineTicks;status;outcome", "uint256;address;int32;uint8;uint8");
        assertEq(vm.parseJsonString(json, string.concat(market, "[3].internalType")), "enum MarketStatus");
        assertEq(vm.parseJsonString(json, string.concat(market, "[4].internalType")), "enum Outcome");

        json = _artifact("OspexPositions");
        string memory position = "$.abi[?(@.name == 'getPosition')].outputs[0].components";
        _assertParams(json, position, "risk;profit;side;claimed", "uint256;uint256;uint8;bool");
        assertEq(vm.parseJsonString(json, string.concat(position, "[2].internalType")), "enum Side");
        // Shared collateral: both claims answer the payout, previewFill answers the pull and the pay-back, and
        // the end call and the pay-back entry answer nothing.
        _assertParams(json, "$.abi[?(@.name == 'claimPosition')].outputs", "payout", "uint256");
        _assertParams(json, "$.abi[?(@.name == 'claimPositionFor')].outputs", "payout", "uint256");
        _assertParams(json, "$.abi[?(@.name == 'previewFill')].outputs", "pull;payBack", "uint256;uint256");
        assertTrue(vm.keyExistsJson(json, "$.abi[?(@.name == 'finishFills')].outputs"), "finishFills is in the ABI");
        assertFalse(vm.keyExistsJson(json, "$.abi[?(@.name == 'finishFills')].outputs[0]"), "finishFills answers");
        assertTrue(vm.keyExistsJson(json, "$.abi[?(@.name == 'sendPayBack')].outputs"), "sendPayBack is in the ABI");
        assertFalse(vm.keyExistsJson(json, "$.abi[?(@.name == 'sendPayBack')].outputs[0]"), "sendPayBack answers");

        json = _artifact("OspexMatching");
        string memory skipped = "$.abi[?(@.name == 'OrderSkipped')].inputs";
        assertEq(vm.parseJsonString(json, string.concat(skipped, "[3].internalType")), "enum OspexMatching.SkipReason");

        // The numbers themselves: 0 is never a settled outcome; side A is 0.
        assertEq(uint8(MarketStatus.Open), 0);
        assertEq(uint8(MarketStatus.Closed), 1);
        assertEq(uint8(Outcome.None), 0);
        assertEq(uint8(Outcome.Away), 1);
        assertEq(uint8(Outcome.Home), 2);
        assertEq(uint8(Outcome.Over), 3);
        assertEq(uint8(Outcome.Under), 4);
        assertEq(uint8(Outcome.Push), 5);
        assertEq(uint8(Outcome.Void), 6);
        assertEq(uint8(Side.A), 0);
        assertEq(uint8(Side.B), 1);
        // A skip's reasons, in the order they are tested.
        assertEq(uint8(OspexMatching.SkipReason.NoCourier), 0);
        assertEq(uint8(OspexMatching.SkipReason.Cancelled), 1);
        assertEq(uint8(OspexMatching.SkipReason.Expired), 2);
        assertEq(uint8(OspexMatching.SkipReason.NoRoom), 3);
        assertEq(uint8(OspexMatching.SkipReason.NothingFits), 4);
        assertEq(uint8(OspexMatching.SkipReason.UnderMinFill), 5);
        assertEq(uint8(OspexMatching.SkipReason.PullRefused), 6);
    }

    // ──────────────────────────── Helpers ──────────────────────────────

    function _assertFunctions(string memory name, string memory want) internal view {
        string[] memory got = vm.parseJsonKeys(_artifact(name), "$.methodIdentifiers");
        _assertSameSet(got, vm.split(want, ";"), string.concat(name, " function"));
    }

    /// @dev The functions of `name` whose names begin "i_", from its compiled artifact, as signatures.
    function _deployValues(string memory name) internal view returns (string[] memory got) {
        string[] memory all = vm.parseJsonKeys(_artifact(name), "$.methodIdentifiers");
        string[] memory found = new string[](all.length);
        uint256 n;
        for (uint256 i; i < all.length; ++i) {
            bytes memory key = bytes(all[i]);
            if (key.length > 2 && key[0] == "i" && key[1] == "_") found[n++] = all[i];
        }
        got = new string[](n);
        for (uint256 i; i < n; ++i) {
            got[i] = found[i];
        }
    }

    /// @dev `a` with `b` appended, or `a` alone when `b` is empty.
    function _together(string[] memory a, string memory b) internal pure returns (string[] memory out) {
        if (bytes(b).length == 0) return a;
        out = new string[](a.length + 1);
        for (uint256 i; i < a.length; ++i) {
            out[i] = a[i];
        }
        out[a.length] = b;
    }

    function _assertErrors(string memory name, string memory want) internal view {
        _assertSameSet(_abiSignatures(_artifact(name), "error"), vm.split(want, ";"), string.concat(name, " error"));
    }

    function _assertEvents(string memory name, string memory want) internal view {
        string[] memory w = bytes(want).length == 0 ? new string[](0) : vm.split(want, ";");
        _assertSameSet(_abiSignatures(_artifact(name), "event"), w, string.concat(name, " event"));
    }
}
