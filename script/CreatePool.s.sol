// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.36;

import {Script, console} from "forge-std/Script.sol";
import {PoolManager} from "../src/PoolManager.sol";
import {Winfall} from "../src/interface/IPoolManager.sol";

/// @notice creates one winfall pool through a deployed PoolManager. the sender needs POOL_CREATOR_ROLE.
///
///         forge script script/CreatePool.s.sol --rpc-url bsc_testnet --broadcast --account <keystore>
///
///         env:
///           POOL_MANAGER     required
///           POOL_NAME        default "Winfall"
///           POOL_SYMBOL      default "WIN"
///           TICKET_PRICE     default 0.001 ether (in the payment token's smallest unit)
///           PAYMENT_TOKEN    default address(0) = native bnb
///           POT_CURRENCY     default = PAYMENT_TOKEN. if different, the pot's share is swapped on pancakeswap v3
///           DURATION         default 1 days + 10 minutes, seconds the pool sells tickets for (manager minimum: 1 day)
///           FEE_BPS          default 500   (5% protocol fee, the rest of the price goes into the pot)
///           REFERRAL_BPS     default 100   (1% of the price to the buyer's referrer, taken out of that fee)
///           WINNING_SHARES   default "7000,3000". prize split in bps, comma separated, has to add up to 10000
///           DIFFICULTIES     default "" (every position always won). bps per position, comma separated, max 9000
contract CreatePool is Script {
    function run() external returns (address pool) {
        PoolManager manager = PoolManager(vm.envAddress("POOL_MANAGER"));

        Winfall memory w;
        w.name = vm.envOr("POOL_NAME", string("Winfall"));
        w.ticketPrice = vm.envOr("TICKET_PRICE", uint256(0.001 ether));
        w.paymentToken = vm.envOr("PAYMENT_TOKEN", address(0));
        w.currency = vm.envOr("POT_CURRENCY", w.paymentToken);
        w.feeBps = uint16(vm.envOr("FEE_BPS", uint256(500)));
        w.referralBps = uint16(vm.envOr("REFERRAL_BPS", uint256(100)));
        w.closeTime = block.timestamp + vm.envOr("DURATION", uint256(1 days + 10 minutes));

        uint256[] memory defaultShares = new uint256[](2);
        defaultShares[0] = 7_000;
        defaultShares[1] = 3_000;
        w.winningShares = vm.envOr("WINNING_SHARES", ",", defaultShares);

        uint256[] memory difficulties = vm.envOr("DIFFICULTIES", ",", new uint256[](0));
        w.difficultiesBps = new uint16[](difficulties.length);
        for (uint256 i = 0; i < difficulties.length; i++) {
            w.difficultiesBps[i] = uint16(difficulties[i]);
        }

        vm.startBroadcast();
        pool = manager.createPool(vm.envOr("POOL_SYMBOL", string("WIN")), w);
        vm.stopBroadcast();

        console.log("pool        ", pool);
        console.log("close time  ", w.closeTime);
        console.log("positions   ", w.winningShares.length);
    }
}
