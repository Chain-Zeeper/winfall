// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.36;
import {Test} from "forge-std/Test.sol";
import "../src/Pool.sol";
import {PoolClone} from "./PoolClone.sol";
import {IPool} from "../src/interface/IPool.sol";
import {MockCoord} from "./Retry.t.sol";
import {Reverter} from "./Claim.t.sol";

contract GasBurner {
    receive() external payable {
        while (true) {}
    }
}

contract DistributeTest is Test {
    Pool pool;
    MockCoord coord;

    function setUp() public {
        coord = new MockCoord();
        uint256[] memory shares = new uint256[](4);
        shares[0] = 40;
        shares[1] = 30;
        shares[2] = 20;
        shares[3] = 10;
        IPool.PoolConfig memory w = IPool.PoolConfig(4, shares, address(0), 0, 0, block.timestamp + 1 days);
        pool = PoolClone.make(new Pool(address(coord), bytes32(0), 1), address(this), w);
        for (uint160 i = 1; i <= 6; i++) {
            pool.safeMint(address(0x1000 + i), i);
        }
        vm.deal(address(pool), 100 ether);
        vm.warp(block.timestamp + 1 days);
        coord.fulfill(pool, pool.requestWinners(), 99);
        pool.pickWinners();
    }

    function _move(uint256 i, address to) internal {
        address h = pool.winnerAt(i);
        uint256 t = pool.winners(i);
        vm.prank(h);
        pool.transferFrom(h, to, t);
    }

    function test_batchesAcrossCallsAndAnyoneCanCall() public {
        address[4] memory h;
        for (uint256 i; i < 4; i++) {
            h[i] = pool.winnerAt(i);
        }
        vm.prank(address(0xCAFE));
        assertEq(pool.distribute(2), 2);
        assertEq(pool.distributeCursor(), 2);
        assertEq(h[0].balance, 40 ether);
        assertEq(h[1].balance, 30 ether);
        assertEq(h[2].balance, 0);
        vm.prank(address(0xCAFE));
        assertEq(pool.distribute(10), 2);
        assertEq(h[2].balance, 20 ether);
        assertEq(h[3].balance, 10 ether);
        assertTrue(pool.allClaimed());
        assertEq(pool.distribute(5), 0); // nothing left, no revert
    }

    function test_skipsAlreadyClaimed() public {
        address h1 = pool.winnerAt(1);
        vm.prank(h1);
        pool.claim(1);
        assertEq(pool.distribute(2), 2); // positions 0 and 2, 1 skipped without using the batch
        assertEq(h1.balance, 30 ether); // not paid twice
        assertEq(pool.distributeCursor(), 3);
    }

    function test_badRecipientsDontBlockBatchAndCanStillClaim() public {
        Reverter r = new Reverter();
        GasBurner g = new GasBurner();
        _move(0, address(r));
        _move(2, address(g));
        address h1 = pool.winnerAt(1);
        address h3 = pool.winnerAt(3);
        assertEq(pool.distribute(4), 2);
        assertEq(h1.balance, 30 ether);
        assertEq(h3.balance, 10 ether);
        assertFalse(pool.prizeClaimed(0));
        assertFalse(pool.prizeClaimed(2));
        assertFalse(pool.allClaimed());
        // reverter hands the ticket on, new holder claims normally
        uint256 t0 = pool.winners(0);
        vm.prank(address(r));
        pool.transferFrom(address(r), address(0xBEEF), t0);
        vm.prank(address(0xBEEF));
        assertEq(pool.claim(0), 40 ether);
    }

    function test_snapshotSharedWithClaim() public {
        pool.distribute(1); // takes snapshot at 100
        vm.deal(address(pool), address(pool).balance + 1000 ether);
        address h1 = pool.winnerAt(1);
        vm.prank(h1);
        assertEq(pool.claim(1), 30 ether);
        assertEq(pool.potSnapshot(), 100 ether);
    }

    function test_revertsBeforeDraw() public {
        uint256[] memory shares = new uint256[](1);
        shares[0] = 1;
        Pool p = PoolClone.make(
            new Pool(address(coord), bytes32(0), 1),
            address(this),
            IPool.PoolConfig(1, shares, address(0), 0, 0, block.timestamp + 1 days)
        );
        vm.expectRevert(IPool.WINNERS_NOT_PICKED.selector);
        p.distribute(1);
    }

    function test_allClaimedThenDistributeReturnsZero() public {
        for (uint256 i; i < 4; i++) {
            vm.prank(pool.winnerAt(i));
            pool.claim(i);
        }
        assertTrue(pool.allClaimed());
        assertEq(pool.distribute(10), 0); // everything claimed already, no revert
        assertEq(pool.distributeCursor(), 4);
    }

    function test_emptyPotRevertsFirstPayoutOnly() public {
        vm.deal(address(pool), 0);
        vm.expectRevert(IPool.EMPTY_POT.selector);
        pool.distribute(10);
        address h0 = pool.winnerAt(0);
        vm.prank(h0);
        vm.expectRevert(IPool.EMPTY_POT.selector);
        pool.claim(0);

        vm.deal(address(pool), 10 ether); // funded later: first payout snapshots 10
        assertEq(pool.distribute(1), 1);
        assertEq(pool.potSnapshot(), 10 ether);
        vm.deal(address(pool), 0); // drained afterwards: no EMPTY_POT, snapshot is kept,
        address h1 = pool.winnerAt(1);
        vm.prank(h1); // the transfer itself fails instead
        vm.expectRevert("prize transfer failed");
        pool.claim(1);
        assertEq(pool.distribute(10), 0); // distribute skips the failing payouts, no revert
    }
}
