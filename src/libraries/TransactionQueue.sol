// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {
    DoubleEndedQueue
} from "@openzeppelin/contracts/utils/structs/DoubleEndedQueue.sol";

library TransactionQueue {
    using SafeCast for uint256;
    using DoubleEndedQueue for DoubleEndedQueue.Bytes32Deque;

    error QueueEmpty();
    error QueueFull(); // only when more than uint128 entries exceeded

    struct Transaction {
        address beneficiary;
        uint96 amount;
    }

    function encodeTX(
        address beneficiary,
        uint256 amount
    ) private pure returns (bytes32 element) {
        element = bytes32(
            uint256(uint160(beneficiary) | uint256(amount.toUint96() << 160))
        );
    }

    function decodeTX(
        bytes32 element
    ) private pure returns (address beneficiary, uint256 amount) {
        uint256 e = uint256(element);
        beneficiary = address(uint160(e));
        amount = uint256(uint96(e >> 160));
    }

    function front(
        DoubleEndedQueue.Bytes32Deque storage queue
    ) internal returns (address beneficiary, uint256 amount) {
        (bool success, bytes32 value) = queue.tryFront();
        if (!success) revert QueueEmpty();

        (beneficiary, amount) = decodeTX(value);
    }

    function length(
        DoubleEndedQueue.Bytes32Deque storage queue
    ) internal view returns (uint256) {
        return queue.length();
    }

    function pop(
        DoubleEndedQueue.Bytes32Deque storage queue
    ) internal returns (address beneficiary, uint256 amount) {
        (bool success, bytes32 value) = queue.tryPopFront();
        if (!success) revert QueueEmpty();

        (beneficiary, amount) = decodeTX(value);
    }

    function push(
        DoubleEndedQueue.Bytes32Deque storage queue,
        address beneficiary,
        uint256 amount
    ) internal {
        bytes32 element = encodeTX(beneficiary, amount);

        bool success = queue.tryPushBack(element);
        if (!success) revert QueueFull();
    }
}
