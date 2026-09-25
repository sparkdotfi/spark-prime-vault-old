// SPDX-License-Identifier: MIT
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

    /// @notice Withdraw base assets from the Vault. Emits FundsTaken. LIQUIDITY_MANAGER_ROLE only
    /// @dev Mimics ISparkVaultLike to allow ISparkVaultFacet to withdraw funds via PAU's ALMProxy
    function take(uint256 baseAmount) external;

    /// @notice Total amount of liquid USDC available for NEW withdraw request
    /// @dev base asset balance - claimableWithdrawTotal
    /// @dev Can be negative
    function availableLiquidAssets() external view returns (int256);

    /// @notice Total spPRIME shares that can be minted (excludes what is locked for claimable deposits)
    function availableLiquidShares() external view returns (int256);
}
