// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {ILiquidityManagement} from "../interfaces/ILiquidityManagement.sol";
import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {VaultBase} from "./VaultBase.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

abstract contract LiquidityManagement is
    VaultBase,
    AccessControlUpgradeable,
    ILiquidityManagement
{
    using SafeERC20 for IERC20;

    /// @notice Provides Spark PAU ability to withdraw the vaults baseAsset balance
    function take(uint256 baseAmount) public onlyRole(LIQUIDITY_MANAGER_ROLE) {
        Storage storage $ = getStorage();
        $.baseAsset.safeTransfer(msg.sender, baseAmount);
    }

    /// @notice Calculates how many shares the vault can allocate for instant deposits
    /// @return totalLiquidShares Available SP Prime Tokens
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

    /// @notice Calculates how many assets the vault can allocate for instant withdrawals
    /// @dev It is the Rebalancers responsibility to convert Savings Vault shares back to base asset for them to be considered instant liquidty
    /// @return totalBaseAssets Instant Withdrawal Liquidity
    function availableLiquidAssets()
        public
        view
        returns (int256 totalBaseAssets)
    {
        Storage storage $ = getStorage();
        totalBaseAssets = int256(
            $.baseAsset.balanceOf(address(this)) -
                convertToAssets($.totalClaimableWithdraws)
        );
    }
}
