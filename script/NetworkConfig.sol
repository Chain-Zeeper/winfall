// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.36;

import {Script} from "forge-std/Script.sol";

/// @notice per chain addresses the scripts need. every value can be overridden with an env var of the same name
///         in upper snake case (VRF_COORDINATOR, VRF_KEY_HASH, SMART_ROUTER, V3_FACTORY, WRAPPED_NATIVE)
abstract contract NetworkConfig is Script {
    struct Network {
        /// chainlink vrf v2.5 coordinator and the key hash (gas lane) requests use
        address vrfCoordinator;
        bytes32 vrfKeyHash;
        /// pancakeswap v3
        address smartRouter;
        address v3Factory;
        address wrappedNative;
        /// tokens the swapper routes through when there's no direct pool, in priority order
        address[] hubs;
    }

    uint256 internal constant BSC_TESTNET = 97;
    uint256 internal constant BSC_MAINNET = 56;

    function _network() internal view returns (Network memory net) {
        if (block.chainid == BSC_TESTNET) {
            // checked on chain: coordinator.LINK() is testnet LINK and the key hash is a registered proving key
            // (50 gwei lane), SmartRouter.factory() / WETH9() are the factory and WBNB below
            net.vrfCoordinator = 0xDA3b641D438362C440Ac5458c57e00a712b66700;
            net.vrfKeyHash = 0x8596b430971ac45bdf6088665b9ad8e8630c9d5049ab54b14dff711bee7c0e26;
            net.smartRouter = 0x9a489505a00cE272eAa5e07Dba6491314CaE3796;
            net.v3Factory = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
            net.wrappedNative = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;
            net.hubs = new address[](2);
            net.hubs[0] = net.wrappedNative;
            net.hubs[1] = 0x337610d27c682E347C9cD60BD4b3b107C9d34dDd; // testnet USDT
        } else if (block.chainid == BSC_MAINNET) {
            // pancakeswap addresses are the ones the fork tests run against. the vrf coordinator and key hash have to
            // be given: take them from chainlink's docs for bnb chain and check them on chain first
            net.smartRouter = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
            net.v3Factory = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
            net.wrappedNative = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
            net.hubs = new address[](2);
            net.hubs[0] = net.wrappedNative;
            net.hubs[1] = 0x55d398326f99059fF775485246999027B3197955; // USDT
        } else {
            revert("unsupported chain: add it to NetworkConfig");
        }

        net.vrfCoordinator = vm.envOr("VRF_COORDINATOR", net.vrfCoordinator);
        net.vrfKeyHash = vm.envOr("VRF_KEY_HASH", net.vrfKeyHash);
        net.smartRouter = vm.envOr("SMART_ROUTER", net.smartRouter);
        net.v3Factory = vm.envOr("V3_FACTORY", net.v3Factory);
        net.wrappedNative = vm.envOr("WRAPPED_NATIVE", net.wrappedNative);
        require(
            net.vrfCoordinator != address(0) && net.vrfKeyHash != bytes32(0), "set VRF_COORDINATOR and VRF_KEY_HASH"
        );
    }
}
