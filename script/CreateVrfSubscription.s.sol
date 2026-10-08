// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.36;

import {Script, console} from "forge-std/Script.sol";
import {IVRFCoordinatorV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";
import {NetworkConfig} from "./NetworkConfig.sol";

/// @notice creates a chainlink vrf v2.5 subscription owned by the deployer. run it before Deploy.s.sol:
///
///         forge script script/CreateVrfSubscription.s.sol --rpc-url bsc_testnet --broadcast --account <keystore>
///
///         the id depends on the block the subscription is created in, so the one printed during the simulation is
///         NOT the real one. read the real id from the SubscriptionCreated event of the broadcast transaction:
///
///         cast receipt <tx hash> --rpc-url bsc_testnet --json | jq -r '.logs[0].topics[1]' | cast to-dec
///
///         (or create the subscription at vrf.chain.link, which shows the id). then set VRF_SUBSCRIPTION_ID
contract CreateVrfSubscription is Script, NetworkConfig {
    function run() external {
        Network memory net = _network();
        vm.startBroadcast();
        IVRFCoordinatorV2Plus(net.vrfCoordinator).createSubscription();
        vm.stopBroadcast();
        console.log("subscription created on coordinator", net.vrfCoordinator);
        console.log("read its id from the SubscriptionCreated event of the broadcast transaction (see this script)");
    }
}
