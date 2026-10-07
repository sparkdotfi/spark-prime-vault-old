// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 }   from "../lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import { IERC165 }  from "../lib/openzeppelin-contracts/contracts/interfaces/IERC165.sol";
import { IERC4626 } from "../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

/**************************************************************************************************/
/*** ERC-7575 / ERC-7540 standard interfaces                                                    ***/
/**************************************************************************************************/

/// @dev https://eips.ethereum.org/EIPS/eip-7575
interface IERC7575 is IERC165, IERC4626 {

    function share() external view returns (address shareTokenAddress);

}

/// @dev https://eips.ethereum.org/EIPS/eip-7540
interface IERC7540Operator {

    event OperatorSet(address indexed controller, address indexed operator, bool approved);

    function setOperator(address operator, bool approved) external returns (bool);

    function isOperator(address controller, address operator) external view returns (bool status);

}

/// @dev https://eips.ethereum.org/EIPS/eip-7540
interface IERC7540Deposit {

    event DepositRequest(
        address indexed controller,
        address indexed owner,
        uint256 indexed requestId,
        address sender,
        uint256 assets
    );

    function requestDeposit(uint256 assets, address controller, address owner) external returns (uint256 requestId);

    function pendingDepositRequest(uint256 requestId, address controller) external view returns (uint256 pendingAssets);

    function claimableDepositRequest(uint256 requestId, address controller) external view returns (uint256 claimableAssets);

    function deposit(uint256 assets, address receiver, address controller) external returns (uint256 shares);

    function mint(uint256 shares, address receiver, address controller) external returns (uint256 assets);

}

/// @dev https://eips.ethereum.org/EIPS/eip-7540
interface IERC7540Redeem {

    event RedeemRequest(
        address indexed controller,
        address indexed owner,
        uint256 indexed requestId,
        address sender,
        uint256 shares
    );

    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId);

    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256 pendingShares);

    function claimableRedeemRequest(uint256 requestId, address controller) external view returns (uint256 claimableShares);

}

/// @dev https://eips.ethereum.org/EIPS/eip-7540
interface IERC7540 is IERC7540Operator, IERC7540Deposit, IERC7540Redeem, IERC7575 {}

/**************************************************************************************************/
/*** ISpPrime                                                                                   ***/
/**************************************************************************************************/

/**
 * @title  ISpPrime
 * @notice Asynchronous ERC-7540 vault with an admin-set continuous rate.
 *         Users request deposits/redeems. Requests fill instantly when capacity (deposits) or
 *         idle base asset (redeems) allows, otherwise they wait in FIFO queues until the
 *         Rebalancer calls processQueue. Filled amounts become claimable and the user claims
 *         them via deposit/mint or withdraw/redeem.
 */
interface ISpPrime is IERC7540 {

    /**********************************************************************************************/
    /*** Structs                                                                                ***/
    /**********************************************************************************************/

    /// @notice A queued request. `amount` is Savings Vault shares (deposit queue) or vault shares (withdraw queue)
    struct Transaction {
        address controller;
        address owner;
        uint256 amount;
        uint256 nonce;
    }

    struct InitParams {
        string   name;
        string   symbol;
        IERC20   baseAsset;
        IERC4626 savingsVault;
        uint256  minimumDeposit;
        uint256  minimumWithdraw;
        uint256  capacity;
        uint256  ratePerSecond;
        address  admin;
        address  vaultManager;
        address  liquidityManager;
        address  rebalancer;
    }

    /// @notice Per-controller accounting of pending and claimable amounts
    struct Settlement {
        uint256 depositedAssets;       // claimable deposit, in base asset
        uint256 sharesOwed;            // claimable deposit, in vault shares
        uint256 pendingSavingsShares;  // queued deposit, in Savings Vault shares
        uint256 withdrawnShares;       // claimable redeem, in vault shares
        uint256 assetsOwed;            // claimable redeem, in base asset
        uint256 pendingSharesOut;      // queued redeem, in vault shares
    }

    /**********************************************************************************************/
    /*** Errors                                                                                 ***/
    /**********************************************************************************************/

    error AssetMismatch();
    error DeltaMismatch();
    error ZeroValueProvided();
    error UnauthorizedCaller(address caller);
    error OperatorMaliciousAction(address receiver, address victim);
    error MustExceedMinimumRequestAmount(uint256 amount);
    error ShareConversionFailure(uint256 assets);
    error InsufficientClaimableBalance(uint256 requested, uint256 available);
    error InsufficientClaimableAmount(uint256 requested, uint256 actual);
    error InsufficientFunds();
    error Insolvency();
    error RequestNotQueued(address controller, uint256 nonce);

    // Queue
    error InputVolumeExceedsLiquidity();
    error InputVolumeExceedsAvailableCapacity();
    error PartialFillFailure();
    error AssetInvariantBroken(int256 available);
    error ShareInvariantBroken(int256 available);

