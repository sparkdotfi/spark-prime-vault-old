// SPDX-License-Identifier: AGPL-3.0-or-later
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
    event SavingsDeposit(uint256 assets, uint256 outputShares);

    /// @notice Emitted when REBALANCER_ROLE withdraws from Savings Vault
    event SavingsWithdraw(uint256 shares, uint256 outputAssets);

    /// @notice Thrown when withdrawFromSavings would unwind savings shares that are locked to queued deposits
    error ExceedsFreeSavingsShares(uint256 shares, uint256 free);

    /// @notice Move idle base asset from Vault to Savings Vault to earn yield. REBALANCER_ROLE only
    /// @dev Internals handle conversion to saving vault. Reverts with ExceedsAvailableLiquidity above availableLiquidAssets()
    function depositToSavings(uint256 assets) external returns (uint256 shares);

    /// @notice Withdraws from Savings Vault into Prime vault base asset. REBALANCER_ROLE only
    /// @dev Internals handle conversion to saving vault. Reverts with ExceedsFreeSavingsShares if it would unwind shares locked to queued deposits
    function withdrawFromSavings(
        uint256 shares
    ) external returns (uint256 assets);

}
