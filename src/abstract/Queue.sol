// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultBase} from "./VaultBase.sol";
import {IQueue} from "../interfaces/IQueue.sol";
import {TransactionQueue} from "../libraries/TransactionQueue.sol";

abstract contract Queue is VaultBase, IQueue {
    function withdrawQueueLength() public view returns (uint256) {
        Storage storage $ = getStorage();
        return TransactionQueue.length($.withdrawQueue);
    }

    function withdrawQueueHead()
        public
        view
        returns (Transaction memory transaction)
    {
        Storage storage $ = getStorage();
        transaction = TransactionQueue.front($, $.withdrawQueue);
    }

    function depositQueueLength() public view returns (uint256) {
        Storage storage $ = getStorage();
        return TransactionQueue.length($.depositQueue);
    }

    function depositQueueHead()
        public
        view
        returns (Transaction memory transaction)
    {
        Storage storage $ = getStorage();
        transaction = TransactionQueue.front($, $.withdrawQueue);
    }
}
