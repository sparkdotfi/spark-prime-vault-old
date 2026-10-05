// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { DoubleEndedQueue } from "../../lib/openzeppelin-contracts/contracts/utils/structs/DoubleEndedQueue.sol";

import { ISpPrime } from "../ISpPrime.sol";

/// @notice FIFO request queue for SpPrime. Copy of TransactionQueue typed on ISpPrime.Transaction.
/// @dev    `order` holds keys, `entries` holds data. Deleting an entry leaves its key in `order`;
///         pop and front skip keys whose entry is empty.
library SpPrimeQueue {

    using DoubleEndedQueue for DoubleEndedQueue.Bytes32Deque;

    error QueueEmpty();
    error QueueFull();  // only when more than uint128 entries exceeded

    struct RequestQueue {
        DoubleEndedQueue.Bytes32Deque            order;
        mapping(bytes32 => ISpPrime.Transaction) entries;
    }

    function key(address controller, uint256 nonce) internal pure returns (bytes32 element) {
        element = keccak256(abi.encode(controller, nonce));
    }

    function tryGet(RequestQueue storage queue, bytes32 element)
        internal
        view
        returns (bool active, ISpPrime.Transaction memory transaction)
    {
        transaction = queue.entries[element];
        active      = transaction.controller != address(0);
    }

    function front(RequestQueue storage queue)
        internal
        view
        returns (ISpPrime.Transaction memory transaction)
    {
        uint256 n = queue.order.length();
        for (uint256 i; i < n; ++i) {
            bool active;
            ( active, transaction ) = tryGet(queue, queue.order.at(i));
            if (active) return transaction;
        }
        revert QueueEmpty();
    }

    function length(RequestQueue storage queue) internal view returns (uint256) {
        return queue.order.length();
    }

    function isEmpty(RequestQueue storage queue) internal view returns (bool) {
        return queue.order.empty();
    }

    function pop(RequestQueue storage queue)
        internal
        returns (bool active, ISpPrime.Transaction memory data)
    {
        ( bool success, bytes32 value ) = queue.order.tryPopFront();

        if (!success) revert QueueEmpty();

        ( active, data ) = tryGet(queue, value);

        if (active) delete queue.entries[value];
    }

    function push(RequestQueue storage queue, ISpPrime.Transaction memory transaction) internal {
        bytes32 element = key(transaction.controller, transaction.nonce);

        if (!queue.order.tryPushBack(element)) revert QueueFull();

        queue.entries[element] = transaction;
    }

    function pushFront(
        RequestQueue         storage queue,
        ISpPrime.Transaction memory  transaction
    )
        internal
    {
        bytes32 element = key(transaction.controller, transaction.nonce);

        if (!queue.order.tryPushFront(element)) revert QueueFull();

        queue.entries[element] = transaction;
    }

}
