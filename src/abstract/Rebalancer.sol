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
    /// @notice Allows Spark Planner to increase baseAsset position by unwinding Savings Vault deposits
    /// @dev Trusts the planner/rebalancer for a reasonable `baseAssets` amount
    function withdrawFromSavings(
        uint256 baseAssets
    ) public onlyRole(REBALANCER_ROLER) {
        Storage storage $ = getStorage();
        $.savingsVault.withdraw(baseAssets, msg.sender, address(this));
    }

    /// @notice Allows Spark Planner to increase Savings Vault position by depositing vault baseAsset balance
    /// @dev Trusts the planner/rebalancer for a reasonable `baseAssets` amount
    function depositToSavings(
        uint256 baseAmount
    ) public onlyRole(REBALANCER_ROLER) {
        Storage storage $ = getStorage();
        $.savingsVault.deposit(baseAmount, address(this));
    }

    /// @notice The total share amount in the Withdraw Queue
    function totalPendingWithdraws() public view returns (uint256 shares) {
        Storage storage $ = getStorage();
        shares = $.totalWithdrawQueueShares;
    }

    /// @notice The total deposit amount in the Deposit Queue
    function totalPendingDeposits() public view returns (uint256 assets) {
        Storage storage $ = getStorage();
        assets = $.totalDepositQueueAssets;
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
