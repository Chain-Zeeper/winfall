// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Pool} from "../src/Pool.sol";
import {IPool} from "../src/interface/IPool.sol";
import "../src/PoolManager.sol";
import {Winfall} from "../src/interface/IPoolManager.sol";
import {MockCoordSub} from "./Manager.t.sol";

contract RollTok is ERC20 {
    constructor() ERC20("T", "T") {
        _mint(msg.sender, 1e30);
    }
}

contract RolloverTest is Test {
    MockCoordSub coord;
    Pool impl;
    PoolManager mgr;

    function setUp() public {
        coord = new MockCoordSub();
        impl = new Pool(address(coord), bytes32(0), 5);
        mgr = new PoolManager(address(this), address(0x7EA), address(impl), address(coord), 5);
    }

    // ---- helpers ----

    function _arr(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory r) {
        r = new uint256[](3);
        (r[0], r[1], r[2]) = (a, b, c);
    }

    function _diff(uint16 a, uint16 b, uint16 c) internal pure returns (uint16[] memory r) {
        r = new uint16[](3);
        (r[0], r[1], r[2]) = (a, b, c);
    }

    /// pool owned by this test: 3 positions with shares 50/30/20
    function _pool(uint16[] memory difficulties) internal returns (Pool p) {
        p = Pool(payable(Clones.clone(address(impl))));
        p.initialize(
            address(this),
            "P",
            "P",
            IPool.PoolConfig(3, _arr(5_000, 3_000, 2_000), difficulties, address(0), block.timestamp + 1 days)
        );
        coord.addConsumer(5, address(p));
    }

    function _mint(Pool p, uint256 n) internal {
        for (uint256 i = 1; i <= n; i++) {
            p.safeMint(address(uint160(0x10000 + i)), i);
        }
    }

    function _draw(Pool p, uint256 seed) internal returns (uint256[] memory) {
        vm.warp(p.getConfig().closeTime);
        coord.fulfill(address(p), p.requestWinners(), seed);
        return p.pickWinners();
    }

    /// prize position of every winner, in draw order
    function _positions(Pool p) internal view returns (uint256[] memory pos) {
        IPool.WinnerInfo[] memory info = p.winnersInfo();
        pos = new uint256[](info.length);
        for (uint256 k; k < info.length; k++) {
            pos[k] = info[k].position;
        }
    }

    function _misses(uint256 seed, uint256 position, uint16 difficulty) internal pure returns (bool) {
        return uint256(keccak256(abi.encode(seed, "miss", position))) % 10_000 < difficulty;
    }

    /// a seed for which position 0 misses at `d0` and position 2 misses at `d2` (position 1 has difficulty 0)
    function _seedMissing0And2(uint16 d0, uint16 d2) internal pure returns (uint256 seed) {
        while (!_misses(seed, 0, d0) || !_misses(seed, 2, d2)) {
            seed++;
        }
    }

    // ---- difficulty per position ----

    function test_noDifficultiesMeansEveryPositionIsWon() public {
        Pool p = _pool(new uint16[](0));
        _mint(p, 10);
        vm.deal(address(p), 100 ether);
        assertEq(_draw(p, 42).length, 3);
        assertEq(p.wonShares(), 10_000);
        assertEq(p.rolloverAmount(), 0);
        vm.expectRevert(IPool.NOTHING_TO_ROLL_OVER.selector);
        p.rollover(address(0xBEEF));
    }

    function test_missedPositionsKeepTheirShareForRollover() public {
        // 1st place 90% hard, 2nd guaranteed, 3rd 50% hard
        Pool p = _pool(_diff(9_000, 0, 5_000));
        _mint(p, 10);
        vm.deal(address(p), 100 ether);
        uint256[] memory w = _draw(p, _seedMissing0And2(9_000, 5_000));

        assertEq(w.length, 1); // only 2nd place was won
        assertEq(p.winnerPositions(0), 1);
        assertEq(p.wonShares(), 3_000);
        assertEq(p.rolloverAmount(), 70 ether); // 1st (50) + 3rd (20)

        address winner = p.winnerAt(0);
        vm.prank(winner);
        assertEq(p.claim(0), 30 ether); // paid right away, the rollover doesn't block winners
        assertEq(address(p).balance, 70 ether);
    }

    function test_prizeAndWinnerViews() public {
        Pool p = _pool(_diff(9_000, 0, 5_000));
        _mint(p, 10);
        vm.deal(address(p), 100 ether);

        // before the draw: prizes from the current pot, no winners yet
        assertEq(p.pot(), 100 ether); // live balance until the snapshot
        assertEq(p.prizes()[0], 50 ether);
        uint256[] memory amounts = p.prizes();
        assertEq(amounts.length, 3);
        assertEq(amounts[1], 30 ether);
        assertEq(amounts[2], 20 ether);
        assertEq(p.winnersInfo().length, 0);

        uint256 seed; // 1st place misses, 2nd (no difficulty) and 3rd are won
        while (!_misses(seed, 0, 9_000) || _misses(seed, 2, 5_000)) {
            seed++;
        }
        _draw(p, seed);
        IPool.WinnerInfo[] memory info = p.winnersInfo();
        assertEq(info.length, 2);
        assertEq(info[0].position, 1);
        assertEq(info[0].prize, 30 ether);
        assertEq(info[0].ticketId, p.winners(0));
        assertEq(info[0].holder, p.winnerAt(0));
        assertFalse(info[0].claimed);
        assertEq(info[1].position, 2);
        assertEq(info[1].prize, 20 ether);

        vm.prank(info[0].holder);
        assertEq(p.claim(0), info[0].prize); // the view matches what claim pays
        vm.deal(address(p), 500 ether); // money added after the snapshot doesn't change the prizes
        assertEq(p.pot(), 100 ether); // the snapshot, not the balance
        info = p.winnersInfo();
        assertTrue(info[0].claimed);
        assertEq(info[1].prize, 20 ether);
        assertEq(p.prizes()[0], 50 ether);

        // an unclaimed winning ticket shows its current holder, who is the one that can claim
        uint256 ticket = info[1].ticketId;
        vm.prank(info[1].holder);
        p.transferFrom(info[1].holder, address(0xCAFE), ticket);
        assertEq(p.winnersInfo()[1].holder, address(0xCAFE));

        // once claimed, the winner on record is who was paid, whoever holds the ticket afterwards
        address paid = info[0].holder;
        uint256 claimedTicket = info[0].ticketId;
        vm.prank(paid);
        p.transferFrom(paid, address(0xD00D), claimedTicket);
        assertEq(p.ownerOf(claimedTicket), address(0xD00D));
        assertEq(p.winnersInfo()[0].holder, paid);
        assertEq(p.winnerAt(0), paid);
        assertEq(p.prizePaidTo(0), paid);

        p.distribute(10); // paid through distribute: recorded the same way
        vm.prank(address(0xCAFE));
        p.transferFrom(address(0xCAFE), address(0xD00D), ticket);
        assertEq(p.winnersInfo()[1].holder, address(0xCAFE));
    }

    /// win rate per position over many draws: 0% / 50% / 90% difficulty
    function test_eachPositionMissesAtItsOwnRate() public {
        uint256[3] memory won;
        uint256 runs = 300;
        for (uint256 s; s < runs; s++) {
            Pool p = _pool(_diff(0, 5_000, 9_000));
            _mint(p, 5);
            _draw(p, uint256(keccak256(abi.encode("run", s))));
            uint256[] memory pos = _positions(p);
            for (uint256 k; k < pos.length; k++) {
                won[pos[k]]++;
            }
        }
        emit log_named_uint("1st place won (difficulty 0%) of 300", won[0]);
        emit log_named_uint("2nd place won (difficulty 50%) of 300", won[1]);
        emit log_named_uint("3rd place won (difficulty 90%) of 300", won[2]);
        assertEq(won[0], runs);
        assertGt(won[1], 115);
        assertLt(won[1], 185);
        assertGt(won[2], 10);
        assertLt(won[2], 55);
    }

    /// 1000 real draws with 5 positions at 0 / 25 / 50 / 75 / 90% difficulty: every position is won at its
    /// expected rate (within ~3.5 standard deviations), and a harder position is won less often than an easier one
    function test_difficultySweep() public {
        uint16[5] memory difficulty = [uint16(0), 2_500, 5_000, 7_500, 9_000];
        uint256[] memory shares = new uint256[](5);
        uint16[] memory d = new uint16[](5);
        for (uint256 i; i < 5; i++) {
            shares[i] = 2_000;
            d[i] = difficulty[i];
        }

        uint256 runs = 1000;
        uint256[5] memory won;
        uint256 noWinnerAtAll;
        for (uint256 s; s < runs; s++) {
            Pool p = Pool(payable(Clones.clone(address(impl))));
            p.initialize(address(this), "P", "P", IPool.PoolConfig(5, shares, d, address(0), block.timestamp + 1 days));
            coord.addConsumer(5, address(p));
            _mint(p, 6); // enough for all 5 positions
            if (_draw(p, uint256(keccak256(abi.encode("sweep", s)))).length == 0) noWinnerAtAll++;
            uint256[] memory pos = _positions(p);
            for (uint256 k; k < pos.length; k++) {
                won[pos[k]]++;
            }
        }

        for (uint256 i; i < 5; i++) {
            uint256 expected = runs * (10_000 - difficulty[i]) / 10_000;
            emit log_named_uint(string.concat("difficulty ", vm.toString(difficulty[i]), " bps, won of 1000"), won[i]);
            if (difficulty[i] == 0) {
                assertEq(won[i], runs); // never misses
            } else {
                assertApproxEqAbs(won[i], expected, 50); // 3.5 sd at p = 0.5 is ~55, tighter at the edges
            }
            if (i > 0) assertLt(won[i], won[i - 1]); // harder is won less
        }
        assertEq(noWinnerAtAll, 0); // the 0% position always has a winner
        emit log_named_uint("expected 90% difficulty wins", runs / 10);
    }

    /// difficulty doesn't depend on how many tickets sold: 1 ticket or 30, a 50% position is won about half the time
    function test_difficultyIndependentOfTicketCount() public {
        uint256[2] memory sizes = [uint256(1), 30];
        for (uint256 t; t < 2; t++) {
            uint256 won;
            for (uint256 s; s < 300; s++) {
                Pool p = _pool(_diff(5_000, 5_000, 5_000));
                _mint(p, sizes[t]);
                _draw(p, uint256(keccak256(abi.encode("tickets", t, s))));
                uint256[] memory pos = _positions(p);
                if (pos.length > 0 && pos[0] == 0) won++; // 1st place was won
            }
            emit log_named_uint(string.concat("1st place won of 300 with ", vm.toString(sizes[t]), " tickets"), won);
            assertApproxEqAbs(won, 150, 30); // ~3.5 sd
        }
    }

    /// a position whose roll lands exactly on the difficulty is won, one below it misses
    function test_missRollBoundary() public {
        Pool p = _pool(_diff(9_000, 0, 0));
        _mint(p, 5);
        uint256 seed;
        // find a seed whose 1st place roll is exactly 9000 (just not a miss) to pin the comparison
        while (uint256(keccak256(abi.encode(seed, "miss", uint256(0)))) % 10_000 != 9_000) {
            seed++;
        }
        _draw(p, seed);
        assertEq(_positions(p)[0], 0); // roll 9000 is not < 9000: 1st place is won

        Pool q = _pool(_diff(9_001 - 1, 0, 0));
        _mint(q, 5);
        uint256 seed2;
        while (uint256(keccak256(abi.encode(seed2, "miss", uint256(0)))) % 10_000 != 8_999) {
            seed2++;
        }
        _draw(q, seed2);
        uint256[] memory pos = _positions(q);
        assertTrue(pos.length == 0 || pos[0] != 0); // roll 8999 < 9000: 1st place misses
    }

    function testFuzz_winnersDistinctAndAmountsAddUp(uint256 seed, uint8 t, uint16 d0, uint16 d1, uint16 d2) public {
        uint16[] memory d = _diff(uint16(bound(d0, 0, 9_000)), uint16(bound(d1, 0, 9_000)), uint16(bound(d2, 0, 9_000)));
        Pool p = _pool(d);
        _mint(p, bound(t, 1, 20));
        vm.deal(address(p), 100 ether);
        uint256[] memory w = _draw(p, seed);
        uint256[] memory pos = _positions(p);

        uint256 prizes;
        uint256[3] memory share = [uint256(50), 30, 20];
        for (uint256 i; i < w.length; i++) {
            assertFalse(_misses(seed, pos[i], d[pos[i]]));
            for (uint256 k; k < i; k++) {
                assertTrue(w[i] != w[k]);
                assertLt(pos[k], pos[i]);
            }
            prizes += 100 ether * share[pos[i]] / 100;
        }
        assertEq(prizes + p.rolloverAmount(), 100 ether); // every wei is either a prize or rollable
    }

    // ---- rollover on the pool ----

    function test_rolloverMovesOnlyTheUnwonShareOnce() public {
        Pool p = _pool(_diff(9_000, 0, 5_000));
        _mint(p, 10);
        vm.deal(address(p), 100 ether);

        vm.expectRevert(IPool.WINNERS_NOT_PICKED.selector); // not before the draw
        p.rollover(address(0xBEEF));

        _draw(p, _seedMissing0And2(9_000, 5_000));
        vm.prank(address(0xBAD));
        vm.expectRevert(); // owner only
        p.rollover(address(0xBAD));

        assertEq(p.rollover(address(0xBEEF)), 70 ether);
        assertEq(address(0xBEEF).balance, 70 ether);
        assertEq(p.rolloverAmount(), 0);
        vm.expectRevert(IPool.ALREADY_ROLLED_OVER.selector);
        p.rollover(address(0xBEEF));

        address winner = p.winnerAt(0); // the winner is still paid from the same snapshot afterwards
        vm.prank(winner);
        assertEq(p.claim(0), 30 ether);
    }

    function test_potIsLockedUntilPaidAndRolledOver() public {
        Pool p = _pool(_diff(9_000, 0, 5_000));
        _mint(p, 10);
        vm.deal(address(p), 100 ether);

        vm.expectRevert("pot locked until winners are paid and the rest rolled over"); // not before the draw
        p.rescueFunds(address(0), address(this), 1);

        _draw(p, _seedMissing0And2(9_000, 5_000));
        address winner = p.winnerAt(0);
        vm.prank(winner);
        p.claim(0);
        vm.expectRevert("pot locked until winners are paid and the rest rolled over"); // unwon share still there
        p.rescueFunds(address(0), address(this), 1);

        p.rollover(address(0xBEEF));
        vm.deal(address(p), 1 ether); // dust / late top up
        p.rescueFunds(address(0), address(0xD057), type(uint256).max);
        assertEq(address(0xD057).balance, 1 ether);
    }

    function test_poolWithoutTicketsRollsEverything() public {
        Pool p = _pool(new uint16[](0));
        vm.deal(address(p), 40 ether);
        vm.warp(p.getConfig().closeTime);
        assertEq(p.requestWinners(), 0); // no vrf request needed
        assertTrue(p.drawn());
        assertEq(p.getWinners().length, 0);
        assertEq(p.rolloverAmount(), 40 ether);
        assertEq(p.rollover(address(0xBEEF)), 40 ether);
        vm.expectRevert(IPool.WINNERS_ALREADY_PICKED.selector);
        p.requestWinners();
    }

    function test_initRejectsBadSettings() public {
        Pool p = Pool(payable(Clones.clone(address(impl))));
        uint256[] memory shares = _arr(5_000, 3_000, 2_000);
        uint16[] memory two = new uint16[](2);
        vm.expectRevert(IPool.INVALID_DIFFICULTIES.selector); // one difficulty per position
        p.initialize(address(this), "P", "P", IPool.PoolConfig(3, shares, two, address(0), block.timestamp + 1 days));
        vm.expectRevert(IPool.INVALID_DIFFICULTIES.selector); // above the 90% cap
        p.initialize(
            address(this),
            "P",
            "P",
            IPool.PoolConfig(3, shares, _diff(0, 0, 9_001), address(0), block.timestamp + 1 days)
        );
        vm.expectRevert(IPool.INVALID_WINNER_SHARES.selector); // shares have to add up to 10_000 bps
        p.initialize(
            address(this),
            "P",
            "P",
            IPool.PoolConfig(3, _arr(5_000, 3_000, 200), new uint16[](0), address(0), block.timestamp + 1 days)
        );
        vm.expectRevert(IPool.INVALID_CLOSE_TIME.selector);
        p.initialize(address(this), "P", "P", IPool.PoolConfig(3, shares, new uint16[](0), address(0), block.timestamp));
    }

    // ---- rollover through the manager ----

    function _winfall(address currency, uint16 difficulty) internal view returns (Winfall memory w) {
        uint256[] memory shares = new uint256[](1);
        shares[0] = 10_000;
        uint16[] memory d = new uint16[](1);
        d[0] = difficulty;
        w.name = "W";
        w.ticketPrice = 1 ether;
        w.paymentToken = currency;
        w.currency = currency;
        w.closeTime = block.timestamp + 1 days;
        w.winningShares = shares;
        w.difficultiesBps = d;
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = a;
    }

    function _missSeed(uint16 difficulty) internal pure returns (uint256 seed) {
        while (!_misses(seed, 0, difficulty)) {
            seed++;
        }
    }

    /// pool with one 90% hard position, one ticket sold, drawn without a winner: 1 ether rollable
    function _unwonPool() internal returns (address p) {
        p = mgr.createPool("A", _winfall(address(0), 9_000));
        address buyer = address(0xA11CE);
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        mgr.buyTickets{value: 1 ether}(p, _ids(7), address(0));
        vm.warp(IPool(p).getConfig().closeTime);
        coord.fulfill(p, mgr.requestWinners(p), _missSeed(9_000));
        assertEq(IPool(p).pickWinners().length, 0);
    }

    function test_managerRollsUnwonPotIntoNextPool() public {
        address a = _unwonPool();
        assertEq(IPool(a).rolloverAmount(), 1 ether);
        address b = mgr.createPool("B", _winfall(address(0), 0));

        assertEq(mgr.rollover(a, b), 1 ether);
        assertEq(a.balance, 0);
        assertEq(b.balance, 1 ether);

        // the next pool's winner gets the rolled pot plus that pool's own sales
        address bob = address(0xB0B);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        mgr.buyTickets{value: 1 ether}(b, _ids(7), address(0)); // ticket numbers are per pool
        vm.warp(IPool(b).getConfig().closeTime);
        coord.fulfill(b, mgr.requestWinners(b), 123);
        IPool(b).pickWinners();
        vm.prank(bob);
        assertEq(IPool(b).claim(0), 2 ether);
    }

    function test_rolloverCanOnlyGoIntoAnotherOpenPoolOfTheSameCurrency() public {
        address a = _unwonPool();
        RollTok tok = new RollTok();
        address tokenPool = mgr.createPool("T", _winfall(address(tok), 0));
        address drawnPool = mgr.createPool("D", _winfall(address(0), 0));
        vm.warp(IPool(drawnPool).getConfig().closeTime);
        mgr.requestWinners(drawnPool); // no tickets: drawn right away

        vm.expectRevert(INVALID_ROLLOVER_TARGET.selector); // a wallet
        mgr.rollover(a, address(0xBEEF));
        vm.expectRevert(INVALID_ROLLOVER_TARGET.selector); // itself
        mgr.rollover(a, a);
        vm.expectRevert(INVALID_ROLLOVER_TARGET.selector); // other pot currency
        mgr.rollover(a, tokenPool);
        vm.expectRevert(INVALID_ROLLOVER_TARGET.selector); // already drawn, the money would miss its pot
        mgr.rollover(a, drawnPool);

        vm.expectRevert("pot locked until winners are paid and the rest rolled over"); // the admin can't take it
        mgr.rescuePoolFunds(a, address(0), address(this), 1 ether);

        address open = mgr.createPool("B", _winfall(address(0), 0));
        vm.prank(address(0xBAD));
        vm.expectRevert(); // needs the pool creator role
        mgr.rollover(a, open);
        mgr.rollover(a, open);
        assertEq(open.balance, 1 ether);
    }

    function test_vrfSlotReleasedOnlyAfterTheDraw() public {
        address p = mgr.createPool("A", _winfall(address(0), 0));
        vm.expectRevert(WINFALL_STILL_OPEN.selector);
        mgr.releaseVrfConsumer(p);
        vm.warp(IPool(p).getConfig().closeTime);
        mgr.requestWinners(p);
        mgr.releaseVrfConsumer(p);
        assertFalse(coord.consumer(p));
    }
}