    // Vault management
    error MaximumCapacityCannotExceedCurrentTotal();
    error InterestRateBelowRay();
    error TotalAssetsExceedIndexValue();

    /**********************************************************************************************/
    /*** Events                                                                                 ***/
    /**********************************************************************************************/

    event AccruedInterest(uint256 newIndex, uint256 timestamp);
    event ReferralCode(address beneficiary, uint256 code);
    event DepositRequestCancelled(
        address indexed controller,
        address indexed owner,
        uint256 nonce,
        uint256 assets
    );

    // Queue
    event ClaimableDeposit(address beneficiary, uint256 totalAmount);
    event ClaimableWithdraw(address beneficiary, uint256 totalShares);
    event DepositQueueValuation(uint256 newAmount);
    event WithdrawQueueValuation(uint256 newAmount);
    event TotalClaimableWithdraws(uint256 newAmount);

    // Liquidity management
    event FundsTaken(address indexed to, uint256 baseAmount);

    // Rebalancer
    event SavingsDeposit(uint256 assets, uint256 outputShares);
    event SavingsWithdraw(uint256 shares, uint256 outputAssets);

    // Vault management
    event RateUpdated(uint256 oldRate, uint256 newRate);
    event CapacityUpdated(uint256 oldCapacity, uint256 newCapacity);
    event WithdrawFeeUpdated(uint256 oldValue, uint256 newValue);
    event MinimumDepositUpdated(uint256 amount);
    event MinimumWithdrawUpdated(uint256 amount);
    event TotalAssetsUpdated(uint256 oldTotalAssets, uint256 newTotalAssets);

    /**********************************************************************************************/
    /*** User functions                                                                         ***/
    /**********************************************************************************************/

    /// @notice ERC-4626 deposit overload with a Spark referral code
    function deposit(
        uint256 assets,
        address receiver,
        address controller,
        uint256 referralCode
    ) external returns (uint256 shares);

    /// @notice Cancel a queued deposit. Savings Vault shares are redeemed to the request owner
    function cancelDepositRequest(address controller, uint256 nonce) external;

    /**********************************************************************************************/
    /*** Rebalancer functions                                                                   ***/
    /**********************************************************************************************/

    /// @notice Fill the withdraw queue then the deposit queue, up to `tradeVolume` base asset each
    function processQueue(uint256 tradeVolume) external;

    /// @notice Move idle base asset into the Savings Vault
    function depositToSavings(uint256 assets) external returns (uint256 shares);

    /// @notice Redeem Savings Vault shares back into base asset
    function withdrawFromSavings(uint256 shares) external returns (uint256 assets);

    /**********************************************************************************************/
    /*** Liquidity manager functions                                                            ***/
    /**********************************************************************************************/

    /// @notice Send base asset out of the vault to the caller
    function take(uint256 baseAmount) external;

    /**********************************************************************************************/
    /*** Vault manager / admin functions                                                        ***/
    /**********************************************************************************************/

    function setInterestRate(uint256 newRate) external;

    function setTotalAssets(uint256 newTotalAssets) external;

    function setCapacity(uint256 newCapacity) external;

    function setMinimumDeposit(uint256 amount) external;

    function setMinimumWithdraw(uint256 amount) external;

    function updateWithdrawFee(uint256 bps) external;

    function pause() external;

    function unpause() external;

    /**********************************************************************************************/
    /*** View functions                                                                         ***/
    /**********************************************************************************************/

    // Rate
    function interestRate() external view returns (uint256);

    function index() external view returns (uint256);

    function previewIndex() external view returns (uint256);

    function lastAccrual() external view returns (uint256);

    function totalLoss() external view returns (uint256);

    // Capacity and limits
    function maxCapacity() external view returns (uint256);

    function availableCapacity() external view returns (uint256);

    function minimumDeposit() external view returns (uint256);

    function minimumWithdraw() external view returns (uint256);

    // Liquidity
    function availableLiquidAssets() external view returns (int256);

    function maxTradeVolume() external view returns (uint256);

    // Queues
    function depositQueueLength() external view returns (uint256);

    function withdrawQueueLength() external view returns (uint256);

    function depositQueueHead() external view returns (Transaction memory transaction);

    function withdrawQueueHead() external view returns (Transaction memory transaction);

    function totalPendingDeposits() external view returns (uint256 shares);

    function totalPendingWithdraws() external view returns (uint256 shares);

    function claimableDepositTotal() external view returns (uint256);

    function claimableWithdrawTotal() external view returns (uint256);

    // Requests
    function requestNonce(address controller) external view returns (uint256);

    function queuedDepositRequest(
        address controller,
        uint256 nonce
    ) external view returns (Transaction memory transaction);

    function pendingWithdrawAmount(address controller) external view returns (uint256);

    // Upgrades
    function getImplementation() external view returns (address);

}
