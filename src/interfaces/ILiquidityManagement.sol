// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

interface ILiquidityManagement {

    /**
     * @title ILiquidityManagement
     * @notice Interface used to move base asset funds in/out of the Spark Prime Vault
     * Provides statisical view functions to understand the distribution of the vaults'
     * base asset and saving vault token balances
     * LIQUIDITY_MANAGER will be the Spark PAU diamond address
     */
    /// @notice Emitted when LIQUIDITY_MANAGER withdraws funds from vault
    event FundsTaken(address indexed to, uint256 baseAmount);

    /// @notice Thrown when take or depositToSavings would spend base asset owed to claimable withdrawals
    error ExceedsAvailableLiquidity(uint256 amount, int256 available);

    /// @notice Withdraw base assets from the Vault. Emits FundsTaken. LIQUIDITY_MANAGER_ROLE only
    /// @dev Reverts with ExceedsAvailableLiquidity above availableLiquidAssets(), so claimable withdrawals stay funded
    /// @dev Mimics ISparkVaultLike to allow ISparkVaultFacet to withdraw funds via PAU's ALMProxy
    function take(uint256 baseAmount) external;

    /// @notice Total amount of liquid USDC available for NEW withdraw request
    /// @dev base asset balance - claimableWithdrawTotal. take and depositToSavings cannot push it below zero
    /// @dev Savings vault shares the vault holds do not count until the rebalancer withdraws them
    function availableLiquidAssets() external view returns (int256);

    /// @notice Largest `tradeVolume` processQueue accepts. In base Assets.
    /// @dev min(availableLiquidAssets + deposit queue value the savings vault can redeem now, convertToAssets(totalPendingWithdraws + availableCapacity))
    function maxTradeVolume() external view returns (uint256);

}
