// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VaultHandler} from "./VaultHandler.t.sol";
import {IVault} from "src/interfaces/IVault.sol";
import {IVaultManagement} from "src/interfaces/IVaultManagement.sol";
import {USDC} from "./mocks/USDC.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {console} from "forge-std/console.sol";
import {QueueHelper} from "./utils/QueueHelper.sol";

contract VaultManagerUnitTests is QueueHelper {
    function setUp() public {
        _deployVault();
    }

    function test_cannot_setCapacity_overTotalAssets() public {
        _fundAndDeposit(vault, user, baseAsset, 100 ether);

        vm.prank(user);
        vault.deposit(100 ether, user);

        assertEq(vault.totalAssets(), 100 ether);

        vm.prank(vaultManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultManagement
                    .MaximumCapacityCannotExceedCurrentTotal
                    .selector
            )
        );
        vault.setCapacity(50 ether);
    }
}
