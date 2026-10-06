// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;
import {IRebalancer} from "../interfaces/IRebalancer.sol";
import {LiquidityManagement} from "./LiquidityManagement.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

abstract contract Rebalancer is LiquidityManagement, IRebalancer {
    using SafeERC20 for IERC20;

    function depositToSavings(
        uint256 assets
    ) public onlyRole(REBALANCER_ROLE) nonReentrant returns (uint256 shares) {
        Storage storage $ = getStorage();
        _requireAvailableLiquidity(assets);
        IERC20(asset()).forceApprove(address($.savingsVault), assets);
        shares = $.savingsVault.deposit(assets, address(this));
        if (shares == 0) revert ShareConversionFailure(assets);
        emit SavingsDeposit(assets, shares);
    }

    function withdrawFromSavings(
        uint256 shares
    ) public onlyRole(REBALANCER_ROLE) nonReentrant returns (uint256 assets) {
        Storage storage $ = getStorage();
        uint256 held = $.savingsVault.balanceOf(address(this));
        uint256 queued = $.totalDepositQueueSavingsShares;
        if (shares + queued > held)
            revert ExceedsFreeSavingsShares(
                shares,
                held > queued ? held - queued : 0
            );
        assets = $.savingsVault.redeem(shares, address(this), address(this));
        emit SavingsWithdraw(shares, assets);
    }
}
