// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.36;
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pool} from "../src/Pool.sol";
import "../src/PoolManager.sol";
import {PancakeV3Swapper, INVALID_TWAP_WINDOW} from "../src/PancakeV3Swapper.sol";
import {ISwapper} from "../src/interface/ISwapper.sol";
import {Winfall} from "../src/interface/IPoolManager.sol";
import {IV3SwapRouter} from "../src/interface/IV3SwapRouter.sol";
import {MockCoordSub} from "./Manager.t.sol";

contract Tok is ERC20 {
    constructor(string memory n) ERC20(n, n) {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// observe() as if the pool sat at `tick` with `liquidity` for its whole history
contract MockV3Pool {
    int24 public tick;
    uint128 public liquidity = 1e20;
    bool public tooYoung;

    function set(int24 t) external {
        tick = t;
    }

    function setLiquidity(uint128 l) external {
        liquidity = l;
    }

    function setTooYoung(bool v) external {
        tooYoung = v;
    }

    function observe(uint32[] calldata ago) external view returns (int56[] memory c, uint160[] memory s) {
        require(!tooYoung, "OLD");
        c = new int56[](ago.length);
        s = new uint160[](ago.length);
        for (uint256 i; i < ago.length; i++) {
            uint256 t = 1_000_000 - ago[i];
            c[i] = int56(tick) * int56(uint56(t));
            s[i] = uint160((t << 128) / liquidity);
        }
    }
}

contract WNative is Tok {
    constructor() Tok("WBNB") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 a) external {
        _burn(msg.sender, a);
        payable(msg.sender).transfer(a);
    }
}

contract MockFactory {
    mapping(address => mapping(address => mapping(uint24 => address))) public getPool;

    function add(address a, address b, uint24 fee, address p) external {
        getPool[a][b][fee] = p;
        getPool[b][a][fee] = p;
    }
}

/// pays amountIn * num / den of tokenOut per (tokenIn, tokenOut), like pools whose spot price is num/den
contract MockRouter {
    mapping(address => mapping(address => uint256[2])) public rate;
    bytes public lastPath;

    function setRate(address a, address b, uint256 n, uint256 d) external {
        rate[a][b] = [n, d];
    }

    function exactOutput(IV3SwapRouter.ExactOutputParams calldata p) external payable returns (uint256 amountIn) {
        lastPath = p.path;
        address tokenOut = address(bytes20(p.path[:20]));
        address tokenIn = address(bytes20(p.path[p.path.length - 20:]));
        uint256[2] memory r = rate[tokenIn][tokenOut];
        amountIn = (p.amountOut * r[1] + r[0] - 1) / r[0];
        require(amountIn <= p.amountInMaximum, "Too much requested");
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        Tok(tokenOut).mint(p.recipient, p.amountOut);
    }
}

contract SwapTest is Test {
    Tok usdt;
    Tok btc;
    WNative wbnb;
    Tok doge;
    MockFactory factory;
    MockRouter router;
    MockV3Pool btcPool;
    MockV3Pool bnbPool;
    MockV3Pool bnbBtcPool;
    PancakeV3Swapper swapper;
    PoolManager mgr;
    address ref = address(0x5E5);
    address treasury = address(0x7EA);
    address buyer = address(0xB0B);

    function _tick(address base, address quote, int24 up, int24 down) internal pure returns (int24) {
        return base < quote ? up : down; // `up` when token0 is base (price = quote per base)
    }

    function setUp() public {
        usdt = new Tok("USDT");
        btc = new Tok("BTCB");
        wbnb = new WNative();
        doge = new Tok("DOGE");
        factory = new MockFactory();
        router = new MockRouter();
        btcPool = new MockV3Pool();
        bnbPool = new MockV3Pool();
        bnbBtcPool = new MockV3Pool();
        // btc = 60000 usdt, bnb = 600 usdt -> 1 btc = 100 bnb
        btcPool.set(_tick(address(btc), address(usdt), 110026, -110027));
        bnbPool.set(_tick(address(wbnb), address(usdt), 63972, -63973));
        bnbBtcPool.set(_tick(address(btc), address(wbnb), 46054, -46055));
        factory.add(address(usdt), address(btc), 500, address(btcPool));
        factory.add(address(usdt), address(wbnb), 500, address(bnbPool));
        factory.add(address(wbnb), address(btc), 2500, address(bnbBtcPool));

        address[] memory hubs = new address[](1);
        hubs[0] = address(wbnb);
        swapper = new PancakeV3Swapper(address(this), address(router), address(factory), address(wbnb), hubs);

        MockCoordSub coord = new MockCoordSub();
        Pool impl = new Pool(address(coord), bytes32(0), 5);
        mgr = new PoolManager(address(this), treasury, address(impl), address(coord), 5);
        mgr.setSwapper(address(swapper));
        router.setRate(address(usdt), address(btc), 1, 60000);
        router.setRate(address(btc), address(usdt), 60000, 1);
        router.setRate(address(wbnb), address(usdt), 600, 1);
        router.setRate(address(wbnb), address(btc), 1, 100);
        vm.deal(address(wbnb), 1_000_000 ether); // backing for withdraw of minted mock wbnb
        usdt.mint(buyer, 1_000_000e18);
        vm.prank(buyer);
        usdt.approve(address(mgr), type(uint256).max);
    }

    function _w(address pay, address pot) internal view returns (Winfall memory w) {
        uint256[] memory shares = new uint256[](1);
        shares[0] = 10_000;
        w.name = "BTC pot";
        w.ticketPrice = 100e18;
        w.paymentToken = pay;
        w.currency = pot;
        w.feeBps = 500;
        w.referralBps = 100;
        w.closeTime = block.timestamp + 2 days;
        w.winningShares = shares;
    }

    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = b;
    }

    function _direct(uint24 fee) internal view returns (bytes memory) {
        return abi.encodePacked(address(usdt), fee, address(btc));
    }

    // ---- routing ----

    function test_findsDirectRoute() public view {
        assertEq(swapper.findRoute(address(usdt), address(btc)), _direct(500));
    }

    function test_picksFeeTierWithMostTimeWeightedLiquidity() public {
        MockV3Pool deep = new MockV3Pool();
        deep.set(btcPool.tick());
        deep.setLiquidity(1e24);
        factory.add(address(usdt), address(btc), 2500, address(deep));
        assertEq(swapper.findRoute(address(usdt), address(btc)), _direct(2500));
        deep.setLiquidity(1e10); // shallower than the 0.05% pool now
        assertEq(swapper.findRoute(address(usdt), address(btc)), _direct(500));
    }

    function test_skipsPoolsTooYoungForWindow() public {
        MockV3Pool young = new MockV3Pool();
        young.set(btcPool.tick());
        young.setLiquidity(1e30);
        young.setTooYoung(true);
        factory.add(address(usdt), address(btc), 100, address(young));
        assertEq(swapper.findRoute(address(usdt), address(btc)), _direct(500));
    }

    function test_routesThroughHubWithoutDirectPool() public {
        factory.add(address(usdt), address(btc), 500, address(0)); // remove direct pool
        assertEq(
            swapper.findRoute(address(usdt), address(btc)),
            abi.encodePacked(address(usdt), uint24(500), address(wbnb), uint24(2500), address(btc))
        );
    }

    function test_noRouteReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ISwapper.NO_ROUTE.selector, address(usdt), address(doge)));
        swapper.findRoute(address(usdt), address(doge));
        vm.expectRevert(abi.encodeWithSelector(ISwapper.NO_ROUTE.selector, address(usdt), address(doge)));
        mgr.createPool("X", _w(address(usdt), address(doge)));
    }

    // ---- twap ----

    function test_twapQuoteMatchesPrice() public view {
        assertApproxEqRel(swapper.quote(_direct(500), 60000e18), 1e18, 0.0002e18);
        bytes memory viaBnb = abi.encodePacked(address(usdt), uint24(500), address(wbnb), uint24(2500), address(btc));
        assertApproxEqRel(swapper.quote(viaBnb, 60000e18), 1e18, 0.0003e18);
    }

    // ---- cross currency pools: 100 usdt tickets, 5% fee, btc pot ----

    /// what the pot is owed for 2 tickets: the btc that 190 usdt are worth at the twap
    function _potAmount() internal view returns (uint256) {
        return swapper.quote(_direct(500), 190e18);
    }

    function test_crossCurrencyPoolNeedsBuyTicketsWith() public {
        address p = mgr.createPool("BTC", _w(address(usdt), address(btc)));
        assertEq(mgr.swapRoute(p), _direct(500));
        vm.prank(buyer);
        vm.expectRevert(USE_BUY_TICKETS_WITH.selector); // no price limit, no market purchase
        mgr.buyTickets(p, _ids(1, 2), ref);
    }

    function test_payInPaymentToken_potGetsTheTwapAmount() public {
        address p = mgr.createPool("BTC", _w(address(usdt), address(btc)));
        uint256 owed = _potAmount();
        assertApproxEqRel(owed, uint256(190e18) / 60000, 0.0002e18);

        uint256 before = usdt.balanceOf(buyer);
        vm.prank(buyer);
        mgr.buyTicketsWith(p, _ids(1, 2), address(usdt), 250e18, block.timestamp, ref);

        assertEq(btc.balanceOf(p), owed); // exactly what it's owed
        assertEq(mgr.soldIntoPot(p), owed);
        assertEq(usdt.balanceOf(treasury), 8e18); // 10 usdt fee, 2 of it to the referrer
        assertEq(mgr.referralEarnings(ref, address(usdt)), 2e18);
        // the buyer paid the fee plus what the btc cost on the market, the rest of the 250 came back
        uint256 spent = before - usdt.balanceOf(buyer);
        assertEq(spent, 10e18 + owed * 60000);
        assertApproxEqRel(spent, 200e18, 0.0002e18);
        assertEq(Pool(payable(p)).ownerOf(2), buyer);
        _assertNothingLeft();
    }

    /// a pushed price can't shortchange the pot and can't block the purchase: it only changes what the buyer pays
    function test_marketPriceOnlyChangesWhatTheBuyerPays() public {
        address p = mgr.createPool("BTC", _w(address(usdt), address(btc)));
        uint256 owed = _potAmount();

        router.setRate(address(usdt), address(btc), 98, 100 * 60000); // btc 2% more expensive than the twap
        uint256 before = usdt.balanceOf(buyer);
        vm.prank(buyer);
        mgr.buyTicketsWith(p, _ids(1, 2), address(usdt), 250e18, block.timestamp, ref);
        assertEq(btc.balanceOf(p), owed); // the pot still gets all of it
        uint256 spent = before - usdt.balanceOf(buyer);
        assertGt(spent, 203e18); // 10 + 190 / 0.98
        assertLt(spent, 204.5e18);

        vm.prank(buyer); // the buyer's own limit is the only thing that stops a purchase: the pot's btc fits in 201,
        vm.expectPartialRevert(MAX_AMOUNT_IN_EXCEEDED.selector); // the 10 usdt fee on top doesn't
        mgr.buyTicketsWith(p, _ids(3, 4), address(usdt), 201e18, block.timestamp, ref);
        vm.prank(buyer); // and a limit below the btc's cost stops it at the swap
        vm.expectRevert(bytes("Too much requested"));
        mgr.buyTicketsWith(p, _ids(3, 4), address(usdt), 190e18, block.timestamp, ref);

        router.setRate(address(usdt), address(btc), 102, 100 * 60000); // btc 2% cheaper than the twap
        before = usdt.balanceOf(buyer);
        vm.prank(buyer);
        mgr.buyTicketsWith(p, _ids(3, 4), address(usdt), 250e18, block.timestamp, ref);
        assertEq(btc.balanceOf(p), 2 * owed);
        assertLt(before - usdt.balanceOf(buyer), 197e18); // 10 + 190 / 1.02
        _assertNothingLeft();
    }

    /// paying with the pot currency: the pot part isn't swapped, only the fee is
    function test_payWithPotCurrency() public {
        address p = mgr.createPool("BTC", _w(address(usdt), address(btc)));
        uint256 owed = _potAmount();
        btc.mint(buyer, 1e18);
        vm.startPrank(buyer);
        btc.approve(address(mgr), 1e18);
        mgr.buyTicketsWith(p, _ids(1, 2), address(btc), 0.01e18, block.timestamp, ref);
        vm.stopPrank();
        assertEq(btc.balanceOf(p), owed);
        uint256 feeCost = (uint256(10e18) + 59999) / 60000; // 10 usdt of fee bought with btc
        assertEq(btc.balanceOf(buyer), 1e18 - owed - feeCost);
        assertEq(usdt.balanceOf(treasury), 8e18);
        assertEq(mgr.referralEarnings(ref, address(usdt)), 2e18);
        _assertNothingLeft();
    }

    /// paying with a third token: it buys the pot's btc and the fee's usdt directly
    function test_payWithWbnbToken() public {
        address p = mgr.createPool("BTC", _w(address(usdt), address(btc)));
        uint256 owed = _potAmount();
        wbnb.mint(buyer, 5e18);
        vm.startPrank(buyer);
        wbnb.approve(address(mgr), 5e18);
        mgr.buyTicketsWith(p, _ids(1, 2), address(wbnb), 1e18, block.timestamp, ref); // ~1/3 bnb needed, max 1
        vm.stopPrank();
        uint256 spent = owed * 100 + (uint256(10e18) + 599) / 600; // btc at 100 bnb, fee at 600 usdt per bnb
        assertEq(wbnb.balanceOf(buyer), 5e18 - spent); // unspent refunded
        assertEq(btc.balanceOf(p), owed);
        assertEq(usdt.balanceOf(treasury), 8e18);
        assertEq(mgr.referralEarnings(ref, address(usdt)), 2e18);
        assertEq(Pool(payable(p)).ownerOf(1), buyer);
        _assertNothingLeft();
    }

    function test_payWithNativeBnb() public {
        address p = mgr.createPool("BTC", _w(address(usdt), address(btc)));
        uint256 owed = _potAmount();
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        mgr.buyTicketsWith{value: 1 ether}(p, _ids(1, 2), address(0), 1 ether, block.timestamp, ref);
        assertEq(buyer.balance, 1 ether - owed * 100 - (uint256(10e18) + 599) / 600); // native refund
        assertEq(btc.balanceOf(p), owed);
        assertEq(usdt.balanceOf(treasury), 8e18);
        _assertNothingLeft();
    }

    /// native bnb into a wbnb pot: the pot part is only wrapped, the fee is swapped
    function test_payNativeIntoWrappedNativePot() public {
        address p = mgr.createPool("BNB", _w(address(usdt), address(wbnb)));
        uint256 owed = swapper.quote(abi.encodePacked(address(usdt), uint24(500), address(wbnb)), 190e18);
        assertApproxEqRel(owed, uint256(190e18) / 600, 0.0002e18);
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        mgr.buyTicketsWith{value: 1 ether}(p, _ids(1, 2), address(0), 1 ether, block.timestamp, ref);
        assertEq(wbnb.balanceOf(p), owed);
        assertEq(buyer.balance, 1 ether - owed - (uint256(10e18) + 599) / 600);
        assertEq(usdt.balanceOf(treasury), 8e18);
        _assertNothingLeft();
    }

    function test_refreshRoute() public {
        address p = mgr.createPool("BTC", _w(address(usdt), address(btc)));
        MockV3Pool deep = new MockV3Pool();
        deep.set(btcPool.tick());
        deep.setLiquidity(1e24);
        factory.add(address(usdt), address(btc), 2500, address(deep));
        assertEq(mgr.swapRoute(p), _direct(500)); // stored route doesn't move by itself
        mgr.refreshSwapRoute(p);
        assertEq(mgr.swapRoute(p), _direct(2500));
        vm.prank(buyer);
        vm.expectRevert();
        mgr.refreshSwapRoute(p);
    }

    function test_configChecks() public {
        vm.expectRevert(NATIVE_SWAP_UNSUPPORTED.selector);
        mgr.createPool("X", _w(address(usdt), address(0)));
        vm.expectRevert(INVALID_TWAP_WINDOW.selector);
        swapper.setTwapWindow(60);
        vm.startPrank(buyer);
        vm.expectRevert();
        swapper.setTwapWindow(600);
        vm.expectRevert();
        swapper.setHubs(new address[](0));
        vm.expectRevert();
        mgr.setSwapper(address(1));
        vm.stopPrank();
    }

    function test_swapperNeededForCrossCurrencyPools() public {
        MockCoordSub coord = new MockCoordSub();
        PoolManager bare = new PoolManager(
            address(this), treasury, address(new Pool(address(coord), bytes32(0), 5)), address(coord), 5
        );
        vm.expectRevert(SWAPPER_NOT_SET.selector);
        bare.createPool("X", _w(address(usdt), address(btc)));
    }

    function test_buyWithRejects() public {
        address p = mgr.createPool("BTC", _w(address(usdt), address(btc)));
        wbnb.mint(buyer, 5e18);
        btc.mint(buyer, 1e18);
        vm.startPrank(buyer);
        wbnb.approve(address(mgr), 5e18);
        btc.approve(address(mgr), 1e18);
        vm.expectRevert(bytes("Too much requested")); // max below what the pot's btc costs
        mgr.buyTicketsWith(p, _ids(1, 2), address(wbnb), 0.3e18, block.timestamp, ref);
        uint256 owed = _potAmount();
        vm.expectRevert(abi.encodeWithSelector(MAX_AMOUNT_IN_EXCEEDED.selector, owed - 1, owed)); // same, no swap
        mgr.buyTicketsWith(p, _ids(1, 2), address(btc), owed - 1, block.timestamp, ref);
        vm.expectRevert(EXPIRED.selector);
        mgr.buyTicketsWith(p, _ids(1, 2), address(wbnb), 1e18, block.timestamp - 1, ref);
        vm.deal(buyer, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(WRONG_PAYMENT.selector, 2 ether, 1 ether));
        mgr.buyTicketsWith{value: 1 ether}(p, _ids(1, 2), address(0), 2 ether, block.timestamp, ref);
        doge.mint(buyer, 1e18);
        doge.approve(address(mgr), 1e18);
        vm.expectRevert(abi.encodeWithSelector(ISwapper.NO_ROUTE.selector, address(doge), address(btc)));
        mgr.buyTicketsWith(p, _ids(1, 2), address(doge), 1e18, block.timestamp, ref);
        vm.stopPrank();
        assertEq(btc.balanceOf(p), 0); // nothing went through
        assertEq(wbnb.balanceOf(buyer), 5e18);
    }

    // ---- same currency pools paid with another token ----

    function test_sameCurrencyPoolPaidWithNative() public {
        address p = mgr.createPool("USDT", _w(address(usdt), address(usdt)));
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        mgr.buyTicketsWith{value: 1 ether}(p, _ids(1, 2), address(0), 1 ether, block.timestamp, ref);
        assertEq(usdt.balanceOf(p), 190e18);
        assertEq(buyer.balance, 1 ether - (uint256(200e18) + 599) / 600);
        assertEq(usdt.balanceOf(treasury), 8e18);
        vm.prank(buyer); // paying in the pool's own token is what buyTickets is for
        vm.expectRevert(USE_BUY_TICKETS.selector);
        mgr.buyTicketsWith(p, _ids(3, 4), address(usdt), 250e18, block.timestamp, ref);
        _assertNothingLeft();
    }

    function test_twoHopExactOutUsesReversedPath() public {
        address p = mgr.createPool("USDT", _w(address(usdt), address(usdt)));
        MockV3Pool dogePool = new MockV3Pool();
        factory.add(address(doge), address(wbnb), 10000, address(dogePool));
        router.setRate(address(doge), address(usdt), 1, 10); // 1 doge = 0.1 usdt
        doge.mint(buyer, 10_000e18);
        vm.startPrank(buyer);
        doge.approve(address(mgr), 10_000e18);
        mgr.buyTicketsWith(p, _ids(1, 2), address(doge), 3_000e18, block.timestamp, ref);
        vm.stopPrank();
        assertEq(
            router.lastPath(), abi.encodePacked(address(usdt), uint24(500), address(wbnb), uint24(10000), address(doge))
        );
        assertEq(doge.balanceOf(buyer), 10_000e18 - 2_000e18);
    }

    // ---- airdrops ----

    /// usdt tickets, btc pot: the seeded btc is valued in usdt at the twap to size the airdrop allowance
    function test_airdropAllowanceValuesSeedAtTwap() public {
        address p = mgr.createPool("BTC", _w(address(usdt), address(btc)));
        assertEq(mgr.airdropsLeft(p), 0);
        btc.mint(p, 1e18); // seeded: 1 btc = 60000 usdt = 600 tickets of 100 usdt (tick rounding aside)
        assertApproxEqAbs(mgr.airdropsLeft(p), 600, 1);
        uint256 before = mgr.airdropsLeft(p);

        vm.prank(buyer); // sales put btc in the pot too, but only the seed counts
        mgr.buyTicketsWith(p, _ids(1, 2), address(usdt), 250e18, block.timestamp, ref);
        assertEq(mgr.soldIntoPot(p), _potAmount());
        assertEq(mgr.seededPot(p), 1e18);
        assertEq(mgr.airdropsLeft(p), before);

        address[] memory tos = new address[](1);
        uint256[] memory ids = new uint256[](1);
        tos[0] = buyer;
        ids[0] = 777;
        mgr.airdrop(p, tos, ids);
        assertEq(Pool(payable(p)).ownerOf(777), buyer);
        assertEq(mgr.airdropsLeft(p), before - 1);
    }

    /// neither contract keeps the buyer's money or an open approval, only unclaimed referral earnings stay
    function _assertNothingLeft() internal view {
        assertEq(
            usdt.balanceOf(address(mgr)) + usdt.balanceOf(address(swapper)), mgr.referralEarnings(ref, address(usdt))
        );
        assertEq(wbnb.balanceOf(address(mgr)) + wbnb.balanceOf(address(swapper)), 0);
        assertEq(btc.balanceOf(address(mgr)) + btc.balanceOf(address(swapper)), 0);
        assertEq(address(mgr).balance + address(swapper).balance, 0);
        assertEq(wbnb.allowance(address(mgr), address(swapper)) + wbnb.allowance(address(swapper), address(router)), 0);
        assertEq(usdt.allowance(address(mgr), address(swapper)) + usdt.allowance(address(swapper), address(router)), 0);
        assertEq(btc.allowance(address(mgr), address(swapper)) + btc.allowance(address(swapper), address(router)), 0);
    }
}
