// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.36;
import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {Pool} from "../src/Pool.sol";
import {PoolManager, INVALID_CLOSE_TIME, UNKNOWN_POOL, VRF_CONFIG_MISMATCH} from "../src/PoolManager.sol";
import {Winfall} from "../src/interface/IPoolManager.sol";
import {IPool} from "../src/interface/IPool.sol";

contract MockCoordSub {
    uint256 next = 1;
    mapping(address => bool) public consumer;

    function requestRandomWords(VRFV2PlusClient.RandomWordsRequest calldata) external returns (uint256) {
        require(consumer[msg.sender], "not consumer");
        return next++;
    }

    function addConsumer(uint256, address c) external {
        consumer[c] = true;
    }

    function removeConsumer(uint256, address c) external {
        consumer[c] = false;
    }

    function fulfill(address p, uint256 id, uint256 word) external {
        uint256[] memory w = new uint256[](1);
        w[0] = word;
        Pool(payable(p)).rawFulfillRandomWords(id, w);
    }
}

contract ManagerTest is Test {
    MockCoordSub coord;
    Pool impl;
    PoolManager mgr;

    function setUp() public {
        coord = new MockCoordSub();
        impl = new Pool(address(coord), bytes32(0), 5);
        mgr = new PoolManager(address(this), address(0x7EA), address(impl), address(coord), 5);
    }

    function _w(uint256 close) internal pure returns (Winfall memory w) {
        uint256[] memory shares = new uint256[](2);
        shares[0] = 7_000;
        shares[1] = 3_000;
        w.name = "Winfall #1";
        w.ticketPrice = 1 ether;
        w.closeTime = close;
        w.winningShares = shares;
    }

    function test_createPoolClonesAndRegisters() public {
        address p = mgr.createPool("WF1", _w(block.timestamp + 2 days), 10 ether, 0);
        assertEq(Pool(payable(p)).owner(), address(mgr));
        assertEq(Pool(payable(p)).name(), "Winfall #1");
        assertEq(IPool(p).getConfig().totalWinners, 2);
        assertTrue(coord.consumer(p));
        assertEq(mgr.winfalls(p).pool, p);
        assertEq(mgr.winfalls(p).winningShares[0], 7_000);
        assertEq(mgr.totalPools(), 1);
        assertLt(p.code.length, 100); // minimal proxy
    }

    function test_fullRoundThroughManager() public {
        address p = mgr.createPool("WF1", _w(block.timestamp + 2 days), 0, 0);
        vm.prank(address(mgr));
        IPool(p).safeMint(address(0xA11CE), 1);
        vm.prank(address(mgr));
        IPool(p).safeMint(address(0xB0B), 2);
        vm.deal(p, 10 ether);
        vm.warp(block.timestamp + 2 days);
        uint256 r = mgr.requestWinners(p);
        coord.fulfill(p, r, 3);
        IPool(p).pickWinners();
        mgr.releaseVrfConsumer(p); // only once the draw is final, a Pool could still roll over before
        assertFalse(coord.consumer(p));
        assertEq(IPool(p).distribute(10), 2);
        assertEq(address(0xA11CE).balance + address(0xB0B).balance, 10 ether);
        assertEq(p.balance, 0); // paid out
        assertEq(mgr.getPrizePool(p), 10 ether); // still reports the pot that was played for
    }

    function test_rejects() public {
        vm.expectRevert(INVALID_CLOSE_TIME.selector);
        mgr.createPool("X", _w(block.timestamp + 1 hours), 0, 0);
        vm.expectRevert(abi.encodeWithSelector(UNKNOWN_POOL.selector, address(0xBAD)));
        mgr.requestWinners(address(0xBAD));
        Pool other = new Pool(address(coord), bytes32(0), 999);
        vm.expectRevert(VRF_CONFIG_MISMATCH.selector);
        mgr.setPoolImplementation(address(other));
        vm.prank(address(0xE71));
        vm.expectRevert();
        mgr.createPool("X", _w(block.timestamp + 2 days), 0, 0);
    }

    function test_rolesCreatorsCanRunPoolsButNotAdminActions() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        bytes32 creator = mgr.POOL_CREATOR_ROLE();
        mgr.grantRole(creator, alice);
        mgr.grantRole(creator, bob);

        vm.prank(alice);
        address p1 = mgr.createPool("A", _w(block.timestamp + 2 days), 0, 0);
        vm.prank(bob);
        address p2 = mgr.createPool("B", _w(block.timestamp + 2 days), 0, 0);
        assertEq(mgr.totalPools(), 2);

        // bob can run alice's pool too, roles are manager wide
        vm.prank(address(mgr));
        IPool(p1).safeMint(address(0x1111), 1);
        vm.warp(block.timestamp + 2 days);
        vm.prank(bob);
        mgr.requestWinners(p1);

        // creators can't do admin actions
        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        mgr.rescuePoolFunds(p2, address(0), alice, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        mgr.setPoolImplementation(address(impl));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        mgr.grantRole(creator, address(0xE71));
        vm.stopPrank();

        // revoke works
        mgr.revokeRole(creator, bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bob, creator));
        mgr.createPool("C", _w(block.timestamp + 2 days), 0, 0);
    }
}
