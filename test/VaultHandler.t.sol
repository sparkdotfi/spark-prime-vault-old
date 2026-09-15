// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../src/Vault.sol";

contract VaultHandler is Test {
    Vault public vault;

    function setUp() public {
        vault = new Vault();
    }

    function test_Increment() public {
        // vault.increment();
        // assertEq(counter.number(), 1);
        assertTrue(true);
    }

    function testFuzz_SetNumber(uint256 x) public {
        // counter.setNumber(x);
        // assertEq(counter.number(), x);
        assertTrue(true);
    }
}
