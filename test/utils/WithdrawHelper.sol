// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {VaultHandler} from "../VaultHandler.t.sol";
import {ISparkPrimeVault} from "../../src/interfaces/ISparkPrimeVault.sol";
import {
    IERC7540,
    IERC7540Redeem
} from "@openzeppelin/community-contracts/interfaces/IERC7540.sol";
abstract contract WithdrawHelper is Test {}
