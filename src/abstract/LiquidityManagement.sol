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
import {console} from "forge-std/console.sol";

abstract contract LiquidityManagement is
    VaultBase,
    AccessControlUpgradeable,
    ILiquidityManagement
{
    using SafeERC20 for IERC20;

    /// @notice Provides Spark PAU ability to withdraw the vaults baseAsset balance
    function take(uint256 baseAmount) public onlyRole(LIQUIDITY_MANAGER_ROLE) {
        Storage storage $ = getStorage();
        IERC20(asset()).safeTransfer(msg.sender, baseAmount);
    }

    /// @notice Calculates how many shares the vault can allocate for instant deposits
    /// @return shares Available SP Prime Tokens
    function availableLiquidShares() public view returns (int256 shares) {
        Storage storage $ = getStorage();
        uint256 shareBalance = balanceOf(address(this));
        console.log("Share balance: %e", shareBalance);
        console.log("Maximum Capacity: %e", $.maximumCapacity);
        console.log("Total Assets: %e", totalAssets());
        uint256 mintableShares = totalMintableShares();
        console.log("Mintable Shares: %e", mintableShares);

        console.log(
            "Total Claimable Deposits Shares: %e",
            convertToShares($.totalClaimableDeposits)
        );
        // Any idle share balance the vault owns from withdraw claims - locked shares for previous claimers
        shares =
            int256(shareBalance + mintableShares) -
            int256(convertToShares($.totalClaimableDeposits));
    }
    function totalMintableShares() public view returns (uint256 shares) {
        Storage storage $ = getStorage();
        shares = convertToShares($.maximumCapacity - totalAssets());
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
            IERC20(asset()).balanceOf(address(this)) -
                convertToAssets($.totalClaimableWithdraws)
        );
    }
}
