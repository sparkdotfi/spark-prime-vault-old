// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import { IVault } from "./IVault.sol";

/**
 * @title ISparkPrimeVault
 * @notice Asynchronous ERC-7540 vault whose shares (spPRIME) accrue at a continuous rate set by the Spark Planner or PAU
 * @author 0xpotionseller, arkis.xyz
 * @dev
 * Pricing: a single index prices every conversion. It compounds per second at
 * the rate VAULT_MANAGER sets, and RISK_MANAGER books a realized loss, only
 * while GUARDIAN has paused the vault, by lowering totalAssets, which scales the index down. The
 * vault is agnostic to the strategies downstream (Arkis) and to realized P&L:
 * the Spark Planner reconciles off-chain and expresses the net policy rate.
 *
 * Holdings: idle base asset and savings vault shares. The savings vault is
 * fixed at initialization (initially spUSDC) and MUST accept the base asset as
 * a deposit. The Spark Planner moves base asset out with take and back in with plain
 * transfers through the PAU (LIQUIDITY_MANAGER), and between idle and the
 * savings vault as REBALANCER.
 *
 * Requests: requestDeposit and requestRedeem become Claimable in the same
 * transaction, in full or in part, when their own queue is empty and the vault
 * has free capacity (deposits) or idle liquidity (redemptions). The rest joins
 * that FIFO queue; queued deposits wait in the savings vault. Only REBALANCER
 * matches the queues, through processQueue; a user request never matches
 * against the opposite queue.
 *
 * Claims: users move Claimable to Claimed themselves with deposit or mint and
 * withdraw or redeem. An approved operator may claim for a controller, to the
 * controller only, but cannot open or cancel requests.
 *
 * Cancellation: a queued deposit can be cancelled by its owner, its
 * controller or GUARDIAN, which refunds the owner. Redemption requests cannot be cancelled.
 *
 * Pause: GUARDIAN pauses every request and claim and DEFAULT_ADMIN
 * unpauses. Cancellation, processQueue and take keep working while paused.
 */

interface ISparkPrimeVault {

    /// @notice Emitted when the user performs deposit or mint with a referral code
    event ReferralCode(address beneficiary, uint256 code);

    /// @notice Emitted when a deposit request, or remainder from partial fill, is queued as `savingsShares`
    /// @dev `nonce` identifies the entry for cancelDepositRequest. requestId is always 0
    event DepositQueued(
        address indexed controller,
        address indexed owner,
        uint256 nonce,
        uint256 savingsShares
    );

    /// @notice Emitted when a queued deposit is cancelled and `assets` are refunded to `owner`
    event DepositRequestCancelled(
        address indexed controller,
        address indexed owner,
        uint256 nonce,
        uint256 assets
    );

    /// @notice Thrown when a required amount or address is zero
    error ZeroValueProvided();

    /// @notice Thrown when a request is below the configured minimum `amount`
    error BelowMinimumRequestAmount(uint256 amount);

    /// @notice Thrown when cancelDepositRequest targets a nonce with no queued deposit
    error RequestNotQueued(address controller, uint256 nonce);

    /// @notice Thrown when a withdraw or redeem claim exceeds the controller's claimable balance
    error InsufficientClaimableAmount(uint256 requested, uint256 actual);

    /// @notice Returned when the vault fails cannot pay out owed shares/assets to a claimer
    error Insolvency();

    error InsufficientFunds();

    /// @notice Cancels a queued deposit and refunds its savings shares, redeemed to base asset, to the request's owner
    /// @dev Callable by the owner, the controller or GUARDIAN, including while paused
    function cancelDepositRequest(address controller, uint256 nonce) external;

    /// @notice Overload of ERC4626 deposit to allow Spark Referal Program support
    function deposit(
        uint256 assets,
        address receiver,
        address controller,
        uint256 referralCode
    ) external returns (uint256 shares);

    /// @notice Overload of ERC4626 mint to allow Spark Referal Program support
    function mint(
        uint256 shares,
        address receiver,
        address controller,
        uint256 referralCode
    ) external returns (uint256 assets);

    /// @notice Nonce of the controller's latest request; queued deposits are keyed by (controller, nonce)
    function requestNonce(address controller) external view returns (uint256);

    /// @notice The queued deposit for (controller, nonce), its amount in savings vault shares; empty once filled or cancelled
    function queuedDepositRequest(
        address controller,
        uint256 nonce
    ) external view returns (IVault.Transaction memory transaction);

}
