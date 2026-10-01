// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultBase} from "../abstract/VaultBase.sol";
interface IQueue {
    /// @notice Emitted when a users claimable deposit amount changes
    event ClaimableDeposit(address beneficiary, uint256 totalAmount);

    /// @notice Emitted when a users claimable withdraw amount changes
    event ClaimableWithdraw(address beneficiary, uint256 totalShares);

    /// @notice Emitted whenever Deposit Queue value changes
    event DepositQueueValuation(uint256 newAmount);

    /// @notice Emitted whenever Total Claimable Withdraw changes
    event TotalClaimableWithdraws(uint256 newAmount);

    /// @notice Emitted whenever Withdraw Queue value changes
    event WithdrawQueueValuation(uint256 newAmount);

    function depositQueueLength() external view returns (uint256);

    function withdrawQueueLength() external view returns (uint256);

    error PartialFillFailure();

    /// @notice Post Process Queue invariant: the vault owes more base asset than it holds
    error AssetInvariantBroken(int256 available);

    /// @notice Post Process Queue invariant: spPRIME total supply exceeded maximumCapacity
    error ShareInvariantBroken(int256 available);

    function depositQueueHead()
        external
        view
        returns (VaultBase.Transaction memory transaction);

    function withdrawQueueHead()
        external
        view
        returns (VaultBase.Transaction memory transaction);

    /// @notice Fulfill any pending withdraw queue entries
    //function processQueue() external;

    /// @notice Total Savings Vault shares currently in the deposit queue
    function totalPendingDeposits() external view returns (uint256 shares);

    /// @notice Total spPRIME shares held in escrow for claimable deposits
    function claimableDepositTotal() external view returns (uint256);

    /// @notice Total number of Spark Prime Shares waiting to converted to base asset
    function totalPendingWithdraws() external view returns (uint256 shares);

    /// @notice Total base asset of vault balance that is LOCKED and promised to claimers
    function claimableWithdrawTotal() external view returns (uint256);
}
