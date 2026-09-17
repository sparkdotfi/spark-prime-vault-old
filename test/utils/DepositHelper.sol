// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {VaultHandler} from "../VaultHandler.t.sol";
abstract contract DepositHelper is Test {
    function _fundAndDeposit(
        VaultHandler vault,
        address _user,
        IERC20 asset,
        uint256 amount
    ) internal {
        vm.startPrank(_user);

        deal(address(asset), _user, amount);
        asset.approve(address(vault), amount);

        vault.requestDeposit(amount, _user, _user);

        vm.stopPrank();
    }
}
