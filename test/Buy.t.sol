// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.36;
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Pool} from "../src/Pool.sol";
import {IPool} from "../src/interface/IPool.sol";
import {
    PoolManager,
    POOL_CLOSED,
    UNKNOWN_POOL,
    WRONG_PAYMENT,
    INVALID_FEES,
    INVALID_TICKET_PRICE
} from "../src/PoolManager.sol";
import {Winfall} from "../src/interface/IPoolManager.sol";
import {MockCoordSub} from "./Manager.t.sol";

contract Tok is ERC20 {
    constructor() ERC20("T", "T") {
        _mint(msg.sender, 1e30);
    }
}

contract BuyTest is Test {
    MockCoordSub coord;
    PoolManager mgr;
    Tok tok;
    address ref = address(0x5E5);
    address treasury = address(0x7EA);
    address buyer = address(0xB0B);

    function setUp() public {
        coord = new MockCoordSub();
        Pool impl = new Pool(address(coord), bytes32(0), 5);
        mgr = new PoolManager(address(this), treasury, address(impl), address(coord), 5);
        tok = new Tok();
    }

    function _w(address currency, uint256 price, uint16 fee, uint16 res) internal view returns (Winfall memory w) {
        uint256[] memory shares = new uint256[](1);
        shares[0] = 10_000;
        w.name = "W";
        w.ticketPrice = price;
        w.currency = currency;
        w.paymentToken = currency;
        w.feeBps = fee;
        w.referralBps = res;
        w.closeTime = block.timestamp + 2 days;
        w.winningShares = shares;
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = a;
    }

    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = b;
    }

    function _ids(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory r) {
        r = new uint256[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }

    function test_buyEthSplitsFees() public {
        // 5% protocol, 10% referral
        address p = mgr.createPool("W", _w(address(0), 1 ether, 500, 1_000), 0, 0);
        vm.deal(buyer, 3 ether);
        vm.prank(buyer);
        mgr.buyTickets{value: 3 ether}(p, _ids(7, 777, 42), ref);
        assertEq(treasury.balance, 0.15 ether);
        assertEq(mgr.referralEarnings(ref, address(0)), 0.3 ether);
        assertEq(p.balance, 2.55 ether);
        assertEq(address(mgr).balance, 0.3 ether); // referral earnings wait to be claimed
        assertEq(Pool(payable(p)).ownerOf(777), buyer);
        assertEq(Pool(payable(p)).ticketsMinted(), 3);
    }

    function test_buyTokenSplitsFees() public {
        address p = mgr.createPool("W", _w(address(tok), 100e18, 500, 1_000), 0, 0);
        tok.transfer(buyer, 200e18);
        vm.startPrank(buyer);
        tok.approve(address(mgr), 200e18);
        mgr.buyTickets(p, _ids(1, 2), ref);
        vm.stopPrank();
        assertEq(tok.balanceOf(treasury), 10e18);
        assertEq(mgr.referralEarnings(ref, address(tok)), 20e18);
        assertEq(tok.balanceOf(p), 170e18);
        assertEq(tok.balanceOf(address(mgr)), 20e18);
    }

    function test_buyRejects() public {
        address p = mgr.createPool("W", _w(address(0), 1 ether, 0, 0), 0, 0);
        vm.deal(buyer, 10 ether);
        vm.startPrank(buyer);
        vm.expectRevert(abi.encodeWithSelector(WRONG_PAYMENT.selector, 2 ether, 1 ether));
        mgr.buyTickets{value: 1 ether}(p, _ids(1, 2), ref);
        vm.expectRevert(abi.encodeWithSelector(UNKNOWN_POOL.selector, address(0xBAD)));
        mgr.buyTickets{value: 1 ether}(address(0xBAD), _ids(1), ref);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(POOL_CLOSED.selector);
        mgr.buyTickets{value: 1 ether}(p, _ids(1), ref);
        vm.stopPrank();
        address t = mgr.createPool("W", _w(address(tok), 1e18, 0, 0), 0, 0);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(WRONG_PAYMENT.selector, 0, 1));
        mgr.buyTickets{value: 1}(t, _ids(1), ref);
    }

    function test_createRejectsBadFeesAndPrice() public {
        vm.expectRevert(INVALID_FEES.selector);
        mgr.createPool("W", _w(address(0), 1 ether, 5_001, 0), 0, 0);
        vm.expectRevert(INVALID_FEES.selector);
        mgr.createPool("W", _w(address(0), 1 ether, 5_000, 5_001), 0, 0);
        vm.expectRevert(INVALID_TICKET_PRICE.selector);
        mgr.createPool("W", _w(address(0), 0, 0, 0), 0, 0);
    }

    function test_onlyManagerCanMint() public {
        address p = mgr.createPool("W", _w(address(0), 1 ether, 0, 0), 0, 0);
        vm.prank(buyer);
        vm.expectRevert();
        Pool(payable(p)).safeMint(buyer, 99);
    }

    function test_treasuryAdminOnly() public {
        vm.prank(buyer);
        vm.expectRevert();
        mgr.setFeeTreasury(buyer);
        mgr.setFeeTreasury(address(0x9));
        assertEq(mgr.feeTreasury(), address(0x9));
    }

    function test_takenTicketsRevertWholeBatchAndCanBeChecked() public {
        address p = mgr.createPool("W", _w(address(0), 1 ether, 0, 0), 0, 0);
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        mgr.buyTickets{value: 1 ether}(p, _ids(7), ref);

        assertTrue(IPool(p).ticketExists(7));
        assertFalse(IPool(p).ticketExists(8));

        address other = address(0x0DD);
        vm.deal(other, 10 ether);
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(IPool.TICKET_TAKEN.selector, 7));
        mgr.buyTickets{value: 2 ether}(p, _ids(8, 7), ref); // 7 taken -> 8 not bought either
        assertFalse(IPool(p).ticketExists(8));
        assertEq(other.balance, 10 ether); // nothing charged

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(IPool.TICKET_TAKEN.selector, 9));
        mgr.buyTickets{value: 2 ether}(p, _ids(9, 9), ref); // duplicate inside one batch
    }
}
