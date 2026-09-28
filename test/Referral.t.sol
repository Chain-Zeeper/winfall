// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.36;
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Pool} from "../src/Pool.sol";
import "../src/PoolManager.sol";
import {Winfall} from "../src/interface/IPoolManager.sol";
import {MockCoordSub} from "./Manager.t.sol";

contract RTok is ERC20 {
    constructor() ERC20("T", "T") {
        _mint(msg.sender, 1e30);
    }
}

contract Rejecter {
    receive() external payable {
        revert();
    }
}

contract ReferralTest is Test {
    PoolManager mgr;
    RTok tok;
    address treasury = address(0x7EA);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA201);

    function setUp() public {
        MockCoordSub coord = new MockCoordSub();
        mgr = new PoolManager(
            address(this), treasury, address(new Pool(address(coord), bytes32(0), 5)), address(coord), 5
        );
        tok = new RTok();
        vm.deal(bob, 100 ether);
    }

    function _pool(address currency) internal returns (address) {
        uint256[] memory shares = new uint256[](1);
        shares[0] = 1;
        Winfall memory w;
        w.name = "R";
        w.ticketPrice = 1 ether;
        w.paymentToken = currency;
        w.currency = currency;
        w.feeBps = 500;
        w.referralBps = 1_000;
        w.closeTime = block.timestamp + 2 days;
        w.winningShares = shares;
        return mgr.createPool("R", w, 0, 0);
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = a;
    }

    function test_noReferrerCutGoesToPot() public {
        address p = _pool(address(0));
        vm.prank(bob);
        mgr.buyTickets{value: 1 ether}(p, _ids(1), address(0));
        assertEq(p.balance, 0.95 ether);
        assertEq(treasury.balance, 0.05 ether);
        assertEq(mgr.referrerOf(bob), address(0));
    }

    function test_firstReferrerSticks() public {
        address p = _pool(address(0));
        vm.prank(bob);
        mgr.buyTickets{value: 1 ether}(p, _ids(1), alice);
        assertEq(mgr.referrerOf(bob), alice);
        vm.prank(bob); // carol ignored, alice keeps earning
        mgr.buyTickets{value: 1 ether}(p, _ids(2), carol);
        vm.prank(bob);
        mgr.buyTickets{value: 1 ether}(p, _ids(3), address(0));
        assertEq(mgr.referralEarnings(alice, address(0)), 0.3 ether);
        assertEq(mgr.referralEarnings(carol, address(0)), 0);
        assertEq(p.balance, 2.55 ether);
    }

    function test_selfReferralIgnored() public {
        address p = _pool(address(0));
        vm.prank(bob);
        mgr.buyTickets{value: 1 ether}(p, _ids(1), bob);
        assertEq(mgr.referrerOf(bob), address(0));
        assertEq(p.balance, 0.95 ether);
    }

    function test_claimNativeAndToken() public {
        address pe = _pool(address(0));
        address pt = _pool(address(tok));
        vm.prank(bob);
        mgr.buyTickets{value: 1 ether}(pe, _ids(1), alice);
        tok.transfer(bob, 10 ether);
        vm.startPrank(bob);
        tok.approve(address(mgr), 10 ether);
        mgr.buyTickets(pt, _ids(1), address(0));
        vm.stopPrank();

        vm.startPrank(alice);
        assertEq(mgr.claimReferral(address(0)), 0.1 ether);
        assertEq(alice.balance, 0.1 ether);
        assertEq(mgr.claimReferral(address(tok)), 0.1 ether); // bob's tie applies to every pool
        assertEq(tok.balanceOf(alice), 0.1 ether);
        vm.expectRevert(NOTHING_TO_CLAIM.selector);
        mgr.claimReferral(address(0));
        vm.stopPrank();
        assertEq(address(mgr).balance, 0);
        assertEq(tok.balanceOf(address(mgr)), 0);
    }

    function test_referrerThatCantReceiveDoesntBlockBuyers() public {
        address p = _pool(address(0));
        address rej = address(new Rejecter());
        vm.prank(bob);
        mgr.buyTickets{value: 1 ether}(p, _ids(1), rej);
        vm.prank(bob); // still fine
        mgr.buyTickets{value: 1 ether}(p, _ids(2), address(0));
        vm.prank(rej); // only the referrer is stuck
        vm.expectRevert();
        mgr.claimReferral(address(0));
        assertEq(mgr.referralEarnings(rej, address(0)), 0.2 ether);
    }
}
