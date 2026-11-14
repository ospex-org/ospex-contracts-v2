// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GameStatus, IOspexGames, ReporterKind} from "../../src/games/IOspexGames.sol";
import {OspexBetting} from "../../src/betting/OspexBetting.sol";
import {OspexMarkets} from "../../src/betting/OspexMarkets.sol";
import {OspexPositions} from "../../src/betting/OspexPositions.sol";
import {OspexMatching} from "../../src/betting/OspexMatching.sol";
import {OspexMoneylineScorer} from "../../src/betting/OspexMoneylineScorer.sol";
import {OspexSpreadScorer} from "../../src/betting/OspexSpreadScorer.sol";
import {OspexTotalScorer} from "../../src/betting/OspexTotalScorer.sol";
import {Market, MarketStatus, Outcome, Position, Side} from "../../src/betting/OspexBettingTypes.sol";
import {RefusingCoin} from "../games/CoinFixtures.sol";
import {Deploy, GamesBase, MockReporter, OspexGamesHarness} from "../games/GamesBase.sol";

/// @dev A stand-in for a module: it answers the core's four reads as it was told at its deploy, or as it was last
///      told to answer. It is no module of the repository. The core's checks are tested against it one answer at a
///      time; with every answer right it registers, which is the limit of a check that reads answers and not code.
contract StandInModule {
    bytes32 public getModuleType;
    address public i_ospexCore;
    address public i_games;
    address public i_token;

    constructor(bytes32 moduleType, address core, address games, address token) {
        getModuleType = moduleType;
        i_ospexCore = core;
        i_games = games;
        i_token = token;
    }

    /// @dev Changes the three answers, as a contract whose answers are not fixed can at any time.
    function answer(address core, address games, address token) external {
        i_ospexCore = core;
        i_games = games;
        i_token = token;
    }
}

/// @dev A contract that answers a type and none of the three wiring reads: it has no such functions.
contract TypeOnlyModule {
    bytes32 public immutable getModuleType;

    constructor(bytes32 moduleType) {
        getModuleType = moduleType;
    }
}

/// @dev A stand-in whose every answer is right, and which writes to its own storage inside one of them: the
///      read numbered `writesIn`, 0 for the type, 1 for the games set, 2 for the coin, 3 for the core, and 4 for
///      none. None of its four functions is declared a read.
contract WritingModule {
    bytes32 internal immutable i_type;
    address internal immutable i_coreAnswer;
    address internal immutable i_gamesAnswer;
    address internal immutable i_tokenAnswer;
    uint256 internal immutable i_writesIn;
    uint256 public s_writes;

    constructor(bytes32 moduleType, address core, address games, address token, uint256 writesIn) {
        i_type = moduleType;
        i_coreAnswer = core;
        i_gamesAnswer = games;
        i_tokenAnswer = token;
        i_writesIn = writesIn;
    }

    function getModuleType() external returns (bytes32) {
        if (i_writesIn == 0) ++s_writes;
        return i_type;
    }

    function i_games() external returns (address) {
        if (i_writesIn == 1) ++s_writes;
        return i_gamesAnswer;
    }

    function i_token() external returns (address) {
        if (i_writesIn == 2) ++s_writes;
        return i_tokenAnswer;
    }

    function i_ospexCore() external returns (address) {
        if (i_writesIn == 3) ++s_writes;
        return i_coreAnswer;
    }
}

/// @dev A stand-in whose every answer is right but one, which it does not give: the read numbered `silentIn`, 0
///      for the type, 1 for the games set, 2 for the coin, 3 for the core, and 4 for none, reverts with no data,
///      as a call to a function the contract does not have would.
contract SilentModule {
    bytes32 internal immutable i_type;
    address internal immutable i_coreAnswer;
    address internal immutable i_gamesAnswer;
    address internal immutable i_tokenAnswer;
    uint256 internal immutable i_silentIn;

    constructor(bytes32 moduleType, address core, address games, address token, uint256 silentIn) {
        i_type = moduleType;
        i_coreAnswer = core;
        i_gamesAnswer = games;
        i_tokenAnswer = token;
        i_silentIn = silentIn;
    }

    function getModuleType() external view returns (bytes32) {
        if (i_silentIn == 0) revert();
        return i_type;
    }

    function i_games() external view returns (address) {
        if (i_silentIn == 1) revert();
        return i_gamesAnswer;
    }

    function i_token() external view returns (address) {
        if (i_silentIn == 2) revert();
        return i_tokenAnswer;
    }

    function i_ospexCore() external view returns (address) {
        if (i_silentIn == 3) revert();
        return i_coreAnswer;
    }
}

