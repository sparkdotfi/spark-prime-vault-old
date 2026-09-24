// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISparkPrimeVault} from "./interfaces/ISparkPrimeVault.sol";
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    ERC4626Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {
    DoubleEndedQueue
} from "@openzeppelin/contracts/utils/structs/DoubleEndedQueue.sol";
import {TransactionQueue} from "./libraries/TransactionQueue.sol";
import {InterestLib} from "./libraries/InterestLib.sol";
import {VaultBase} from "./abstract/VaultBase.sol";
import {Rebalancer} from "./abstract/Rebalancer.sol";
import {LiquidityManagement} from "./abstract/LiquidityManagement.sol";
import {VaultManagement} from "./abstract/VaultManagement.sol";
import {Queue} from "./abstract/Queue.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {
    IERC7540Operator
} from "@openzeppelin/community-contracts/interfaces/IERC7540.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {console} from "forge-std/console.sol";
contract Vault is
    Rebalancer,
    //  LiquidityManagement,
    VaultManagement,
    Queue,
    ISparkPrimeVault
{
    //Withdraw Queue: Withdraw Requests that couldn't be fulfilled with availableLiquidAssets()
    //Deposit Queue: Requests that couldn't be fulfilled with availableCapacity()

    //Spark Principles
    //Invariant: If availableLiquidAssets > 0, Withdraw Queue must be empty.
    //Note: Can use transient storage here to make sure curator calls processQueue after any IRebalancer non-view function

    //Test: A user can cancel their deposit request and synchronously recieve unfulfilled amount
    //Test: A user can cancel their withdraw request and unlock any unfulfilled amount

    //FIFO principles
    //Test: If deposit queue exists, new deposit always queues
    //Test: If withdraw queue exists, new withdraw always queues

    //Operator Rules
    //Test: Operator cannot claim for a controller that hasn't assigned him
    //Test: Operator cannot claim deposit to any address other than the controller
    //Test: Operator cannot claim withdraw to any address other than the controller
    //Test: Operator cannot create a deposit request
    //Test: Operator cannot create a withdraw request

    //Withdraw Queue Rules
    //Test: User cannot transfer shares that they've commited to withdraw queue
    //Test: If no withdraw queue exists,

    //Withdraw Claim Rules
    //Test: If claim amount is greater than claimableWithdrawTotal(), always revert (Insolvency)

    //Deposit Queue Rules
    //Test:

    // TransactionQueue Library
    //Fuzz Test: Encoding and Decoding should be a strict bi-directional match, for any input

    using TransactionQueue for DoubleEndedQueue.Bytes32Deque;
    using SafeERC20 for IERC20;
    using SafeCast for int256;

    /// @dev type(IERC7575).interfaceId
    bytes4 private constant ERC7575_INTERFACE_ID = 0x2f0a18c5;
    /// @dev type(IERC7540Deposit).interfaceId
    bytes4 private constant ERC7540_DEPOSIT_INTERFACE_ID = 0xce3bbe50;
    /// @dev type(IERC7540Redeem).interfaceId
    bytes4 private constant ERC7540_REDEEM_INTERFACE_ID = 0x620ee8e4;

    constructor() {
        _disableInitializers();
    }
    function initialize(InitParams calldata params) external initializer {
        __ERC20_init(params.name, params.symbol);
        __ERC4626_init(params.baseAsset);
        __AccessControl_init();
        __Pausable_init();

        Storage storage $ = getStorage();
        $.savingsVault = params.savingsVault;
        $.maximumCapacity = params.capacity;
        $.minimumDeposit = params.minimumDeposit;
        $.minimumWithdraw = params.minimumWithdraw;
        $.ratePerSecond = params.ratePerSecond;
        $.indexRate = InterestLib.RAY;
        $.lastAccrualTimestamp = block.timestamp;

        _grantRole(DEFAULT_ADMIN_ROLE, params.admin);
        _grantRole(VAULT_MANAGER_ROLE, params.vaultManager);
        _grantRole(LIQUIDITY_MANAGER_ROLE, params.liquidityManager);
        _grantRole(REBALANCER_ROLER, params.rebalancer);
    }
    function pendingDepositRequest(
        uint256,
        address controller
    ) public view returns (uint256 pendingAssets) {
        Storage storage $ = getStorage();
        return $.ledger[controller].pendingAssetsIn;
    }

    function pendingRedeemRequest(
        uint256,
        address controller
    ) public view returns (uint256 pendingShares) {
        Storage storage $ = getStorage();
        return $.ledger[controller].pendingSharesOut;
    }

    function pendingWithdrawAmount(
        address controller
    ) public view returns (uint256) {
        Storage storage $ = getStorage();
        return $.ledger[controller].pendingSharesOut;
    }

    /// @dev Synchronous 4626 deposits are converted to async. The caller is assigned to controller
    function deposit(
        uint256 assets,
        address receiver
    ) public override(ERC4626Upgradeable, IERC4626) returns (uint256 shares) {
        return deposit(assets, receiver, msg.sender);
    }
    /** ERC7540 overrides **/

    /// @dev Should always revert if entire claimable amount cannot be fulfilled
    /// @notice Only user themselves or their approved operator can call
    /// @dev Always uses liquid shares, mints the excess (if capacity allows)
    function deposit(
        uint256 assets,
        address receiver,
        address controller
    ) public whenNotPaused nonReentrant returns (uint256 shares) {
        Storage storage $ = getStorage();
        if (assets == 0) revert ZeroValueProvided();

        if (controller != msg.sender && !isOperator(controller, msg.sender))
            revert UnauthorizedCaller(msg.sender);
        if (msg.sender != controller && receiver != controller)
            revert OperatorMaliciousAction(receiver, controller);

        if (assets > $.ledger[controller].assetsIn)
            revert InsufficientClaimableBalance(
                assets,
                $.ledger[controller].assetsIn
            );

        InterestLib.accrueInterest($);

        shares = convertToShares(assets);
        if (shares == 0) revert ShareConversionFailure(assets);

        $.ledger[controller].assetsIn -= assets;
        $.totalClaimableDeposits -= assets;

        _mint(receiver, shares);

        emit Deposit(controller, receiver, assets, shares);
        return shares;
    }

    function requestDeposit(
        uint256 assets,
        address controller,
        address owner
    ) public whenNotPaused nonReentrant returns (uint256) {
        Storage storage $ = getStorage();
        if (assets == 0) revert ZeroValueProvided();
        if (assets < $.minimumDeposit)
            revert MustExceedMinimumRequestAmount($.minimumDeposit);
        if (msg.sender != owner) revert UnauthorizedCaller(msg.sender);

        InterestLib.accrueInterest($);

        /// How many shares are available to mint (subtracting what we've committed to claimable deposits)
        uint256 capacity = availableCapacity();

        Transaction memory transaction = Transaction(
            controller,
            owner,
            assets,
            ++$.nonces[controller]
        );
        if (!$.depositQueue.isEmpty() || capacity == 0) {
            /// If a queue exists, or there's no shares to mint: Immediately queue entire request
            _pushToDepositQueue($, transaction);
        } else if (assets > capacity) {
            /// User request can be partially fulfilled instantly, remainder is queued
            _markClaimableDeposit($, controller, capacity, true);
            transaction.amount -= capacity;
            _pushToDepositQueue($, transaction);
        } else {
            /// User request can be completed fulfilled instantly
            _markClaimableDeposit($, controller, assets, true);
        }

        /// Transfer baseAsset from user to vault and emit DepositRequest
        IERC20 baseAsset = IERC20(asset());

        uint256 before = baseAsset.balanceOf(address(this));
        baseAsset.safeTransferFrom(owner, address(this), assets);

        if (baseAsset.balanceOf(address(this)) - before != assets)
            revert DeltaMismatch();

        emit DepositRequest(controller, owner, 0, msg.sender, assets);
        return 0;
    }

    function deposit(
        uint256 assets,
        address receiver,
        address controller,
        uint256 referralCode
    ) public returns (uint256 shares) {
        emit ReferralCode(receiver, referralCode);
        return deposit(assets, receiver, controller);
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address controller
    )
        public
        override(ERC4626Upgradeable, IERC4626)
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        _authorizeClaim(receiver, controller);

        Storage storage $ = getStorage();
        Settlement storage settlement = $.ledger[controller];

        if (assets > settlement.assetsOut)
            revert InsufficientClaimableAmount(assets, settlement.assetsOut);

        /// Calculate the amount owed to user, based on their sharesOut and assetsOut at `processQueue` time
        shares = Math.mulDiv(
            settlement.sharesOut,
            assets,
            settlement.assetsOut,
            Math.Rounding.Ceil
        );

        _claimRedeem(receiver, controller, shares, assets);
    }

    function mint(
        uint256 shares,
        address receiver,
        address controller
    ) public returns (uint256 assets) {
        uint256 sharesReceived = deposit(
            convertToAssets(shares),
            receiver,
            controller
        );
        assets = convertToAssets(sharesReceived);
    }

    function mint(
        uint256 shares,
        address receiver
    ) public override(ERC4626Upgradeable, IERC4626) returns (uint256 assets) {
        return mint(shares, receiver, msg.sender); /// @dev When user calls 4626 sync functions, we transform to async assuming they are their own controller
    }

    function requestRedeem(
        uint256 shares,
        address controller,
        address owner
    ) public whenNotPaused nonReentrant returns (uint256) {
        Storage storage $ = getStorage();
        if (shares == 0) revert ZeroValueProvided();
        if (convertToAssets(shares) < $.minimumWithdraw)
            revert MustExceedMinimumRequestAmount($.minimumWithdraw);

        if (owner != msg.sender) revert UnauthorizedCaller(msg.sender);

        Transaction memory transaction = Transaction(
            controller,
            owner,
            shares,
            ++$.nonces[controller]
        );

        emit RedeemRequest(controller, owner, 0, msg.sender, shares);

        /// Vault locks the users shares by taking ownership of them
        _transfer(owner, address(this), shares);

        InterestLib.accrueInterest($);

        /// Amount of baseAsset the vault holds (subtracting amounts commited to claimable withdraws)
        int256 availableLiquidAssets = availableLiquidAssets();

        /// If no assets/over-commited to claimers or queue already exists: Immediately queue entire request
        if (availableLiquidAssets <= 0 || !$.withdrawQueue.isEmpty()) {
            _pushToWithdrawQueue($, transaction);
        } else {
            uint256 requestedAmount = convertToAssets(shares);
            uint256 liquidAssets = availableLiquidAssets.toUint256();

            /// Users entire request can be fulfilled using the vaults liquid assets, instant claimable
            if (liquidAssets >= requestedAmount) {
                _markClaimableWithdraw($, controller, shares, true);
            } else {
                uint256 instantShares = convertToShares(liquidAssets);
                /// We partially fill from liquidAssets if possible
                if (instantShares > 0) {
                    _markClaimableWithdraw($, controller, instantShares, true);
                    transaction.amount -= instantShares;
                }
                /// We queue the remainder
                if (transaction.amount > 0)
                    _pushToWithdrawQueue($, transaction);
            }
        }
        return 0;
    }

    function redeem(
        uint256 shares,
        address receiver,
        address controller
    )
        public
        override(ERC4626Upgradeable, IERC4626)
        whenNotPaused
        nonReentrant
        returns (uint256 assets)
    {
        _authorizeClaim(receiver, controller);

        Storage storage $ = getStorage();

        Settlement storage settlement = $.ledger[controller];

        if (settlement.sharesOut < shares)
            revert InsufficientClaimableAmount(shares, settlement.sharesOut);

        /// Calculate the amount owed to user, based on their sharesOut and assetsOut at `processQueue` time
        assets = Math.mulDiv(
            settlement.assetsOut,
            shares,
            settlement.sharesOut
        );

        _claimRedeem(receiver, controller, shares, assets);
    }

    function _authorizeClaim(
        address receiver,
        address controller
    ) internal view {
        if (controller != msg.sender && !isOperator(controller, msg.sender))
            revert UnauthorizedCaller(msg.sender);
        if (msg.sender != controller && receiver != controller)
            revert OperatorMaliciousAction(receiver, controller);
    }

    function _claimRedeem(
        address receiver,
        address controller,
        uint256 shares,
        uint256 assets
    ) internal {
        Storage storage $ = getStorage();
        Settlement storage settlement = $.ledger[controller];

        settlement.sharesOut -= shares;
        settlement.assetsOut -= assets;
        $.totalClaimableWithdrawAssets -= assets;

        IERC20 baseAsset = IERC20(asset());
        if (assets > baseAsset.balanceOf(address(this))) revert Insolvency();
        baseAsset.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    function cancelDepositRequest(
        address controller,
        uint256 nonce
    ) external nonReentrant {
        Storage storage $ = getStorage();
        bytes32 element = TransactionQueue.depositKey(controller, nonce);

        (bool active, Transaction memory data) = TransactionQueue.tryGet(
            $,
            element
        );
        if (!active) revert RequestNotQueued(controller, nonce);
        _authorizeCancel(controller, data.owner);

        InterestLib.accrueInterest($);

        uint256 assets = data.amount;

        int256 free = availableLiquidAssets();
        if (free < 0 || uint256(free) < assets)
            revert InsufficientFreeLiquidity(assets, free);

        delete $.transactionRegistry[element];
        $.totalDepositQueueAssets -= assets;
        $.ledger[controller].pendingAssetsIn -= assets;

        emit DepositRequestCancelled(controller, data.owner, nonce, assets);
        emit DepositQueueValuation($.totalDepositQueueAssets);

        IERC20(asset()).safeTransfer(data.owner, assets);
    }

    function _authorizeCancel(
        address controller,
        address owner
    ) internal view {
        if (
            msg.sender != owner &&
            msg.sender != controller &&
            !isOperator(controller, msg.sender) &&
            !hasRole(VAULT_MANAGER_ROLE, msg.sender)
        ) revert UnauthorizedCaller(msg.sender);
    }

    function requestNonce(address controller) public view returns (uint256) {
        Storage storage $ = getStorage();
        return $.nonces[controller];
    }

    function queuedDepositRequest(
        address controller,
        uint256 nonce
    ) public view returns (Transaction memory transaction) {
        Storage storage $ = getStorage();
        transaction = $.transactionRegistry[
            TransactionQueue.depositKey(controller, nonce)
        ];
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(AccessControlUpgradeable, IERC165) returns (bool) {
        return
            interfaceId == type(IERC7540Operator).interfaceId ||
            interfaceId == ERC7575_INTERFACE_ID ||
            interfaceId == ERC7540_DEPOSIT_INTERFACE_ID ||
            interfaceId == ERC7540_REDEEM_INTERFACE_ID ||
            super.supportsInterface(interfaceId);
    }

    function setOperator(
        address operator,
        bool approved
    ) external returns (bool) {
        Storage storage $ = getStorage();
        if (approved && operator == address(0)) revert ZeroValueProvided();
        if (approved) $.operators[msg.sender] = operator;
        else if ($.operators[msg.sender] == operator)
            $.operators[msg.sender] = address(0);

        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    function isOperator(
        address controller,
        address operator
    ) public view returns (bool status) {
        if (operator == address(0)) return false;
        Storage storage $ = getStorage();
        status = $.operators[controller] == operator;
    }
}
