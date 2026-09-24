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

    error QueueEmpty();
    error QueueFull(); // only when more than uint128 entries exceeded

    uint8 internal constant DEPOSIT_REQUEST_TYPE = 0;
    uint8 internal constant REDEEM_REQUEST_TYPE = 1;

    function key(
        uint8 requestType,
        address controller,
        uint256 nonce
    ) internal pure returns (bytes32 element) {
        element = keccak256(abi.encode(requestType, controller, nonce));
    }

    function depositKey(
        address controller,
        uint256 nonce
    ) internal pure returns (bytes32) {
        return key(DEPOSIT_REQUEST_TYPE, controller, nonce);
    }

    function encodeTransaction(
        uint8 requestType,
        IVault.Transaction memory transaction
    ) internal pure returns (bytes32 element) {
        element = key(requestType, transaction.controller, transaction.nonce);
    }

    function tryGet(
        VaultBase.Storage storage $,
        bytes32 element
    ) internal view returns (bool active, IVault.Transaction memory transaction) {
        transaction = $.transactionRegistry[element];
        active = transaction.controller != address(0);
    }

    function front(
        VaultBase.Storage storage $,
        DoubleEndedQueue.Bytes32Deque storage queue
    ) internal view returns (IVault.Transaction memory transaction) {
        uint256 n = queue.length();
        for (uint256 i; i < n; ++i) {
            bool active;
            (active, transaction) = tryGet($, queue.at(i));
            if (active) return transaction;
        }
        revert QueueEmpty();
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
    ) internal returns (bool active, VaultBase.Transaction memory data) {
        (bool success, bytes32 value) = queue.tryPopFront();
        if (!success) revert QueueEmpty();

        (active, data) = tryGet($, value);

        if (active) delete $.transactionRegistry[value];
    }

    function push(
        DoubleEndedQueue.Bytes32Deque storage queue,
        uint8 requestType,
        VaultBase.Transaction memory transaction
    ) internal returns (bytes32 element) {
        element = encodeTransaction(requestType, transaction);

        bool success = queue.tryPushBack(element);
        if (!success) revert QueueFull();
    }

    function pushFront(
        DoubleEndedQueue.Bytes32Deque storage queue,
        uint8 requestType,
        VaultBase.Transaction memory transaction
    ) internal returns (bytes32 element) {
        element = encodeTransaction(requestType, transaction);

        bool success = queue.tryPushFront(element);
        if (!success) revert QueueFull();
    }
}
