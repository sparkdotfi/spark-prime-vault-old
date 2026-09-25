// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {
    IERC7540
} from "@openzeppelin/community-contracts/interfaces/IERC7540.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface IVault is IERC7540 {
    struct InitParams {
        string name;
        string symbol;
        IERC20 baseAsset;
        IERC4626 savingsVault;
        uint256 minimumDeposit;
        uint256 minimumWithdraw;
        uint256 capacity;
        uint256 ratePerSecond;
        address admin;
        address vaultManager;
        address liquidityManager;
        address rebalancer;
    }

    struct Settlement {
        address beneficiary;
        uint256 assetsIn;
        uint256 sharesIn;
        uint256 pendingSavingsShares;
        uint256 sharesOut;
        uint256 assetsOut;
        uint256 pendingSharesOut;
    }

    struct Transaction {
        address controller;
        address owner;
        uint256 amount;
        uint256 nonce;
    }

    error DeltaMismatch();

    error AssetMismatch();

    /// @notice Lazy accrual of continuous interest
    event AccruedInterest(uint256 newIndex, uint256 timestamp);

    error UnauthorizedCaller(address caller);

    error OperatorMaliciousAction(address reciever, address victim);

    error InsufficientClaimableBalance(uint256 requested, uint256 available);

    error ShareConversionFailure(uint256 assets);

    /// @notice Current per second rate set by the VAULT_MANAGER.
    /// @dev based in 1e27 (RAY math), 1e27 = 0% APR
    function interestRate() external view returns (uint256);

    /// @notice Total baseAsset amount allowed in the vault
    function maxCapacity() external view returns (uint256);

    /// @notice Total baseAsset amount available before maximum capacity is reached
    /// @dev Can be negative
    function availableCapacity() external view returns (uint256);

    /// @notice Current interest rate index based off last accrual timestamp
    function index() external view returns (uint256);

    /// @notice Calculate the index at the current point in time. Simulates `accrueInterest`
    function previewIndex() external view returns (uint256);

    /// @notice Last Accrual Timestamp
    function lastAccrual() external view returns (uint256);
}
