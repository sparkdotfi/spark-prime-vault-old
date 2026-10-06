// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

interface IVaultManagement {
    /**
     * @title IVaultManagement
     * @notice Interface used by VAULT_MANAGER (rate, capacity, minimums), RISK_MANAGER (loss, withdraw fee) and GUARDIAN (pause)
     * @dev This will be the Spark Automated Software
     */
    /// @notice Emitted when VAULT_MANAGER updates the continuous interest rate
    event RateUpdated(uint256 oldRate, uint256 newRate);

    /// @notice Emitted when RISK_MANAGER sets totalAssets to reflect a loss
    event TotalAssetsUpdated(uint256 oldTotalAssets, uint256 newTotalAssets);

    /// @notice Emitted when VAULT_MANAGER adjusts the vault capacity
    event CapacityUpdated(uint256 oldCapacity, uint256 newCapacity);

    /// @notice Emitted when VAULT_MANAGER sets the minimum deposit
    event MinimumDepositUpdated(uint256 amount);

    /// @notice Emitted when VAULT_MANAGER sets the minimum withdraw
    event MinimumWithdrawUpdated(uint256 amount);

    /// @notice Emitted when RISK_MANAGER changes the withdraw fee, in bps
    event WithdrawFeeUpdated(uint256 oldValue, uint256 newValue);

    /// @notice Thrown when VAULT_MANAGER attempts to set a per-second rate below RAY (a negative rate)
    error InterestRateBelowRay();

    /// @notice Thrown when VAULT_MANAGER attempts to set a per-second rate above MAX_RATE (100% APY)
    /// @dev At MAX_RATE a single accrual gap stays within _rpow's range for about 76 years
    error InterestRateAboveMax();

    /// @notice Thrown when RISK_MANAGER attempts to set totalAssets above convertToAssets(totalSupply())
    error TotalAssetsExceedIndexValue();

    /// @notice Thrown when RISK_MANAGER attempts to set a withdraw fee above MAX_WITHDRAW_BPS (5,000 bps, 50%)
    error WithdrawFeeAboveMax();

    /// @notice Thrown when VAULT_MANAGER attempts to set maximumCapacity below totalSupply
    error CapacityBelowTotalSupply();

    /// @notice Thrown when a capacity above type(uint128).max is set, which share conversions could overflow
    error CapacityAboveLimit();

    /// @notice Sets the per-second continiuous interest rate. VAULT_MANAGER only
    /// @dev Accrues at the old rate first. The rate must be within [RAY, MAX_RATE]
    function setInterestRate(uint256 newRate) external;

    /// @notice Set totalAssets to reflect a loss. RISK_MANAGER only
    /// @dev Scales the index by newTotalAssets / totalAssets(), so every conversion prices in the loss. Only while paused
    function setTotalAssets(uint256 newTotalAssets) external;

    /// @notice Set Maximum Vault Capacity (spPRIME shares cap). VAULT_MANAGER only
    /// @dev Must be at least totalSupply and at most type(uint128).max
    function setCapacity(uint256 newCapacity) external;

    /// @notice Sets the smallest base asset amount requestDeposit accepts; 0 disables it. VAULT_MANAGER only
    function setMinimumDeposit(uint256 amount) external;

    /// @notice Sets the smallest base asset value requestRedeem accepts; 0 disables it. VAULT_MANAGER only
    function setMinimumWithdraw(uint256 amount) external;

    /// @notice Sets the withdraw fee, in bps, for redemption requests made from now on. Existing requests are not affected. RISK_MANAGER only
    /// @dev Each request keeps the fee in force when it was made. The fee is taken from the base asset owed when the request
    /// becomes claimable, rounded up, and stays in the vault as free liquidity. At most MAX_WITHDRAW_BPS (5,000 bps, 50%)
    function updateWithdrawFee(uint256 bps) external;

    /// @notice Withdraw fee, in bps, applied to new redemption requests
    function withdrawFee() external view returns (uint256);

    /// @notice Pauses requests and claims. GUARDIAN only
    /// @dev cancelDepositRequest, setOperator and the role-gated functions, including processQueue and take, stay callable
    function pause() external;

    /// @notice Resumes requests and claims. DEFAULT_ADMIN only
    function unpause() external;
}
