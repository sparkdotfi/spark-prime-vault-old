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
}
