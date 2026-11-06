// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {VmSafe} from "forge-std/Vm.sol";
import {OspexBetting} from "../../src/betting/OspexBetting.sol";
import {OspexMatching} from "../../src/betting/OspexMatching.sol";
import {Side} from "../../src/betting/OspexBettingTypes.sol";
import {BettingBase} from "./BettingBase.sol";

/// @dev An account that is a contract: it holds code and does nothing. The tests send its calls for it.
contract ContractAccount {}

/// @dev A courier that is a contract and answers yes to whatever it is asked.
contract YesCourier {
    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(true);
    }
}

/// @notice The matching module as it stands: the signed order's type names the game, so its typehash is new and
///         a signer following the type string written out here produces the hash the contract accepts; the
///         per-order cancel and the per-line floor; an account's couriers, registered and dropped by the
///         account; no fill.
contract OspexMatchingTest is BettingBase {
    /// @dev The signed order's type string, written out: nine fields, the game named `gameId`.
    bytes32 internal constant TYPEHASH = keccak256(
        "OspexCommitment(address maker,uint256 gameId,address scorer,int32 lineTicks,uint8 positionType,uint16 oddsTick,uint256 riskAmount,uint256 nonce,uint256 expiry)"
    );
    /// @dev v2's type string, which named the game `contestId`.
    bytes32 internal constant V2_TYPEHASH = keccak256(
        "OspexCommitment(address maker,uint256 contestId,address scorer,int32 lineTicks,uint8 positionType,uint16 oddsTick,uint256 riskAmount,uint256 nonce,uint256 expiry)"
    );
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    address internal signer;
    uint256 internal signerKey;

    function setUp() public override {
        super.setUp();
        (signer, signerKey) = makeAddrAndKey("signer");
    }

    function _order() internal view returns (OspexMatching.OspexCommitment memory c) {
        c = OspexMatching.OspexCommitment({
            maker: signer,
            gameId: 7,
            scorer: address(spread),
            lineTicks: -35,
            positionType: Side.A,
            oddsTick: 193,
            riskAmount: 10_000_000,
            nonce: 3,
            expiry: 1_800_000_037
        });
    }

    /// @dev The EIP-712 hash of an order under a type string, built here from first principles: the domain is
    ///      the module's name, version, chain and address; the struct hash is the typehash over the nine fields.
    function _digest(OspexMatching.OspexCommitment memory c, bytes32 typehash) internal view returns (bytes32) {
        bytes32 domain =
            keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("Ospex"), keccak256("1"), block.chainid, address(matching)));
        bytes32 structHash = keccak256(
            abi.encode(
                typehash,
                c.maker,
                c.gameId,
                c.scorer,
                c.lineTicks,
                uint8(c.positionType),
                c.oddsTick,
                c.riskAmount,
                c.nonce,
                c.expiry
            )
        );
        return keccak256(abi.encodePacked(hex"1901", domain, structHash));
    }

    // ──────────────────────────── The signed type ──────────────────────

    function test_typehash_namesTheGame() public view {
        assertEq(matching.COMMITMENT_TYPEHASH(), TYPEHASH, "the typehash is the type string written out");
        assertTrue(TYPEHASH != V2_TYPEHASH, "the rename changed the typehash");
    }

    function test_hash_isWhatASignerComputesFromTheTypeString() public view {
        OspexMatching.OspexCommitment memory c = _order();
        bytes32 want = _digest(c, TYPEHASH);
        assertEq(matching.getCommitmentHash(c), want, "the hash");
        assertEq(
            matching.getDomainSeparator(),
            keccak256(
                abi.encode(DOMAIN_TYPEHASH, keccak256("Ospex"), keccak256("1"), block.chainid, address(matching))
            ),
            "the domain separator"
        );
        // A signature over that hash recovers the maker.
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, want);
        assertEq(ecrecover(want, v, r, s), signer, "the signer recovers");
        // The same nine values under v2's type string hash to something else: no v2 signature is a v3 order.
        assertTrue(matching.getCommitmentHash(c) != _digest(c, V2_TYPEHASH), "a v2 hash is a v3 hash");
    }

    function test_hash_movesWithEveryField() public view {
        OspexMatching.OspexCommitment memory base = _order();
        bytes32 h = matching.getCommitmentHash(base);
        for (uint256 i; i < 9; ++i) {
            OspexMatching.OspexCommitment memory c = _order();
            if (i == 0) c.maker = stranger;
            if (i == 1) c.gameId = 8;
            if (i == 2) c.scorer = address(total);
            if (i == 3) c.lineTicks = -45;
            if (i == 4) c.positionType = Side.B;
            if (i == 5) c.oddsTick = 194;
            if (i == 6) c.riskAmount = 10_000_001;
            if (i == 7) c.nonce = 4;
            if (i == 8) c.expiry = 1_800_000_038;
            assertTrue(matching.getCommitmentHash(c) != h, string.concat("field ", vm.toString(i), " not hashed"));
        }
    }

    function test_domain_isNamedVersionedAndBoundToTheModule() public view {
        (bytes1 fields, string memory name, string memory version, uint256 chainId, address verifying,,) =
            matching.eip712Domain();
        assertEq(fields, hex"0f");
        assertEq(name, "Ospex");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifying, address(matching));
    }

    // ──────────────────────────── Cancelling ──────────────────────────

    function test_cancel_byTheMakerOnly() public {
        OspexMatching.OspexCommitment memory c = _order();
        bytes32 h = matching.getCommitmentHash(c);
        vm.prank(stranger, stranger);
        vm.expectRevert(OspexMatching.OspexMatching__NotCommitmentMaker.selector);
        matching.cancelCommitment(c);
        assertFalse(matching.s_cancelledCommitments(h));

        // A courier is not the maker. A courier the maker registered cancels nothing of the maker's, and
        // neither does an account that registered the maker as its own courier.
        address courier = makeAddr("courier");
        vm.prank(signer, signer);
        matching.registerCourier(courier);
        vm.prank(stranger, stranger);
        matching.registerCourier(signer);
        address[2] memory notTheMaker = [courier, stranger];
        for (uint256 i; i < notTheMaker.length; ++i) {
            vm.prank(notTheMaker[i], notTheMaker[i]);
            vm.expectRevert(OspexMatching.OspexMatching__NotCommitmentMaker.selector);
            matching.cancelCommitment(c);
        }
        assertFalse(matching.s_cancelledCommitments(h), "an order cancelled by an address that is not its maker");

        vm.expectEmit(true, true, true, true, address(matching));
        emit OspexMatching.CommitmentCancelled(
            h, signer, c.gameId, c.scorer, c.lineTicks, c.positionType, c.oddsTick, c.riskAmount, c.nonce, c.expiry
        );
        vm.expectEmit(true, true, true, true, address(core));
        emit OspexBetting.CoreEventEmitted(
            matching.EVENT_COMMITMENT_CANCELLED(),
            address(matching),
            abi.encode(
                h, signer, c.gameId, c.scorer, c.lineTicks, c.positionType, c.oddsTick, c.riskAmount, c.nonce, c.expiry
            )
        );
        vm.prank(signer, signer);
        matching.cancelCommitment(c);
        assertTrue(matching.s_cancelledCommitments(h));
    }

    function test_raiseMinNonce_risesPerAccountPerMarket() public {
        bytes32 key = keccak256(abi.encode(uint256(7), address(spread), int32(-35)));
        assertEq(matching.s_minNonces(signer, key), 0);

        vm.expectEmit(true, true, true, true, address(matching));
        emit OspexMatching.MinNonceUpdated(signer, 7, address(spread), -35, 5, key);
        vm.expectEmit(true, true, true, true, address(core));
        emit OspexBetting.CoreEventEmitted(
            matching.EVENT_MIN_NONCE_UPDATED(),
            address(matching),
            abi.encode(signer, uint256(7), address(spread), int32(-35), uint256(5), key)
        );
        vm.prank(signer, signer);
        matching.raiseMinNonce(7, address(spread), -35, 5);
        assertEq(matching.s_minNonces(signer, key), 5);

        // Not the same, not lower, not the top value.
        uint256[3] memory refused = [uint256(5), 3, type(uint256).max];
        for (uint256 i; i < refused.length; ++i) {
            vm.prank(signer, signer);
            vm.expectRevert(OspexMatching.OspexMatching__NonceMustIncrease.selector);
            matching.raiseMinNonce(7, address(spread), -35, refused[i]);
        }
        vm.prank(signer, signer);
        matching.raiseMinNonce(7, address(spread), -35, 6);
        assertEq(matching.s_minNonces(signer, key), 6);

        // Another market of the same account, and the same market of another account, are untouched.
        assertEq(matching.s_minNonces(signer, keccak256(abi.encode(uint256(7), address(spread), int32(-45)))), 0);
        assertEq(matching.s_minNonces(signer, keccak256(abi.encode(uint256(8), address(spread), int32(-35)))), 0);
        assertEq(matching.s_minNonces(stranger, key), 0);
    }

    // ──────────────────────────── Couriers ────────────────────────────
    //
    // Each of these runs three times: for an account whose calls arrive with another address as the
    // transaction's origin, for an account that sends its own, and for an account that is a contract. The
    // module is to read the caller in each, and to treat a contract as it treats a key.

    /// @dev The transaction origin these tests give a call when the caller is not to be its own origin. It
    ///      makes no call of its own unless a test says so.
    address internal origin = makeAddr("origin");

    /// @dev An account that is a contract. Its calls arrive with the origin above.
    address internal contractAccount = address(new ContractAccount());

    /// Break: in OspexMatching.unregisterCourier, delete the write, `s_couriers[msg.sender][courier] = false;`.
    /// The dropped courier then stays. Others turn it red: one courier at a time; a dropped courier that does
    /// not register again, at once or after several rounds; and a courier that is asked whether it may be
    /// dropped.
    function test_couriers_anAccountRegistersSeveralAndDropsOne() public {
        _registersSeveralAndDropsOne(signer, origin);
        _registersSeveralAndDropsOne(stranger, stranger);
        _registersSeveralAndDropsOne(contractAccount, origin);

        // Nothing is asked of a courier. A contract that answers yes to whatever it is asked is registered,
        // registered again and dropped like any other address, and the module never calls it.
        address yes = address(new YesCourier());
        vm.expectCall(yes, bytes(""), 0);
        vm.startPrank(signer, origin);
        matching.registerCourier(yes);
        matching.registerCourier(yes);
        assertTrue(matching.isCourier(signer, yes), "a courier that answers yes");
        matching.unregisterCourier(yes);
        vm.stopPrank();
        assertFalse(matching.isCourier(signer, yes), "a courier that answers yes was not dropped");
    }

    function _registersSeveralAndDropsOne(address account, address sentFrom) internal {
        address one = makeAddr("courier one");
        address two = makeAddr("courier two");
        vm.startPrank(account, sentFrom);
        matching.registerCourier(one);
        assertTrue(matching.isCourier(account, one), "the first courier");
        assertFalse(matching.isCourier(account, two), "the second, before it is registered");
        matching.registerCourier(two);
        assertTrue(matching.isCourier(account, one), "the first, after the second is registered");
        assertTrue(matching.isCourier(account, two), "the second courier");

        // Dropping one leaves the other.
        matching.unregisterCourier(one);
        assertFalse(matching.isCourier(account, one), "the dropped courier");
        assertTrue(matching.isCourier(account, two), "the courier that was not dropped");

        // A dropped courier registers again. An account may name itself, and may name a contract.
        matching.registerCourier(one);
        matching.registerCourier(account);
        matching.registerCourier(address(core));
        vm.stopPrank();
        assertTrue(matching.isCourier(account, one), "the courier registered again");
        assertTrue(matching.isCourier(account, account), "the account as its own courier");
        assertTrue(matching.isCourier(account, address(core)), "a contract as a courier");
        assertTrue(matching.isCourier(account, two), "the second, at the end");

        // A courier is dropped and registered again as often as the account likes: eight rounds here.
        address again = makeAddr("courier again");
        vm.startPrank(account, sentFrom);
        for (uint256 round; round < 8; ++round) {
            matching.registerCourier(again);
            assertTrue(matching.isCourier(account, again), "registered, on a later round");
            matching.unregisterCourier(again);
            assertFalse(matching.isCourier(account, again), "dropped, on a later round");
        }
        vm.stopPrank();
    }

    /// Break, one for each refusal: in OspexMatching.registerCourier, delete the zero check, `if (courier ==
    /// address(0)) revert OspexMatching__ZeroCourier();`; in unregisterCourier, delete the check that the
    /// account has the courier. Two more turn it red: that check reading the origin's entry,
    /// `s_couriers[tx.origin][courier]`, and the origin in place of the caller in the refusal's own arguments.
    function test_couriers_refusesTheZeroAddressAndADropThatChangesNothing() public {
        _refusesZeroAndADropThatChangesNothing(signer, origin, stranger);
        _refusesZeroAndADropThatChangesNothing(maker, maker, taker);
        _refusesZeroAndADropThatChangesNothing(contractAccount, origin, makeAddr("another account"));

        // What the origin of a call holds is not the caller's. The origin registers a courier of its own; the
        // signer, sending from that origin, does not have it to drop, and the origin keeps it.
        address theirs = makeAddr("the origin's courier");
        vm.prank(origin, origin);
        matching.registerCourier(theirs);
        vm.prank(signer, origin);
        vm.expectRevert(
            abi.encodeWithSelector(OspexMatching.OspexMatching__CourierNotRegistered.selector, signer, theirs)
        );
        matching.unregisterCourier(theirs);
        assertTrue(matching.isCourier(origin, theirs), "the origin's own courier, after the caller's refused drop");
    }

    /// @dev `account` sends from `sentFrom`. `another` is a second account, which sends its own calls.
    function _refusesZeroAndADropThatChangesNothing(address account, address sentFrom, address another) internal {
        address courier = makeAddr("courier");

        // The zero address is not registered.
        vm.prank(account, sentFrom);
        vm.expectRevert(OspexMatching.OspexMatching__ZeroCourier.selector);
        matching.registerCourier(address(0));
        assertFalse(matching.isCourier(account, address(0)), "the zero address is a courier");

        // A courier the account does not have is not dropped: one never registered, the zero address, the
        // account itself, and a contract.
        address[4] memory absent = [courier, address(0), account, address(core)];
        for (uint256 i; i < absent.length; ++i) {
            vm.prank(account, sentFrom);
            vm.expectRevert(
                abi.encodeWithSelector(OspexMatching.OspexMatching__CourierNotRegistered.selector, account, absent[i])
            );
            matching.unregisterCourier(absent[i]);
        }

        // The refusal is per account: a courier another account has is not the account's to drop, and the
        // other account keeps it.
        vm.prank(another, another);
        matching.registerCourier(courier);
        vm.prank(account, sentFrom);
        vm.expectRevert(
            abi.encodeWithSelector(OspexMatching.OspexMatching__CourierNotRegistered.selector, account, courier)
        );
        matching.unregisterCourier(courier);
        assertTrue(matching.isCourier(another, courier), "the other account's courier, after the refused drop");

        // Registered, it is dropped once; a second time, refused, and the other account's stands.
        vm.prank(account, sentFrom);
        matching.registerCourier(courier);
        vm.prank(account, sentFrom);
        matching.unregisterCourier(courier);
        assertFalse(matching.isCourier(account, courier), "the dropped courier");
        vm.prank(account, sentFrom);
        vm.expectRevert(
            abi.encodeWithSelector(OspexMatching.OspexMatching__CourierNotRegistered.selector, account, courier)
        );
        matching.unregisterCourier(courier);
        assertFalse(matching.isCourier(account, courier), "the courier, after the refused second drop");
        assertTrue(matching.isCourier(another, courier), "the other account's courier, after the drop");
    }

    /// Break: in OspexMatching.registerCourier, delete the line that returns on a repeat, `if
    /// (s_couriers[msg.sender][courier]) return;`. A repeated registration then writes and emits again. More
    /// turn it red: a repeat that is refused; one that drops the courier; one that emits the module's event,
    /// or the hub's, with no change; a repeat judged by the origin's entry, or taken as one only when the
    /// caller is its own origin, or only when it is not; the return skipped when the account names itself, or
    /// when the caller or the courier is a contract; and a registration that returns a value.
    function test_couriers_aRepeatedRegistrationSucceedsAndChangesNothing() public {
        vm.record();
        _aRepeatChangesNothing(signer, origin, stranger);
        _aRepeatChangesNothing(maker, maker, taker);
        _aRepeatChangesNothing(contractAccount, origin, makeAddr("another account"));

        // What the origin of a call holds is not the caller's. The origin registers a courier of its own; the
        // signer's registration of it, sent from that origin, is the signer's first: written, and emitted.
        address theirs = makeAddr("the origin's courier");
        vm.prank(origin, origin);
        matching.registerCourier(theirs);
        _registersAsAChange(signer, origin, theirs, "a courier the origin has");
        assertTrue(matching.isCourier(origin, theirs), "the origin's own courier");
    }

    /// @dev `account` sends from `sentFrom`. `another` is a second account, which sends its own calls.
    function _aRepeatChangesNothing(address account, address sentFrom, address another) internal {
        address courier = makeAddr("courier");

        // The first registration is a change. The second and the third succeed and are none: no event of the
        // module's, none through the hub, no storage write, and the courier stays.
        _registersAsAChange(account, sentFrom, courier, "a courier");
        _registersAsARepeat(account, sentFrom, courier, "a courier, a second time");
        _registersAsARepeat(account, sentFrom, courier, "a courier, a third time");

        // The account as its own courier is no exception, and neither is a courier that is a contract.
        _registersAsAChange(account, sentFrom, account, "the account itself");
        _registersAsARepeat(account, sentFrom, account, "the account itself, a second time");
        _registersAsAChange(account, sentFrom, address(core), "a contract");
        _registersAsARepeat(account, sentFrom, address(core), "a contract, a second time");

        // A repeat is per account: another account registering the same courier is its first.
        _registersAsAChange(another, another, courier, "another account's courier");
        _registersAsARepeat(account, sentFrom, courier, "a courier another account has too");

        // And only while the account has the courier: after a drop, a registration is a change again.
        vm.prank(account, sentFrom);
        matching.unregisterCourier(courier);
        _registersAsAChange(account, sentFrom, courier, "a dropped courier");
        _registersAsARepeat(account, sentFrom, courier, "a dropped courier, registered and then repeated");
        assertTrue(matching.isCourier(another, courier), "the other account's courier, at the end");
    }

    /// @dev A registration that is a change: one storage write, the two events, no value returned, and the
    ///      pair reads true.
    function _registersAsAChange(address account, address sentFrom, address courier, string memory what)
        internal
    {
        assertFalse(matching.isCourier(account, courier), string.concat("registered before the call: ", what));
        uint256 before = _writes();
        vm.recordLogs();
        _register(account, sentFrom, courier, what);
        _assertTheTwoLogs(
            vm.getRecordedLogs(),
            keccak256("CourierRegistered(address,address)"),
            keccak256("COURIER_REGISTERED"),
            account,
            courier
        );
        assertEq(_writes() - before, 1, string.concat("the registration did not write one slot: ", what));
        assertTrue(matching.isCourier(account, courier), string.concat("not registered: ", what));
    }

    /// @dev A registration of a courier the account has: the call succeeds and returns no value, nothing is
    ///      emitted by any contract, the module's storage is not written, and the pair still reads true.
    function _registersAsARepeat(address account, address sentFrom, address courier, string memory what) internal {
        assertTrue(matching.isCourier(account, courier), string.concat("not registered before the repeat: ", what));
        uint256 before = _writes();
        vm.recordLogs();
        _register(account, sentFrom, courier, what);
        assertEq(vm.getRecordedLogs().length, 0, string.concat("a repeated registration emitted: ", what));
        assertEq(_writes() - before, 0, string.concat("a repeated registration wrote to storage: ", what));
        assertTrue(matching.isCourier(account, courier), string.concat("a repeated registration dropped: ", what));
    }

    /// @dev One registration, sent as a raw call so that what it returns is read: it succeeds, and it returns
    ///      nothing, so a change and a repeat are not told apart by a returned value. The call is built from
    ///      the signature written out, so this file still compiles beside a second function of the same name.
    function _register(address account, address sentFrom, address courier, string memory what) internal {
        vm.prank(account, sentFrom);
        (bool taken, bytes memory returned) =
            address(matching).call(abi.encodeWithSignature("registerCourier(address)", courier));
        assertTrue(taken, string.concat("the registration was refused: ", what));
        assertEq(returned.length, 0, string.concat("the registration returned a value: ", what));
    }

    /// @dev How many storage writes the matching module has made since the test began recording them.
    function _writes() internal returns (uint256) {
        (, bytes32[] memory writes) = vm.accesses(address(matching));
        return writes.length;
    }

    /// Break, one for each of the four emits: in OspexMatching.registerCourier, swap the typed event's two
    /// arguments, `emit CourierRegistered(courier, msg.sender);`; delete its call to the hub; in
    /// unregisterCourier, emit `CourierRegistered` in place of `CourierUnregistered`; swap the two values of
    /// its hub payload, `abi.encode(courier, msg.sender)`. Four more turn it red: the origin in place of the
    /// caller in the registration's typed event, or in the drop's hub payload; and an emit made only when the
    /// caller is the origin, or only when it is not. So does an emit that differs, or is missing, when the
    /// caller is a contract, when the courier is one, or when the account names itself.
    function test_couriers_eachChangeEmitsOnceItselfAndOnceThroughTheHub() public {
        // The two types the hub carries, written out.
        assertEq(matching.EVENT_COURIER_REGISTERED(), keccak256("COURIER_REGISTERED"));
        assertEq(matching.EVENT_COURIER_UNREGISTERED(), keccak256("COURIER_UNREGISTERED"));

        address courier = makeAddr("courier");
        _emitsTwicePerChange(signer, origin, courier);
        _emitsTwicePerChange(stranger, stranger, courier);
        _emitsTwicePerChange(contractAccount, origin, courier);

        // Whatever the courier is: the account itself, and a contract.
        _emitsTwicePerChange(signer, origin, signer);
        _emitsTwicePerChange(signer, origin, address(core));
    }

    function _emitsTwicePerChange(address account, address sentFrom, address courier) internal {
        vm.recordLogs();
        vm.prank(account, sentFrom);
        matching.registerCourier(courier);
        _assertTheTwoLogs(
            vm.getRecordedLogs(),
            keccak256("CourierRegistered(address,address)"),
            keccak256("COURIER_REGISTERED"),
            account,
            courier
        );

        vm.recordLogs();
        vm.prank(account, sentFrom);
        matching.unregisterCourier(courier);
        _assertTheTwoLogs(
            vm.getRecordedLogs(),
            keccak256("CourierUnregistered(address,address)"),
            keccak256("COURIER_UNREGISTERED"),
            account,
            courier
        );
    }

    /// @dev The logs of one change are exactly two. First the module's own event: the account and the courier,
    ///      both indexed, and no data. Then the core's: the type, the module that emitted it, and the payload,
    ///      the account then the courier.
    function _assertTheTwoLogs(
        VmSafe.Log[] memory logs,
        bytes32 typedEvent,
        bytes32 coreType,
        address account,
        address courier
    ) internal view {
        assertEq(logs.length, 2, "the change did not emit exactly twice");

        assertEq(logs[0].emitter, address(matching), "the first event's emitter");
        assertEq(logs[0].topics.length, 3, "the typed event's topics");
        assertEq(logs[0].topics[0], typedEvent, "the typed event");
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(account))), "the typed event's account");
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(courier))), "the typed event's courier");
        assertEq(logs[0].data.length, 0, "the typed event carries data");

        assertEq(logs[1].emitter, address(core), "the second event's emitter");
        assertEq(logs[1].topics.length, 3, "the hub event's topics");
        assertEq(logs[1].topics[0], keccak256("CoreEventEmitted(bytes32,address,bytes)"), "the hub event");
        assertEq(logs[1].topics[1], coreType, "the hub event's type");
        assertEq(logs[1].topics[2], bytes32(uint256(uint160(address(matching)))), "the hub event's emitter field");
        assertEq(abi.decode(logs[1].data, (bytes)), abi.encode(account, courier), "the hub event's payload");
    }

    /// On the set as deployed, with nothing registered, no pair reads as registered.
    function testFuzz_couriers_noneBeforeARegistration(address account, address courier) public view {
        assertFalse(matching.isCourier(account, courier));
    }

    /// A registration writes the caller's pair and no other, a repeat of it moves neither, and a drop takes it
    /// back, whether the caller sends its own call or another address is the origin.
    function testFuzz_couriers_aCallWritesTheCallersPairAndNoOther(
        address account,
        address courier,
        address otherAccount,
        address otherCourier,
        address sentFrom,
        bool direct
    ) public {
        vm.assume(courier != address(0));
        vm.assume(otherAccount != account || otherCourier != courier);
        if (direct) sentFrom = account;

        vm.prank(account, sentFrom);
        matching.registerCourier(courier);
        assertTrue(matching.isCourier(account, courier), "the caller's pair");
        assertFalse(matching.isCourier(otherAccount, otherCourier), "another pair was written");

        vm.prank(account, sentFrom);
        matching.registerCourier(courier);
        assertTrue(matching.isCourier(account, courier), "the caller's pair, after a repeat");
        assertFalse(matching.isCourier(otherAccount, otherCourier), "another pair, after a repeat");

        vm.prank(account, sentFrom);
        matching.unregisterCourier(courier);
        assertFalse(matching.isCourier(account, courier), "the caller's pair, after the drop");
        assertFalse(matching.isCourier(otherAccount, otherCourier), "another pair, after the drop");
    }

    function test_module_answersItsTypeAndTheCore() public view {
        assertEq(matching.getModuleType(), core.MATCHING_MODULE());
        assertEq(address(matching.i_ospexCore()), address(core));
        assertEq(matching.ODDS_SCALE(), 100);
        assertEq(matching.MIN_ODDS(), 101);
        assertEq(matching.MAX_ODDS(), 10100);
        assertEq(matching.MAX_LINE_TICKS(), 1_000_000);
        assertEq(markets.MAX_LINE_TICKS(), 1_000_000);
    }
}
