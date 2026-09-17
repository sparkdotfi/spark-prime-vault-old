// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultBase} from "../abstract/VaultBase.sol";
interface IQueue {
    function depositQueueLength() external view returns (uint256);

    function withdrawQueueLength() external view returns (uint256);

    function depositQueueHead()
        external
        view
        returns (VaultBase.Transaction memory transaction);

    function withdrawQueueHead()
        external
        view
        returns (VaultBase.Transaction memory transaction);
}
