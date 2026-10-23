// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {OspexGames} from "../../src/games/OspexGames.sol";
import {IOspexGames} from "../../src/games/IOspexGames.sol";
import {IOspexReporter} from "../../src/games/IOspexReporter.sol";
import {IGameReporters} from "../../src/signpost/IGameReporters.sol";
import {GamesBase} from "./GamesBase.sol";

/// @notice The games contract's interface freezes at deploy: every reporter, the betting set, the indexer and
///         the signpost are built against it. These tests pin it from literal text and from the compiled
///         artifacts, the interface's and the deploying contract's both, so any change to a name, a type, an
///         order, an indexed flag, an error or the set of functions is a deliberate edit here. A hash taken
///         from the code under test would move with the code; the signatures below are written out instead.
contract OspexGamesInterfaceTest is GamesBase {
    string internal iface;
    string internal impl;

    /// @dev The four terms, in order, wherever they appear.
    string internal constant TERMS_NAMES = "window;day7Clock;day30Clock;fee";
    string internal constant TERMS_TYPES = "uint64;uint64;uint64;uint96";

    function setUp() public override {
        super.setUp();
        iface = _artifact("IOspexGames");
        impl = _artifact("OspexGames");
    }

    /// The contract has exactly these functions: the two writes anyone may send, the timelock's three calls,
    /// the five reads, the other reads and nine constants. So it has no owner, no pause and no setter but the
    /// timelock's three, and nothing else writes a game or the list.
    /// Break: add any external function to OspexGames, such as one that pushes onto a game's reporters.
    function test_theFunctionsAreExactlyThese() public view {
        string[] memory want = vm.split(
            "MAX_CLOCK();MAX_DATE_AHEAD();MAX_HINTS();MAX_HINT_ID_LENGTH();MAX_LEAGUE_LENGTH();MAX_REPORTERS();"
            "MAX_SCORE();MAX_TEAM_LENGTH();START_BOUND();i_timelock();"
            "approveReporter(address,uint8,bytes32);retireReporter(address);"
            "setTerms(string,(uint64,uint64,uint64,uint96));"
            "createGame(string,string,string,uint64,(uint8,string)[]);"
            "report((uint256,uint8,uint64,uint32,uint32,(uint8,uint8,uint32,uint32)[],address));"
            "gameCount();getGameReporters(uint256);getGameScores(uint256);getGameStart(uint256);"
            "getGameStatus(uint256);getGameWindow(uint256);getGameTerms(uint256);isEveryReporterRetired(uint256);"
            "getApprovedReporters();getReporter(address);getTerms(string)",
            ";"
        );
        string[] memory got = vm.parseJsonKeys(impl, "$.methodIdentifiers");
        _assertSameSet(got, want, "function");
        // No payable function, no receive and no fallback: the contract takes no native money.
        assertFalse(vm.keyExistsJson(impl, "$.abi[?(@.type == 'receive')]"), "a receive function");
        assertFalse(vm.keyExistsJson(impl, "$.abi[?(@.type == 'fallback')]"), "a fallback function");
        assertFalse(vm.keyExistsJson(impl, "$.abi[?(@.stateMutability == 'payable')]"), "a payable function");
    }

    /// The contract's errors are exactly these, by name and argument types. A reader or an agent tells one
    /// refusal from another by its selector, the hash of this signature, so pinning the signatures pins the
    /// selectors the tests expect. Read from the compiled artifact and compared with signatures written out
    /// here.
    /// Break: in OspexGames.sol, change `error OspexGames__StartOutOfRange(uint256 gameId, uint64 start);` to
    /// `error OspexGames__StartOutOfRange(uint256 gameId, uint256 start);`.
    function test_theErrorsAreExactlyThese() public view {
        string[] memory want = vm.split(
            "OspexGames__TimelockNotAContract(address);OspexGames__TimelockIsTheDeployer(address);"
            "OspexGames__NotTheTimelock(address);OspexGames__NoReporters();"
            "OspexGames__LengthsDiffer(uint256,uint256,uint256);OspexGames__NoFirstNReporter();"
            "OspexGames__NoKind(address);OspexGames__AlreadyApproved(address);OspexGames__ReporterRetired(address);"
            "OspexGames__ListFull();OspexGames__NoCode(address);OspexGames__Delegated(address);"
            "OspexGames__CodeHashMismatch(address,bytes32,bytes32);OspexGames__NoFixedValues(address);"
            "OspexGames__NotApproved(address);OspexGames__TermsNotValid();"
            "OspexGames__LeagueNotValid();OspexGames__TeamNotValid();"
            "OspexGames__SameTeams();OspexGames__DateNotValid(uint64);OspexGames__TooManyHints(uint256);"
            "OspexGames__HintNotValid(uint256);OspexGames__HintSeatRepeated(uint256);"
            "OspexGames__UnknownGame(uint256);OspexGames__NotAReporter(uint256,address);"
            "OspexGames__ReportKindNotTaken(uint8);OspexGames__FieldNotEmpty(uint8);"
            "OspexGames__SilentReadingNotEmpty(uint256);OspexGames__GameEnded(uint256,uint8);"
            "OspexGames__StartAlreadyWritten(uint256);OspexGames__NotFirstN(uint256,address);"
            "OspexGames__StartOutOfRange(uint256,uint64);OspexGames__StartNotWritten(uint256);"
            "OspexGames__Disputed(uint256);OspexGames__BeforeStart(uint256,uint64);"
            "OspexGames__InsideWindow(uint256,uint256);OspexGames__ScoreOutOfRange(uint32,uint32);"
            "OspexGames__NotScored(uint256,uint8)",
            ";"
        );
        _assertSameSet(_errorSignatures(impl), want, "error");
        // Spot checks that the selector the tests use is the hash of the signature written out.
        assertEq(
            OspexGames.OspexGames__StartOutOfRange.selector,
            bytes4(keccak256("OspexGames__StartOutOfRange(uint256,uint64)"))
        );
        assertEq(OspexGames.OspexGames__GameEnded.selector, bytes4(keccak256("OspexGames__GameEnded(uint256,uint8)")));
        assertEq(
            OspexGames.OspexGames__CodeHashMismatch.selector,
            bytes4(keccak256("OspexGames__CodeHashMismatch(address,bytes32,bytes32)"))
        );
    }

    /// The limits a creator, a reporter and the timelock meet, by value and by type, each written out here.
    /// Break: in OspexGames.sol, change `uint256 public constant MAX_REPORTERS = 8;` to
    /// `uint8 public constant MAX_REPORTERS = 8;`.
    function test_theLimitsAreThese() public view {
        assertEq(games.MAX_SCORE(), 1_000_000);
        assertEq(games.START_BOUND(), 86_400);
        assertEq(games.MAX_DATE_AHEAD(), 31_536_000);
        assertEq(games.MAX_CLOCK(), 31_536_000);
        assertEq(games.MAX_REPORTERS(), 8);
        assertEq(games.MAX_LEAGUE_LENGTH(), 16);
        assertEq(games.MAX_TEAM_LENGTH(), 64);
        assertEq(games.MAX_HINTS(), 8);
        assertEq(games.MAX_HINT_ID_LENGTH(), 64);
        string[9] memory names = [
            "MAX_SCORE",
            "START_BOUND",
            "MAX_DATE_AHEAD",
            "MAX_CLOCK",
            "MAX_REPORTERS",
            "MAX_LEAGUE_LENGTH",
            "MAX_TEAM_LENGTH",
            "MAX_HINTS",
            "MAX_HINT_ID_LENGTH"
        ];
        string[9] memory types =
            ["uint32", "uint64", "uint64", "uint64", "uint256", "uint256", "uint256", "uint256", "uint256"];
        for (uint256 i; i < names.length; ++i) {
            string memory at = string.concat("$.abi[?(@.name == '", names[i], "')]");
            _assertParams(impl, string.concat(at, ".outputs"), "", types[i]);
            assertFalse(vm.keyExistsJson(impl, string.concat(at, ".inputs[0]")), names[i]);
        }
        _assertParams(impl, "$.abi[?(@.name == 'i_timelock')].outputs", "", "address");
    }

    function test_theSelectorsAreThese() public pure {
        assertEq(
            IOspexGames.createGame.selector, bytes4(keccak256("createGame(string,string,string,uint64,(uint8,string)[])"))
        );
        assertEq(IOspexGames.getGameStatus.selector, bytes4(keccak256("getGameStatus(uint256)")));
        assertEq(IOspexGames.getGameStart.selector, bytes4(keccak256("getGameStart(uint256)")));
        assertEq(IGameReporters.getGameReporters.selector, bytes4(keccak256("getGameReporters(uint256)")));
        assertEq(IOspexGames.getGameScores.selector, bytes4(keccak256("getGameScores(uint256)")));
        assertEq(IOspexGames.getGameWindow.selector, bytes4(keccak256("getGameWindow(uint256)")));
        assertEq(IOspexGames.gameCount.selector, bytes4(keccak256("gameCount()")));
        assertEq(IOspexGames.setTerms.selector, bytes4(keccak256("setTerms(string,(uint64,uint64,uint64,uint96))")));
        assertEq(IOspexGames.approveReporter.selector, bytes4(keccak256("approveReporter(address,uint8,bytes32)")));
        assertEq(IOspexGames.retireReporter.selector, bytes4(keccak256("retireReporter(address)")));
        assertEq(IOspexReporter.fixedValues.selector, bytes4(keccak256("fixedValues()")));
    }

    /// Break: in IOspexGames.sol, change GameCreated's `uint64 date,` to `uint256 date,`.
    function test_theEventsAreThese() public view {
        assertEq(
            IOspexGames.GameCreated.selector,
            keccak256(
                "GameCreated(uint256,address,string,string,string,uint64,(uint8,string)[],(uint64,uint64,uint64,uint96),address[],uint8[])"
            )
        );
        assertEq(
            IOspexGames.GameReported.selector,
            keccak256("GameReported(uint256,address,uint8,uint64,uint32,uint32,(uint8,uint8,uint32,uint32)[],address)")
        );
        assertEq(IOspexGames.ReporterApproved.selector, keccak256("ReporterApproved(address,uint8,bytes32,bytes)"));
        assertEq(IOspexGames.ReporterRetired.selector, keccak256("ReporterRetired(address)"));
        assertEq(IOspexGames.TermsSet.selector, keccak256("TermsSet(string,(uint64,uint64,uint64,uint96))"));

        string[2] memory artifacts = [iface, impl];
        for (uint256 a; a < artifacts.length; ++a) {
            string memory json = artifacts[a];
            string memory created = "$.abi[?(@.name == 'GameCreated')].inputs";
            _assertParams(
                json,
                created,
                "gameId;creator;league;homeTeam;awayTeam;date;hints;terms;reporters;kinds",
                "uint256;address;string;string;string;uint64;tuple[];tuple;address[];uint8[]"
            );
            _assertParams(json, string.concat(created, "[6].components"), "seat;id", "uint8;string");
            _assertParams(json, string.concat(created, "[7].components"), TERMS_NAMES, TERMS_TYPES);
            _assertIndexed(json, created, "true;true;false;false;false;false;false;false;false;false");

            string memory reported = "$.abi[?(@.name == 'GameReported')].inputs";
            _assertParams(
                json,
                reported,
                "gameId;reporter;kind;start;homeScore;awayScore;readings;payout",
                "uint256;address;uint8;uint64;uint32;uint32;tuple[];address"
            );
            _assertParams(
                json,
                string.concat(reported, "[6].components"),
                "seat;kind;homeScore;awayScore",
                "uint8;uint8;uint32;uint32"
            );
            _assertIndexed(json, reported, "true;true;true;false;false;false;false;false");
            assertEq(vm.parseJsonString(json, string.concat(reported, "[2].internalType")), "enum ReportKind");

            string memory approved = "$.abi[?(@.name == 'ReporterApproved')].inputs";
            _assertParams(json, approved, "reporter;kind;codeHash;fixedValues", "address;uint8;bytes32;bytes");
            _assertIndexed(json, approved, "true;false;false;false");
            assertEq(vm.parseJsonString(json, string.concat(approved, "[1].internalType")), "enum ReporterKind");

            string memory retired = "$.abi[?(@.name == 'ReporterRetired')].inputs";
            _assertParams(json, retired, "reporter", "address");
            _assertIndexed(json, retired, "true");

            string memory termsSet = "$.abi[?(@.name == 'TermsSet')].inputs";
            _assertParams(json, termsSet, "league;terms", "string;tuple");
            _assertParams(json, string.concat(termsSet, "[1].components"), TERMS_NAMES, TERMS_TYPES);
            _assertIndexed(json, termsSet, "false;false");
        }
    }

    /// Break: in IOspexGames.sol, swap the lines `uint8 seat;` and `string id;` in Hint.
    function test_theCreationIsThis() public view {
        string[2] memory artifacts = [iface, impl];
        for (uint256 a; a < artifacts.length; ++a) {
            string memory inputs = "$.abi[?(@.name == 'createGame')].inputs";
            _assertParams(
                artifacts[a], inputs, "league;homeTeam;awayTeam;date;hints", "string;string;string;uint64;tuple[]"
            );
            _assertParams(artifacts[a], string.concat(inputs, "[4].components"), "seat;id", "uint8;string");
            _assertParams(artifacts[a], "$.abi[?(@.name == 'createGame')].outputs", "gameId", "uint256");
        }
    }

    /// The timelock's three calls, by name and type: the terms in their order, the kind as the enum, the code
    /// hash as 32 bytes.
    /// Break: in IOspexGames.sol, swap the lines `uint64 day7Clock;` and `uint64 day30Clock;` in Terms.
    function test_theTimelocksCallsAreThese() public view {
        string[2] memory artifacts = [iface, impl];
        for (uint256 a; a < artifacts.length; ++a) {
            string memory json = artifacts[a];
            string memory set = "$.abi[?(@.name == 'setTerms')].inputs";
            _assertParams(json, set, "league;terms", "string;tuple");
            _assertParams(json, string.concat(set, "[1].components"), TERMS_NAMES, TERMS_TYPES);
            string memory approve = "$.abi[?(@.name == 'approveReporter')].inputs";
            _assertParams(json, approve, "reporter;kind;codeHash", "address;uint8;bytes32");
            assertEq(vm.parseJsonString(json, string.concat(approve, "[1].internalType")), "enum ReporterKind");
            _assertParams(json, "$.abi[?(@.name == 'retireReporter')].inputs", "reporter", "address");
            string[3] memory calls = ["setTerms", "approveReporter", "retireReporter"];
            for (uint256 c; c < calls.length; ++c) {
                string memory at = string.concat("$.abi[?(@.name == '", calls[c], "')]");
                assertFalse(vm.keyExistsJson(json, string.concat(at, ".outputs[0]")), calls[c]);
            }
        }
        // The one read every reporter has.
        string memory reporter = _artifact("IOspexReporter");
        assertFalse(vm.keyExistsJson(reporter, "$.abi[?(@.name == 'fixedValues')].inputs[0]"), "the read takes nothing");
        _assertParams(reporter, "$.abi[?(@.name == 'fixedValues')].outputs", "values", "bytes");
        assertEq(vm.parseJsonString(reporter, "$.abi[?(@.name == 'fixedValues')].stateMutability"), "view");
    }

    /// Each read's answer, by name and type: the scores home then away, the reporters with their kinds, the
    /// terms in their order.
    /// Break: in OspexGames.sol, change getGameScores's `returns (uint32 homeScore, uint32 awayScore)` to
    /// `returns (uint32 awayScore, uint32 homeScore)`. The values still come back home first, under each
    /// other's names, for anyone who decodes the contract's own ABI by name.
    function test_theReadsAnswerThese() public view {
        string[2] memory artifacts = [iface, impl];
        for (uint256 a; a < artifacts.length; ++a) {
            string memory json = artifacts[a];
            _assertParams(json, "$.abi[?(@.name == 'getGameScores')].outputs", "homeScore;awayScore", "uint32;uint32");
            _assertParams(
                json, "$.abi[?(@.name == 'getGameReporters')].outputs", "reporters;kinds", "address[];uint8[]"
            );
            _assertParams(json, "$.abi[?(@.name == 'getGameStart')].outputs", "", "uint64");
            _assertParams(json, "$.abi[?(@.name == 'getGameWindow')].outputs", "", "uint64");
            _assertParams(json, "$.abi[?(@.name == 'getGameStatus')].outputs", "", "uint8");
            _assertParams(json, "$.abi[?(@.name == 'gameCount')].outputs", "", "uint256");
            assertEq(
                vm.parseJsonString(json, "$.abi[?(@.name == 'getGameStatus')].outputs[0].internalType"),
                "enum GameStatus"
            );
            _assertParams(json, "$.abi[?(@.name == 'getGameTerms')].outputs", "", "tuple");
            _assertParams(json, "$.abi[?(@.name == 'getGameTerms')].outputs[0].components", TERMS_NAMES, TERMS_TYPES);
            _assertParams(json, "$.abi[?(@.name == 'getTerms')].inputs", "league", "string");
            _assertParams(json, "$.abi[?(@.name == 'getTerms')].outputs", "", "tuple");
            _assertParams(json, "$.abi[?(@.name == 'getTerms')].outputs[0].components", TERMS_NAMES, TERMS_TYPES);
            _assertParams(json, "$.abi[?(@.name == 'isEveryReporterRetired')].outputs", "", "bool");
            _assertParams(
                json, "$.abi[?(@.name == 'getApprovedReporters')].outputs", "reporters;kinds", "address[];uint8[]"
            );
            _assertParams(json, "$.abi[?(@.name == 'getReporter')].inputs", "reporter", "address");
            _assertParams(json, "$.abi[?(@.name == 'getReporter')].outputs", "kind;retired", "uint8;bool");
            assertEq(
                vm.parseJsonString(json, "$.abi[?(@.name == 'getReporter')].outputs[0].internalType"),
                "enum ReporterKind"
            );
        }
    }

    // ──────────────────────────── Helpers ──────────────────────────────

    function _assertIndexed(string memory json, string memory path, string memory flags) internal view {
        string[] memory f = vm.split(flags, ";");
        for (uint256 i; i < f.length; ++i) {
            string memory at = string.concat(path, "[", vm.toString(i), "].indexed");
            assertEq(vm.parseJsonBool(json, at), keccak256(bytes(f[i])) == keccak256("true"), at);
        }
        assertFalse(
            vm.keyExistsJson(json, string.concat(path, "[", vm.toString(f.length), "]")),
            string.concat(path, " has a parameter past the last flag")
        );
    }

    /// @dev Every error in an artifact's ABI as its canonical signature, read entry by entry.
    function _errorSignatures(string memory json) internal view returns (string[] memory out) {
        string[] memory found = new string[](128);
        uint256 n;
        for (uint256 i; vm.keyExistsJson(json, string.concat("$.abi[", vm.toString(i), "]")); ++i) {
            string memory entry = string.concat("$.abi[", vm.toString(i), "]");
            if (keccak256(bytes(vm.parseJsonString(json, string.concat(entry, ".type")))) != keccak256("error")) {
                continue;
            }
            string memory sig = string.concat(vm.parseJsonString(json, string.concat(entry, ".name")), "(");
            for (uint256 j; vm.keyExistsJson(json, string.concat(entry, ".inputs[", vm.toString(j), "]")); ++j) {
                string memory t =
                    vm.parseJsonString(json, string.concat(entry, ".inputs[", vm.toString(j), "].type"));
                sig = string.concat(sig, j == 0 ? "" : ",", t);
            }
            found[n++] = string.concat(sig, ")");
        }
        out = new string[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = found[i];
        }
    }

    /// @dev The two lists hold the same strings, each once.
    function _assertSameSet(string[] memory got, string[] memory want, string memory what) internal pure {
        assertEq(got.length, want.length, string.concat("the number of ", what, "s moved"));
        for (uint256 i; i < want.length; ++i) {
            uint256 seen;
            for (uint256 j; j < got.length; ++j) {
                if (keccak256(bytes(got[j])) == keccak256(bytes(want[i]))) ++seen;
            }
            assertEq(seen, 1, string.concat("not exactly once: ", want[i]));
        }
    }
}
