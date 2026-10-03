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
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

abstract contract LiquidityManagement is
    VaultBase,
    AccessControlUpgradeable,
    ILiquidityManagement
{
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    function take(
        uint256 baseAmount
    ) public onlyRole(LIQUIDITY_MANAGER_ROLE) nonReentrant {
        _requireAvailableLiquidity(baseAmount);
        IERC20(asset()).safeTransfer(msg.sender, baseAmount);
        emit FundsTaken(msg.sender, baseAmount);
    }

    function availableLiquidAssets()
        public
        view
        returns (int256 totalBaseAssets)
    {
        Storage storage $ = getStorage();
        totalBaseAssets =
            IERC20(asset()).balanceOf(address(this)).toInt256() -
            $.totalClaimableWithdrawAssets.toInt256();
    }

    function _requireAvailableLiquidity(uint256 amount) internal view {
        int256 available = availableLiquidAssets();
        if (amount.toInt256() > available)
            revert ExceedsAvailableLiquidity(amount, available);
    }
}
