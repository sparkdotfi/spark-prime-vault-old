// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {
    DoubleEndedQueue
} from "@openzeppelin/contracts/utils/structs/DoubleEndedQueue.sol";
import {VaultBase} from "../abstract/VaultBase.sol";
import {IVault} from "../interfaces/IVault.sol";
library TransactionQueue {
    using SafeCast for uint256;
    using DoubleEndedQueue for DoubleEndedQueue.Bytes32Deque;

    error DecodeFailed(bytes32 element);
    error QueueEmpty();
    error QueueFull(); // only when more than uint128 entries exceeded

    function encodeTransaction(
        IVault.Transaction memory transaction
    ) internal pure returns (bytes32 element) {
        element = keccak256(abi.encode(transaction));
    }

    function decodeTransaction(
        VaultBase.Storage storage $,
        bytes32 element
    ) internal view returns (IVault.Transaction memory transaction) {
        transaction = $.transactionRegistry[element];
        if (transaction.beneficiary == address(0)) revert DecodeFailed(element);
    }

    function front(
        VaultBase.Storage storage $,
        DoubleEndedQueue.Bytes32Deque storage queue
    ) internal view returns (IVault.Transaction memory) {
        (bool success, bytes32 value) = queue.tryFront();
        if (!success) revert QueueEmpty();

        return decodeTransaction($, value);
    }

    function length(
        DoubleEndedQueue.Bytes32Deque storage queue
    ) internal view returns (uint256) {
        return queue.length();
    }

    function isEmpty(
        DoubleEndedQueue.Bytes32Deque storage queue
    ) internal view returns (bool) {
        return queue.empty();
    }

    function pop(
        DoubleEndedQueue.Bytes32Deque storage queue,
        VaultBase.Storage storage $
    ) internal returns (VaultBase.Transaction memory) {
        (bool success, bytes32 value) = queue.tryPopFront();
        if (!success) revert QueueEmpty();

        return decodeTransaction($, value);
    }

    function push(
        DoubleEndedQueue.Bytes32Deque storage queue,
        VaultBase.Transaction memory transaction
    ) internal returns (bytes32 element) {
        element = encodeTransaction(transaction);

        bool success = queue.tryPushBack(element);
        if (!success) revert QueueFull();
    }

    function pushFront(
        DoubleEndedQueue.Bytes32Deque storage queue,
        VaultBase.Transaction memory transaction
    ) internal returns (bytes32 element) {
        element = encodeTransaction(transaction);

        bool success = queue.tryPushFront(element);
        if (!success) revert QueueFull();
    }
}
