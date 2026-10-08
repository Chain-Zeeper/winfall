// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.36;
import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pool} from "../src/Pool.sol";
import "../src/PoolManager.sol";
import {PancakeV3Swapper} from "../src/PancakeV3Swapper.sol";
import {Winfall} from "../src/interface/IPoolManager.sol";
import {MockCoordSub} from "./Manager.t.sol";

/// runs against a fork of bnb chain mainnet with the real pancakeswap v3 contracts and pools.
/// vrf is still mocked, the draw isn't what's tested here
contract ForkBscTest is Test {
    // verified on chain: symbol/decimals of the tokens, SmartRouter.factory() == FACTORY, SmartRouter.WETH9() == WBNB
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
    address constant FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant SMART_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;

    PoolManager mgr;
    PancakeV3Swapper swapper;
    address treasury = makeAddr("treasury");
    address ref = makeAddr("ref");
    address buyer = makeAddr("buyer");

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string("https://bsc-dataseed.bnbchain.org"));
        uint256 forkBlock = vm.envOr("BSC_FORK_BLOCK", uint256(0)); // pin a block for reproducible runs
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        address[] memory hubs = new address[](2);
        hubs[0] = WBNB;
        hubs[1] = USDT;
        swapper = new PancakeV3Swapper(address(this), SMART_ROUTER, FACTORY, WBNB, hubs);
        MockCoordSub coord = new MockCoordSub();
        mgr = new PoolManager(
            address(this), treasury, address(new Pool(address(coord), bytes32(0), 5)), address(coord), 5
        );
        mgr.setSwapper(address(swapper));
    }

    function _pool(address pay, address pot) internal returns (address) {
        uint256[] memory shares = new uint256[](1);
        shares[0] = 10_000;
        Winfall memory w;
        w.name = "fork";
        w.ticketPrice = 100e18;
        w.paymentToken = pay;
        w.currency = pot;
        w.feeBps = 500;
        w.referralBps = 100;
        w.closeTime = block.timestamp + 2 days;
        w.winningShares = shares;
        return mgr.createPool("F", w);
    }

    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = b;
    }

    function test_fork_routes() public view {
        bytes memory r = swapper.findRoute(USDT, BTCB);
        console.log("USDT->BTCB route length", r.length);
        console.logBytes(r);
        assertEq(r.length, 43, "expected a direct pool");
        (uint24 fee, uint128 liq) = swapper.bestPool(USDT, BTCB);
        console.log("best fee tier", fee, "time weighted liquidity", liq);
        // the 0.25% pool has 1 observation slot, it must be skipped even though it exists
        assertTrue(fee != 2500);
        bytes memory r2 = swapper.findRoute(WBNB, USDT);
        assertEq(r2.length, 43);
    }

    function test_fork_buyUsdtIntoBtcbPot() public {
        address p = _pool(USDT, BTCB);
        deal(USDT, buyer, 1_000e18);
        uint256 minOut = swapper.minOut(mgr.swapRoute(p), 190e18);
        vm.startPrank(buyer);
        IERC20(USDT).approve(address(mgr), type(uint256).max);
        mgr.buyTickets(p, _ids(1, 2), ref);
        vm.stopPrank();

        uint256 pot = IERC20(BTCB).balanceOf(p);
        console.log("170 USDT -> BTCB in pot", pot, "twap min (1% slippage)", minOut);
        assertGe(pot, minOut);
        assertEq(IERC20(USDT).balanceOf(treasury), 8e18);
        assertEq(mgr.referralEarnings(ref, USDT), 2e18);
        assertEq(IERC20(USDT).balanceOf(address(mgr)), 2e18);
        assertEq(IERC20(USDT).balanceOf(address(swapper)), 0);
        assertEq(Pool(payable(p)).ownerOf(2), buyer);
    }

    function test_fork_buyWithNativeBnbIntoBtcbPot() public {
        address p = _pool(USDT, BTCB);
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        mgr.buyTicketsWith{value: 1 ether}(p, _ids(1, 2), address(0), 1 ether, block.timestamp + 60, ref);

        uint256 spent = 10 ether - buyer.balance;
        console.log("BNB spent for 200 USDT of tickets", spent);
        console.log("BTCB in pot", IERC20(BTCB).balanceOf(p));
        assertGt(spent, 0); // refunded the rest
        assertLt(spent, 1 ether);
        assertGt(IERC20(BTCB).balanceOf(p), 0);
        assertEq(mgr.referralEarnings(ref, USDT), 2e18);
        assertEq(address(mgr).balance + address(swapper).balance, 0);
        assertEq(IERC20(WBNB).balanceOf(address(swapper)), 0);
    }

    function test_fork_buyWithBtcbIntoUsdtPot() public {
        address p = _pool(USDT, USDT);
        deal(BTCB, buyer, 1e18);
        vm.startPrank(buyer);
        IERC20(BTCB).approve(address(mgr), 1e18);
        mgr.buyTicketsWith(p, _ids(1, 2), BTCB, 0.1e18, block.timestamp + 60, address(0));
        vm.stopPrank();
        console.log("BTCB spent for 200 USDT of tickets", 1e18 - IERC20(BTCB).balanceOf(buyer));
        assertEq(IERC20(USDT).balanceOf(p), 190e18); // 5% fee, the rest is the pot
        assertEq(IERC20(BTCB).balanceOf(address(mgr)) + IERC20(BTCB).balanceOf(address(swapper)), 0);
    }

    function test_fork_claimReferral() public {
        address p = _pool(USDT, BTCB);
        deal(USDT, buyer, 1_000e18);
        vm.startPrank(buyer);
        IERC20(USDT).approve(address(mgr), type(uint256).max);
        mgr.buyTickets(p, _ids(1, 2), ref);
        vm.stopPrank();
        vm.prank(ref);
        mgr.claimReferral(USDT);
        assertEq(IERC20(USDT).balanceOf(ref), 2e18);
    }
}
