// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {
    DoubleEndedQueue
} from "@openzeppelin/contracts/utils/structs/DoubleEndedQueue.sol";
import {VaultBase} from "../abstract/VaultBase.sol";

library TransactionQueue {
    using SafeCast for uint256;
    using DoubleEndedQueue for DoubleEndedQueue.Bytes32Deque;

    error DecodeFailed(bytes32 element);
    error QueueEmpty();
    error QueueFull(); // only when more than uint128 entries exceeded

    struct Transaction {
        address beneficiary;
        uint96 amount;
    }

    function encodeTransaction(
        VaultBase.Transaction memory transaction
    ) private pure returns (bytes32 element) {
        element = keccak256(abi.encode(transaction));
    }

    function decodeTransaction(
        VaultBase.Storage storage $,
        bytes32 element
    ) private view returns (VaultBase.Transaction memory transaction) {
        transaction = $.transactionRegistry[element];
        if (transaction.beneficiary == address(0)) revert DecodeFailed(element);
    }

    function front(
        VaultBase.Storage storage $,
        DoubleEndedQueue.Bytes32Deque storage queue
    ) internal view returns (VaultBase.Transaction memory) {
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
}
