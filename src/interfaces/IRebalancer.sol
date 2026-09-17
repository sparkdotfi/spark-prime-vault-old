// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IRebalancer {
    /**
     * @title IRebalancer
     * @notice Interface used to convert between base asset and savings vault token
     * Provides statisical view functions to understand the distribution of the vaults'
     * base asset and saving vault token balances
     * @dev REBALANCER_ROLE will be the Spark Automated Software
     */
    /// @notice Emitted when REBALANCER_ROLE deposits to Savings Vault
    event SavingsDeposit(uint256 baseAmount);

    /// @notice Emitted when REBALANCER_ROLE withdraws from Savings Vault
    event SavingsWithdraw(uint256 baseAmount);

    /// @notice Move idle base asset from Vault to Savings Vault to earn yield. REBALANCER_ROLE only
    /// @dev Internals handle conversion to saving vault.
    function depositToSavings(uint256 baseAmount) external;

    /// @notice Withdraws from Savings Vault into Prime vault base asset. REBALANCER_ROLE only
    /// @dev Internals handle conversion to saving vault.
    function withdrawFromSavings(uint256 baseAmount) external;

    /// @notice Fulfill any pending withdraw queue entries
    /// @dev Should be called after LIQUIDITY_MANAGER transfers funds back to vault via PAU Transfer Facet
    //function processQueue() external;

    /* These are optional convenience functions for the Rebalancer calculations, if not needed will remove */

    /// @notice Total number of base asset in vault balance waiting to be converted/exchanged to Spark Prime Shares
    function totalPendingDeposits() external view returns (uint256 assets);

    /// @notice Total Spark Prime Shares of vault balance that is LOCKED and promised to claimers
    function claimableDepositTotal() external view returns (uint256);

    /// @notice Total number of Spark Prime Shares waiting to converted to base asset
    function totalPendingWithdraws() external view returns (uint256 shares);

    /// @notice Total base asset of vault balance that is LOCKED and promised to claimers
    function claimableWithdrawTotal() external view returns (uint256);
}
