// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.36;
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MegaPool} from "../src/MegaPool.sol";
import "../src/PoolManager.sol";
import {PancakeV3Swapper, INVALID_TWAP_WINDOW, INVALID_SLIPPAGE} from "../src/PancakeV3Swapper.sol";
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
contract MockV3MegaPool {
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
    bool public ignoreMin;
    bytes public lastPath;

    function setRate(address a, address b, uint256 n, uint256 d) external {
        rate[a][b] = [n, d];
    }

    function setIgnoreMin(bool v) external {
        ignoreMin = v;
    }

    function exactInput(IV3SwapRouter.ExactInputParams calldata p) external payable returns (uint256 out) {
        lastPath = p.path;
        address tokenIn = address(bytes20(p.path[:20]));
        address tokenOut = address(bytes20(p.path[p.path.length - 20:]));
        IERC20(tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        uint256[2] memory r = rate[tokenIn][tokenOut];
        out = p.amountIn * r[0] / r[1];
        require(ignoreMin || out >= p.amountOutMinimum, "Too little received");
        Tok(tokenOut).mint(p.recipient, out);
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
    MockV3MegaPool btcPool;
    MockV3MegaPool bnbPool;
    MockV3MegaPool bnbBtcPool;
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
        btcPool = new MockV3MegaPool();
        bnbPool = new MockV3MegaPool();
        bnbBtcPool = new MockV3MegaPool();
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
        MegaPool impl = new MegaPool(address(coord), bytes32(0), 5);
        mgr = new PoolManager(address(this), treasury, address(impl), address(coord), 5);
        mgr.setSwapper(address(swapper));
        router.setRate(address(usdt), address(btc), 1, 60000);
        router.setRate(address(wbnb), address(usdt), 600, 1);
        vm.deal(address(wbnb), 1_000_000 ether); // backing for withdraw of minted mock wbnb
        usdt.mint(buyer, 1_000_000e18);
        vm.prank(buyer);
        usdt.approve(address(mgr), type(uint256).max);
    }

    function _w(address pay, address pot) internal view returns (Winfall memory w) {
        uint256[] memory shares = new uint256[](1);
        shares[0] = 1;
        w.name = "BTC pot";
        w.ticketPrice = 100e18;
        w.paymentToken = pay;
        w.currency = pot;
        w.feeBps = 500;
        w.referralBps = 1_000;
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
        MockV3MegaPool deep = new MockV3MegaPool();
        deep.set(btcPool.tick());
        deep.setLiquidity(1e24);
        factory.add(address(usdt), address(btc), 2500, address(deep));
        assertEq(swapper.findRoute(address(usdt), address(btc)), _direct(2500));
        deep.setLiquidity(1e10); // shallower than the 0.05% pool now
        assertEq(swapper.findRoute(address(usdt), address(btc)), _direct(500));
    }

    function test_skipsPoolsTooYoungForWindow() public {
        MockV3MegaPool young = new MockV3MegaPool();
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
        mgr.createPool("X", _w(address(usdt), address(doge)), 0, 0);
    }

    // ---- twap ----

    function test_twapMinOutMatchesPrice() public {
        swapper.setMaxSlippage(0);
        assertApproxEqRel(swapper.minOut(_direct(500), 60000e18), 1e18, 0.0002e18);
        bytes memory viaBnb = abi.encodePacked(address(usdt), uint24(500), address(wbnb), uint24(2500), address(btc));
        assertApproxEqRel(swapper.minOut(viaBnb, 60000e18), 1e18, 0.0003e18);
    }

    // ---- buying through the manager ----

    function test_createPoolStoresRouteAndBuyFillsPotInBtc() public {
        address p = mgr.createPool("BTC", _w(address(usdt), address(btc)), 0, 0);
        assertEq(mgr.swapRoute(p), _direct(500));
        vm.prank(buyer);
        mgr.buyTickets(p, _ids(1, 2), ref);
        assertEq(usdt.balanceOf(treasury), 10e18);
        assertEq(mgr.referralEarnings(ref, address(usdt)), 20e18);
        assertEq(btc.balanceOf(p), uint256(170e18) / 60000);
        assertEq(router.lastPath(), _direct(500));
        assertEq(
            usdt.balanceOf(address(mgr)) + usdt.balanceOf(address(swapper)), mgr.referralEarnings(ref, address(usdt))
        );
        assertEq(usdt.allowance(address(mgr), address(swapper)) + usdt.allowance(address(swapper), address(router)), 0);
    }

    function test_manipulatedPriceReverts() public {
        address p = mgr.createPool("BTC", _w(address(usdt), address(btc)), 0, 0);
        router.setRate(address(usdt), address(btc), 98, 100 * 60000); // spot pushed 2% below twap, cap is 1%
        vm.prank(buyer);
        vm.expectRevert(bytes("Too little received"));
        mgr.buyTickets(p, _ids(1, 2), ref);
        router.setIgnoreMin(true); // a router ignoring the min is still caught
        uint256 min = swapper.minOut(_direct(500), 170e18);
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(ISwapper.SWAP_OUTPUT_TOO_LOW.selector, min, uint256(170e18) * 98 / (100 * 60000))
        );
        mgr.buyTickets(p, _ids(1, 2), ref);
    }

    function test_withinSlippagePasses() public {
        address p = mgr.createPool("BTC", _w(address(usdt), address(btc)), 0, 0);
        router.setRate(address(usdt), address(btc), 995, 1000 * 60000); // 0.5% worse than twap
        vm.prank(buyer);
        mgr.buyTickets(p, _ids(1, 2), ref);
        assertGt(btc.balanceOf(p), 0);
    }

    function test_refreshRoute() public {
        address p = mgr.createPool("BTC", _w(address(usdt), address(btc)), 0, 0);
        MockV3MegaPool deep = new MockV3MegaPool();
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
        mgr.createPool("X", _w(address(usdt), address(0)), 0, 0);
        vm.expectRevert(INVALID_TWAP_WINDOW.selector);
        swapper.setTwapWindow(60);
        vm.expectRevert(INVALID_SLIPPAGE.selector);
        swapper.setMaxSlippage(1_001);
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
            address(this), treasury, address(new MegaPool(address(coord), bytes32(0), 5)), address(coord), 5
        );
        vm.expectRevert(SWAPPER_NOT_SET.selector);
        bare.createPool("X", _w(address(usdt), address(btc)), 0, 0);
    }

    // ---- paying with another token ----

    function test_buyWithWbnbToken() public {
        address p = mgr.createPool("BTC", _w(address(usdt), address(btc)), 0, 0);
        wbnb.mint(buyer, 5e18);
        vm.startPrank(buyer);
        wbnb.approve(address(mgr), 5e18);
        mgr.buyTicketsWith(p, _ids(1, 2), address(wbnb), 1e18, block.timestamp, ref); // 200 usdt = 1/3 bnb, max 1 bnb
        vm.stopPrank();
        uint256 spent = (uint256(200e18) + 599) / 600;
        assertEq(wbnb.balanceOf(buyer), 5e18 - spent); // unspent refunded
        assertEq(usdt.balanceOf(treasury), 10e18);
        assertEq(mgr.referralEarnings(ref, address(usdt)), 20e18);
        assertEq(btc.balanceOf(p), uint256(170e18) / 60000);
        assertEq(MegaPool(payable(p)).ownerOf(1_000_000_000 + 1), buyer);
        _assertNothingLeft();
    }

    function test_buyWithNativeBnb() public {
        address p = mgr.createPool("BTC", _w(address(usdt), address(btc)), 0, 0);
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        mgr.buyTicketsWith{value: 1 ether}(p, _ids(1, 2), address(0), 1 ether, block.timestamp, ref);
        assertEq(buyer.balance, 1 ether - (uint256(200e18) + 599) / 600); // native refund
        assertEq(btc.balanceOf(p), uint256(170e18) / 60000);
        _assertNothingLeft();
    }

    function test_buyWithSamePotCurrencyNoPotSwap() public {
        address p = mgr.createPool("USDT", _w(address(usdt), address(usdt)), 0, 0);
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        mgr.buyTicketsWith{value: 1 ether}(p, _ids(1, 2), address(0), 1 ether, block.timestamp, ref);
        assertEq(usdt.balanceOf(p), 170e18);
    }

    function test_twoHopExactOutUsesReversedPath() public {
        address p = mgr.createPool("USDT", _w(address(usdt), address(usdt)), 0, 0);
        MockV3MegaPool dogePool = new MockV3MegaPool();
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

    function test_buyWithRejects() public {
        address p = mgr.createPool("BTC", _w(address(usdt), address(btc)), 0, 0);
        wbnb.mint(buyer, 5e18);
        vm.startPrank(buyer);
        wbnb.approve(address(mgr), 5e18);
        vm.expectRevert(bytes("Too much requested")); // max below the price
        mgr.buyTicketsWith(p, _ids(1, 2), address(wbnb), 0.3e18, block.timestamp, ref);
        vm.expectRevert(EXPIRED.selector);
        mgr.buyTicketsWith(p, _ids(1, 2), address(wbnb), 1e18, block.timestamp - 1, ref);
        vm.expectRevert(USE_BUY_TICKETS.selector);
        mgr.buyTicketsWith(p, _ids(1, 2), address(usdt), 1e18, block.timestamp, ref);
        vm.deal(buyer, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(WRONG_PAYMENT.selector, 2 ether, 1 ether));
        mgr.buyTicketsWith{value: 1 ether}(p, _ids(1, 2), address(0), 2 ether, block.timestamp, ref);
        doge.mint(buyer, 1e18);
        doge.approve(address(mgr), 1e18);
        vm.expectRevert(abi.encodeWithSelector(ISwapper.NO_ROUTE.selector, address(doge), address(usdt)));
        mgr.buyTicketsWith(p, _ids(1, 2), address(doge), 1e18, block.timestamp, ref);
        vm.stopPrank();
    }

    function _assertNothingLeft() internal view {
        assertEq(
            usdt.balanceOf(address(mgr)) + usdt.balanceOf(address(swapper)), mgr.referralEarnings(ref, address(usdt))
        );
        assertEq(wbnb.balanceOf(address(mgr)) + wbnb.balanceOf(address(swapper)), 0);
        assertEq(address(mgr).balance + address(swapper).balance, 0);
        assertEq(wbnb.allowance(address(mgr), address(swapper)) + wbnb.allowance(address(swapper), address(router)), 0);
    }
}
