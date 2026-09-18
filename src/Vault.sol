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
import {console} from "forge-std/console.sol";
contract Vault is
    Rebalancer,
    LiquidityManagement,
    VaultManagement,
    Queue,
    ISparkPrimeVault,
    PausableUpgradeable
{
    //Withdraw Queue: Withdraw Requests that couldn't be fulfilled with availableLiquidAssets()
    //Deposit Queue: Requests that couldn't be fulfilled with availableLiquidShares()

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

        // We can only mint shares if we're below capacity and transfer shares we own
        // How much of that can we mint, and how much of that can we get from our idle balance

        uint256 totalLiquidShares = this.balanceOf(address(this));

        if (totalAssets() >= $.maximumCapacity) {
            // we cant mint
            if (totalLiquidShares < assets) revert Insolvency(); // Not enough withdraws have claimed to fill liquidity
            transfer(receiver, assets);
        } else {
            // we can mint $.maximumCapacity - totalAssets()
            uint256 mintableShares = $.maximumCapacity - totalAssets();
            if (totalLiquidShares + mintableShares < shares)
                revert Insolvency(); // Both vault owned shares and minting couldn't fulfill this request

            uint256 fromLiquid = Math.min(shares, totalLiquidShares);
            if (fromLiquid > 0) transfer(receiver, fromLiquid);

            uint256 toMint = shares - fromLiquid;
            if (toMint > 0) super._mint(receiver, toMint);
        }

        $.totalClaimableDeposits -= assets;
        $.totalAssets += assets;
        emit TotalClaimableDeposits($.totalClaimableDeposits);
        return shares;
    }

    function requestDeposit(
        uint256 assets,
        address controller,
        address owner
    ) public returns (uint256) {
        Storage storage $ = getStorage();
        if (msg.sender != owner) revert UnauthorizedCaller(msg.sender);

        uint256 capacity = availableCapacity();
        IERC20 baseAsset = IERC20(asset());

        console.log("Available capacity for this deposit: %e", capacity);
        console.log("Deposit size: %e", assets);

        baseAsset.safeTransferFrom(owner, address(this), assets);

        emit DepositRequest(controller, owner, 0, msg.sender, assets);

        VaultBase.Transaction memory transaction = VaultBase.Transaction(
            owner,
            assets,
            controller,
            ++$.nonces[owner]
        );

        if (!$.depositQueue.isEmpty() || capacity == 0) {
            _pushToDepositQueue($, transaction);
            return 0;
        }

        if (assets > capacity) {
            console.log("Assets greater than capacity");
            _markClaimableDeposit($, owner, capacity);
            transaction.amount -= capacity;
            _pushToDepositQueue($, transaction);
        } else {
            console.log("Assets less than or equal to capacity");
            _markClaimableDeposit($, owner, assets);
        }

        return 0;
    }

    function _pushToDepositQueue(
        VaultBase.Storage storage $,
        VaultBase.Transaction memory data
    ) private {
        console.log("Pushing to deposit queue amount: %e", data.amount);
        bytes32 element = $.depositQueue.push(data);
        $.transactionRegistry[element] = data;
        $.totalDepositQueueAssets += data.amount;
        emit DepositQueueValuation($.totalDepositQueueAssets);
    }

    function _markClaimableDeposit(
        VaultBase.Storage storage $,
        address owner,
        uint256 amount
    ) private {
        console.log("Marking claimable assetsIn += %e", amount);
        $.ledger[owner].assetsIn += amount;
        $.totalClaimableDeposits += amount;
        emit TotalClaimableDeposits($.totalClaimableDeposits);
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
        address owner
    ) public override(ERC4626Upgradeable, IERC4626) returns (uint256 shares) {}

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
        VaultBase.Transaction memory transaction = VaultBase.Transaction(
            owner,
            shares,
            controller,
            ++$.nonces[owner]
        );

        $.lockedShares[owner] += shares;

        InterestLib.accrueInterest($);

        int256 availableLiquidAssets = availableLiquidAssets();

        if (availableLiquidAssets <= 0 || !$.withdrawQueue.isEmpty()) {
            _pushToWithdrawQueue($, transaction);
        } else {
            uint256 requestedAmount = convertToAssets(shares);
            uint256 liquidAssets = availableLiquidAssets.toUint256();

            if (liquidAssets >= requestedAmount) {
                _markClaimableWithdraw($, owner, requestedAmount);
            } else {
                _markClaimableWithdraw($, owner, liquidAssets);
                transaction.amount -= liquidAssets;
                _pushToWithdrawQueue($, transaction);
            }
        }
        return 0;
    }

    function _pushToWithdrawQueue(
        VaultBase.Storage storage $,
        VaultBase.Transaction memory data
    ) private {
        bytes32 element = $.withdrawQueue.push(data);
        $.transactionRegistry[element] = data;
        $.totalWithdrawQueueShares += data.amount;
        emit WithdrawQueueValuation($.totalWithdrawQueueShares);
    }

    function _markClaimableWithdraw(
        VaultBase.Storage storage $,
        address owner,
        uint256 amount
    ) private {
        $.ledger[owner].sharesOut += amount;
        $.totalClaimableWithdraws += amount;

        emit TotalClaimableWithdraws($.totalClaimableWithdraws);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override(ERC4626Upgradeable, IERC4626) returns (uint256 assets) {
        require(msg.sender == owner || isOperator(owner, msg.sender));

        Storage storage $ = getStorage();

        if ($.ledger[owner].sharesOut < shares) revert();

        $.ledger[owner].sharesOut -= shares;
        $.totalClaimableWithdraws -= shares;

        emit TotalClaimableWithdraws($.totalClaimableWithdraws);

        SafeERC20.safeTransferFrom(
            IERC20(address(this)),
            owner,
            address(this),
            shares
        );

        InterestLib.accrueInterest($);
        assets = convertToAssets(shares);
        IERC20 baseAsset = IERC20(asset());
        uint256 liquidAssets = baseAsset.balanceOf(address(this));

        if (assets > liquidAssets) revert();
        baseAsset.safeTransfer(receiver, assets);

        $.lockedShares[owner] -= shares;
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

        if (from != address(0)) {
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
        $.operators[msg.sender] = approved ? operator : address(0);
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
