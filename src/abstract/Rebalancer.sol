// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {IRebalancer} from "../interfaces/IRebalancer.sol";
import {VaultBase} from "./VaultBase.sol";
import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

abstract contract Rebalancer is
    VaultBase,
    AccessControlUpgradeable,
    IRebalancer
{
    using SafeERC20 for IERC20;

    /// @notice Allows Rebalancer Role to increase baseAsset position by unwinding Savings Vault deposits
    /// @dev Trusts the planner/rebalancer for a reasonable `share` amount
    function withdrawFromSavings(
        uint256 shares
    ) public onlyRole(REBALANCER_ROLER) returns (uint256 assets) {
        Storage storage $ = getStorage();
        assets = $.savingsVault.redeem(shares, address(this), address(this));
        emit SavingsWithdraw(shares, assets);
    }

    /// @notice Allows Rebalance Roler to increase Savings Vault position by depositing vault baseAsset balance
    /// @dev Trusts the planner/rebalancer for a reasonable `baseAssets` amount
    function depositToSavings(
        uint256 assets
    ) public onlyRole(REBALANCER_ROLER) returns (uint256 shares) {
        Storage storage $ = getStorage();
        IERC20(asset()).forceApprove(address($.savingsVault), assets);
        shares = $.savingsVault.deposit(assets, address(this));
        emit SavingsDeposit(assets, shares);
    }
}
