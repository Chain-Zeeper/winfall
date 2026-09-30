// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.36;
import {Test} from "forge-std/Test.sol";
import "../src/MegaPool.sol";
import {PoolClone} from "./PoolClone.sol";
import {IPool} from "../src/interface/IPool.sol";

contract MockCoord {
    uint256 next = 1;

    function requestRandomWords(VRFV2PlusClient.RandomWordsRequest calldata) external returns (uint256) {
        return next++;
    }

    function fulfill(MegaPool p, uint256 id, uint256 word) external {
        uint256[] memory w = new uint256[](1);
        w[0] = word;
        p.rawFulfillRandomWords(id, w);
    }
}

contract RetryTest is Test {
    MegaPool pool;
    MockCoord coord;

    function setUp() public {
        coord = new MockCoord();
        uint256[] memory shares = new uint256[](1);
        shares[0] = 100;
        IPool.PoolConfig memory w = IPool.PoolConfig(1, shares, address(0), 0, 0, block.timestamp + 1 days, 0, 0, 0);
        pool = PoolClone.make(new MegaPool(address(coord), bytes32(0), 1), address(this), w);
        pool.safeMint(address(0xA1), 1);
        pool.safeMint(address(0xB2), 2);
        vm.warp(block.timestamp + 1 days);
    }

    function test_retryTooEarlyReverts() public {
        pool.requestWinners();
        vm.expectRevert(IPool.DRAW_ALREADY_STARTED.selector);
        pool.requestWinners();
    }

    function test_oldRequestStillCountsAndWinsFirst() public {
        uint256 r1 = pool.requestWinners();
        vm.warp(block.timestamp + 1 days);
        uint256 r2 = pool.requestWinners();
        coord.fulfill(pool, r1, 111); // original answers late -> still accepted
        coord.fulfill(pool, r2, 222); // retry's answer ignored
        assertEq(pool.roundSeed(1), 111); // r1 answered first, its seed is kept
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(MegaPool.RANDOMNESS_ALREADY_FULFILLED.selector);
        pool.requestWinners();
    }

    function test_retryWinsIfFirst() public {
        uint256 r1 = pool.requestWinners();
        vm.warp(block.timestamp + 1 days);
        uint256 r2 = pool.requestWinners();
        coord.fulfill(pool, r2, 222);
        coord.fulfill(pool, r1, 111);
        assertEq(pool.roundSeed(1), 222);
    }

    function test_unknownRequestReverts() public {
        pool.requestWinners();
        vm.expectRevert(abi.encodeWithSelector(MegaPool.UNKNOWN_VRF_REQUEST.selector, 99));
        coord.fulfill(pool, 99, 1);
    }
}