/// @dev A stand-in that answers right only while the core holds nothing of it. Once the core's registry holds an
///      address under its type, or holds its address as a module, each of its three wiring answers is the zero
///      address: a core that wrote an address before it read it would be answered wrong, and would refuse it.
contract ObservingModule {
    bytes32 public immutable getModuleType;
    OspexBetting internal immutable i_core;
    address internal immutable i_gamesAnswer;
    address internal immutable i_tokenAnswer;

    constructor(bytes32 moduleType, OspexBetting core, address games, address token) {
        getModuleType = moduleType;
        i_core = core;
        i_gamesAnswer = games;
        i_tokenAnswer = token;
    }

    /// @dev Whether the core holds nothing of this contract: no address under its type, and not its address.
    function unwritten() public view returns (bool) {
        return i_core.getModule(getModuleType) == address(0) && !i_core.isRegisteredModule(address(this));
    }

    function i_ospexCore() external view returns (address) {
        return unwritten() ? address(i_core) : address(0);
    }

    function i_games() external view returns (address) {
        return unwritten() ? i_gamesAnswer : address(0);
    }

    function i_token() external view returns (address) {
        return unwritten() ? i_tokenAnswer : address(0);
    }
}

/// @dev Shared setup: the games test base, with its games contract, reporters, coin and timelock, and the
///      betting set deployed beside it, bootstrapped and finalized by the deployer; two funded accounts that
///      are keys, so they sign; and helpers that score a game through the production report path, sign orders
///      and put positions into a market through the Cross. Every contract of the set here is the production
///      contract: there is no test-only hook.
abstract contract BettingBase is GamesBase {
    /// @dev A stake in a test that is not about the amount: 10 USDC in six decimals.
    uint256 internal constant STAKE = 10_000_000;

    /// @dev The signed order's type, written out: ten fields, the first named `account`, the last `minFill`. The
    ///      digests the tests sign are built from this string and the two domain strings below, never from the
    ///      contract's reads.
    string internal constant ORDER_TYPE =
        "OspexOrder(address account,uint256 gameId,address scorer,int32 lineTicks,uint8 positionType,uint16 oddsTick,uint256 riskAmount,uint256 nonce,uint256 expiry,uint256 minFill)";
    string internal constant DOMAIN_NAME = "Ospex";
    string internal constant DOMAIN_VERSION = "3";
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    OspexBetting internal core;
    OspexMarkets internal markets;
    OspexPositions internal positions;
    OspexMatching internal matching;
    OspexMoneylineScorer internal moneyline;
    OspexSpreadScorer internal spread;
    OspexTotalScorer internal total;

    /// @dev The two accounts of most tests, each a key. In a fill made by _fill, the maker's order rests and the
    ///      taker's takes.
    address internal maker;
    uint256 internal makerKey;
    address internal taker;
    uint256 internal takerKey;
    /// @dev The address that sends the Crosses of _fill. The maker and the taker register it at their first
    ///      fill, each from its own address, and not before: a test that makes no fill starts with no courier
    ///      registered by anyone.
    address internal fillCourier = makeAddr("fillCourier");
    /// @dev The transaction origin of every Cross the helpers send: an address that is no account, no courier
    ///      and no contract of the set, so a line that read tx.origin where it should read msg.sender would
    ///      find nobody.
    address internal crossOrigin = makeAddr("crossOrigin");
    /// @dev The nonce of the next order _fill signs, so two fills of the same amounts are two orders.
    uint256 internal fillNonce = 1;
    /// @dev Whether the maker and the taker have registered fillCourier.
    bool internal fillCourierRegistered;
    /// @dev Whether _deploySetOn lifts the cap on a taking order's signed stake once the set is finalized, the
    ///      way it is lifted live: K schedules the lift on the stock timelock, the delay passes, a stranger runs
    ///      it. True by default, since the fills of most tests are above a cent; a test of the cap sets it false
    ///      before setUp, so its set starts with the cap in force.
    bool internal liftAtDeploy = true;

    constructor() {
        (maker, makerKey) = makeAddrAndKey("maker");
        (taker, takerKey) = makeAddrAndKey("taker");
    }

    /// @dev A second games set with its own first-n reporter, and a second coin: what a module must not be
    ///      wired to. Deployed by _deployOtherCores, for the tests that need them, and not by setUp.
    OspexGamesHarness internal games2;
    MockReporter internal first2;
    RefusingCoin internal token2;
    /// @dev Three cores that are not `core`. The first names this core's games set and coin, and differs from
    ///      it in its address alone; the second names the second games set; the third the second coin.
    OspexBetting internal coreOfSameValues;
    OspexBetting internal coreOfGames2;
    OspexBetting internal coreOfToken2;

    function setUp() public virtual override {
        super.setUp();
        _deploySet();
        _fund(maker, address(positions));
        _fund(taker, address(positions));
    }

    /// @dev The set as deploy day will make it: the core with the games set and the coin, the six modules on
    ///      the core, bootstrapped under their types, finalized.
    function _deploySet() internal {
        _deploySetOn(address(token));
    }

    /// @dev The same set on a coin of the test's choosing. It replaces the set the helpers act on.
    function _deploySetOn(address coin) internal {
        _deploySetWith(address(games), coin);
        if (liftAtDeploy) _liftTheCap();
    }

    /// @dev The set on a games set and a coin of the test's choosing, with the cap as deployed: in force.
    function _deploySetWith(address gamesSet, address coin) internal {
        vm.startPrank(deployer, deployer);
        core = new OspexBetting(gamesSet, coin);
        markets = new OspexMarkets(address(core));
        positions = new OspexPositions(address(core));
        matching = new OspexMatching(address(core));
        moneyline = new OspexMoneylineScorer(address(core));
        spread = new OspexSpreadScorer(address(core));
        total = new OspexTotalScorer(address(core));
        core.bootstrapModules(_types(), _modules());
        core.finalize();
        vm.stopPrank();
    }

    /// @dev Lifts the cap on the set's matching module the way it is lifted live, through the stock timelock
    ///      the games base deploys: never a storage write.
    function _liftTheCap() internal {
        _throughTimelockTo(address(matching), abi.encodeCall(OspexMatching.liftTakingStakeCap, ()));
        assertTrue(matching.s_takingStakeCapLifted(), "the cap was not lifted");
    }

    /// @dev The six module types, in the order the core's finalize names them.
    function _types() internal view returns (bytes32[] memory t) {
        t = new bytes32[](6);
        t[0] = core.MARKET_MODULE();
        t[1] = core.POSITION_MODULE();
        t[2] = core.MATCHING_MODULE();
        t[3] = core.MONEYLINE_SCORER_MODULE();
        t[4] = core.SPREAD_SCORER_MODULE();
        t[5] = core.TOTAL_SCORER_MODULE();
    }

    /// @dev The six modules, in the same order.
    function _modules() internal view returns (address[] memory a) {
        a = new address[](6);
        a[0] = address(markets);
        a[1] = address(positions);
        a[2] = address(matching);
        a[3] = address(moneyline);
        a[4] = address(spread);
        a[5] = address(total);
    }

    // ──────────────────────────── Other sets ───────────────────────────

    /// @dev Six fresh modules on `c`, built from src/, with their types, in the core's order.
    function _freshSet(OspexBetting c) internal returns (bytes32[] memory types, address[] memory addrs) {
        types = new bytes32[](6);
        addrs = new address[](6);
        types[0] = c.MARKET_MODULE();
        addrs[0] = address(new OspexMarkets(address(c)));
        types[1] = c.POSITION_MODULE();
        addrs[1] = address(new OspexPositions(address(c)));
        types[2] = c.MATCHING_MODULE();
        addrs[2] = address(new OspexMatching(address(c)));
        types[3] = c.MONEYLINE_SCORER_MODULE();
        addrs[3] = address(new OspexMoneylineScorer(address(c)));
        types[4] = c.SPREAD_SCORER_MODULE();
        addrs[4] = address(new OspexSpreadScorer(address(c)));
        types[5] = c.TOTAL_SCORER_MODULE();
        addrs[5] = address(new OspexTotalScorer(address(c)));
    }

    /// @dev The second games set, the second coin and the three other cores. The second games set has the
    ///      first's timelock, fee coin and launch terms and one reporter of its own, and the creator can pay
    ///      its fee.
    function _deployOtherCores() internal {
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        vm.startPrank(deployer, deployer);
        first2 = new MockReporter(IOspexGames(predicted));
        address[] memory reporters = new address[](1);
        reporters[0] = address(first2);
        ReporterKind[] memory kinds = new ReporterKind[](1);
        kinds[0] = ReporterKind.FirstN;
        games2 = new OspexGamesHarness(
            Deploy({
                timelock: address(timelock),
                token: token,
                defaultTerms: _launchTerms(),
                reporters: reporters,
                kinds: kinds,
                codeHashes: _hashes(reporters)
            })
        );
        token2 = new RefusingCoin();
        coreOfSameValues = new OspexBetting(address(games), address(token));
        coreOfGames2 = new OspexBetting(address(games2), address(token));
        coreOfToken2 = new OspexBetting(address(games), address(token2));
        vm.stopPrank();
        assertEq(address(games2), predicted, "the second games set's address as predicted");
        assertTrue(address(games2) != address(games), "the second games set is the first");
        assertTrue(address(token2) != address(token), "the second coin is the first");
        _fund(creator, address(games2));
    }

    /// @dev A game on the second games set with its start written at START by that set's reporter. It takes
    ///      the next number there.
    function _verifiedGameOnGames2() internal returns (uint256 game) {
        uint256 fee = games2.getTerms("nba").fee;
        vm.prank(creator, creator);
        game = games2.createGame("nba", "Denver Nuggets", "Utah Jazz", DATE, _hints(), fee);
        first2.send(_startReport(game, START));
    }

    /// @dev Scores `game` on the second games set `home`-`away`, at the clock as it stands.
    function _scoreOnGames2(uint256 game, uint32 home, uint32 away) internal {
        first2.send(_scoreReport(game, home, away));
    }

    // ──────────────────────────── Games ────────────────────────────────

    /// @dev A game scored `home`-`away` through the production path: created, its start written at START by the
    ///      first-n reporter, and scored one second after the start by the same reporter over three agreeing
    ///      finals. The clock is left at START + 1.
    function _scoredGame(uint32 home, uint32 away) internal returns (uint256 game) {
        game = _create();
        _startBy(first, game, START);
        vm.warp(START + 1);
        _scoreBy(first, game, home, away);
    }

    /// @dev A game with its start written and nothing more: open to positions, not ended.
    function _verifiedGame() internal returns (uint256 game) {
        game = _create();
        _startBy(first, game, START);
    }

    /// @dev Scores `game` `home`-`away` through the production path, one second after START.
    function _score(uint256 game, uint32 home, uint32 away) internal {
        vm.warp(START + 1);
        _scoreBy(first, game, home, away);
    }

    // ──────────────────────────── Orders ───────────────────────────────

    /// @dev An order, field by field, asking for no minimum fill.
    function _order(
        address account,
        uint256 game,
        address scorer,
        int32 line,
        Side side,
        uint16 tick,
        uint256 risk,
        uint256 nonce,
        uint256 expiry
    ) internal pure returns (OspexMatching.OspexOrder memory o) {
        o = _order(account, game, scorer, line, side, tick, risk, nonce, expiry, 0);
    }

    /// @dev An order, field by field, its minimum fill included.
    function _order(
        address account,
        uint256 game,
        address scorer,
        int32 line,
        Side side,
        uint16 tick,
        uint256 risk,
        uint256 nonce,
        uint256 expiry,
        uint256 minFill
    ) internal pure returns (OspexMatching.OspexOrder memory o) {
        o = OspexMatching.OspexOrder({
            account: account,
            gameId: game,
            scorer: scorer,
            lineTicks: line,
            positionType: side,
            oddsTick: tick,
            riskAmount: risk,
            nonce: nonce,
            expiry: expiry,
            minFill: minFill
        });
    }

    /// @dev A price in ticks, as an order carries it. Refuses a number an order's price field does not hold.
    function _tick(uint256 tick) internal pure returns (uint16) {
        require(tick <= type(uint16).max, "not a price in ticks");
        // casting to 'uint16' is safe because the line above refuses anything wider
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(tick);
    }

    /// @dev A grant's end, as its field holds it. Refuses a time the field does not hold.
    function _ends(uint256 time) internal pure returns (uint64) {
        require(time <= type(uint64).max, "not a time in seconds");
        // casting to 'uint64' is safe because the line above refuses anything wider
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(time);
    }

    /// @dev An empty list of lines: a grant on every market.
    function _noLines() internal pure returns (OspexMatching.Line[] memory) {
        return new OspexMatching.Line[](0);
    }

    /// @dev The EIP-712 domain separator of a matching module at `verifying`, from the two strings written out.
    function _domainSeparator(address verifying) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes(DOMAIN_NAME)),
                keccak256(bytes(DOMAIN_VERSION)),
                block.chainid,
                verifying
            )
        );
    }

    /// @dev The struct hash of an order under a type string.
    function _structHash(OspexMatching.OspexOrder memory o, string memory orderType) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(bytes(orderType)),
                o.account,
                o.gameId,
                o.scorer,
                o.lineTicks,
                uint8(o.positionType),
                o.oddsTick,
                o.riskAmount,
                o.nonce,
                o.expiry,
                o.minFill
            )
        );
    }

    /// @dev The hash an account signs for an order on the set's matching module, built here from first
    ///      principles: the domain over the struct hash.
    function _digest(OspexMatching.OspexOrder memory o) internal view returns (bytes32) {
        return _digestOn(address(matching), o);
    }

    /// @dev The same, for a matching module at another address.
    function _digestOn(address verifying, OspexMatching.OspexOrder memory o) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", _domainSeparator(verifying), _structHash(o, ORDER_TYPE)));
    }

    /// @dev A 65-byte signature by `key` over `digest`: r, s, v.
    function _signature(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev An order signed by `key` for the set's matching module.
    function _signed(OspexMatching.OspexOrder memory o, uint256 key)
        internal
        view
        returns (OspexMatching.SignedOrder memory)
    {
        return OspexMatching.SignedOrder({order: o, signature: _signature(key, _digest(o))});
    }

    /// @dev A list of one order.
    function _list(OspexMatching.SignedOrder memory a) internal pure returns (OspexMatching.SignedOrder[] memory l) {
        l = new OspexMatching.SignedOrder[](1);
        l[0] = a;
    }

    /// @dev The other side.
    function _other(Side side) internal pure returns (Side) {
        return side == Side.A ? Side.B : Side.A;
    }

    // ──────────────────────────── The Cross ────────────────────────────

    /// @dev `who` registers `to` as its courier, unless it has.
    function _register(address who, address to) internal {
        if (matching.isCourier(who, to)) return;
        vm.prank(who);
        matching.registerCourier(to);
    }

    /// @dev `sender` sends a Cross, with the result. The sender is the immediate caller, and the transaction's
    ///      origin is another address.
    function _tryCross(
        address sender,
        OspexMatching.SignedOrder memory taking,
        OspexMatching.SignedOrder[] memory resting
    ) internal returns (bool ok, bytes memory err) {
        return _tryCrossAs(sender, crossOrigin, taking, resting);
    }

    /// @dev The same, with the transaction's origin named.
    function _tryCrossAs(
        address sender,
        address origin,
        OspexMatching.SignedOrder memory taking,
        OspexMatching.SignedOrder[] memory resting
    ) internal returns (bool ok, bytes memory err) {
        vm.prank(sender, origin);
        (ok, err) = address(matching).call(abi.encodeCall(OspexMatching.cross, (taking, resting)));
    }

    /// @dev A Cross that must fill. It returns nothing: the events are its record.
    function _cross(address sender, OspexMatching.SignedOrder memory taking, OspexMatching.SignedOrder[] memory resting)
        internal
    {
        (bool ok, bytes memory err) = _tryCross(sender, taking, resting);
        assertTrue(ok, string.concat("the Cross was refused: ", vm.toString(err)));
        assertEq(err.length, 0, "the Cross returned a value");
    }

    // ──────────────────────────── Fills ────────────────────────────────

    /// @dev A fill through the Cross: the maker's order rests on `makerSide` for `makerRisk`, at the price that
    ///      makes the taker's stake `takerRisk`; the taker's order takes on the other side for `takerRisk`, at
    ///      the shortest price, which every resting price meets; fillCourier sends it. The two amounts must be
    ///      a fill an order can express: a resting stake in whole lots, and a taking stake that is the resting
    ///      stake times a price in ticks. Draws the market at the first fill on its three fields.
    function _fill(uint256 game, address scorer, int32 line, Side makerSide, uint256 makerRisk, uint256 takerRisk)
        internal
        returns (uint256 marketId)
    {
        (bool ok, bytes memory err) = _tryFill(game, scorer, line, makerSide, makerRisk, takerRisk);
        assertTrue(ok, string.concat("the fill was refused: ", vm.toString(err)));
        marketId = markets.getMarketId(game, scorer, line);
    }

    /// @dev The same fill, with its result: for refusals whose name a test checks. A refusal of the positions
    ///      module or the markets module comes back as that module raised it.
    function _tryFill(uint256 game, address scorer, int32 line, Side makerSide, uint256 makerRisk, uint256 takerRisk)
        internal
        returns (bool ok, bytes memory err)
    {
        require(makerRisk != 0 && makerRisk % 100 == 0 && takerRisk % 100 == 0, "not a fill an order can express");
        require((takerRisk * 100) % makerRisk == 0, "not a fill at a price in ticks");
        uint256 p = takerRisk * 100 / makerRisk;
        require(p >= 1 && p <= 10_000, "not a fill at an admissible price");
        _readyToFill();
        OspexMatching.SignedOrder memory resting = _signed(
            _order(
                maker,
                game,
                scorer,
                line,
                makerSide,
                _tick(100 + p),
                makerRisk,
                fillNonce++,
                vm.getBlockTimestamp() + 1 days
            ),
            makerKey
        );
        OspexMatching.SignedOrder memory taking = _signed(
            _order(
                taker, game, scorer, line, _other(makerSide), 101, takerRisk, fillNonce++, vm.getBlockTimestamp() + 30
            ),
            takerKey
        );
        (ok, err) = _tryCross(fillCourier, taking, _list(resting));
    }

    /// @dev The maker and the taker register fillCourier, once. A fill does it for itself; a test that watches
    ///      the events of its first fill calls this before it starts to watch.
    function _readyToFill() internal {
        if (fillCourierRegistered) return;
        _register(maker, fillCourier);
        _register(taker, fillCourier);
        fillCourierRegistered = true;
    }

    /// @dev A market on `game`, `scorer` and `line`, with the maker on side A and the taker on side B, each
    ///      risking STAKE: a fill at 2.00.
    function _market(uint256 game, address scorer, int32 line) internal returns (uint256 marketId) {
        marketId = _fill(game, scorer, line, Side.A, STAKE, STAKE);
    }

    /// @dev A fill sent to the positions module as the matching module sends one, with its result: for the
    ///      fills no order can express, a zero stake and two stakes at no price in ticks, which the Cross
    ///      never sends. It is the production entry point, called from the one address it takes a fill from,
    ///      and, as the Cross does after its walk, it is followed by the end call from the same address, which
    ///      pulls the taker and pays back whatever the leg left held above either account's worst loss. A
    ///      refusal of either call is the result; a refused fill makes no end call.
    function _tryRawFill(uint256 game, address scorer, int32 line, Side makerSide, uint256 makerRisk, uint256 takerRisk)
        internal
        returns (bool ok, bytes memory err)
    {
        vm.prank(address(matching));
        (ok, err) = address(positions)
            .call(
                abi.encodeCall(
                    OspexPositions.recordFill, (game, scorer, line, makerSide, maker, makerRisk, taker, takerRisk)
                )
            );
        if (!ok) return (ok, err);
        address[] memory makers = new address[](1);
        makers[0] = maker;
        vm.prank(address(matching));
        (ok, err) = address(positions)
            .call(abi.encodeCall(OspexPositions.finishFills, (abi.decode(err, (uint256)), taker, makers)));
    }

    /// @dev The same, for a fill that must be taken.
    function _rawFill(uint256 game, address scorer, int32 line, Side makerSide, uint256 makerRisk, uint256 takerRisk)
        internal
        returns (uint256 marketId)
    {
        (bool ok, bytes memory err) = _tryRawFill(game, scorer, line, makerSide, makerRisk, takerRisk);
        assertTrue(ok, string.concat("the fill was refused: ", vm.toString(err)));
        marketId = markets.getMarketId(game, scorer, line);
    }

    // ──────────────────────────── Settlement and claims ────────────────

    /// @dev Settles a market, with the result: for refusals whose name a test checks.
    function _trySettle(uint256 marketId) internal returns (bool ok, bytes memory err) {
        (ok, err) = address(markets).call(abi.encodeCall(OspexMarkets.settleMarket, (marketId)));
    }

    /// @dev Settles a market that must settle.
    function _settle(uint256 marketId) internal {
        (bool ok, bytes memory err) = _trySettle(marketId);
        assertTrue(ok, string.concat("settlement refused: ", vm.toString(err)));
    }

    /// @dev `who` claims its position on `side`, with the result.
    function _tryClaim(address who, uint256 marketId, Side side) internal returns (bool ok, bytes memory err) {
        vm.prank(who, who);
        (ok, err) = address(positions).call(abi.encodeCall(OspexPositions.claimPosition, (marketId, side)));
    }

    /// @dev `who` claims a position that must pay, and the coin it was paid, in the set's coin.
    function _claim(address who, uint256 marketId, Side side) internal returns (uint256 paid) {
        IERC20 coin = positions.i_token();
        uint256 before = coin.balanceOf(who);
        (bool ok, bytes memory err) = _tryClaim(who, marketId, side);
        assertTrue(ok, string.concat("claim refused: ", vm.toString(err)));
        paid = coin.balanceOf(who) - before;
    }

    /// @dev A market's outcome as its read gives it.
    function _outcome(uint256 marketId) internal view returns (Outcome) {
        return markets.getMarket(marketId).outcome;
    }

    function _position(uint256 marketId, address who, Side side) internal view returns (Position memory) {
        return positions.getPosition(marketId, who, side);
    }

    // ──────────────────────────── The compiled interface ────────────────

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

    /// @dev Every entry of one ABI type in an artifact, as "Name(type name,type name)"; for an event, each
    ///      indexed parameter is marked "indexed type name". A parameter that is a struct is written out as its
    ///      components, "(type name,type name) name", with its array suffix kept.
    function _abiSignatures(string memory json, string memory abiType) internal view returns (string[] memory out) {
        string[] memory found = new string[](128);
        uint256 n;
        for (uint256 i; vm.keyExistsJson(json, string.concat("$.abi[", vm.toString(i), "]")); ++i) {
            string memory entry = string.concat("$.abi[", vm.toString(i), "]");
            if (keccak256(bytes(vm.parseJsonString(json, string.concat(entry, ".type")))) != keccak256(bytes(abiType)))
            {
                continue;
            }
            string memory sig = string.concat(vm.parseJsonString(json, string.concat(entry, ".name")), "(");
            for (uint256 j; vm.keyExistsJson(json, string.concat(entry, ".inputs[", vm.toString(j), "]")); ++j) {
                string memory input = string.concat(entry, ".inputs[", vm.toString(j), "]");
                string memory t = _abiParamType(json, input);
                if (
                    vm.keyExistsJson(json, string.concat(input, ".indexed"))
                        && vm.parseJsonBool(json, string.concat(input, ".indexed"))
                ) {
                    t = string.concat("indexed ", t);
                }
                t = string.concat(t, " ", vm.parseJsonString(json, string.concat(input, ".name")));
                sig = string.concat(sig, j == 0 ? "" : ",", t);
            }
            found[n++] = string.concat(sig, ")");
        }
        out = new string[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = found[i];
        }
    }

    /// @dev One ABI parameter's type, a struct written out as "(type name,type name)" with the array suffix of
    ///      its own type kept, so "tuple[]" reads "(bytes32 orderHash,...)[]".
    function _abiParamType(string memory json, string memory param) internal view returns (string memory t) {
        t = vm.parseJsonString(json, string.concat(param, ".type"));
        bytes memory raw = bytes(t);
        if (raw.length < 5 || raw[0] != "t" || raw[1] != "u" || raw[2] != "p" || raw[3] != "l" || raw[4] != "e") {
            return t;
        }
        string memory suffix = "";
        for (uint256 i = 5; i < raw.length; ++i) {
            suffix = string.concat(suffix, string(abi.encodePacked(raw[i])));
        }
        string memory inner = "(";
        for (uint256 j; vm.keyExistsJson(json, string.concat(param, ".components[", vm.toString(j), "]")); ++j) {
            string memory c = string.concat(param, ".components[", vm.toString(j), "]");
            inner = string.concat(
                inner,
                j == 0 ? "" : ",",
                _abiParamType(json, c),
                " ",
                vm.parseJsonString(json, string.concat(c, ".name"))
            );
        }
        t = string.concat(inner, ")", suffix);
    }
}
