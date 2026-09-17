// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {ILiquidityManagement} from "../interfaces/ILiquidityManagement.sol";
import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {VaultBase} from "./VaultBase.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

abstract contract LiquidityManagement is
    VaultBase,
    AccessControlUpgradeable,
    ILiquidityManagement
{
    using SafeERC20 for IERC20;
    function take(uint256 baseAmount) public onlyRole(LIQUIDITY_MANAGER_ROLE) {
        Storage storage $ = getStorage();
        $.baseAsset.safeTransfer(msg.sender, baseAmount);
    }

    function availableLiquidShares()
        public
        view
        returns (int256 totalLiquidShares)
    {
        Storage storage $ = getStorage();
        totalLiquidShares = int256(
            this.balanceOf(address(this)) -
                convertToShares($.totalClaimableDeposits)
        );
    }

    function availableLiquidAssets()
        public
        view
        returns (int256 totalBaseAssets)
    {
        Storage storage $ = getStorage();
        IERC4626 savingsVault = $.savingsVault;
        totalBaseAssets = int256(
            $.baseAsset.balanceOf(address(this)) +
                savingsVault.convertToAssets(
                    savingsVault.balanceOf(address(this))
                ) -
                convertToAssets($.totalClaimableWithdraws)
        );
    }
}
