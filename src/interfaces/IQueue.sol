// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import { IVault } from "./IVault.sol";

interface IQueue {
    /// @notice Emitted when a controller's claimable deposit, in base asset, changes
    event ClaimableDeposit(address controller, uint256 totalAmount);

    /// @notice Emitted whenever Deposit Queue value changes
    event DepositQueueValuation(uint256 newAmount);

    /// @notice Emitted when a controller's claimable withdraw, in base asset, changes
    event ClaimableWithdraw(address controller, uint256 totalAssets);

    /// @notice Emitted whenever Withdraw Queue value changes
    event WithdrawQueueValuation(uint256 newAmount);

    /// @notice Emitted whenever Total Claimable Withdraw changes
    event TotalClaimableWithdraws(uint256 newAmount);

    /// @notice Thrown when a partial fill runs out of queue entries before consuming the requested amount
    error PartialFillFailure();

    /// @notice Post Process Queue invariant: the vault owes more base asset than it holds
    error AssetInvariantBroken(int256 available);

    /// @notice Post Process Queue invariant: spPRIME total supply exceeded maximumCapacity
    error ShareInvariantBroken(int256 available);

    /// @notice Matches the withdraw queue against the deposit queue and free capacity for up to `tradeVolume` base asset. REBALANCER_ROLE only
    /// @dev Clamps `tradeVolume` to maxTradeVolume() and trusts the rebalancer to size it so the fill loops fit in a block.
    /// Fills the withdraw queue first, burning the matched shares, then the deposit queue at a single savings vault price, up to what the savings vault can redeem now.
    /// Reverts with AssetInvariantBroken or ShareInvariantBroken if the result leaves the vault insolvent or above capacity
    function processQueue(uint256 tradeVolume) external;

    /// @notice Removes cancelled keys among the first `maxIterations` deposit queue entries without reordering. Callable by anyone
    /// @return removed Number of cancelled keys removed
    function sanitizeDepositQueue(
        uint256 maxIterations
    ) external returns (uint256 removed);

    /// @notice Total Savings Vault shares currently in the deposit queue
    function totalPendingDeposits() external view returns (uint256 shares);

    /// @notice Number of live deposit queue entries, excluding cancelled ones
    function depositQueueLength() external view returns (uint256);

    /// @notice First live deposit queue entry, its amount in savings vault shares
    /// @dev Reverts with QueueEmpty when the queue holds no live entry
    function depositQueueHead()
        external
        view
        returns (IVault.Transaction memory transaction);

    /// @notice Total spPRIME shares held in escrow for claimable deposits
    function claimableDepositTotal() external view returns (uint256);

    /// @notice Total number of Spark Prime Shares waiting to converted to base asset
    function totalPendingWithdraws() external view returns (uint256 shares);

    /// @notice Number of withdraw queue entries
    function withdrawQueueLength() external view returns (uint256);

    /// @notice First withdraw queue entry, its amount in spPRIME shares
    /// @dev Reverts with QueueEmpty when the queue is empty
    function withdrawQueueHead()
        external
        view
        returns (IVault.Transaction memory transaction);

    /// @notice Total base asset of vault balance that is LOCKED and promised to claimers
    function claimableWithdrawTotal() external view returns (uint256);
}
