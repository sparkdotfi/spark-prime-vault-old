// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {
    DoubleEndedQueue
} from "@openzeppelin/contracts/utils/structs/DoubleEndedQueue.sol";
import {IVault} from "../interfaces/IVault.sol";
library TransactionQueue {
    using SafeCast for uint256;
    using DoubleEndedQueue for DoubleEndedQueue.Bytes32Deque;

    error QueueEmpty();
    error QueueFull(); // only when more than uint128 entries exceeded

    struct RequestQueue {
        DoubleEndedQueue.Bytes32Deque order;
        mapping(bytes32 => IVault.Transaction) entries;
    }

    function key(
        address controller,
        uint256 nonce
    ) internal pure returns (bytes32 element) {
        element = keccak256(abi.encode(controller, nonce));
    }

    function tryGet(
        RequestQueue storage queue,
        bytes32 element
    ) internal view returns (bool active, IVault.Transaction memory transaction) {
        transaction = queue.entries[element];
        active = transaction.controller != address(0);
    }

    function front(
        RequestQueue storage queue
    ) internal view returns (IVault.Transaction memory transaction) {
        uint256 n = queue.order.length();
        for (uint256 i; i < n; ++i) {
            bool active;
            (active, transaction) = tryGet(queue, queue.order.at(i));
            if (active) return transaction;
        }
        revert QueueEmpty();
    }

    function length(
        RequestQueue storage queue
    ) internal view returns (uint256) {
        return queue.order.length();
    }

    function isEmpty(RequestQueue storage queue) internal view returns (bool) {
        return queue.order.empty();
    }

    function pop(
        RequestQueue storage queue
    ) internal returns (bool active, IVault.Transaction memory data) {
        (bool success, bytes32 value) = queue.order.tryPopFront();
        if (!success) revert QueueEmpty();

        (active, data) = tryGet(queue, value);

        if (active) delete queue.entries[value];
    }

    function push(
        RequestQueue storage queue,
        IVault.Transaction memory transaction
    ) internal {
        bytes32 element = key(transaction.controller, transaction.nonce);

        bool success = queue.order.tryPushBack(element);
        if (!success) revert QueueFull();

        queue.entries[element] = transaction;
    }

    function pushFront(
        RequestQueue storage queue,
        IVault.Transaction memory transaction
    ) internal {
        bytes32 element = key(transaction.controller, transaction.nonce);

        bool success = queue.order.tryPushFront(element);
        if (!success) revert QueueFull();

        queue.entries[element] = transaction;
    }
}
