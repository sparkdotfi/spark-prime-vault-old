// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {
    IERC7540
} from "./IERC7540.sol";
import {IERC7575Share} from "./IERC7575.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @notice ERC-7540 vault core: shared types, initialization, index and limits
/// @dev Requests carry no request id: requestDeposit and requestRedeem return
/// 0, and Pending and Claimable state is aggregated per controller. ERC-4626
/// deposit(assets, receiver) and mint(shares, receiver) claim with msg.sender
/// as controller, and withdraw and redeem take the controller in the owner
/// position. maxDeposit, maxMint, maxWithdraw and maxRedeem take the
/// controller and return its claimable balance, or 0 while paused;
/// claimableDepositRequest and claimableRedeemRequest ignore the pause. Every
/// preview function reverts.
interface IVault is IERC7540, IERC7575Share {
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
        address guardian;
        address riskManager;
    }

    struct Settlement {
        uint256 depositedAssets;
        uint256 sharesOwed;
        uint256 pendingSavingsShares;
        uint256 withdrawnShares;
        uint256 assetsOwed;
        uint256 pendingSharesOut;
    }

    struct Transaction {
        address controller;
        address owner;
        uint256 amount;
        uint256 fee;
    }

    /// @notice Lazy accrual of continuous interest
    event AccruedInterest(uint256 newIndex, uint256 timestamp);

    /// @notice Thrown by initialize when the savings vault's asset is not the base asset
    error AssetMismatch();

    /// @notice Thrown when requestDeposit receives a different base asset amount than it transferred
    error DeltaMismatch();

    /// @notice Thrown when msg.sender is not authorised to act for the owner or controller, including an operator claiming to a receiver other than the controller
    error UnauthorizedCaller(address caller);

    /// @notice Thrown when a deposit or mint claim exceeds the controller's claimable balance
    error InsufficientClaimableBalance(uint256 requested, uint256 available);

    /// @notice Thrown when an amount converts to zero spPRIME or savings vault shares
    error ShareConversionFailure(uint256 assets);

    /// @notice Initializes the proxy: token metadata, assets, limits, rate and roles. The index starts at RAY
    /// @dev Reverts with AssetMismatch, InterestRateBelowRay, InterestRateAboveMax, or ZeroValueProvided for a zero role address
    function initialize(InitParams calldata params) external;

    /// @notice Current per second rate set by the VAULT_MANAGER.
    /// @dev based in 1e27 (RAY math), 1e27 = 0% APR
    function interestRate() external view returns (uint256);

    /// @notice Current interest rate index based off last accrual timestamp
    function index() external view returns (uint256);

    /// @notice Calculate the index at the current point in time. Simulates `accrueInterest`
    function previewIndex() external view returns (uint256);

    /// @notice Last Accrual Timestamp
    function lastAccrual() external view returns (uint256);

    /// @notice Maximum spPRIME total supply, including shares escrowed by vault for pending redeems and claimable deposits
    function maxCapacity() external view returns (uint256);

    /// @notice Number of spPRIME shares that can still be minted before maximumCapacity is reached
    function availableCapacity() external view returns (uint256);

    /// @notice Smallest base asset amount requestDeposit accepts
    function minimumDeposit() external view returns (uint256);

    /// @notice Smallest base asset value, at the current index, of the shares requestRedeem accepts
    function minimumWithdraw() external view returns (uint256);
}
