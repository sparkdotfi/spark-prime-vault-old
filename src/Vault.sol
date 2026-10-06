// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import { IERC165 } from "../lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";
import { IERC20 } from "../lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import { IERC4626 } from "../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

import { Math } from "../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { SafeCast } from "../lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import { SafeERC20 } from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { TransientSlot } from "../lib/openzeppelin-contracts/contracts/utils/TransientSlot.sol";

import {
    AccessControlUpgradeable
} from "../lib/openzeppelin-contracts-upgradeable/contracts/access/AccessControlUpgradeable.sol";

import {
    ERC4626Upgradeable
} from "../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC4626Upgradeable.sol";

import {
    PausableUpgradeable
} from "../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";

import {
    ReentrancyGuardTransient
} from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";

import { IERC7540Operator } from "./interfaces/IERC7540.sol";
import { IERC7575Share } from "./interfaces/IERC7575.sol";
import { ILiquidityManagement } from "./interfaces/ILiquidityManagement.sol";
import { IQueue } from "./interfaces/IQueue.sol";
import { IRebalancer } from "./interfaces/IRebalancer.sol";
import { ISparkPrimeVault } from "./interfaces/ISparkPrimeVault.sol";
import { IVault } from "./interfaces/IVault.sol";
import { IVaultManagement } from "./interfaces/IVaultManagement.sol";

import { TransactionQueue } from "./libraries/TransactionQueue.sol";

