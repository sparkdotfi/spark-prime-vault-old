// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    IAccessControl
} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {
    IERC7540
} from "@openzeppelin/community-contracts/interfaces/IERC7540.sol";
import {IVaultManagement} from "./IVaultManagement.sol";
import {IRebalancer} from "./IRebalancer.sol";
import {ILiquidityManagement} from "./ILiquidityManagement.sol";

/**
 * @title ISparkPrimeVault
 * @notice Asynchronous ERC-7540 Vault with Admin set continuous rate
 *
 *         The vault tracks user balances via a monotonically-growing rate index.
 *         The rate of growth is set directly by the Spark Automated Software (SAS),
 *         The vault balance may hold idle base asset and Savings Vault token
 *         Initially the Savings Vault is Spark Savings Vault (spUSDC), but should be treated as swappable.
 *.
 *         The vault is agnostic to investment strategies downstream (Arkis) and realized P&L
 *         The SAS reconciles off-chain and expresses the net policy interest rate
 *         The SAS interacts directly to set interest rates
 *         The SAS interacts via PAU to take/put base asset funds into the vault
 *
 *            Savings vault MUST accept base asset as a deposit in order to use
 *         depositToSavings and withdrawFromSavings functions inside IRebalancer
 *
 *         A user performs `claimRequest` which creates state `Pending`. The state may or may not transition to `Claimable` in the same transaction.
 *         If no queue exists and idle liquidity is available, the request transitions from `Pending` to `Claimable` within the same transaction.
 *         Other it is queued and becomes 'Claimable' via Symmetric FIFO queues with cross-matching between deposit and redemption heads.
 *
 *         Cross-matching between queues occurs on user invoked `claimRequest` AND `processQueue` which is invoked by Rebalancer only
 *         Cross-matching is net neutral (Sleeve and capacity unaffected)
 *
 *         User must perform Settlement i.e transition 'Claimable' to 'Claimed' manually, via claimRequest
 *
 */

interface ISparkPrimeVault is
    IERC7540,
    IVaultManagement,
    ILiquidityManagement,
    IRebalancer,
    IAccessControl
{
    enum State {
        Pending,
        Claimable,
        Claimed
    }

    /// @notice Lazy accrual of continuous interest
    event AccruedInterest(uint256 newIndex, uint256 timestamp);

    /// @notice Emitted when the user claims their assetsIn
    event DepositClaimed(address beneficary, uint256 shares);

    /// @notice Overload of ERC4626 deposit to allow Spark Referal Program support
    function deposit(
        uint256 assets,
        address receiver,
        uint256 referralCode
    ) external returns (uint256 shares);

    /// @notice Sets interest rate and capacity. Initially Spark Automated System (SAS)
    function VAULT_MANAGER_ROLE() external view returns (bytes32);

    /// @notice Rebalances between USDC and Savings Vault. Initially SAS
    function REBALANCER_ROLE() external view returns (bytes32);

    /// @notice Push and Pull USDC funds to the vault. Initially PAU diamond address (invoked by SAS)
    function LIQUIDITY_MANAGER_ROLE() external view returns (bytes32);

    /// @notice Amount of deposited base assets that can be claimed for shares
    function claimableDepositAmount(
        address controller
    ) external view returns (uint256);

    /// @notice Amount of deposited base assets that are not yet claimable for shares
    function pendingDepositAmount(
        address controller
    ) external view returns (uint256);

    /// @notice Amount of deposited base assets that can be claimed for shares
    function claimableWithdrawAmount(
        address controller
    ) external view returns (uint256);

    /// @notice All pending deposit request IDs for a user that can be claimed
    function pendingWithdrawAmount(
        address controller
    ) external view returns (uint256);

    /// @notice Current per second rate set by the VAULT_MANAGER.
    /// @dev based in 1e27 (RAY math), 1e27 = 0% APR
    function interestRate() external view returns (uint256);

    /// @notice Total baseAsset amount allowed in the vault
    function maxCapacity() external view returns (uint256);

    /// @notice Total baseAsset amount available before maximum capacity is reached
    function availableCapacity() external view returns (uint256);

    function depositQueueLength() external view returns (uint256);

    function withdrawQueueLength() external view returns (uint256);

    function depositQueueHead()
        external
        view
        returns (address controller, uint256 assets);

    function withdrawQueueHead()
        external
        view
        returns (address controller, uint256 assets);

    /// @notice Current interest rate index based off last accrual timestamp
    function index() external view returns (uint256);

    /// @notice Calculate the index at the current point in time. Simulates `accrueInterest`
    function previewIndex() external view returns (uint256);

    /// @notice Last Accrual Timestamp
    function lastAccrual() external view returns (uint256);
}
