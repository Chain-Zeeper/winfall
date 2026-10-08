// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {Pool} from "../src/Pool.sol";
import {IPool} from "../src/interface/IPool.sol";
import "../src/PoolManager.sol";
import {Winfall} from "../src/interface/IPoolManager.sol";
import {MockCoordSub} from "./Manager.t.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract StrayToken is ERC20 {
    constructor() ERC20("S", "S") {
        _mint(msg.sender, 1e30);
    }
}

contract AirdropTest is Test {
    MockCoordSub coord;
    PoolManager mgr;
    address pool;
    address buyer = address(0xB0B);

    function setUp() public {
        coord = new MockCoordSub();
        mgr = new PoolManager(
            address(this), address(0x7EA), address(new Pool(address(coord), bytes32(0), 5)), address(coord), 5
        );
        pool = _newPool(0);
        vm.deal(buyer, 100 ether);
    }

    /// native pool, 0.01 ether tickets
    function _newPool(uint16 feeBps) internal returns (address) {
        uint256[] memory shares = new uint256[](1);
        shares[0] = 10_000;
        Winfall memory w;
        w.name = "A";
        w.ticketPrice = 0.01 ether;
        w.feeBps = feeBps;
        w.closeTime = block.timestamp + 2 days;
        w.winningShares = shares;
        return mgr.createPool("A", w);
    }

    /// the protocol puts `amount` more into the pot of `p`
    function _seed(address p, uint256 amount) internal {
        vm.deal(p, p.balance + amount);
    }

    /// buys tickets numbered from..from+n-1 of `p`
    function _buy(address p, uint256 from, uint256 n) internal {
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; i++) {
            ids[i] = from + i;
        }
        vm.prank(buyer);
        mgr.buyTickets{value: 0.01 ether * n}(p, ids, address(0));
    }

    function _drop(address to, uint256 id) internal {
        address[] memory tos = new address[](1);
        uint256[] memory ids = new uint256[](1);
        tos[0] = to;
        ids[0] = id;
        mgr.airdrop(pool, tos, ids);
    }

    function test_countsSoldAndAirdroppedSeparately() public {
        _seed(pool, 0.01 ether);
        _buy(pool, 1, 20);
        _drop(address(0xA11CE), 1001);
        IPool p = IPool(pool);
        assertEq(p.ticketsSold(), 20);
        assertEq(p.ticketsAirdropped(), 1);
        assertEq(Pool(payable(pool)).ownerOf(1001), address(0xA11CE));
        assertEq(pool.balance, 0.21 ether); // seed + sales, the airdrop paid nothing
    }

    /// airdropped tickets can be worth as much as the seeded money: 1 ether seed = 100 tickets of 0.01
    function test_seededMoneyCanBeAirdroppedInFull() public {
        assertEq(mgr.airdropsLeft(pool), 0);
        vm.expectRevert(abi.encodeWithSelector(AIRDROP_LIMIT.selector, 0, 1)); // nothing seeded
        _drop(address(0xA11CE), 1001);

        _seed(pool, 1 ether);
        assertEq(mgr.seededPot(pool), 1 ether);
        assertEq(IPool(pool).ticketsSold(), 0);
        assertEq(mgr.airdropsLeft(pool), 100); // before any sale

        address[] memory tos = new address[](100);
        uint256[] memory ids = new uint256[](100);
        for (uint256 i; i < 100; i++) {
            tos[i] = address(uint160(0x5EED00 + i));
            ids[i] = 1001 + i;
        }
        mgr.airdrop(pool, tos, ids);
        assertEq(IPool(pool).ticketsAirdropped(), 100);
        assertEq(mgr.airdropsLeft(pool), 0);
        vm.expectRevert(abi.encodeWithSelector(AIRDROP_LIMIT.selector, 0, 1));
        _drop(address(0xA11CE), 5000);

        _seed(pool, 0.025 ether); // more seed, more airdrops (rounded down to whole tickets)
        assertEq(mgr.airdropsLeft(pool), 2);
    }

    /// ticket sales are the players' money: they don't add any allowance, with or without a fee
    function test_salesDontAddAllowance() public {
        _buy(pool, 1, 30);
        assertEq(mgr.soldIntoPot(pool), 0.3 ether);
        assertEq(mgr.seededPot(pool), 0);
        assertEq(mgr.airdropsLeft(pool), 0);
        vm.expectRevert(abi.encodeWithSelector(AIRDROP_LIMIT.selector, 0, 1));
        _drop(address(0xA11CE), 1001);

        _seed(pool, 0.03 ether);
        assertEq(mgr.airdropsLeft(pool), 3);
        _buy(pool, 31, 20); // more sales after the seed: still 3
        assertEq(mgr.airdropsLeft(pool), 3);

        address withFee = _newPool(500);
        _buy(withFee, 1, 20);
        assertEq(withFee.balance, 0.19 ether);
        assertEq(mgr.soldIntoPot(withFee), 0.19 ether);
        assertEq(mgr.airdropsLeft(withFee), 0);
    }

    /// money rolled over from another pool is the earlier players' money: it doesn't add allowance either
    function test_rolledOverMoneyDoesntAddAllowance() public {
        _seed(pool, 1 ether); // an unwon pot: nobody bought, so all of it rolls over
        vm.warp(block.timestamp + 2 days);
        mgr.requestWinners(pool);
        address next = _newPool(0);
        assertEq(mgr.rollover(pool, next), 1 ether);
        assertEq(mgr.rolledIn(next), 1 ether);
        assertEq(IPool(next).pot(), 1 ether);
        assertEq(mgr.seededPot(next), 0);
        assertEq(mgr.airdropsLeft(next), 0);

        _seed(next, 0.5 ether); // the protocol seeds 0.5 ether on top
        assertEq(mgr.airdropsLeft(next), 50);
        _buy(next, 1, 20);
        assertEq(mgr.airdropsLeft(next), 50); // sales change nothing
    }

    /// a batch that would cross the cap reverts as a whole, nothing is minted
    function test_batchOverTheCapRevertsWhole() public {
        _seed(pool, 0.02 ether);
        address[] memory tos = new address[](3);
        uint256[] memory ids = new uint256[](3);
        for (uint256 i; i < 3; i++) {
            tos[i] = address(0xA11CE);
            ids[i] = 1001 + i;
        }
        vm.expectRevert(abi.encodeWithSelector(AIRDROP_LIMIT.selector, 2, 3));
        mgr.airdrop(pool, tos, ids);
        assertEq(IPool(pool).ticketsAirdropped(), 0);
        assertFalse(IPool(pool).ticketExists(1001));
    }

    function test_airdroppedTicketsAreInTheDraw() public {
        _seed(pool, 0.01 ether);
        _buy(pool, 1, 10);
        _drop(address(0xA11CE), 1001);
        vm.warp(block.timestamp + 2 days);
        // 11 tickets in the draw: find a seed that picks the airdropped one (index 10)
        uint256 seed;
        while (uint256(keccak256(abi.encode(seed, uint256(0)))) % 11 != 10) {
            seed++;
        }
        coord.fulfill(pool, mgr.requestWinners(pool), seed);
        uint256[] memory w = IPool(pool).pickWinners();
        assertEq(w[0], 1001);
        vm.prank(address(0xA11CE));
        assertEq(IPool(pool).claim(0), 0.11 ether); // the seed that backed it plus the buyers' money
    }

    function test_airdropRules() public {
        _seed(pool, 0.05 ether);
        _buy(pool, 1, 30);
        address[] memory tos = new address[](1);
        uint256[] memory ids = new uint256[](2);
        tos[0] = address(0xA11CE);
        vm.expectRevert(LENGTH_MISMATCH.selector);
        mgr.airdrop(pool, tos, ids);

        vm.expectRevert(abi.encodeWithSelector(IPool.TICKET_TAKEN.selector, 5)); // number already bought
        _drop(address(0xA11CE), 5);

        ids = new uint256[](1);
        ids[0] = 1001;
        vm.prank(buyer);
        vm.expectRevert(); // needs the pool creator role
        mgr.airdrop(pool, tos, ids);

        vm.prank(buyer);
        vm.expectRevert(); // only the manager can call the pool directly
        IPool(pool).airdrop(buyer, 1001);

        vm.expectRevert(abi.encodeWithSelector(UNKNOWN_POOL.selector, address(0xBAD)));
        mgr.airdrop(address(0xBAD), tos, ids);

        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(IPool.POOL_CLOSED.selector); // not after sales closed
        _drop(address(0xA11CE), 1001);
    }

    // ---- taking the seed back ----

    /// a pool that closed without a single ticket gives its seed back
    function test_seedWithdrawableFromClosedPoolWithoutTickets() public {
        _seed(pool, 1 ether);
        vm.expectRevert(POT_LOCKED.selector); // still open: someone could be about to buy
        mgr.rescuePoolFunds(pool, address(0), address(0x5AFE), 1 ether);

        vm.warp(block.timestamp + 2 days);
        assertTrue(IPool(pool).unsoldAndClosed());
        vm.prank(buyer);
        vm.expectRevert(); // admin only
        mgr.rescuePoolFunds(pool, address(0), buyer, 1 ether);

        mgr.rescuePoolFunds(pool, address(0), address(0x5AFE), type(uint256).max);
        assertEq(address(0x5AFE).balance, 1 ether);
        assertEq(pool.balance, 0);
    }

    /// only the seed comes out: money that rolled over into the pool has to roll on
    function test_rolledOverMoneyCantBeWithdrawnAsSeed() public {
        _seed(pool, 1 ether);
        vm.warp(block.timestamp + 2 days);
        mgr.requestWinners(pool);
        address next = _newPool(0);
        mgr.rollover(pool, next); // next holds 1 ether of rolled over money
        _seed(next, 0.5 ether); // plus a 0.5 ether seed
        vm.warp(block.timestamp + 2 days);

        vm.expectRevert(abi.encodeWithSelector(ONLY_SEED_WITHDRAWABLE.selector, 0.5 ether, 0.6 ether));
        mgr.rescuePoolFunds(next, address(0), address(0x5AFE), 0.6 ether);
        mgr.rescuePoolFunds(next, address(0), address(0x5AFE), type(uint256).max);
        assertEq(address(0x5AFE).balance, 0.5 ether);
        assertEq(next.balance, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(ONLY_SEED_WITHDRAWABLE.selector, 0, 1));
        mgr.rescuePoolFunds(next, address(0), address(0x5AFE), 1);

        mgr.requestWinners(next); // the rolled over money can still only roll on
        address third = _newPool(0);
        assertEq(mgr.rollover(next, third), 1 ether);
    }

    /// one ticket, bought or airdropped, and the pot stays for the players
    function test_seedLockedOnceThePoolHasATicket() public {
        _seed(pool, 1 ether);
        _buy(pool, 1, 1);
        address airdropOnly = _newPool(0);
        _seed(airdropOnly, 1 ether);
        address[] memory tos = new address[](1);
        uint256[] memory ids = new uint256[](1);
        tos[0] = address(0xA11CE);
        ids[0] = 1;
        mgr.airdrop(airdropOnly, tos, ids);

        vm.warp(block.timestamp + 2 days);
        assertFalse(IPool(pool).unsoldAndClosed());
        vm.expectRevert(POT_LOCKED.selector);
        mgr.rescuePoolFunds(pool, address(0), address(0x5AFE), 1 ether);
        vm.expectRevert(POT_LOCKED.selector);
        mgr.rescuePoolFunds(airdropOnly, address(0), address(0x5AFE), 1 ether);
    }

    /// once the pot was rolled over, the seed went with it: what's left follows the normal leftover rule
    function test_afterRolloverOnlyLeftoversCanBeRescued() public {
        _seed(pool, 1 ether);
        vm.warp(block.timestamp + 2 days);
        mgr.requestWinners(pool);
        address next = _newPool(0);
        mgr.rollover(pool, next);
        assertFalse(IPool(pool).unsoldAndClosed());
        assertEq(pool.balance, 0);
        vm.deal(pool, 0.3 ether); // a late top up
        mgr.rescuePoolFunds(pool, address(0), address(0x5AFE), type(uint256).max);
        assertEq(address(0x5AFE).balance, 0.3 ether);
    }

    /// only the pot currency is restricted: any other token (or stray native coin in a token pool) can be
    /// rescued at any time, even while the pool is open and has tickets
    function test_otherTokensCanAlwaysBeRescued() public {
        StrayToken stray = new StrayToken();
        _seed(pool, 1 ether);
        _buy(pool, 1, 5); // open, with tickets: the bnb pot is locked
        stray.transfer(pool, 100e18);
        vm.expectRevert(POT_LOCKED.selector);
        mgr.rescuePoolFunds(pool, address(0), address(0x5AFE), 1);
        mgr.rescuePoolFunds(pool, address(stray), address(0x5AFE), 40e18);
        mgr.rescuePoolFunds(pool, address(stray), address(0x5AFE), type(uint256).max);
        assertEq(stray.balanceOf(address(0x5AFE)), 100e18);
        assertEq(pool.balance, 1.05 ether); // the pot is untouched

        // a pool whose pot is a token: stray bnb comes out freely, the token pot doesn't
        uint256[] memory shares = new uint256[](1);
        shares[0] = 10_000;
        Winfall memory w;
        w.name = "T";
        w.ticketPrice = 1e18;
        w.paymentToken = address(stray);
        w.currency = address(stray);
        w.closeTime = block.timestamp + 2 days;
        w.winningShares = shares;
        address tokenPool = mgr.createPool("T", w);
        stray.transfer(buyer, 10e18);
        vm.startPrank(buyer);
        stray.approve(address(mgr), 10e18);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        mgr.buyTickets(tokenPool, ids, address(0));
        vm.stopPrank();
        vm.deal(tokenPool, 2 ether);
        mgr.rescuePoolFunds(tokenPool, address(0), address(0xBEEF), type(uint256).max);
        assertEq(address(0xBEEF).balance, 2 ether);
        vm.expectRevert(POT_LOCKED.selector);
        mgr.rescuePoolFunds(tokenPool, address(stray), address(0xBEEF), 1);
    }
}