contract Vault is
    ERC4626Upgradeable,
    ReentrancyGuardTransient,
    PausableUpgradeable,
    AccessControlUpgradeable,
    IVault,
    ILiquidityManagement,
    IQueue,
    IRebalancer,
    IVaultManagement,
    ISparkPrimeVault
{

    // TODO: Get rid of all these with direct library calls.
    using TransactionQueue for TransactionQueue.RequestQueue;
    using SafeERC20 for IERC20;
    using SafeCast for int256;
    using SafeCast for uint256;
    using TransientSlot for *;

    /**********************************************************************************************/
    /*** Constants                                                                              ***/
    /**********************************************************************************************/

    // TODO: These should be removed in favour of inline `.interfaceId`.
    bytes4 private constant ERC7575_INTERFACE_ID = 0x2f0a18c5;
    bytes4 private constant ERC7540_DEPOSIT_INTERFACE_ID = 0xce3bbe50;
    bytes4 private constant ERC7540_REDEEM_INTERFACE_ID = 0x620ee8e4;

    // TODO: Investigate need for transient storage and consider alternate transient storage layout.
    bytes32 private constant SAVINGS_VAULT_PRICE_PER_SHARE =
        keccak256("sparkprime.vault.depositFillRate");

    // TODO: Interface functions and natspec inherit.
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant LIQUIDITY_MANAGER_ROLE = keccak256("LIQUIDITY_MANAGER_ROLE");
    bytes32 public constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE");
    bytes32 public constant RISK_MANAGER_ROLE = keccak256("RISK_MANAGER_ROLE");
    bytes32 public constant VAULT_MANAGER_ROLE = keccak256("VAULT_MANAGER_ROLE");

    // TODO: Interface functions and natspec inherit.
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_RATE = 1.000000021979553151239153027e27;
    uint256 public constant MAX_WITHDRAW_BPS = 5_000;
    uint256 public constant RAY = 1e27;

    /**********************************************************************************************/
    /*** Storage Domain                                                                         ***/
    /**********************************************************************************************/

    // TODO: Investigate need for each of these storage variables.
    /// @custom:storage-location erc7201:spark.sp-prime.vault.v1
    struct VaultStorage {
        mapping (address => Settlement) ledger;
        mapping (address => mapping (address => bool)) operators;
        mapping (address => uint256) nonces;
        TransactionQueue.RequestQueue withdrawQueue;
        TransactionQueue.RequestQueue depositQueue;
        address baseAsset;
        address savingsVault;
        uint256 maximumCapacity;
        uint256 minimumDeposit;
        uint256 minimumWithdraw;
        uint256 ratePerSecond;
        uint256 lastAccrualTimestamp;
        uint256 indexRate;
        uint256 totalDepositQueueSavingsShares;
        uint256 totalWithdrawQueueShares;
        uint256 totalClaimableDepositShares;
        uint256 totalClaimableWithdrawAssets;
        uint256 withdrawFee;
    }

    // keccak256(abi.encode(uint256(keccak256("spark.sp-prime.vault.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 constant STORAGE_SLOT =
        0x972e4775afbe9f187885747468bb3416c7eea6d07463b27927fceb561fbf4200;

    function _getStorage() internal view returns (VaultStorage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }

    /**********************************************************************************************/
    /*** Initialization                                                                         ***/
    /**********************************************************************************************/

    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams calldata params) external initializer {
        if (IERC4626(params.savingsVault).asset() != params.baseAsset) revert AssetMismatch();

        if (params.ratePerSecond < RAY) revert InterestRateBelowRay();

        if (params.ratePerSecond > MAX_RATE) revert InterestRateAboveMax();

        if (params.capacity > type(uint128).max) revert CapacityAboveLimit();

        if (
            params.admin == address(0) ||
            params.vaultManager == address(0) ||
            params.liquidityManager == address(0) ||
            params.rebalancer == address(0) ||
            params.guardian == address(0) ||
            params.riskManager == address(0)
        ) revert ZeroValueProvided();

        __ERC20_init(params.name, params.symbol);
        __ERC4626_init(IERC20(params.baseAsset));
        __AccessControl_init();
        __Pausable_init();

        VaultStorage storage $ = _getStorage();

        $.savingsVault         = params.savingsVault;
        $.maximumCapacity      = params.capacity;
        $.minimumDeposit       = params.minimumDeposit;
        $.minimumWithdraw      = params.minimumWithdraw;
        $.ratePerSecond        = params.ratePerSecond;
        $.indexRate            = RAY;
        $.lastAccrualTimestamp = block.timestamp;

        _grantRole(DEFAULT_ADMIN_ROLE,     params.admin);
        _grantRole(VAULT_MANAGER_ROLE,     params.vaultManager);
        _grantRole(LIQUIDITY_MANAGER_ROLE, params.liquidityManager);
        _grantRole(REBALANCER_ROLE,        params.rebalancer);
        _grantRole(GUARDIAN_ROLE,          params.guardian);
        _grantRole(RISK_MANAGER_ROLE,      params.riskManager);
    }

    /**********************************************************************************************/
    /*** Admin Functions                                                                        ***/
    /**********************************************************************************************/

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**********************************************************************************************/
    /*** Vault Manager Functions                                                                ***/
    /**********************************************************************************************/

    function setInterestRate(uint256 newRate) external onlyRole(VAULT_MANAGER_ROLE) {
        if (newRate < RAY) revert InterestRateBelowRay();

        if (newRate > MAX_RATE) revert InterestRateAboveMax();

        VaultStorage storage $ = _getStorage();

        _accrueInterest($);

        emit RateUpdated($.ratePerSecond, newRate);

        $.ratePerSecond = newRate;
    }

    function setTotalAssets(uint256 newTotalAssets)
        external
        onlyRole(RISK_MANAGER_ROLE)
        whenPaused
    {
        if (newTotalAssets == 0) revert ISparkPrimeVault.ZeroValueProvided();

        VaultStorage storage $ = _getStorage();

        _accrueInterest($);

        uint256 oldTotalAssets = totalAssets();

        if (newTotalAssets > oldTotalAssets) revert TotalAssetsExceedIndexValue();

        $.indexRate = Math.mulDiv($.indexRate, newTotalAssets, oldTotalAssets);

        emit TotalAssetsUpdated(oldTotalAssets, newTotalAssets);
    }

    function setCapacity(uint256 newCapacity) external onlyRole(VAULT_MANAGER_ROLE) {
        if (newCapacity > type(uint128).max) revert CapacityAboveLimit();

        if (newCapacity < totalSupply()) revert CapacityBelowTotalSupply();

        VaultStorage storage $ = _getStorage();

        emit CapacityUpdated($.maximumCapacity, newCapacity);

        $.maximumCapacity = newCapacity;
    }

    function setMinimumDeposit(uint256 amount) external onlyRole(VAULT_MANAGER_ROLE) {
        emit MinimumDepositUpdated(_getStorage().minimumDeposit = amount);
    }

    function setMinimumWithdraw(uint256 amount) external onlyRole(VAULT_MANAGER_ROLE) {
        emit MinimumWithdrawUpdated(_getStorage().minimumWithdraw = amount);
    }

    /**********************************************************************************************/
    /*** Rebalancer Functions                                                                   ***/
    /**********************************************************************************************/

    function depositToSavings(uint256 assets)
        external
        onlyRole(REBALANCER_ROLE)
        nonReentrant
        returns (uint256 shares)
    {
        _requireAvailableLiquidity(assets);

        VaultStorage storage $ = _getStorage();

        IERC20(asset()).forceApprove($.savingsVault, assets);

        shares = IERC4626($.savingsVault).deposit(assets, address(this));

        if (shares == 0) revert ShareConversionFailure(assets);

        emit SavingsDeposit(assets, shares);
    }

    function withdrawFromSavings(uint256 shares)
        external
        onlyRole(REBALANCER_ROLE)
        nonReentrant
        returns (uint256 assets)
    {
        VaultStorage storage $ = _getStorage();

        uint256 held   = IERC4626($.savingsVault).balanceOf(address(this));
        uint256 queued = $.totalDepositQueueSavingsShares;

        if (shares + queued > held) {
            revert ExceedsFreeSavingsShares(shares, held > queued ? held - queued : 0);
        }

        assets = IERC4626($.savingsVault).redeem(shares, address(this), address(this));

        emit SavingsWithdraw(shares, assets);
    }

    // TODO: This should be called `processQueues`, but maybe there should be separate functions for each.
    function processQueue(uint256 tradeVolume) external onlyRole(REBALANCER_ROLE) nonReentrant {
        VaultStorage storage $ = _getStorage();

        _accrueInterest($);

        tradeVolume = Math.min(tradeVolume, maxTradeVolume());

        // TODO: What is the implication of the order of these?
        _fillWithdrawQueue(tradeVolume);
        _fillDepositQueue(tradeVolume);

        int256 assetsLeft = availableLiquidAssets();

        if (assetsLeft < 0) revert AssetInvariantBroken(assetsLeft);

        int256 sharesLeft = $.maximumCapacity.toInt256() - totalSupply().toInt256();

        if (sharesLeft < 0) revert ShareInvariantBroken(sharesLeft);
    }

    /**********************************************************************************************/
    /*** Liquidity Manager Functions                                                            ***/
    /**********************************************************************************************/

    function take(uint256 baseAmount) external onlyRole(LIQUIDITY_MANAGER_ROLE) nonReentrant {
        _requireAvailableLiquidity(baseAmount);

        IERC20(asset()).safeTransfer(msg.sender, baseAmount);

        emit FundsTaken(msg.sender, baseAmount);
    }

    /**********************************************************************************************/
    /*** Risk Manager Functions                                                                 ***/
    /**********************************************************************************************/

    function updateWithdrawFee(uint256 bps) external onlyRole(RISK_MANAGER_ROLE) {
        if (bps > MAX_WITHDRAW_BPS) revert WithdrawFeeAboveMax();

        VaultStorage storage $ = _getStorage();

        emit WithdrawFeeUpdated($.withdrawFee, bps);

        $.withdrawFee = bps;
    }

    /**********************************************************************************************/
    /*** Guardian Functions                                                                     ***/
    /**********************************************************************************************/

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    /**********************************************************************************************/
    /*** User Functions                                                                         ***/
    /**********************************************************************************************/

    // TODO: No longer return 0, buy use a global monotonically increasing counter for request IDs.
    function requestDeposit(uint256 assets, address controller, address owner)
        external
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        VaultStorage storage $ = _getStorage();

        if (assets == 0 || controller == address(0)) revert ZeroValueProvided();

        if (assets < $.minimumDeposit) revert BelowMinimumRequestAmount($.minimumDeposit);

        if (msg.sender != owner) revert UnauthorizedCaller(msg.sender);

        _accrueInterest($);

        if (convertToShares(assets) == 0) revert ShareConversionFailure(assets);

        uint256 capacity = _convertToAssets(availableCapacity(), Math.Rounding.Ceil);

        Transaction memory transaction = Transaction(
            controller,
            owner,
            assets,
            ++$.nonces[controller], // TODO: When a global monotonically increasing counter is used, this can be removed from `Transaction`.
            0
        );

        IERC20 baseAsset = IERC20(asset());

        uint256 before = baseAsset.balanceOf(address(this));

        baseAsset.safeTransferFrom(owner, address(this), assets);

        if (baseAsset.balanceOf(address(this)) - before != assets) revert DeltaMismatch();

        if (!$.depositQueue.isEmpty() || capacity == 0) {
            _queueDeposit($, transaction);
        } else if (assets > capacity) {
            // TODO: No multi-paths, everything should go through the deposit queue.
            _markClaimableDeposit($, transaction, capacity, true);

            transaction.amount -= capacity;

            _queueDeposit($, transaction);
        } else {
            // TODO: No multi-paths, everything should go through the deposit queue.
            _markClaimableDeposit($, transaction, assets, true);
        }

        // TODO: Request ID can be put in the event.
        emit DepositRequest(controller, owner, 0, msg.sender, assets);

        return 0;
    }

    function _queueDeposit(VaultStorage storage $, Transaction memory transaction) internal {
        IERC20(asset()).forceApprove($.savingsVault, transaction.amount);

        uint256 shares = IERC4626($.savingsVault).deposit(transaction.amount, address(this));

        if (shares == 0) revert ShareConversionFailure(transaction.amount);

        transaction.amount = shares;

        _pushToDepositQueue($, transaction);

        emit DepositQueued(transaction.controller, transaction.owner, transaction.nonce, shares);
    }

    function cancelDepositRequest(address controller, uint256 nonce) external nonReentrant {
        bytes32 element = TransactionQueue.key(controller, nonce);

        VaultStorage storage $ = _getStorage();

        ( bool active, Transaction memory data ) = TransactionQueue.tryGet($.depositQueue, element);

        if (!active) revert RequestNotQueued(controller, nonce);

        if (
            (msg.sender != data.owner) &&
            (msg.sender != controller) &&
            !hasRole(GUARDIAN_ROLE, msg.sender)
        ) {
            revert UnauthorizedCaller(msg.sender);
        }

        _accrueInterest($);

        uint256 shares = data.amount;

        $.depositQueue.cancel(element);

        $.totalDepositQueueSavingsShares          -= shares;
        $.ledger[controller].pendingSavingsShares -= shares;

        uint256 assets = IERC4626($.savingsVault).redeem(shares, data.owner, address(this));

        emit DepositRequestCancelled(controller, data.owner, nonce, assets);
        emit DepositQueueValuation($.totalDepositQueueSavingsShares);
    }

    // TODO: Make a single `_deposit` function and have the 3 public overloads each be `whenNotPaused` and `nonReentrant` and call it.
    function deposit(uint256 assets, address receiver, address controller)
        public
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroValueProvided();

        _authorizeClaim(receiver, controller);

        VaultStorage storage $ = _getStorage();

        Settlement storage settlement = $.ledger[controller];

        if (assets > settlement.depositedAssets) {
            revert InsufficientClaimableBalance(assets, settlement.depositedAssets);
        }

        _accrueInterest($);

        shares = Math.mulDiv(settlement.sharesOwed, assets, settlement.depositedAssets);

        if (shares == 0) revert ShareConversionFailure(assets);

        _claimDeposit(receiver, controller, assets, shares);
    }

    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256 shares)
    {
        return deposit(assets, receiver, msg.sender);
    }

    function deposit(uint256 assets, address receiver, address controller, uint256 referralCode)
        public
        returns (uint256 shares)
    {
        emit ReferralCode(receiver, referralCode);
        return deposit(assets, receiver, controller);
    }

    // TODO: Make a single `_mint` function and have the 3 public overloads each be `whenNotPaused` and `nonReentrant` and call it.
    function mint(uint256 shares, address receiver, address controller)
        public
        whenNotPaused
        nonReentrant
        returns (uint256 assets)
    {
        if (shares == 0) revert ZeroValueProvided();

        _authorizeClaim(receiver, controller);

        VaultStorage storage $ = _getStorage();

        Settlement storage settlement = $.ledger[controller];

        if (shares > settlement.sharesOwed) {
            revert InsufficientClaimableBalance(shares, settlement.sharesOwed);
        }

        _accrueInterest($);

        assets = Math.mulDiv(
            settlement.depositedAssets,
            shares,
            settlement.sharesOwed,
            Math.Rounding.Ceil
        );

        _claimDeposit(receiver, controller, assets, shares);
    }

    function mint(uint256 shares, address receiver)
        public
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256 assets)
    {
        return mint(shares, receiver, msg.sender);
    }

    function mint(uint256 shares, address receiver, address controller, uint256 referralCode)
        public
        returns (uint256 assets)
    {
        emit ReferralCode(receiver, referralCode);
        return mint(shares, receiver, controller);
    }

    // TODO: No longer return 0, buy use a global monotonically increasing counter for request IDs.
    function requestRedeem(uint256 shares, address controller, address owner)
        public
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        VaultStorage storage $ = _getStorage();

        _accrueInterest($);

        if (shares == 0 || controller == address(0)) revert ZeroValueProvided();

        if (convertToAssets(shares) < $.minimumWithdraw) {
            revert BelowMinimumRequestAmount($.minimumWithdraw);
        }

        if (owner != msg.sender) revert UnauthorizedCaller(msg.sender);

        Transaction memory transaction = Transaction(
            controller,
            owner,
            shares,
            ++$.nonces[controller], // TODO: When a global monotonically increasing counter is used, this can be removed from `Transaction`.
            $.withdrawFee
        );

        // TODO: Request ID can be put in the event.
        emit RedeemRequest(controller, owner, 0, msg.sender, shares);

        _transfer(owner, address(this), shares);

        int256 availableLiquidAssets = availableLiquidAssets();

        if (availableLiquidAssets <= 0 || !$.withdrawQueue.isEmpty()) {
            _pushToWithdrawQueue($, transaction);

            return 0;
        }

        uint256 requestedAmount = convertToAssets(shares);
        uint256 liquidAssets    = availableLiquidAssets.toUint256();

        if (liquidAssets >= requestedAmount) {
            // TODO: No multi-paths, everything should go through the withdraw queue.
            _markClaimableWithdraw($, transaction, shares, true);

            return 0;
        }

        uint256 instantShares = convertToShares(liquidAssets);

        if (instantShares > 0) {
            // TODO: No multi-paths, everything should go through the withdraw queue.
            _markClaimableWithdraw(
                $,
                transaction,
                instantShares,
                true
            );

            transaction.amount -= instantShares;
        }

        if (transaction.amount > 0) {
            _pushToWithdrawQueue($, transaction);
        }

        return 0;
    }

    function withdraw(uint256 assets, address receiver, address controller)
        public
        override(ERC4626Upgradeable, IERC4626)
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroValueProvided();

        _authorizeClaim(receiver, controller);

        Settlement storage settlement = _getStorage().ledger[controller];

        if (assets > settlement.assetsOwed) {
            revert InsufficientClaimableAmount(assets, settlement.assetsOwed);
        }

        shares = Math.mulDiv(
            settlement.withdrawnShares,
            assets,
            settlement.assetsOwed,
            Math.Rounding.Ceil
        );

        _claimRedeem(receiver, controller, shares, assets);
    }

    function redeem(uint256 shares, address receiver, address controller)
        public
        override(ERC4626Upgradeable, IERC4626)
        whenNotPaused
        nonReentrant
        returns (uint256 assets)
    {
        if (shares == 0) revert ZeroValueProvided();

        _authorizeClaim(receiver, controller);

        Settlement storage settlement = _getStorage().ledger[controller];

        if (settlement.withdrawnShares < shares) {
            revert InsufficientClaimableAmount(shares, settlement.withdrawnShares);
        }

        assets = Math.mulDiv(settlement.assetsOwed, shares, settlement.withdrawnShares);

        _claimRedeem(receiver, controller, shares, assets);
    }

    function _authorizeClaim(address receiver, address controller) internal view {
        if (
            (controller != msg.sender) &&
            (
                !isOperator(controller, msg.sender) || (receiver != controller)
            )
        ) {
            revert UnauthorizedCaller(msg.sender);
        }

        if ((receiver == address(0)) || (receiver == address(this))) {
            revert ERC20InvalidReceiver(receiver);
        }
    }

    function _claimDeposit(address receiver, address controller, uint256 assets, uint256 shares)
        internal
    {
        VaultStorage storage $          = _getStorage();
        Settlement   storage settlement = $.ledger[controller];

        settlement.depositedAssets    -= assets;
        settlement.sharesOwed         -= shares;
        $.totalClaimableDepositShares -= shares;

        emit ClaimableDeposit(controller, settlement.depositedAssets);

        _transfer(address(this), receiver, shares);

        emit Deposit(controller, receiver, assets, shares);
    }

    function _claimRedeem(address receiver, address controller, uint256 shares, uint256 assets)
        internal
    {
        VaultStorage storage $          = _getStorage();
        Settlement   storage settlement = $.ledger[controller];

        settlement.withdrawnShares     -= shares;
        settlement.assetsOwed          -= assets;
        $.totalClaimableWithdrawAssets -= assets;

        emit ClaimableWithdraw(controller, settlement.assetsOwed);
        emit TotalClaimableWithdraws($.totalClaimableWithdrawAssets);

        IERC20 baseAsset = IERC20(asset());

        if (assets > baseAsset.balanceOf(address(this))) revert Insolvency();

        baseAsset.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    function setOperator(address operator, bool approved) external returns (bool) {
        if (approved && operator == address(0)) revert ZeroValueProvided();

        _getStorage().operators[msg.sender][operator] = approved;

        emit OperatorSet(msg.sender, operator, approved);

        return true;
    }

    function isOperator(address controller, address operator) public view returns (bool status) {
        return _getStorage().operators[controller][operator];
    }

    function pendingDepositRequest(uint256, address controller)
        external
        view
        returns (uint256 pendingAssets)
    {
        VaultStorage storage $ = _getStorage();

        return IERC4626($.savingsVault).convertToAssets($.ledger[controller].pendingSavingsShares);
    }

    function pendingRedeemRequest(uint256, address controller)
        external
        view
        returns (uint256 pendingShares)
    {
        return _getStorage().ledger[controller].pendingSharesOut;
    }

    // TODO: Should be able to remove this once a global monotonically increasing counter is used for request IDs.
    function requestNonce(address controller) external view returns (uint256) {
        return _getStorage().nonces[controller];
    }

    function queuedDepositRequest(address controller, uint256 nonce)
        external
        view
        returns (Transaction memory transaction)
    {
        transaction = _getStorage().depositQueue.entries[
            TransactionQueue.key(controller, nonce)
        ];
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControlUpgradeable, IERC165)
        returns (bool)
    {
        // TODO: Use `.interfaceId` instead of magic values (i.e. `type(IERC7575).interfaceId`).
        return
            interfaceId == type(IERC7540Operator).interfaceId ||
            interfaceId == ERC7575_INTERFACE_ID ||
            interfaceId == type(IERC7575Share).interfaceId ||
            interfaceId == ERC7540_DEPOSIT_INTERFACE_ID ||
            interfaceId == ERC7540_REDEEM_INTERFACE_ID ||
            super.supportsInterface(interfaceId);
    }

    /**********************************************************************************************/
    /*** Internal Interactive Functions                                                         ***/
    /**********************************************************************************************/

    function _accrueInterest(VaultStorage storage $) internal {
        uint256 timeDelta = block.timestamp - $.lastAccrualTimestamp;

        if (timeDelta == 0) return;

        $.lastAccrualTimestamp = block.timestamp;

        uint256 compoundingFactor = _rpow($.ratePerSecond, timeDelta);

        $.indexRate = Math.mulDiv($.indexRate, compoundingFactor, RAY);

        emit IVault.AccruedInterest($.indexRate, block.timestamp);
    }

    /**********************************************************************************************/
    /*** External/Public View/Pure Functions                                                    ***/
    /**********************************************************************************************/

    function availableLiquidAssets() public view returns (int256 totalBaseAssets) {
        return
            IERC20(asset()).balanceOf(address(this)).toInt256() -
            _getStorage().totalClaimableWithdrawAssets.toInt256();
    }

    function withdrawFee() external view returns (uint256) {
        return _getStorage().withdrawFee;
    }

    /**********************************************************************************************/
    /*** Internal View/Pure Functions                                                           ***/
    /**********************************************************************************************/

    function _requireAvailableLiquidity(uint256 amount) internal view {
        int256 available = availableLiquidAssets();

        if (amount.toInt256() > available) revert ExceedsAvailableLiquidity(amount, available);
    }

    function _accruedIndexRate() internal view returns (uint256 newIndexRate) {
        VaultStorage storage $ = _getStorage();

        uint256 timeDelta = block.timestamp - $.lastAccrualTimestamp;

        if (timeDelta == 0) return $.indexRate;

        uint256 compoundingFactor = _rpow($.ratePerSecond, timeDelta);

        return Math.mulDiv($.indexRate, compoundingFactor, RAY);
    }

    function _rpow(uint256 x, uint256 n) internal pure returns (uint256 z) {
        assembly {
            switch x case 0 {switch n case 0 {z := RAY} default {z := 0}}
            default {
                switch mod(n, 2) case 0 { z := RAY } default { z := x }
                let half := div(RAY, 2)  // for rounding.
                for { n := div(n, 2) } n { n := div(n,2) } {
                    let xx := mul(x, x)
                    if iszero(eq(div(xx, x), x)) { revert(0,0) }
                    let xxRound := add(xx, half)
                    if lt(xxRound, xx) { revert(0,0) }
                    x := div(xxRound, RAY)
                    if mod(n,2) {
                        let zx := mul(z, x)
                        if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) { revert(0,0) }
                        let zxRound := add(zx, half)
                        if lt(zxRound, zx) { revert(0,0) }
                        z := div(zxRound, RAY)
                    }
                }
            }
        }
    }

    /**********************************************************************************************/
    /*** Vault Base Stuff                                                                       ***/
    /**********************************************************************************************/

    function convertToShares(uint256 assets)
        public
        view
        virtual
        override(IERC4626, ERC4626Upgradeable)
        returns (uint256)
    {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    function convertToAssets(uint256 shares)
        public
        view
        override(IERC4626, ERC4626Upgradeable)
        returns (uint256)
    {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding)
        internal
        view
        override(ERC4626Upgradeable)
        returns (uint256)
    {
        return Math.mulDiv(assets, RAY, _accruedIndexRate(), rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding)
        internal
        view
        override(ERC4626Upgradeable)
        returns (uint256)
    {
        return Math.mulDiv(shares, _accruedIndexRate(), RAY, rounding);
    }

    function totalAssets() public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return convertToAssets(totalSupply());
    }

    function interestRate() external view returns (uint256) {
        return _getStorage().ratePerSecond;
    }

    function index() external view returns (uint256) {
        return _getStorage().indexRate;
    }

    function previewIndex() external view returns (uint256 newIndexRate) {
        return _accruedIndexRate();
    }

    function lastAccrual() external view returns (uint256) {
        return _getStorage().lastAccrualTimestamp;
    }

    function maxCapacity() external view returns (uint256) {
        return _getStorage().maximumCapacity;
    }

    function availableCapacity() public view returns (uint256 available) {
        uint256 maximumCapacity_ = _getStorage().maximumCapacity;
        uint256 supply           = totalSupply();

        return maximumCapacity_ > supply ? maximumCapacity_ - supply : 0;
    }

    function minimumDeposit() external view returns (uint256) {
        return _getStorage().minimumDeposit;
    }

    function minimumWithdraw() external view returns (uint256) {
        return _getStorage().minimumWithdraw;
    }

    function claimableDepositRequest(uint256, address controller)
        external
        view
        override
        returns (uint256 claimableAssets)
    {
        claimableAssets = _getStorage().ledger[controller].depositedAssets;
    }

    function maxDeposit(address controller)
        public
        view
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256 claimableAssets)
    {
        return paused() ? 0 : _getStorage().ledger[controller].depositedAssets;
    }

    function maxMint(address controller)
        public
        view
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256 claimableShares)
    {
        return paused() ? 0 : _getStorage().ledger[controller].sharesOwed;
    }

    function claimableRedeemRequest(uint256, address controller)
        external
        view
        override
        returns (uint256 claimableShares)
    {
        return _getStorage().ledger[controller].withdrawnShares;
    }

    function maxWithdraw(address controller)
        public
        view
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256 claimValue)
    {
        return paused() ? 0 : _getStorage().ledger[controller].assetsOwed;
    }

    function maxRedeem(address controller)
        public
        view
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256 claimableShares)
    {
        return paused() ? 0 : _getStorage().ledger[controller].withdrawnShares;
    }

    function previewDeposit(uint256)
        public
        pure
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256)
    {
        revert();
    }

    function previewMint(uint256)
        public
        pure
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256)
    {
        revert();
    }

    function previewWithdraw(uint256)
        public
        pure
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256)
    {
        revert();
    }

    function previewRedeem(uint256)
        public
        pure
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256)
    {
        revert();
    }

    // TODO: This virtual getter needs to be renamed.
    function share() external view override returns (address shareTokenAddress) {
        return address(this);
    }

    function vault(address asset_) external view returns (address) {
        return asset_ == asset() ? address(this) : address(0);
    }

    /**********************************************************************************************/
    /*** Queue Stuff                                                                            ***/
    /**********************************************************************************************/

    function maxTradeVolume() public view returns (uint256) {
        return Math.min(_availableDepositLiquidity(), _availableWithdrawLiquidity());
    }

    function _availableDepositLiquidity() internal view returns (uint256 valueInBaseAssets) {
        int256 liquidAssets = availableLiquidAssets() + _fillableDepositValue().toInt256();

        return uint256(liquidAssets > 0 ? liquidAssets : int256(0));
    }

    function _availableWithdrawLiquidity() internal view returns (uint256 valueInBaseAssets) {
        return convertToAssets(totalPendingWithdraws() + availableCapacity());
    }

    function _fillWithdrawQueue(uint256 tradeVolume) internal {
        VaultStorage storage $ = _getStorage();

        uint256 queuedBefore = $.totalWithdrawQueueShares;

        tradeVolume >= convertToAssets(totalPendingWithdraws())
            ? _fillUnbounded($, $.withdrawQueue, _markClaimableWithdraw)
            : _fillUntil($, $.withdrawQueue, _markClaimableWithdraw, convertToShares(tradeVolume));

        uint256 matched = queuedBefore - $.totalWithdrawQueueShares;

        if (matched <= 0) return;

        _burn(address(this), matched);

        emit WithdrawQueueValuation($.totalWithdrawQueueShares);
    }

    function _fillDepositQueue(uint256 tradeVolume) internal {
        VaultStorage storage $ = _getStorage();

        uint256 totalSavingsSharesInQueue = $.totalDepositQueueSavingsShares;
        uint256 claimableBefore           = $.totalClaimableDepositShares;
        uint256 queueValue                = _depositQueueValuation();
        uint256 volume                    = Math.min(tradeVolume, _fillableDepositValue());

        bool fillAll = volume >= queueValue;

        ( uint256 shares, uint256 credit ) =
            fillAll
                ? ( totalSavingsSharesInQueue, queueValue )
                : ( _savingsSharesFor($.savingsVault, volume), volume );

        SAVINGS_VAULT_PRICE_PER_SHARE.asUint256().tstore(
            shares == 0 ? 0 : Math.mulDiv(credit, RAY, shares)
        );

        fillAll
            ? _fillUnbounded($, $.depositQueue, _markClaimableDeposit)
            : _fillUntil($, $.depositQueue, _markClaimableDeposit, shares);

        SAVINGS_VAULT_PRICE_PER_SHARE.asUint256().tstore(0);

        uint256 minted = $.totalClaimableDepositShares - claimableBefore;

        if (minted > 0) _mint(address(this), minted);

        uint256 processedSavingsShares =
            totalSavingsSharesInQueue - $.totalDepositQueueSavingsShares;

        if (processedSavingsShares <= 0) return;

        IERC4626($.savingsVault).redeem(processedSavingsShares, address(this), address(this));

        emit DepositQueueValuation($.totalDepositQueueSavingsShares);
    }

    function _fillUnbounded(
        VaultStorage storage $,
        TransactionQueue.RequestQueue storage queue,
        function (VaultStorage storage, Transaction memory, uint256, bool) claim
    ) internal {
        uint256 n = queue.length();

        for (n; n > 0; --n) {
            ( bool active, Transaction memory data ) = queue.pop();

            if (!active) continue;

            claim($, data, data.amount, false);
        }
    }

    function _fillUntil(
        VaultStorage storage $,
        TransactionQueue.RequestQueue storage queue,
        function (VaultStorage storage, Transaction memory, uint256, bool) claim,
        uint256 remainder
    ) internal {
        uint256 length = queue.length();

        while (remainder > 0) {
            if (length == 0) revert PartialFillFailure();

            ( bool active, Transaction memory data ) = queue.pop();

            --length;

            if (!active) continue;

            if (data.amount >= remainder) {
                claim($, data, remainder, false);

                if (data.amount == remainder) return;

                // Re-insert rest of amount at head.
                data.amount -= remainder;
                queue.pushFront(data);

                return;
            }

            claim($, data, data.amount, false);

            remainder -= data.amount;
        }
    }

    function _pushToDepositQueue(VaultStorage storage $, IVault.Transaction memory data) internal {
        $.depositQueue.push(data);

        $.totalDepositQueueSavingsShares               += data.amount;
        $.ledger[data.controller].pendingSavingsShares += data.amount;

        emit DepositQueueValuation($.totalDepositQueueSavingsShares);
    }

    // TODO: Remove code smell of boolean flag. Either the caller knows how to handle the case of an
    //       instant deposit, or there is a `_markClaimableDeposit` and `_markInstantClaimableDeposit`.
    function _markClaimableDeposit(
        VaultStorage storage $,
        Transaction memory data,
        uint256 amount,
        bool instantClaim
    ) internal {
        address controller = data.controller;

        uint256 baseAssets =
            instantClaim
                ? amount
                : Math.mulDiv(amount, SAVINGS_VAULT_PRICE_PER_SHARE.asUint256().tload(), RAY);

        uint256 shares = convertToShares(baseAssets);

        if (shares == 0) baseAssets = 0;

        $.ledger[controller].depositedAssets += baseAssets;
        $.ledger[controller].sharesOwed      += shares;
        $.totalClaimableDepositShares        += shares;

        if (instantClaim) {
            _mint(address(this), shares);
        } else {
            $.ledger[controller].pendingSavingsShares -= amount;
            $.totalDepositQueueSavingsShares          -= amount;
        }

        emit ClaimableDeposit(controller, $.ledger[controller].depositedAssets);
    }

    function _pushToWithdrawQueue(VaultStorage storage $, IVault.Transaction memory data) internal {
        $.withdrawQueue.push(data);
        $.totalWithdrawQueueShares += data.amount;
        $.ledger[data.controller].pendingSharesOut += data.amount;

        emit WithdrawQueueValuation($.totalWithdrawQueueShares);
    }

    // TODO: Remove code smell of boolean flag. Either the caller knows how to handle the case of an
    //       instant withdraw, or there is a `_markClaimableWithdraw` and `_markInstantClaimableWithdraw`.
    function _markClaimableWithdraw(
        VaultStorage storage $,
        Transaction memory data,
        uint256 amount,
        bool instantClaim
    ) internal {
        address controller = data.controller;
        uint256 assets     = convertToAssets(amount);

        assets -= Math.mulDiv(assets, data.fee, BPS, Math.Rounding.Ceil);

        $.ledger[controller].withdrawnShares += amount;
        $.ledger[controller].assetsOwed      += assets;
        $.totalClaimableWithdrawAssets       += assets;

        if (instantClaim) {
            _burn(address(this), amount);
        } else {
            $.ledger[controller].pendingSharesOut -= amount;
            $.totalWithdrawQueueShares            -= amount;
        }

        emit ClaimableWithdraw(controller, $.ledger[controller].assetsOwed);
        emit TotalClaimableWithdraws($.totalClaimableWithdrawAssets);
    }

    function sanitizeDepositQueue(uint256 maxIterations) external returns (uint256 removed) {
        return _getStorage().depositQueue.sanitize(maxIterations);
    }

    function totalPendingDeposits() external view returns (uint256 shares) {
        return _getStorage().totalDepositQueueSavingsShares;
    }

    function _depositQueueValuation() internal view returns (uint256 assets) {
        VaultStorage storage $ = _getStorage();

        uint256 shares = $.totalDepositQueueSavingsShares;

        return shares == 0 ? 0 : IERC4626($.savingsVault).convertToAssets(shares);
    }

    function _fillableDepositValue() internal view returns (uint256) {
        uint256 queued = _depositQueueValuation();

        if (queued == 0) return 0;

        IERC4626 savingsVault = IERC4626(_getStorage().savingsVault);

        uint256 redeemable = savingsVault.convertToAssets(savingsVault.maxRedeem(address(this)));

        return Math.min(queued, redeemable);
    }

    // TODO: This seems odd as it always assume at most a 1 wei rounding error.
    function _savingsSharesFor(address savingsVault, uint256 assets)
        internal
        view
        returns (uint256 shares)
    {
        shares = IERC4626(savingsVault).convertToShares(assets);

        return IERC4626(savingsVault).convertToAssets(shares) < assets ? shares + 1 : shares;
    }

    function depositQueueLength() external view returns (uint256) {
        TransactionQueue.RequestQueue storage depositQueue = _getStorage().depositQueue;

        return TransactionQueue.length(depositQueue) - depositQueue.cancelled;
    }

    // TODO: I cannot imagine this function being exclusively necessary. Either they can all be
    //       externally fetched or none of them can be. They are not extremely costly to fetch.
    function depositQueueHead() external view returns (Transaction memory transaction) {
        return TransactionQueue.front(_getStorage().depositQueue);
    }

    function claimableDepositTotal() external view returns (uint256) {
        return _getStorage().totalClaimableDepositShares;
    }

    function totalPendingWithdraws() public view returns (uint256 shares) {
        return _getStorage().totalWithdrawQueueShares;
    }

    function withdrawQueueLength() external view returns (uint256) {
        return TransactionQueue.length(_getStorage().withdrawQueue);
    }

    // TODO: I cannot imagine this function being exclusively necessary. Either they can all be
    //       externally fetched or none of them can be. They are not extremely costly to fetch.
    function withdrawQueueHead() external view returns (Transaction memory transaction) {
        return TransactionQueue.front(_getStorage().withdrawQueue);
    }

    function claimableWithdrawTotal() external view returns (uint256) {
        return _getStorage().totalClaimableWithdrawAssets;
    }

}
