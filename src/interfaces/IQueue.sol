// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
interface IQueue {
    function depositQueueLength() external view returns (uint256);

    function withdrawQueueLength() external view returns (uint256);

    function depositQueueHead()
        external
        view
        returns (address controller, uint256 assets);

    function withdrawQueueHead()
        external
        view
        returns (address controller, uint256 assets);
}
