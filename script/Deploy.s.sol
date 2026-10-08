// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.36;

import {Script, console} from "forge-std/Script.sol";
import {IVRFCoordinatorV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";
import {Pool} from "../src/Pool.sol";
import {PoolManager} from "../src/PoolManager.sol";
import {PancakeV3Swapper} from "../src/PancakeV3Swapper.sol";
import {NetworkConfig} from "./NetworkConfig.sol";

interface ILinkToken {
    function balanceOf(address owner) external view returns (uint256);
    function transferAndCall(address to, uint256 value, bytes calldata data) external returns (bool);
}

interface IVRFCoordinatorLink {
    function LINK() external view returns (address);
}

/// @notice deploys Pool (implementation), PancakeV3Swapper and PoolManager, and hands the vrf subscription to the
///         manager.
///
///         forge script script/Deploy.s.sol --rpc-url bsc_testnet --broadcast --account <keystore>
///
///         env:
///           VRF_SUBSCRIPTION_ID  required. a subscription the deployer owns, create it with
///                                script/CreateVrfSubscription.s.sol or at vrf.chain.link
///           ADMIN                optional, default: the deployer. gets both PoolManager roles and owns the swapper
///           FEE_TREASURY         optional, default: the deployer
///           VRF_FUND_LINK        optional, LINK (in wei) to fund the subscription with from the deployer
///           network overrides    see NetworkConfig.sol
contract Deploy is Script, NetworkConfig {
    function run() external returns (PoolManager manager, Pool poolImplementation, PancakeV3Swapper swapper) {
        Network memory net = _network();
        uint256 subId = vm.envUint("VRF_SUBSCRIPTION_ID");
        IVRFCoordinatorV2Plus coordinator = IVRFCoordinatorV2Plus(net.vrfCoordinator);

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        address admin = vm.envOr("ADMIN", deployer);
        address treasury = vm.envOr("FEE_TREASURY", deployer);

        // fail before sending anything if the hand over of the subscription can't work
        (,,, address subOwner,) = coordinator.getSubscription(subId);
        require(subOwner == deployer, "deployer doesn't own VRF_SUBSCRIPTION_ID");

        poolImplementation = new Pool(net.vrfCoordinator, net.vrfKeyHash, subId);
        swapper = new PancakeV3Swapper(admin, net.smartRouter, net.v3Factory, net.wrappedNative, net.hubs);
        // the deployer is admin for the setup below, roles move to ADMIN at the end
        manager = new PoolManager(deployer, treasury, address(poolImplementation), net.vrfCoordinator, subId);
        manager.setSwapper(address(swapper));

        // the manager has to own the subscription to add every new pool as a consumer
        coordinator.requestSubscriptionOwnerTransfer(subId, address(manager));
        manager.acceptVrfSubscription();

        uint256 fundLink = vm.envOr("VRF_FUND_LINK", uint256(0));
        if (fundLink > 0) {
            ILinkToken link = ILinkToken(IVRFCoordinatorLink(net.vrfCoordinator).LINK());
            link.transferAndCall(net.vrfCoordinator, fundLink, abi.encode(subId));
        }

        if (admin != deployer) {
            manager.grantRole(manager.DEFAULT_ADMIN_ROLE(), admin);
            manager.grantRole(manager.POOL_CREATOR_ROLE(), admin);
            manager.renounceRole(manager.POOL_CREATOR_ROLE(), deployer);
            manager.renounceRole(manager.DEFAULT_ADMIN_ROLE(), deployer);
        }
        vm.stopBroadcast();

        console.log("chain id            ", block.chainid);
        console.log("PoolManager         ", address(manager));
        console.log("Pool implementation ", address(poolImplementation));
        console.log("PancakeV3Swapper    ", address(swapper));
        console.log("admin               ", admin);
        console.log("fee treasury        ", treasury);
        console.log("vrf subscription    ", subId);
        if (fundLink == 0) {
            console.log(
                "the subscription isn't funded by this script: add LINK at vrf.chain.link before the first draw"
            );
        }
    }
}
