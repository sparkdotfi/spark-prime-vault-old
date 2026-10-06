// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";

import { IERC20 }   from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { Math }     from "@openzeppelin/contracts/utils/math/Math.sol";

import { Vault }            from "src/Vault.sol";
import { IVault }           from "src/interfaces/IVault.sol";
import { USDC }             from "./mocks/USDC.sol";
import { TransactionQueue } from "src/libraries/TransactionQueue.sol";

contract VaultHandler is Vault {

    function convertToSharesRounded(
        uint256 assets,
        Math.Rounding rounding
    ) external view returns (uint256) {
        return _convertToShares(assets, rounding);
    }

    function convertToAssetsRounded(
        uint256 shares,
        Math.Rounding rounding
    ) external view returns (uint256) {
        return _convertToAssets(shares, rounding);
    }

    function setIndexRate(uint256 value) external {
        Storage storage $ = getStorage();
        $.indexRate = value;
    }

    function setOperatorForUser(
        address user,
        address operator,
        bool value
    ) external {
        Storage storage $ = getStorage();
        $.operators[user][operator] = value;
    }

    function setTotalClaimableDepositShares(uint256 value) external {
        Storage storage $ = getStorage();
        $.totalClaimableDepositShares = value;
    }

    function setMaximumCapacity(uint256 value) external {
        Storage storage $ = getStorage();
        $.maximumCapacity = value;
    }

    function setTotalClaimableWithdrawAssets(uint256 value) external {
        Storage storage $ = getStorage();
        $.totalClaimableWithdrawAssets = value;
    }

    function pushToDepositQueue(IVault.Transaction memory data) external {
        Storage storage $ = getStorage();
        _pushToDepositQueue($, data);
    }

    function pushToWithdrawQueue(IVault.Transaction memory data) external {
        Storage storage $ = getStorage();
        _pushToWithdrawQueue($, data);
    }

    function fillWithdrawQueue() external {
        Storage storage $ = getStorage();
        _fill($, $.withdrawQueue, _markClaimableWithdraw, $.withdrawQueue.pending);
    }

    function fillUntilWithdrawQueue(uint256 capacity) external {
        Storage storage $ = getStorage();
        _fill($, $.withdrawQueue, _markClaimableWithdraw, capacity);
    }

    /// Number of live deposit queue entries, walking past cancelled holes
    function depositQueueLength() external view returns (uint256) {
        return _liveEntries(getStorage().depositQueue);
    }

    /// Number of live withdraw queue entries
    function withdrawQueueLength() external view returns (uint256) {
        return _liveEntries(getStorage().withdrawQueue);
    }

    /// Slot id handed to the most recent queued deposit
    function lastDepositId() external view returns (uint256) {
        return getStorage().depositQueue.issued;
    }

    /// Slot id handed to the most recent queued redeem
    function lastWithdrawId() external view returns (uint256) {
        return getStorage().withdrawQueue.issued;
    }

    function _liveEntries(
        TransactionQueue.RequestQueue storage queue
    ) internal view returns (uint256 count) {
        for (uint256 slot = queue.consumed + 1; slot <= queue.issued; ++slot) {
            if (queue.entries[slot].controller != address(0)) ++count;
        }
    }

}
