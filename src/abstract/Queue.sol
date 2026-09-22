// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultBase} from "./VaultBase.sol";
import {IVault} from "../interfaces/IVault.sol";
import {IQueue} from "../interfaces/IQueue.sol";
import {
    DoubleEndedQueue
} from "@openzeppelin/contracts/utils/structs/DoubleEndedQueue.sol";
import {TransactionQueue} from "../libraries/TransactionQueue.sol";
import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {console} from "forge-std/console.sol";

abstract contract Queue is VaultBase, AccessControlUpgradeable, IQueue {
    using TransactionQueue for DoubleEndedQueue.Bytes32Deque;

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

    /// @notice Provides the number of requests present in the FIFO Withdraw Queue
    function withdrawQueueLength() public view returns (uint256) {
        Storage storage $ = getStorage();
        return TransactionQueue.length($.withdrawQueue);
    }

    /// @notice Provides the first entry in the FIFO Withdraw Queue
    /// @dev Can revert with QueueEmpty
    function withdrawQueueHead()
        public
        view
        returns (Transaction memory transaction)
    {
        Storage storage $ = getStorage();
        transaction = TransactionQueue.front($, $.withdrawQueue);
    }

    /// @notice Provides the number of requests present in the FIFO Deposit Queue
    function depositQueueLength() public view returns (uint256) {
        Storage storage $ = getStorage();
        return TransactionQueue.length($.depositQueue);
    }

    /// @notice Provides the first entry in the FIFO Deposit Queue
    /// @dev Can revert with QueueEmpty
    function depositQueueHead()
        public
        view
        returns (Transaction memory transaction)
    {
        Storage storage $ = getStorage();
        transaction = TransactionQueue.front($, $.depositQueue);
    }

    /// @notice Process pending deposits/withdrawals against eachother
    /// @dev Trusts the planner/rebalancer for a reasonable `capacity` amount to bound the loop
    function processQueue(uint256 capacity) public onlyRole(REBALANCER_ROLER) {
        Storage storage $ = getStorage();

        uint256 totalWithdrawValue = convertToAssets(totalPendingWithdraws());
        uint256 totalDepositValue = totalPendingDeposits();
        if (capacity > totalWithdrawValue || capacity > totalDepositValue)
            revert CapacityOutOfBounds();

        capacity == totalWithdrawValue
            ? fillUnbounded($, $.withdrawQueue, _markClaimableWithdraw)
            : fillUntil(
                $,
                $.withdrawQueue,
                _markClaimableWithdraw,
                convertToShares(capacity)
            );

        capacity == totalDepositValue
            ? fillUnbounded($, $.depositQueue, _markClaimableDeposit)
            : fillUntil($, $.depositQueue, _markClaimableDeposit, capacity);
    }

    /// @dev Iterate over entire queue and eat until EOF
    function fillUnbounded(
        Storage storage $,
        DoubleEndedQueue.Bytes32Deque storage queue,
        function(Storage storage, address, uint256, bool) claim
    ) internal {
        uint256 n = queue.length();

        for (n; n > 0; --n) {
            Transaction memory data = queue.pop($);
            claim($, data.controller, data.amount, false);
        }
    }
    /// @dev Iterate queue and accumulate claims until we hit required capacity. Reverts on pre-mature EOF
    function fillUntil(
        Storage storage $,
        DoubleEndedQueue.Bytes32Deque storage queue,
        function(Storage storage, address, uint256, bool) claim,
        uint256 remainder
    ) internal {
        uint256 length = queue.length();

        while (remainder > 0) {
            if (length == 0) revert PartialFillFailure();

            Transaction memory data = queue.pop($);
            if (data.amount >= remainder) {
                /// @dev Base case, occurs exactly once at the last processed element
                claim($, data.controller, remainder, false);
                if (data.amount == remainder) break;
                _insertHeadWithNewAmount(
                    $,
                    queue,
                    data,
                    data.amount - remainder
                );
                break;
            } else {
                /// @dev Recursive case
                claim($, data.controller, data.amount, false);
                remainder -= data.amount;
            }
            length--;
        }
    }

    function _markClaimableDeposit(
        VaultBase.Storage storage $,
        address owner,
        uint256 amount,
        bool instantClaim
    ) internal {
        console.log("Marking claimable assetsIn += %e", amount);
        $.ledger[owner].assetsIn += amount;
        if (!instantClaim) $.ledger[owner].pendingAssetsIn -= amount;
        $.totalClaimableDeposits += amount;

        console.log(
            "Total deposit queue assets: %e",
            $.totalDepositQueueAssets
        );

        console.log("Reducing by amount: %e", amount);
        if (!instantClaim) $.totalDepositQueueAssets -= amount;
        emit ClaimableDeposit(owner, $.ledger[owner].assetsIn);
    }

    function _markClaimableWithdraw(
        VaultBase.Storage storage $,
        address owner,
        uint256 amount,
        bool instantClaim
    ) internal {
        $.ledger[owner].sharesOut += amount;
        if (!instantClaim) $.ledger[owner].pendingSharesOut -= amount;

        $.totalClaimableWithdraws += amount;
        console.log(
            "Total withdraw queue assets: %e",
            $.totalWithdrawQueueShares
        );

        console.log("Reducing by amount: %e", amount);
        if (!instantClaim) $.totalWithdrawQueueShares -= amount;
        emit ClaimableWithdraw(owner, $.ledger[owner].sharesOut);
    }

    /// @notice Cleans up void registry entries and links new data
    /// @dev Restricted usage to modify an existing element to head (partial fills).
    function _insertHeadWithNewAmount(
        Storage storage $,
        DoubleEndedQueue.Bytes32Deque storage queue,
        Transaction memory data,
        uint256 newAmount
    ) private {
        delete $.transactionRegistry[TransactionQueue.encodeTransaction(data)];

        data.amount = newAmount;
        bytes32 newHash = queue.pushFront(data);

        $.transactionRegistry[newHash] = data;
    }

    function _pushToWithdrawQueue(
        Storage storage $,
        IVault.Transaction memory data
    ) internal {
        bytes32 element = $.withdrawQueue.push(data);
        $.transactionRegistry[element] = data;
        $.totalWithdrawQueueShares += data.amount;
        $.ledger[data.controller].pendingSharesOut += data.amount;
        emit WithdrawQueueValuation($.totalWithdrawQueueShares);
    }

    function _pushToDepositQueue(
        VaultBase.Storage storage $,
        VaultBase.Transaction memory data
    ) internal {
        console.log("Pushing to deposit queue amount: %e", data.amount);
        bytes32 element = $.depositQueue.push(data);
        $.transactionRegistry[element] = data;
        $.totalDepositQueueAssets += data.amount;
        $.ledger[data.controller].pendingAssetsIn += data.amount;
        emit DepositQueueValuation($.totalDepositQueueAssets);
    }
}
