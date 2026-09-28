// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.36;
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import "../src/Pool.sol";

/// test helper: one implementation per coordinator, pools are clones of it
library PoolClone {
    function make(Pool impl, address owner, IPool.PoolConfig memory w) internal returns (Pool p) {
        p = Pool(payable(Clones.clone(address(impl))));
        p.initialize(owner, "P", "P", w);
    }
}
