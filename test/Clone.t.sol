// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.36;
import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "../src/Pool.sol";
import {IPool} from "../src/interface/IPool.sol";

contract CloneTest is Test {
    Pool impl;
    IPool.PoolConfig cfg;

    function setUp() public {
        impl = new Pool(address(0xC0), bytes32(uint256(7)), 42);
        uint256[] memory shares = new uint256[](2);
        shares[0] = 6_000;
        shares[1] = 4_000;
        cfg = IPool.PoolConfig(2, shares, new uint16[](0), address(0), block.timestamp + 1 days);
    }

    function test_implementationIsLocked() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(this), "X", "X", cfg);
    }

    function test_cloneInitOnceAndSharesVrfConfig() public {
        Pool p = Pool(payable(Clones.clone(address(impl))));
        p.initialize(address(0xABC), "Winfall #1", "WF1", cfg);
        assertEq(p.owner(), address(0xABC));
        assertEq(p.name(), "Winfall #1");
        assertEq(p.symbol(), "WF1");
        assertEq(p.getConfig().winnerShares[1], 4_000);
        assertEq(address(p.VRF_COORDINATOR()), address(0xC0));
        assertEq(p.vrfSubscriptionId(), 42);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        p.initialize(address(this), "X", "X", cfg);
        vm.prank(address(0xABC)); // new owner works
        p.safeMint(address(1), 1);
        assertEq(p.ownerOf(1), address(1));
    }

    function test_zeroOwnerRejected() public {
        Pool p = Pool(payable(Clones.clone(address(impl))));
        vm.expectRevert(abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0)));
        p.initialize(address(0), "X", "X", cfg);
    }

    function test_gasCloneVsNew() public {
        uint256 g = gasleft();
        Pool p = Pool(payable(Clones.clone(address(impl))));
        p.initialize(address(this), "P", "P", cfg);
        uint256 cloneGas = g - gasleft();
        g = gasleft();
        Pool q = new Pool(address(0xC0), bytes32(uint256(7)), 42);
        uint256 newGas = g - gasleft();
        emit log_named_uint("clone + initialize gas", cloneGas);
        emit log_named_uint("new Pool gas (no init)", newGas);
        assertLt(cloneGas, newGas);
        q;
    }
}
