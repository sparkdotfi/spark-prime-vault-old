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
} from "./interfaces/IERC7540.sol";
import {IERC7575Share} from "./interfaces/IERC7575.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract Vault is Rebalancer, VaultManagement, Queue, ISparkPrimeVault {
    using TransactionQueue for TransactionQueue.RequestQueue;
    using SafeERC20 for IERC20;
    using SafeCast for int256;

    bytes4 private constant ERC7575_INTERFACE_ID = 0x2f0a18c5;
    bytes4 private constant ERC7540_DEPOSIT_INTERFACE_ID = 0xce3bbe50;
    bytes4 private constant ERC7540_REDEEM_INTERFACE_ID = 0x620ee8e4;

    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams calldata params) external initializer {
        if (params.savingsVault.asset() != address(params.baseAsset))
            revert AssetMismatch();
        if (params.ratePerSecond < InterestLib.RAY)
            revert InterestRateBelowRay();
        if (params.ratePerSecond > InterestLib.MAX_RATE)
            revert InterestRateAboveMax();
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
        _grantRole(REBALANCER_ROLE, params.rebalancer);
        _grantRole(GUARDIAN_ROLE, params.guardian);
        _grantRole(RISK_MANAGER_ROLE, params.riskManager);
    }

    function requestDeposit(
        uint256 assets,
        address controller,
        address owner
    ) public whenNotPaused nonReentrant returns (uint256) {
        Storage storage $ = getStorage();
        if (assets == 0 || controller == address(0)) revert ZeroValueProvided();
        if (assets < $.minimumDeposit)
            revert BelowMinimumRequestAmount($.minimumDeposit);
        if (msg.sender != owner) revert UnauthorizedCaller(msg.sender);

        InterestLib.accrueInterest($);
        if (convertToShares(assets) == 0) revert ShareConversionFailure(assets);

        uint256 capacity = _convertToAssets(
            availableCapacity(),
            Math.Rounding.Ceil
        );

        Transaction memory transaction = Transaction(
            controller,
            owner,
            assets,
            0
        );
        IERC20 baseAsset = IERC20(asset());

        uint256 before = baseAsset.balanceOf(address(this));
        baseAsset.safeTransferFrom(owner, address(this), assets);

        if (baseAsset.balanceOf(address(this)) - before != assets)
            revert DeltaMismatch();

        if (!$.depositQueue.isEmpty() || capacity == 0) {
            _queueDeposit($, transaction);
        } else if (assets > capacity) {
            _markClaimableDeposit($, transaction, capacity, true);
            transaction.amount -= capacity;
            _queueDeposit($, transaction);
        } else {
            _markClaimableDeposit($, transaction, assets, true);
        }

        emit DepositRequest(controller, owner, 0, msg.sender, assets);
        return 0;
    }

    function _queueDeposit(
        Storage storage $,
        Transaction memory transaction
    ) internal {
        IERC20(asset()).forceApprove(
            address($.savingsVault),
            transaction.amount
        );
        uint256 shares = $.savingsVault.deposit(
            transaction.amount,
            address(this)
        );
        if (shares == 0) revert ShareConversionFailure(transaction.amount);
        transaction.amount = shares;
        uint256 slot = _pushToDepositQueue($, transaction);
        emit DepositQueued(
            transaction.controller,
            transaction.owner,
            slot,
            shares
        );
    }

    function cancelDepositRequest(
        address controller,
        uint256 id
    ) external nonReentrant {
        Storage storage $ = getStorage();
        Transaction memory data = $.depositQueue.entries[id];

        if (data.controller != controller) revert RequestNotQueued(controller, id);
        _authorizeCancel(controller, data.owner);

        uint256 shares = data.amount;

        $.depositQueue.cancel(id);
        $.ledger[controller].pendingSavingsShares -= shares;

        uint256 assets = $.savingsVault.redeem(
            shares,
            data.owner,
            address(this)
        );

        emit DepositRequestCancelled(controller, data.owner, id, assets);
        emit DepositQueueValuation($.depositQueue.pending);
    }

    function deposit(
        uint256 assets,
        address receiver,
        address controller
    ) public whenNotPaused nonReentrant returns (uint256 shares) {
        Storage storage $ = getStorage();
        if (assets == 0) revert ZeroValueProvided();

        _authorizeClaim(receiver, controller);

        Settlement storage settlement = $.ledger[controller];

        if (assets > settlement.depositedAssets)
            revert InsufficientClaimableBalance(
                assets,
                settlement.depositedAssets
            );

        InterestLib.accrueInterest($);

        shares = Math.mulDiv(
            settlement.sharesOwed,
            assets,
            settlement.depositedAssets
        );
        if (shares == 0) revert ShareConversionFailure(assets);

        _claimDeposit(receiver, controller, assets, shares);
    }

    function deposit(
        uint256 assets,
        address receiver
    ) public override(ERC4626Upgradeable, IERC4626) returns (uint256 shares) {
        return deposit(assets, receiver, msg.sender);
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

    function mint(
        uint256 shares,
        address receiver,
        address controller
    ) public whenNotPaused nonReentrant returns (uint256 assets) {
        Storage storage $ = getStorage();
        if (shares == 0) revert ZeroValueProvided();

        _authorizeClaim(receiver, controller);

        Settlement storage settlement = $.ledger[controller];

        if (shares > settlement.sharesOwed)
            revert InsufficientClaimableBalance(shares, settlement.sharesOwed);

        InterestLib.accrueInterest($);

        assets = Math.mulDiv(
            settlement.depositedAssets,
            shares,
            settlement.sharesOwed,
            Math.Rounding.Ceil
        );

        _claimDeposit(receiver, controller, assets, shares);
    }

    function mint(
        uint256 shares,
        address receiver
    ) public override(ERC4626Upgradeable, IERC4626) returns (uint256 assets) {
        return mint(shares, receiver, msg.sender);
    }

    function mint(
        uint256 shares,
        address receiver,
        address controller,
        uint256 referralCode
    ) public returns (uint256 assets) {
        emit ReferralCode(receiver, referralCode);
        return mint(shares, receiver, controller);
    }

    function requestRedeem(
        uint256 shares,
        address controller,
        address owner
    ) public whenNotPaused nonReentrant returns (uint256) {
        Storage storage $ = getStorage();
        InterestLib.accrueInterest($);
        if (shares == 0 || controller == address(0)) revert ZeroValueProvided();
        if (convertToAssets(shares) < $.minimumWithdraw)
            revert BelowMinimumRequestAmount($.minimumWithdraw);

        if (owner != msg.sender) revert UnauthorizedCaller(msg.sender);

        Transaction memory transaction = Transaction(
            controller,
            owner,
            shares,
            $.withdrawFee
        );

        emit RedeemRequest(controller, owner, 0, msg.sender, shares);

        _transfer(owner, address(this), shares);

        int256 availableLiquidAssets = availableLiquidAssets();

        if (availableLiquidAssets <= 0 || !$.withdrawQueue.isEmpty()) {
            _pushToWithdrawQueue($, transaction);
        } else {
            uint256 requestedAmount = convertToAssets(shares);
            uint256 liquidAssets = availableLiquidAssets.toUint256();

            if (liquidAssets >= requestedAmount) {
                _markClaimableWithdraw($, transaction, shares, true);
            } else {
                uint256 instantShares = convertToShares(liquidAssets);
                if (instantShares > 0) {
                    _markClaimableWithdraw(
                        $,
                        transaction,
                        instantShares,
                        true
                    );
                    transaction.amount -= instantShares;
                }
                if (transaction.amount > 0)
                    _pushToWithdrawQueue($, transaction);
            }
        }
        return 0;
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
        if (assets == 0) revert ZeroValueProvided();
        _authorizeClaim(receiver, controller);

        Storage storage $ = getStorage();
        Settlement storage settlement = $.ledger[controller];

        if (assets > settlement.assetsOwed)
            revert InsufficientClaimableAmount(assets, settlement.assetsOwed);

        shares = Math.mulDiv(
            settlement.withdrawnShares,
            assets,
            settlement.assetsOwed,
            Math.Rounding.Ceil
        );

        _claimRedeem(receiver, controller, shares, assets);
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
        if (shares == 0) revert ZeroValueProvided();
        _authorizeClaim(receiver, controller);

        Storage storage $ = getStorage();

        Settlement storage settlement = $.ledger[controller];

        if (settlement.withdrawnShares < shares)
            revert InsufficientClaimableAmount(
                shares,
                settlement.withdrawnShares
            );

        assets = Math.mulDiv(
            settlement.assetsOwed,
            shares,
            settlement.withdrawnShares
        );

        _claimRedeem(receiver, controller, shares, assets);
    }

    function _authorizeClaim(
        address receiver,
        address controller
    ) internal view {
        if (
            controller != msg.sender &&
            (!isOperator(controller, msg.sender) || receiver != controller)
        ) revert UnauthorizedCaller(msg.sender);
        if (receiver == address(0) || receiver == address(this))
            revert ERC20InvalidReceiver(receiver);
    }

    function _authorizeCancel(address controller, address owner) internal view {
        if (
            msg.sender != owner &&
            msg.sender != controller &&
            !hasRole(GUARDIAN_ROLE, msg.sender)
        ) revert UnauthorizedCaller(msg.sender);
    }

    function _claimDeposit(
        address receiver,
        address controller,
        uint256 assets,
        uint256 shares
    ) internal {
        Storage storage $ = getStorage();
        Settlement storage settlement = $.ledger[controller];

        settlement.depositedAssets -= assets;
        settlement.sharesOwed -= shares;
        $.totalClaimableDepositShares -= shares;
        emit ClaimableDeposit(controller, settlement.depositedAssets);

        _transfer(address(this), receiver, shares);

        emit Deposit(controller, receiver, assets, shares);
    }

    function _claimRedeem(
        address receiver,
        address controller,
        uint256 shares,
        uint256 assets
    ) internal {
        Storage storage $ = getStorage();
        Settlement storage settlement = $.ledger[controller];

        settlement.withdrawnShares -= shares;
        settlement.assetsOwed -= assets;
        $.totalClaimableWithdrawAssets -= assets;
        emit ClaimableWithdraw(controller, settlement.assetsOwed);
        emit TotalClaimableWithdraws($.totalClaimableWithdrawAssets);

        IERC20 baseAsset = IERC20(asset());
        if (assets > baseAsset.balanceOf(address(this))) revert Insolvency();
        baseAsset.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    function setOperator(
        address operator,
        bool approved
    ) external returns (bool) {
        Storage storage $ = getStorage();
        if (approved && operator == address(0)) revert ZeroValueProvided();
        $.operators[msg.sender][operator] = approved;

        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    function isOperator(
        address controller,
        address operator
    ) public view returns (bool status) {
        Storage storage $ = getStorage();
        status = $.operators[controller][operator];
    }

    function pendingDepositRequest(
        uint256,
        address controller
    ) public view returns (uint256 pendingAssets) {
        Storage storage $ = getStorage();
        return
            $.savingsVault.convertToAssets(
                $.ledger[controller].pendingSavingsShares
            );
    }

    function pendingRedeemRequest(
        uint256,
        address controller
    ) public view returns (uint256 pendingShares) {
        Storage storage $ = getStorage();
        return $.ledger[controller].pendingSharesOut;
    }

    function queuedDepositRequest(
        uint256 id
    ) public view returns (Transaction memory) {
        return getStorage().depositQueue.entries[id];
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(AccessControlUpgradeable, IERC165) returns (bool) {
        return
            interfaceId == type(IERC7540Operator).interfaceId ||
            interfaceId == ERC7575_INTERFACE_ID ||
            interfaceId == type(IERC7575Share).interfaceId ||
            interfaceId == ERC7540_DEPOSIT_INTERFACE_ID ||
            interfaceId == ERC7540_REDEEM_INTERFACE_ID ||
            super.supportsInterface(interfaceId);
    }
}
