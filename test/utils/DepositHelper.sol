// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {VaultHandler} from "../VaultHandler.t.sol";
import {ISparkPrimeVault} from "src/interfaces/ISparkPrimeVault.sol";
import {
    IERC7540,
    IERC7540Redeem
} from "@openzeppelin/community-contracts/interfaces/IERC7540.sol";
import {IVault} from "src/interfaces/IVault.sol";
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

    function _claimDeposit(
        VaultHandler vault,
        address _user,
        uint256 amount
    ) internal {
        vm.startPrank(_user);
        vault.deposit(amount, _user);
        vm.stopPrank();
    }
    /*
    /// @dev total value: 31 ether [user (1), userTwo (10), userThree (20)]
    function createDepositQueue() public {
        IVault.Transaction memory depositOne = IVault.Transaction(
            user,
            1 ether,
            user,
            0
        );
        vault.pushToDepositQueue(depositOne);
        IVault.Transaction memory depositTwo = IVault.Transaction(
            userTwo,
            10 ether,
            userTwo,
            0
        );
        vault.pushToDepositQueue(depositTwo);
        IVault.Transaction memory depositTwo = IVault.Transaction(
            userThree,
            20 ether,
            userThree,
            0
        );
        vault.pushToDepositQueue(depositThree);
    }
*/
    function createDepositQueue(
        VaultHandler vault,
        uint256 length,
        uint256 totalValue,
        address[] memory users
    ) public {
        uint256 valuePerEntry = totalValue / length;
        uint256 totalUsers = users.length;

        for (length; length > 0; --length) {
            uint256 i = length % totalUsers;
            address user = users[i];
            IVault.Transaction memory data = IVault.Transaction(
                user,
                valuePerEntry,
                user,
                0
            );
            vault.pushToDepositQueue(data);
        }
    }
    function createWithdrawQueue(
        VaultHandler vault,
        uint256 length,
        uint256 totalValue,
        address[] memory users
    ) public {
        uint256 valuePerEntry = totalValue / length;
        uint256 totalUsers = users.length;

        for (length; length > 0; --length) {
            uint256 i = length % totalUsers;
            address user = users[i];
            IVault.Transaction memory data = IVault.Transaction(
                user,
                valuePerEntry,
                user,
                0
            );
            vault.pushToWithdrawQueue(data);
        }
    }
}
