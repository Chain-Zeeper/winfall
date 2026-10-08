// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.36;
import {Test} from "forge-std/Test.sol";
import "../src/Pool.sol";
import {PoolClone} from "./PoolClone.sol";
import {IPool} from "../src/interface/IPool.sol";
import {MockCoord} from "./Retry.t.sol";

contract Reverter {
    receive() external payable {
        revert();
    }
}

contract ClaimTest is Test {
    Pool pool;
    MockCoord coord;
    address a = address(0xA1);
    address b = address(0xB2);
    address c = address(0xC3);

    function _pool(uint256[] memory shares) internal returns (Pool p) {
        IPool.PoolConfig memory w =
            IPool.PoolConfig(shares.length, shares, new uint16[](0), address(0), block.timestamp + 1 days);
        p = PoolClone.make(new Pool(address(coord), bytes32(0), 1), address(this), w);
    }

    function setUp() public {
        coord = new MockCoord();
        uint256[] memory shares = new uint256[](2);
        shares[0] = 7_000;
        shares[1] = 3_000;
        pool = _pool(shares);
        pool.safeMint(a, 1);
        pool.safeMint(b, 2);
        pool.safeMint(c, 3);
        vm.deal(address(pool), 100 ether);
        vm.warp(block.timestamp + 1 days);
        uint256 r = pool.requestWinners();
        coord.fulfill(pool, r, 42);
        pool.pickWinners();
    }

    function _holder(uint256 i) internal view returns (address) {
        return pool.winnerAt(i);
    }

    function test_claimSplitsBySharesAndSnapshotIgnoresTopUp() public {
        address w0 = _holder(0);
        address w1 = _holder(1);
        vm.prank(w0);
        assertEq(pool.claim(0), 70 ether);
        vm.deal(address(pool), address(pool).balance + 50 ether); // top up after first claim
        vm.prank(w1); // still from the 100 snapshot
        assertEq(pool.claim(1), 30 ether);
        assertEq(pool.potSnapshot(), 100 ether);
        assertTrue(pool.allClaimed());
    }

    function test_cannotClaimTwiceOrForOthers() public {
        address w0 = _holder(0);
        vm.prank(address(0xDEAD));
        vm.expectRevert(IPool.NOT_TICKET_OWNER.selector);
        pool.claim(0);
        vm.startPrank(w0);
        pool.claim(0);
        vm.expectRevert(abi.encodeWithSelector(IPool.ALREADY_CLAIMED.selector, 0));
        pool.claim(0);
        vm.stopPrank();
    }

    function test_newTicketHolderClaims() public {
        address w0 = _holder(0);
        uint256 t0 = pool.winners(0);
        vm.prank(w0);
        pool.transferFrom(w0, address(0xBEEF), t0);
        vm.prank(address(0xBEEF));
        pool.claim(0);
        assertEq(address(0xBEEF).balance, 70 ether);
    }

    function test_rescueLockedUntilAllClaimed() public {
        vm.expectRevert("pot locked until winners are paid and the rest rolled over");
        pool.rescueFunds(address(0), address(this), 1);
        vm.prank(_holder(0));
        pool.claim(0);
        vm.expectRevert("pot locked until winners are paid and the rest rolled over");
        pool.rescueFunds(address(0), address(this), 1);
        vm.prank(_holder(1));
        pool.claim(1);
        vm.deal(address(pool), 5 ether); // leftover / late top up
        pool.rescueFunds(address(0), address(0x1234), type(uint256).max);
        assertEq(address(0x1234).balance, 5 ether);
    }

    function test_fewerTicketsThanPositionsLeavesTheRestForRollover() public {
        uint256[] memory shares = new uint256[](3);
        shares[0] = 5_000;
        shares[1] = 3_000;
        shares[2] = 2_000;
        Pool p = _pool(shares);
        p.safeMint(a, 1);
        p.safeMint(b, 2);
        vm.deal(address(p), 100 ether);
        vm.warp(block.timestamp + 1 days);
        coord.fulfill(p, p.requestWinners(), 7);
        p.pickWinners();
        // 2 tickets for 3 positions: 3rd place (20%) has no winner, its share isn't split among the others
        assertEq(p.rolloverAmount(), 20 ether);
        vm.prank(p.winnerAt(0));
        assertEq(p.claim(0), 50 ether);
        vm.prank(p.winnerAt(1));
        assertEq(p.claim(1), 30 ether);
        assertEq(address(p).balance, 20 ether);
    }

    function test_revertingHolderOnlyBlocksItself() public {
        Reverter r = new Reverter();
        address w0 = _holder(0);
        uint256 t0 = pool.winners(0);
        vm.prank(w0);
        pool.transferFrom(w0, address(r), t0);
        vm.prank(address(r));
        vm.expectRevert("prize transfer failed");
        pool.claim(0);
        vm.prank(_holder(1));
        assertEq(pool.claim(1), 30 ether);
    }

    function test_badSharesRejected() public {
        uint256[] memory shares = new uint256[](2);
        shares[0] = 10_000;
        shares[1] = 0;
        IPool.PoolConfig memory w = IPool.PoolConfig(2, shares, new uint16[](0), address(0), block.timestamp + 1 days);
        Pool impl = new Pool(address(coord), bytes32(0), 1);
        vm.expectRevert(IPool.INVALID_WINNER_SHARES.selector);
        this.makeExt(impl, w);
    }

    function makeExt(Pool impl, IPool.PoolConfig memory w) external returns (Pool) {
        return PoolClone.make(impl, address(this), w);
    }
    receive() external payable {}
}
