// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {MegaPool} from "../src/MegaPool.sol";
import {IPool} from "../src/interface/IPool.sol";
import "../src/PoolManager.sol";
import {Winfall} from "../src/interface/IPoolManager.sol";
import {MockCoordSub} from "./Manager.t.sol";

contract MegaPoolTest is Test {
    MockCoordSub coord;
    MegaPool impl;

    function setUp() public {
        coord = new MockCoordSub();
        impl = new MegaPool(address(coord), bytes32(0), 5);
    }

    function _mega(uint16 difficulty, uint32 rounds, uint256 winnersN) internal returns (MegaPool m) {
        uint256[] memory shares = new uint256[](winnersN);
        for (uint256 i; i < winnersN; i++) {
            shares[i] = 1;
        }
        m = MegaPool(payable(Clones.clone(address(impl))));
        m.initialize(
            address(this),
            "M",
            "M",
            IPool.PoolConfig(winnersN, shares, address(0), 0, 0, block.timestamp + 1 days, difficulty, rounds, 1 days)
        );
        coord.addConsumer(5, address(m));
    }

    function _mint(MegaPool m, uint256 from, uint256 n) internal {
        for (uint256 i = from; i < from + n; i++) {
            m.safeMint(address(uint160(0x10000 + i)), i);
        }
    }

    /// closes the current round and draws it with `seed`
    function _draw(MegaPool m, uint256 seed) internal returns (uint256[] memory) {
        vm.warp(m.roundCloseTime());
        uint256 id = m.requestWinners();
        coord.fulfill(address(m), id, seed);
        return m.pickWinners();
    }

    /// a seed for which a 1 position draw over `slots` slots lands on a slot >= `total` (a ticket nobody holds)
    function _missSeed(uint256 total, uint256 slots) internal pure returns (uint256 seed) {
        while (uint256(keccak256(abi.encode(seed, uint256(0)))) % slots < total) {
            seed++;
        }
    }

    function test_difficultyZeroAlwaysHasWinners() public {
        MegaPool m = _mega(0, 1, 3);
        _mint(m, 1, 10);
        uint256[] memory w = _draw(m, 42);
        assertEq(w.length, 3);
        assertTrue(m.ended());
        assertEq(m.winningRound(), 1);
    }

    function test_noWinnerRollsIntoNextRound() public {
        MegaPool m = _mega(9_000, 3, 1);
        m.safeMint(address(0xA11CE), 7);
        vm.deal(address(m), 10 ether);
        // 1 ticket at 90% difficulty: 10 slots, only slot 0 is a real ticket
        uint256[] memory w = _draw(m, _missSeed(1, 10));

        assertEq(w.length, 0);
        assertFalse(m.ended());
        assertEq(m.currentRound(), 2);
        assertEq(m.totalRounds(), 3);
        assertEq(m.roundCloseTime(), block.timestamp + 1 days);
        assertTrue(m.isOpen());
        assertEq(address(m).balance, 10 ether); // pot stays for the next round

        // ticket numbers restart: 7 is free again in round 2, and the round 1 ticket is still owned
        assertFalse(m.ticketExists(7));
        m.safeMint(address(0xB0B0), 7);
        assertEq(m.ownerOf(m.ticketId(1, 7)), address(0xA11CE));
        assertEq(m.ownerOf(m.ticketId(2, 7)), address(0xB0B0));
        (uint256 round, uint256 number) = m.decodeTicket(m.ticketId(2, 7));
        assertEq(round, 2);
        assertEq(number, 7);
        assertEq(
            m.tokenURI(m.ticketId(2, 7)),
            string.concat("https://winfall/megapool/", vm.toLowercase(vm.toString(address(m))), "/ticket/2/7")
        );
        uint256 unsold = m.ticketId(3, 7);
        vm.expectRevert(); // unknown tickets have no metadata
        m.tokenURI(unsold);
        vm.expectRevert(abi.encodeWithSelector(IPool.TICKET_TAKEN.selector, 7));
        m.safeMint(address(0xCA201), 7);
    }

    function test_lastRoundIsGuaranteedAndPotAccumulates() public {
        MegaPool m = _mega(9_000, 2, 1);
        m.safeMint(address(0xA11CE), 1);
        vm.deal(address(m), 10 ether);
        _draw(m, _missSeed(1, 10)); // round 1: nobody wins

        m.safeMint(address(0xB0B0), 1); // round 2 ticket
        vm.deal(address(m), 15 ether); // round 2 sales grow the pot
        assertEq(m.currentDifficultyBps(), 0); // last round ignores difficulty
        uint256[] memory w = _draw(m, _missSeed(1, 10)); // same seed would miss at 90%, can't miss now

        assertEq(w.length, 1);
        assertEq(m.winningRound(), 2);
        assertEq(m.winnerAt(0), address(0xB0B0)); // only round 2 tickets are in round 2's draw
        vm.prank(address(0xB0B0));
        assertEq(m.claim(0), 15 ether);
    }

    function test_emptyRoundRollsWithoutVrf() public {
        MegaPool m = _mega(5_000, 2, 1);
        vm.warp(m.roundCloseTime());
        assertEq(m.requestWinners(), 0);
        assertEq(m.currentRound(), 2);

        vm.deal(address(m), 3 ether);
        vm.warp(m.roundCloseTime());
        assertEq(m.requestWinners(), 0); // last round sold nothing either
        assertTrue(m.ended());
        assertEq(m.getWinners().length, 0);
        m.rescueFunds(address(0), address(0xBEEF), type(uint256).max); // pot can be recovered
        assertEq(address(0xBEEF).balance, 3 ether);
    }

    function test_answerForAnOldRoundIsIgnored() public {
        MegaPool m = _mega(9_000, 3, 1);
        m.safeMint(address(0xA11CE), 1);
        vm.warp(m.roundCloseTime());
        uint256 first = m.requestWinners();
        vm.warp(block.timestamp + m.VRF_RETRY_DELAY());
        uint256 retry = m.requestWinners();
        coord.fulfill(address(m), first, _missSeed(1, 10));
        m.pickWinners(); // round 1 missed, round 2 open

        vm.expectEmit(address(m));
        emit MegaPool.LateFulfillmentIgnored(retry);
        coord.fulfill(address(m), retry, 0); // round 1's retry answering late can't seed round 2
        assertFalse(m.roundFulfilled(2));
    }

    function test_cantDrawTwiceOrAfterEnd() public {
        MegaPool m = _mega(0, 1, 1);
        _mint(m, 1, 2);
        _draw(m, 1);
        vm.expectRevert(MegaPool.POOL_ENDED.selector);
        m.pickWinners();
        vm.expectRevert(MegaPool.POOL_ENDED.selector);
        m.requestWinners();
        assertFalse(m.isOpen());
    }

    function testFuzz_winnersDistinctAndFromCurrentRound(uint256 seed, uint8 t, uint8 n, uint16 d) public {
        uint256 tickets = bound(t, 1, 40);
        uint256 winnersN = bound(n, 1, 8);
        uint16 difficulty = uint16(bound(d, 0, 9_900));
        MegaPool m = _mega(difficulty, 5, winnersN);
        _mint(m, 1, tickets);
        uint256[] memory w = _draw(m, seed);
        uint256[] memory pos = m.getWinnerPositions();
        for (uint256 i; i < w.length; i++) {
            (uint256 round,) = m.decodeTicket(w[i]);
            assertEq(round, 1);
            assertLt(pos[i], winnersN);
            for (uint256 k; k < i; k++) {
                assertTrue(w[i] != w[k]);
            }
        }
        if (difficulty == 0) {
            assertEq(w.length, winnersN < tickets ? winnersN : tickets);
        }
    }

    /// 10 tickets, 1 position, 50% difficulty: 20 slots, so about half the draws have a winner
    function test_difficultyHalvesTheWinChance() public {
        uint256 won;
        uint256 runs = 200;
        for (uint256 s; s < runs; s++) {
            MegaPool m = _mega(5_000, 2, 1);
            _mint(m, 1, 10);
            if (_draw(m, uint256(keccak256(abi.encode("seed", s)))).length > 0) won++;
        }
        emit log_named_uint("rounds won out of 200 at 50% difficulty", won);
        assertGt(won, 70);
        assertLt(won, 130);
    }

    function test_initRejectsBadSettings() public {
        uint256[] memory shares = new uint256[](1);
        shares[0] = 1;
        MegaPool m = MegaPool(payable(Clones.clone(address(impl))));
        vm.expectRevert(IPool.INVALID_ROUNDS.selector); // 100% difficulty
        m.initialize(address(this), "M", "M", IPool.PoolConfig(1, shares, address(0), 0, 0, 1 days, 10_000, 2, 1 days));
        vm.expectRevert(IPool.INVALID_ROUNDS.selector); // several rounds need a round duration
        m.initialize(address(this), "M", "M", IPool.PoolConfig(1, shares, address(0), 0, 0, 1 days, 100, 2, 0));
    }

    // ---- through the manager ----

    function _winfall(uint16 difficulty, uint32 rounds) internal view returns (Winfall memory w) {
        uint256[] memory shares = new uint256[](1);
        shares[0] = 1;
        w.name = "Mega";
        w.ticketPrice = 1 ether;
        w.closeTime = block.timestamp + 2 days;
        w.winningShares = shares;
        w.difficultyBps = difficulty;
        w.totalRounds = rounds;
        w.roundDuration = 1 days;
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = a;
    }

    function test_managerSellsLaterRounds() public {
        PoolManager mgr = new PoolManager(address(this), address(0x7EA), address(impl), address(coord), 5);
        MegaPool m = MegaPool(payable(mgr.createPool("M", _winfall(9_000, 3), 0, 0)));
        assertEq(m.totalRounds(), 3);
        assertEq(m.owner(), address(mgr));

        address buyer = address(0xB0B);
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        mgr.buyTickets{value: 1 ether}(address(m), _ids(5), address(0));

        vm.warp(m.roundCloseTime());
        vm.prank(buyer);
        vm.expectRevert(POOL_CLOSED.selector);
        mgr.buyTickets{value: 1 ether}(address(m), _ids(6), address(0));

        uint256 id = mgr.requestWinners(address(m));
        coord.fulfill(address(m), id, _missSeed(1, 10));
        m.pickWinners();
        assertEq(m.currentRound(), 2);

        vm.prank(buyer); // round 2 is on sale through the manager, number 5 is free again
        mgr.buyTickets{value: 1 ether}(address(m), _ids(5), address(0));
        assertEq(m.ownerOf(m.ticketId(2, 5)), buyer);
        assertEq(address(m).balance, 2 ether);

        // difficulty 0, one round: a plain lottery round from the same contract
        MegaPool plain = MegaPool(payable(mgr.createPool("P", _winfall(0, 1), 0, 0)));
        assertEq(plain.totalRounds(), 1);
        assertEq(plain.currentDifficultyBps(), 0);
    }
}
