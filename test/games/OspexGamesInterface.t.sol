// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {OspexGames} from "../../src/games/OspexGames.sol";
import {IOspexGames} from "../../src/games/IOspexGames.sol";
import {IGameReporters} from "../../src/signpost/IGameReporters.sol";
import {GamesBase} from "./GamesBase.sol";

/// @notice The games contract's interface freezes at deploy: every reporter, the betting set, the indexer and
///         the signpost are built against it. These tests pin it from literal text and from the compiled
///         artifact, so any change to a name, a type, an order, an indexed flag or the set of functions is a
///         deliberate edit here. A hash taken from the code under test would move with the code; the
///         signatures below are written out instead.
contract OspexGamesInterfaceTest is GamesBase {
    string internal iface;
    string internal impl;

    function setUp() public override {
        super.setUp();
        iface = _artifact("IOspexGames");
        impl = _artifact("OspexGames");
    }

    /// The contract has exactly these functions: the two writes, the five reads, the count and five
    /// constants. So it has no owner, no setter and no pause, and nothing else writes a game.
    /// Break: add any external function to OspexGames, such as one that pushes onto a game's reporters.
    function test_theFunctionsAreExactlyThese() public view {
        string[] memory want = vm.split(
            "MAX_HINTS();MAX_HINT_ID_LENGTH();MAX_LEAGUE_LENGTH();MAX_SCORE();MAX_TEAM_LENGTH();"
            "createGame(string,string,string,uint64,(uint8,string)[]);gameCount();getGameReporters(uint256);"
            "getGameScores(uint256);getGameStart(uint256);getGameStatus(uint256);getGameWindow(uint256);"
            "report((uint256,uint8,uint64,uint32,uint32,(uint8,uint8,uint32,uint32)[],address))",
            ";"
        );
        string[] memory got = vm.parseJsonKeys(impl, "$.methodIdentifiers");
        assertEq(got.length, want.length, "the number of functions moved");
        for (uint256 i; i < want.length; ++i) {
            bool found;
            for (uint256 j; j < got.length; ++j) {
                if (keccak256(bytes(got[j])) == keccak256(bytes(want[i]))) found = true;
            }
            assertTrue(found, string.concat("missing: ", want[i]));
        }
        // No payable function, no receive and no fallback: the contract takes no native money.
        assertFalse(vm.keyExistsJson(impl, "$.abi[?(@.type == 'receive')]"), "a receive function");
        assertFalse(vm.keyExistsJson(impl, "$.abi[?(@.type == 'fallback')]"), "a fallback function");
        assertFalse(vm.keyExistsJson(impl, "$.abi[?(@.stateMutability == 'payable')]"), "a payable function");
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
    }

    /// Break: in IOspexGames.sol, change GameCreated's `uint64 date,` to `uint256 date,`.
    function test_theEventsAreThese() public view {
        assertEq(
            IOspexGames.GameCreated.selector,
            keccak256("GameCreated(uint256,address,string,string,string,uint64,(uint8,string)[],uint64,address[],uint8[])")
        );
        assertEq(
            IOspexGames.GameReported.selector,
            keccak256("GameReported(uint256,address,uint8,uint64,uint32,uint32,(uint8,uint8,uint32,uint32)[],address)")
        );

        string memory created = "$.abi[?(@.name == 'GameCreated')].inputs";
        _assertParams(
            iface,
            created,
            "gameId;creator;league;homeTeam;awayTeam;date;hints;window;reporters;kinds",
            "uint256;address;string;string;string;uint64;tuple[];uint64;address[];uint8[]"
        );
        _assertParams(iface, string.concat(created, "[6].components"), "seat;id", "uint8;string");
        _assertIndexed(created, "true;true;false;false;false;false;false;false;false;false");

        string memory reported = "$.abi[?(@.name == 'GameReported')].inputs";
        _assertParams(
            iface,
            reported,
            "gameId;reporter;kind;start;homeScore;awayScore;readings;payout",
            "uint256;address;uint8;uint64;uint32;uint32;tuple[];address"
        );
        _assertParams(
            iface, string.concat(reported, "[6].components"), "seat;kind;homeScore;awayScore", "uint8;uint8;uint32;uint32"
        );
        _assertIndexed(reported, "true;true;true;false;false;false;false;false");
        assertEq(vm.parseJsonString(iface, string.concat(reported, "[2].internalType")), "enum ReportKind");
    }

    /// Break: in IOspexGames.sol, swap the lines `uint8 seat;` and `string id;` in Hint.
    function test_theCreationIsThis() public view {
        string memory inputs = "$.abi[?(@.name == 'createGame')].inputs";
        _assertParams(
            iface, inputs, "league;homeTeam;awayTeam;date;hints", "string;string;string;uint64;tuple[]"
        );
        _assertParams(iface, string.concat(inputs, "[4].components"), "seat;id", "uint8;string");
        _assertParams(iface, "$.abi[?(@.name == 'createGame')].outputs", "gameId", "uint256");
    }

    /// Each read's answer, by name and type: the scores home then away, the reporters with their kinds.
    function test_theReadsAnswerThese() public view {
        _assertParams(iface, "$.abi[?(@.name == 'getGameScores')].outputs", "homeScore;awayScore", "uint32;uint32");
        _assertParams(iface, "$.abi[?(@.name == 'getGameReporters')].outputs", "reporters;kinds", "address[];uint8[]");
        _assertParams(iface, "$.abi[?(@.name == 'getGameStart')].outputs", "", "uint64");
        _assertParams(iface, "$.abi[?(@.name == 'getGameWindow')].outputs", "", "uint64");
        _assertParams(iface, "$.abi[?(@.name == 'getGameStatus')].outputs", "", "uint8");
        assertEq(
            vm.parseJsonString(iface, "$.abi[?(@.name == 'getGameStatus')].outputs[0].internalType"), "enum GameStatus"
        );
    }

    function _assertIndexed(string memory path, string memory flags) internal view {
        string[] memory f = vm.split(flags, ";");
        for (uint256 i; i < f.length; ++i) {
            string memory at = string.concat(path, "[", vm.toString(i), "].indexed");
            assertEq(vm.parseJsonBool(iface, at), keccak256(bytes(f[i])) == keccak256("true"), at);
        }
    }
}
