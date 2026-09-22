// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ISparkPrimeVault
 * @notice Asynchronous ERC-7540 Vault with Admin set continuous rate
 * @author 0xpotionseller, arkis.xyz
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

interface ISparkPrimeVault {
    /// @notice Emitted when the user claims their withdraw
    event WithdrawClaimed(address beneficary, uint256 amount, uint256 shares);

    /// @notice Emitted when the user performs deposit with a referral code
    event ReferralCode(address beneficary, uint256 code);

    /// @notice Returned when the vault fails cannot pay out owed shares/assets to a claimer
    error Insolvency();

    error ZeroValueProvided();

    error InsufficientClaimableAmount(uint256 requested, uint256 actual);

    /// @notice Overload of ERC4626 deposit to allow Spark Referal Program support
    function deposit(
        uint256 assets,
        address receiver,
        address controller,
        uint256 referralCode
    ) external returns (uint256 shares);
}
