// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IVaultManagement {
    /**
     * @title IVaultManagement
     * @notice Interface used by VAULT_MANAGER to set interest rate, withdraw fee and max capacity
     * @dev This will be the Spark Automated Software
     */
    /// @notice Emitted when VAULT_MANAGER updates the continuous interest rate
    event RateUpdated(uint256 oldRate, uint256 newRate);

    /// @notice Emitted when VAULT_MANAGER adjusts the vault capacity
    event CapacityUpdated(uint256 oldCapacity, uint256 newCapacity);

    /// @notice Emitted when VAULT_MANAGER calls updateWithdrawFee(uint256 bps)
    event WithdrawFeeUpdated(uint256 oldValue, uint256 newValue);

    /// @notice Thrown when VAULT_MANAGER attempts to set maximumCapacity < totalAssets
    error MaximumCapacityCannotExceedCurrentTotal();

    /// @notice Sets the per-second continiuous interest rate. VAULT_MANAGER only
    function setInterestRate(uint256 newRate) external;

    /// @notice Set the fee on withdrawal from timestamp onwards. Existing requests are not affected.
    function updateWithdrawFee(uint256 bps) external;

    /// @notice Set Maximum Vault Capacity (totalAssets cap). VAULT_MANAGER only
    function setCapacity(uint256 newCapacity) external;
}
