// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultBase} from "./VaultBase.sol";
import {IQueue} from "../interfaces/IQueue.sol";
import {TransactionQueue} from "../libraries/TransactionQueue.sol";

abstract contract Queue is VaultBase, IQueue {
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
}
