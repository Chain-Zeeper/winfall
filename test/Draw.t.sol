// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.36;
import {Test} from "forge-std/Test.sol";
import "../src/MegaPool.sol";
import {IPool} from "../src/interface/IPool.sol";
import {PoolClone} from "./PoolClone.sol";
import {MockCoord} from "./Retry.t.sol";

contract DrawTest is Test {
    MockCoord coord;
    MegaPool impl;

    function setUp() public {
        coord = new MockCoord();
        impl = new MegaPool(address(coord), bytes32(0), 1);
    }

    function _drawn(uint256 tickets, uint256 winnersN, uint256 seed)
        internal
        returns (MegaPool p, uint256[] memory w, uint256 gasUsed)
    {
        uint256[] memory shares = new uint256[](winnersN);
        for (uint256 i; i < winnersN; i++) {
            shares[i] = 1;
        }
        p = PoolClone.make(
            impl, address(this), IPool.PoolConfig(winnersN, shares, address(0), 0, 0, block.timestamp + 1 days, 0, 0, 0)
        );
        // non sequential ids
        for (uint256 i = 1; i <= tickets; i++) {
            p.safeMint(address(uint160(0x10000 + i)), i * 7);
        }
        vm.warp(block.timestamp + 1 days);
        coord.fulfill(p, p.requestWinners(), seed);
        uint256 g = gasleft();
        w = p.pickWinners();
        gasUsed = g - gasleft();
    }

    /// reference: the old implementation, full copy + real swaps
    function _reference(uint256[] memory tickets, uint256 count, uint256 seed)
        internal
        pure
        returns (uint256[] memory out)
    {
        out = new uint256[](count);
        uint256 total = tickets.length;
        for (uint256 i; i < count; i++) {
            uint256 j = i + (uint256(keccak256(abi.encode(seed, i))) % (total - i));
            (tickets[i], tickets[j]) = (tickets[j], tickets[i]);
            out[i] = tickets[i];
        }
    }

    function testFuzz_matchesFullCopyAndDistinct(uint256 seed, uint8 t, uint8 n) public {
        uint256 tickets = bound(t, 1, 60);
        uint256 winnersN = bound(n, 1, 12);
        (, uint256[] memory w,) = _drawn(tickets, winnersN, seed);
        uint256[] memory all = new uint256[](tickets);
        for (uint256 i; i < tickets; i++) {
            all[i] = (1 << 128) | ((i + 1) * 7); // round 1 nft ids
        }
        uint256 count = winnersN > tickets ? tickets : winnersN;
        uint256[] memory ref = _reference(all, count, seed);
        assertEq(w.length, count);
        for (uint256 i; i < count; i++) {
            assertEq(w[i], ref[i]);
            for (uint256 k; k < i; k++) {
                assertTrue(w[i] != w[k]);
            }
        }
    }

    function test_gasDoesNotGrowWithTickets() public {
        (,, uint256 small) = _drawn(50, 5, 123);
        (,, uint256 big) = _drawn(3000, 5, 123);
        emit log_named_uint("pickWinners gas, 50 tickets", small);
        emit log_named_uint("pickWinners gas, 3000 tickets", big);
        assertLt(big, small * 11 / 10);
    }
}
