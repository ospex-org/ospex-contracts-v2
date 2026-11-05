// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

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
            "s_marketCount();s_marketLookup(uint256,address,int32);s_markets(uint256);settleMarket(uint256)"
        );
        _assertFunctions(
            "OspexPositions",
            "EVENT_POSITION_CLAIMED();EVENT_POSITION_MATCHED_PAIR();MARKET_MODULE();MATCHING_MODULE();"
            "POSITION_MODULE();claimPosition(uint256,uint8);getModuleType();getPosition(uint256,address,uint8);"
            "i_ospexCore();i_token();recordFill(uint256,address,int32,uint8,address,uint256,address,uint256);"
            "s_positions(uint256,address,uint8)"
        );
        _assertFunctions(
            "OspexMatching",
            "COMMITMENT_TYPEHASH();EVENT_COMMITMENT_CANCELLED();EVENT_MIN_NONCE_UPDATED();MARKET_MODULE();"
            "MATCHING_MODULE();MAX_LINE_TICKS();MAX_ODDS();MIN_ODDS();ODDS_SCALE();POSITION_MODULE();"
            "cancelCommitment((address,uint256,address,int32,uint8,uint16,uint256,uint256,uint256));"
            "eip712Domain();"
            "getCommitmentHash((address,uint256,address,int32,uint8,uint16,uint256,uint256,uint256));"
            "getDomainSeparator();getModuleType();i_ospexCore();raiseMinNonce(uint256,address,int32,uint256);"
            "s_cancelledCommitments(bytes32);s_minNonces(address,bytes32)"
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
        // No contract of the set takes native money.
        string[7] memory names = [
            "OspexBetting",
            "OspexMarkets",
            "OspexPositions",
            "OspexMatching",
            "OspexMoneylineScorer",
            "OspexSpreadScorer",
            "OspexTotalScorer"
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
            "OspexBetting__ModuleCountMismatch(uint256 registered,uint256 required);"
            "OspexBetting__ModuleNotRegistered(bytes32 moduleType);"
            "OspexBetting__ModuleTypeMismatch(address moduleAddress,bytes32 named,bytes32 found);"
            "OspexBetting__NotDeployer(address caller);OspexBetting__NotRegisteredModule(address moduleAddress);"
            "OspexBetting__TokenNotAContract(address token)"
        );
        _assertErrors(
            "OspexMarkets",
            "OspexMarkets__AlreadySettled(uint256 marketId);OspexMarkets__GameEnded(uint256 gameId,uint8 status);"
            "OspexMarkets__GameNotEnded(uint256 gameId,uint8 status);OspexMarkets__InvalidAddress();"
            "OspexMarkets__InvalidLineTicks(address scorer,int32 lineTicks);"
            "OspexMarkets__LineTicksOutOfRange(int32 lineTicks);OspexMarkets__MarketExists(uint256 marketId);"
            "OspexMarkets__ModuleNotSet(bytes32 moduleType);OspexMarkets__NotAuthorized(address caller);"
            "OspexMarkets__ScorerNotApproved(address scorer);OspexMarkets__UnknownMarket(uint256 marketId)"
        );
        _assertErrors(
            "OspexPositions",
            "OspexPositions__AlreadyClaimed();OspexPositions__InvalidAddress();OspexPositions__InvalidAmount();"
            "OspexPositions__MarketNotOpen(uint256 marketId);OspexPositions__ModuleNotSet(bytes32 moduleType);"
            "OspexPositions__NoPayout();OspexPositions__NotMatchingModule(address caller);"
            "OspexPositions__NotSettled(uint256 marketId);ReentrancyGuardReentrantCall();"
            "SafeERC20FailedOperation(address token)"
        );
        _assertErrors(
            "OspexMatching",
            "InvalidShortString();OspexMatching__InvalidAddress();OspexMatching__NonceMustIncrease();"
            "OspexMatching__NotCommitmentMaker();StringTooLong(string str)"
        );
        _assertErrors("OspexMoneylineScorer", "OspexScorer__InvalidCore()");
        _assertErrors("OspexSpreadScorer", "OspexScorer__InvalidCore()");
        _assertErrors("OspexTotalScorer", "OspexScorer__InvalidCore()");
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
            "PositionClaimed(indexed uint256 marketId,indexed address user,uint8 side,uint256 payout);"
            "PositionFilled(indexed uint256 marketId,indexed address maker,indexed address taker,uint8 makerSide,"
            "uint8 takerSide,uint256 makerRisk,uint256 takerRisk)"
        );
        _assertEvents(
            "OspexMatching",
            "CommitmentCancelled(indexed bytes32 commitmentHash,indexed address maker,uint256 gameId,"
            "address scorer,int32 lineTicks,uint8 positionType,uint16 oddsTick,uint256 riskAmount,uint256 nonce,"
            "uint256 expiry);EIP712DomainChanged();MinNonceUpdated(indexed address maker,uint256 gameId,"
            "address scorer,int32 lineTicks,uint256 newMinNonce,indexed bytes32 marketKey)"
        );
        _assertEvents("OspexMoneylineScorer", "");
        _assertEvents("OspexSpreadScorer", "");
        _assertEvents("OspexTotalScorer", "");
    }

    /// The enums the events and the reads carry, by number: a market's status, its outcome and a side.
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
    }

    // ──────────────────────────── Helpers ──────────────────────────────

    function _assertFunctions(string memory name, string memory want) internal view {
        string[] memory got = vm.parseJsonKeys(_artifact(name), "$.methodIdentifiers");
        _assertSameSet(got, vm.split(want, ";"), string.concat(name, " function"));
    }

    function _assertErrors(string memory name, string memory want) internal view {
        _assertSameSet(_abiSignatures(_artifact(name), "error"), vm.split(want, ";"), string.concat(name, " error"));
    }

    function _assertEvents(string memory name, string memory want) internal view {
        string[] memory w = bytes(want).length == 0 ? new string[](0) : vm.split(want, ";");
        _assertSameSet(_abiSignatures(_artifact(name), "event"), w, string.concat(name, " event"));
    }
}
