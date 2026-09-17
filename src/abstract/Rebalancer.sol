// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {IRebalancer} from "../interfaces/IRebalancer.sol";
import {VaultBase} from "./VaultBase.sol";
import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

abstract contract Rebalancer is
    VaultBase,
    AccessControlUpgradeable,
    IRebalancer
{
    /// @dev Trusts the planner/rebalancer for a reasonable `baseAssets` amount
    function withdrawFromSavings(
        uint256 baseAssets
    ) public onlyRole(REBALANCER_ROLER) {
        Storage storage $ = getStorage();
        $.savingsVault.withdraw(baseAssets, msg.sender, address(this));
    }

    /// @dev Trusts the planner/rebalancer for a reasonable `baseAssets` amount
    function depositToSavings(
        uint256 baseAmount
    ) public onlyRole(REBALANCER_ROLER) {
        Storage storage $ = getStorage();
        $.savingsVault.deposit(baseAmount, address(this));
    }

    function totalPendingWithdraws() public view returns (uint256 shares) {
        Storage storage $ = getStorage();
        shares = $.totalWithdrawQueueShares;
    }

    function totalPendingDeposits() public view returns (uint256 assets) {
        Storage storage $ = getStorage();
        assets = $.totalDepositQueueAssets;
    }

    function totalAssets() public view override returns (uint256) {
        Storage storage $ = getStorage();
        return $.totalAssets;
    }

    function claimableWithdrawTotal() public view returns (uint256) {
        Storage storage $ = getStorage();
        return $.totalClaimableWithdraws;
    }

    function claimableDepositTotal() public view returns (uint256) {
        Storage storage $ = getStorage();
        return $.totalClaimableDeposits;
    }
}
