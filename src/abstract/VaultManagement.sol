// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IVaultManagement} from "../interfaces/IVaultManagement.sol";
import {ISparkPrimeVault} from "../interfaces/ISparkPrimeVault.sol";
import {VaultBase} from "./VaultBase.sol";
import {InterestLib} from "../libraries/InterestLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

abstract contract VaultManagement is
    VaultBase,
    AccessControlUpgradeable,
    IVaultManagement
{
    function pause() public onlyRole(VAULT_MANAGER_ROLE) {
        _pause();
    }

    function unpause() public onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function setInterestRate(
        uint256 newRate
    ) public onlyRole(VAULT_MANAGER_ROLE) {
        if (newRate < InterestLib.RAY) revert InterestRateBelowRay();
        if (newRate > InterestLib.MAX_RATE) revert InterestRateAboveMax();
        Storage storage $ = getStorage();
        InterestLib.accrueInterest($);
        uint256 oldRate = $.ratePerSecond;
        $.ratePerSecond = newRate;
        emit RateUpdated(oldRate, newRate);
    }

    function setTotalAssets(
        uint256 newTotalAssets
    ) public onlyRole(VAULT_MANAGER_ROLE) whenPaused {
        if (newTotalAssets == 0) revert ISparkPrimeVault.ZeroValueProvided();
        Storage storage $ = getStorage();

        InterestLib.accrueInterest($);

        uint256 oldTotalAssets = totalAssets();
        if (newTotalAssets > oldTotalAssets)
            revert TotalAssetsExceedIndexValue();
        $.indexRate = Math.mulDiv($.indexRate, newTotalAssets, oldTotalAssets);

        emit TotalAssetsUpdated(oldTotalAssets, newTotalAssets);
    }

    function setMinimumDeposit(
        uint256 amount
    ) public onlyRole(VAULT_MANAGER_ROLE) {
        Storage storage $ = getStorage();
        $.minimumDeposit = amount;
        emit MinimumDepositUpdated(amount);
    }

    function setMinimumWithdraw(
        uint256 amount
    ) public onlyRole(VAULT_MANAGER_ROLE) {
        Storage storage $ = getStorage();
        $.minimumWithdraw = amount;
        emit MinimumWithdrawUpdated(amount);
    }
    function updateWithdrawFee(
        uint256 bps
    ) public onlyRole(VAULT_MANAGER_ROLE) {}

    function setCapacity(
        uint256 newCapacity
    ) public onlyRole(VAULT_MANAGER_ROLE) {
        Storage storage $ = getStorage();
        if (newCapacity < totalSupply())
            revert MaximumCapacityCannotExceedCurrentTotal();
        emit CapacityUpdated($.maximumCapacity, newCapacity);
        $.maximumCapacity = newCapacity;
    }
}
