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
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {console} from "forge-std/console.sol";
contract Vault is
    Rebalancer,
    //  LiquidityManagement,
    VaultManagement,
    Queue,
    ISparkPrimeVault,
    PausableUpgradeable
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
    //Test: Claimed amount is deducted from lockedShares
    //Test: If claim amount is greater than claimableWithdrawTotal(), always revert (Insolvency)

    //Deposit Queue Rules
    //Test:

    // TransactionQueue Library
    //Fuzz Test: Encoding and Decoding should be a strict bi-directional match, for any input

    using TransactionQueue for DoubleEndedQueue.Bytes32Deque;
    using SafeERC20 for IERC20;
    using SafeCast for int256;
    using TransientSlot for bytes32;
    using TransientSlot for TransientSlot.BooleanSlot;

    /// @dev cast index-erc7201 sparkprime.vault.internalTransfer
    bytes32 private constant INTERNAL_TRANSFER_SLOT =
        0x847c1ce996b34c883673c43d0837cf9867d57360e13c4942350d76beee85a400;

    function _setInternalTransfer(bool value) private {
        INTERNAL_TRANSFER_SLOT.asBoolean().tstore(value);
    }

    function _isInternalTransfer() private view returns (bool) {
        return INTERNAL_TRANSFER_SLOT.asBoolean().tload();
    }
    constructor() {
        _disableInitializers();
    }
    function initialize(
        string memory name,
        string memory symbol,
        IERC20 _baseAsset,
        IERC4626 _savingsVault,
        uint256 minimumDeposit,
        uint256 minimumWithdraw,
        uint256 _capacity,
        uint256 _ratePerSecond,
        address admin,
        address vaultManager,
        address liquidityManager,
        address rebalancer
    ) external initializer {
        __ERC20_init(name, symbol);
        __ERC4626_init(_baseAsset);
        __AccessControl_init();
        __Pausable_init();

        {
            Storage storage $ = getStorage();
            $.savingsVault = _savingsVault;
            $.maximumCapacity = _capacity;
            $.minimumDeposit = minimumDeposit;
            $.minimumWithdraw = minimumWithdraw;
            $.ratePerSecond = _ratePerSecond;
            $.indexRate = InterestLib.RAY;
            $.lastAccrualTimestamp = block.timestamp;
        }

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(VAULT_MANAGER_ROLE, vaultManager);
        _grantRole(LIQUIDITY_MANAGER_ROLE, liquidityManager);
        _grantRole(REBALANCER_ROLER, rebalancer);
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
    ) public returns (uint256 shares) {
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

        console.log("USer assetsIn: %e", $.ledger[controller].assetsIn);
        console.log("assets minused: %e", assets);

        $.ledger[controller].assetsIn -= assets;

        // We can only mint shares if we're below capacity and transfer shares we own
        // How much of that can we mint, and how much of that can we get from our idle balance

        uint256 totalLiquidShares = balanceOf(address(this));

        if (totalAssets() >= $.maximumCapacity) {
            // we cant mint
            if (totalLiquidShares < shares) revert Insolvency(); // Not enough withdraws have claimed to fill liquidity
            _setInternalTransfer(true);
            _transfer(address(this), receiver, shares);
            _setInternalTransfer(false);
        } else {
            // we can mint $.maximumCapacity - totalAssets()
            uint256 mintableShares = convertToShares(
                $.maximumCapacity - totalAssets()
            );
            console.log("Mintable Shares: %e", mintableShares);
            console.log("Total Liquid Shares: %e", totalLiquidShares);
            if (totalLiquidShares + mintableShares < shares)
                revert Insolvency(); // Both vault owned shares and minting couldn't fulfill this request

            uint256 fromLiquid = Math.min(shares, totalLiquidShares);
            if (fromLiquid > 0) {
                _setInternalTransfer(true);
                _transfer(address(this), receiver, fromLiquid);
                _setInternalTransfer(false);
            }

            console.log("toMint = %e - %e", shares, fromLiquid);
            uint256 toMint = shares - fromLiquid;
            if (toMint > 0) super._mint(receiver, toMint);
        }

        $.totalClaimableDeposits -= assets;
        $.totalAssets += assets;
        emit Deposit(msg.sender, controller, assets, shares);
        return shares;
    }

    function requestDeposit(
        uint256 assets,
        address controller,
        address owner
    ) public returns (uint256) {
        Storage storage $ = getStorage();
        if (assets == 0) revert ZeroValueProvided();
        if (assets < $.minimumDeposit)
            revert MustExceedMinimumRequestAmount($.minimumDeposit);
        if (msg.sender != owner) revert UnauthorizedCaller(msg.sender);

        uint256 capacity = availableCapacity();
        Transaction memory transaction = Transaction(
            controller,
            assets,
            ++$.nonces[controller]
        );
        if (!$.depositQueue.isEmpty() || capacity == 0) {
            _pushToDepositQueue($, transaction);
        } else if (assets > capacity) {
            _markClaimableDeposit($, controller, capacity, true);
            transaction.amount -= capacity;
            _pushToDepositQueue($, transaction);
        } else {
            _markClaimableDeposit($, controller, assets, true);
        }

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
    ) public override(ERC4626Upgradeable, IERC4626) returns (uint256 shares) {
        return
            convertToAssets(
                redeem(convertToShares(assets), receiver, controller)
            );
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
    ) public returns (uint256) {
        Storage storage $ = getStorage();
        if (shares == 0) revert ZeroValueProvided();
        if (convertToAssets(shares) < $.minimumWithdraw)
            revert MustExceedMinimumRequestAmount($.minimumWithdraw);

        if (owner != msg.sender) revert UnauthorizedCaller(msg.sender);

        uint256 unlockedShares = balanceOf(owner) - $.lockedShares[owner];
        if (shares > unlockedShares) revert InsufficientFunds();

        Transaction memory transaction = Transaction(
            controller,
            shares,
            ++$.nonces[controller]
        );

        emit RedeemRequest(controller, owner, 0, msg.sender, shares);

        if (owner != controller) {
            /// @dev If owner != controller: A user has put blind trust in their controller to claim and manage requests on their behalf.
            /// We want to accrue yield and allow cancellations while in the withdraw queue but redeem has no concept of the owner.
            /// In this case, we transfer shares to the controller. The controller is trusted to call the correct `reciever == owner` at redeem time
            _transfer(owner, controller, shares);
            owner = controller;
        }

        $.lockedShares[owner] += shares;

        InterestLib.accrueInterest($);

        int256 availableLiquidAssets = availableLiquidAssets();

        if (availableLiquidAssets <= 0 || !$.withdrawQueue.isEmpty()) {
            _pushToWithdrawQueue($, transaction);
        } else {
            uint256 requestedAmount = convertToAssets(shares);
            uint256 liquidAssets = availableLiquidAssets.toUint256();

            if (liquidAssets >= requestedAmount) {
                _markClaimableWithdraw($, owner, shares, true);
            } else {
                uint256 instantShares = convertToShares(liquidAssets);
                _markClaimableWithdraw($, owner, instantShares, true);
                transaction.amount -= instantShares;
                _pushToWithdrawQueue($, transaction);
            }
        }
        return 0;
    }

    function redeem(
        uint256 shares,
        address receiver,
        address controller
    ) public override(ERC4626Upgradeable, IERC4626) returns (uint256 assets) {
        if (controller != msg.sender && !isOperator(controller, msg.sender))
            revert UnauthorizedCaller(msg.sender);
        if (msg.sender != controller && receiver != controller)
            revert OperatorMaliciousAction(receiver, controller);

        Storage storage $ = getStorage();

        if ($.ledger[controller].sharesOut < shares)
            revert InsufficientClaimableAmount(
                shares,
                $.ledger[controller].sharesOut
            );

        $.ledger[controller].sharesOut -= shares;
        $.totalClaimableWithdraws -= shares;

        _setInternalTransfer(true);
        _transfer(controller, address(this), shares);
        _setInternalTransfer(false);
        //(IERC20(address(this)), owner, address(this), shares);

        InterestLib.accrueInterest($);
        assets = convertToAssets(shares);
        IERC20 baseAsset = IERC20(asset());
        uint256 liquidAssets = baseAsset.balanceOf(address(this));

        if (assets > liquidAssets) revert Insolvency();
        baseAsset.safeTransfer(receiver, assets);

        $.lockedShares[controller] -= shares;
        emit WithdrawClaimed(receiver, assets, shares);
    }

    /// @dev Prevent a Withdrawer from transferring their commited shares
    /// @dev Exclude mints
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        Storage storage $ = getStorage();

        if (from != address(0) && !_isInternalTransfer()) {
            uint256 balanceRemaining = balanceOf(from) - value;
            if ($.lockedShares[from] > balanceRemaining) revert();
        }

        super._update(from, to, value);
    }

    function setOperator(
        address operator,
        bool approved
    ) external returns (bool) {
        Storage storage $ = getStorage();
        if (approved) $.operators[msg.sender] = operator;
        else if ($.operators[msg.sender] == operator)
            $.operators[msg.sender] = address(0);
        else revert NotAnOperator(operator);
        return true;
    }

    function isOperator(
        address controller,
        address operator
    ) public view returns (bool status) {
        Storage storage $ = getStorage();
        status = $.operators[controller] == operator;
    }
}
