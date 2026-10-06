// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IVault } from "../interfaces/IVault.sol";

library TransactionQueue {

    error NotQueued(uint256 slot);
    error QueueEmpty();

    struct RequestQueue {
        uint128 consumed;  // Highest slot removed from the front.
        uint128 issued;    // Highest slot ever assigned.
        uint256 pending;   // Sum of live amounts.
        mapping(uint256 slot => IVault.Transaction) entries;  // Transaction = {controller, owner, fee, amount}
    }

    function push(RequestQueue storage queue, IVault.Transaction memory transaction)
        internal returns (uint256 slot)
    {
        slot                = ++queue.issued;
        queue.entries[slot] = transaction;
        queue.pending       += transaction.amount;
    }

    function cancel(RequestQueue storage queue, uint256 slot) internal {
        IVault.Transaction storage transaction = queue.entries[slot];

        if (transaction.controller == address(0)) revert NotQueued(slot);

        queue.pending -= transaction.amount;
        delete queue.entries[slot];
    }

    function peek(RequestQueue storage queue)
        internal returns (uint256 slot, IVault.Transaction storage transaction)
    {
        while (queue.consumed < queue.issued) {
            slot        = queue.consumed + 1;
            transaction = queue.entries[slot];

            if (transaction.controller != address(0)) return (slot, transaction);

            ++queue.consumed;
        }

        revert QueueEmpty();
    }

    function take(RequestQueue storage queue, uint256 slot, uint256 amount) internal {
        IVault.Transaction storage transaction = queue.entries[slot];
        queue.pending -= amount;

        if (transaction.amount == amount) {
            delete queue.entries[slot];
            ++queue.consumed;
        } else {
            transaction.amount -= amount;
        }
    }

    function isEmpty(RequestQueue storage queue) internal view returns (bool) {
        return queue.pending == 0;
    }

    function front(RequestQueue storage queue) internal view returns (IVault.Transaction memory transaction) {
        for (uint256 slot = queue.consumed + 1; slot <= queue.issued; ++slot) {
            transaction = queue.entries[slot];
            if (transaction.controller != address(0)) return transaction;
        }

        revert QueueEmpty();
    }

}
