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

    event MinimumDepositUpdated(uint256 amount);

    event MinimumWithdrawUpdated(uint256 amount);

    /// @notice Emitted when VAULT_MANAGER sets totalAssets to reflect a loss
    event TotalAssetsUpdated(uint256 oldTotalAssets, uint256 newTotalAssets);

    /// @notice Thrown when VAULT_MANAGER attempts to set maximumCapacity < totalSupply
    error MaximumCapacityCannotExceedCurrentTotal();

    /// @notice Thrown when VAULT_MANAGER attempts to set a per-second rate below RAY (a negative rate)
    error InterestRateBelowRay();

    /// @notice Thrown when VAULT_MANAGER attempts to set totalAssets above convertToAssets(totalSupply())
    error TotalAssetsExceedIndexValue();

    /// @notice Sets the per-second continiuous interest rate. VAULT_MANAGER only
    function setInterestRate(uint256 newRate) external;

    /// @notice Set totalAssets to reflect a loss. VAULT_MANAGER only
    /// @dev Records the loss as convertToAssets(totalSupply()) - newTotalAssets; the index and redemption values are unchanged
    function setTotalAssets(uint256 newTotalAssets) external;

    /// @notice Set the fee on withdrawal from timestamp onwards. Existing requests are not affected.
    function updateWithdrawFee(uint256 bps) external;

    /// @notice Set Maximum Vault Capacity (spPRIME shares cap). VAULT_MANAGER only
    function setCapacity(uint256 newCapacity) external;

    /// @notice Halts every user entry point. VAULT_MANAGER only
    function pause() external;

    /// @notice Resumes user entry points. DEFAULT_ADMIN only
    function unpause() external;
}
