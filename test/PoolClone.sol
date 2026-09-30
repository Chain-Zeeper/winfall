// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.36;
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import "../src/MegaPool.sol";

/// test helper: one implementation per coordinator, pools are clones of it
library PoolClone {
    function make(MegaPool impl, address owner, IPool.PoolConfig memory w) internal returns (MegaPool p) {
        p = MegaPool(payable(Clones.clone(address(impl))));
        p.initialize(owner, "P", "P", w);
    }
}
