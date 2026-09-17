// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISparkPrimeVault} from "./interfaces/ISparkPrimeVault.sol";
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {
    DoubleEndedQueue
} from "@openzeppelin/contracts/utils/structs/DoubleEndedQueue.sol";
import {TransactionQueue} from "./libraries/TransactionQueue.sol";

import {
    ERC20Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {InterestLib} from "./libraries/InterestLib.sol";
import {VaultBase} from "./abstract/VaultBase.sol";
import {Rebalancer} from "./abstract/Rebalancer.sol";
import {LiquidityManagement} from "./abstract/LiquidityManagement.sol";
import {VaultManagement} from "./abstract/VaultManagement.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
contract Vault is
    Rebalancer,
    LiquidityManagement,
    VaultManagement,
    ISparkPrimeVault,
    ERC20Upgradeable,
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

    // Deposit Claim Rules
    //Test: Always consume claimableDepositTotal(), any remainder is minted (if below capacity). Always revert if total amount cannot be claimed (Insolvency)

    // TransactionQueue Library
    //Fuzz Test: Encoding and Decoding should be a strict bi-directional match, for any input

    using TransactionQueue for DoubleEndedQueue.Bytes32Deque;
    using SafeERC20 for IERC20;
    modifier accrueInterest(Storage storage $) {
        InterestLib.accrueInterest($);
        _;
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
    ) public returns (uint256 shares) {
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
        // require controller == receiver or isOperator(controller, msg.sender)
        require(controller == msg.sender || isOperator(controller, msg.sender));
        if (assets > $.ledger[controller].assetsIn) revert();

        shares = convertToShares(assets);
        if (shares == 0) revert();

        $.ledger[controller].assetsIn -= assets;

        uint256 totalMintableShares = convertToShares(availableCapacity());
        uint256 totalLiquidShares = this.balanceOf(address(this));

        if (shares > totalLiquidShares + totalMintableShares) revert(); //insolvency

        if (shares > totalLiquidShares) {
            transfer(receiver, totalLiquidShares);
        } else {
            transfer(receiver, shares);
            $.totalClaimableDeposits -= assets;
            emit TotalClaimableDeposits($.totalClaimableDeposits);
            return shares;
        }

        $.totalAssets += assets;
        super._mint(receiver, shares - totalLiquidShares);

        $.totalClaimableDeposits -= assets;
        emit TotalClaimableDeposits($.totalClaimableDeposits);
        return shares;
    }

    function requestDeposit(
        uint256 assets,
        address controller,
        address owner
    ) public returns (uint256) {
        Storage storage $ = getStorage();
        require(msg.sender == owner);

        $.baseAsset.safeTransferFrom(owner, address(this), assets);
        uint256 capacity = availableCapacity();

        emit DepositRequest(controller, owner, 0, msg.sender, assets);

        VaultBase.Transaction memory transaction = VaultBase.Transaction(
            owner,
            assets,
            controller,
            $.nonces[owner]++
        );

        if (!$.depositQueue.isEmpty() || capacity == 0) {
            _pushToDepositQueue($, transaction);
            return 0;
        }

        if (assets > capacity) {
            _markClaimableDeposit($, owner, capacity);
            transaction.amount -= capacity;
            _pushToDepositQueue($, transaction);
        } else {
            _markClaimableDeposit($, owner, assets);
        }

        return 0;
    }

    function _pushToDepositQueue(
        VaultBase.Storage storage $,
        VaultBase.Transaction memory data
    ) private {
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
    ) public returns (uint256 shares) {}

    function mint(
        uint256 shares,
        address receiver,
        address controller
    ) public returns (uint256 assets) {}

    function mint(
        uint256 shares,
        address receiver
    ) public returns (uint256 assets) {
        return mint(shares, receiver, msg.sender); /// @dev When user calls 4626 sync functions, we transform to async assuming they are their own controller
    }

    function requestRedeem(
        uint256 shares,
        address controller,
        address owner
    ) public returns (uint256 requestId) {}

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public returns (uint256 assets) {
        /**
         * Insert redeem queue order whilst abiding by FIFO principles listed above
         *
         */
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

    function lastAccrual() public view returns (uint256) {
        Storage storage $ = getStorage();
        return $.lastAccrualTimestamp;
    }

    function share() public view returns (address shareTokenAddress) {
        shareTokenAddress = address(this);
    }

    function interestRate() public view returns (uint256) {
        Storage storage $ = getStorage();
        return $.ratePerSecond;
    }

    function previewIndex() external view returns (uint256 newIndexRate) {
        Storage storage $ = getStorage();
        return InterestLib.simulateAccrue($);
    }

    function index() external view returns (uint256) {
        Storage storage $ = getStorage();
        return $.indexRate;
    }

    function asset() public view returns (address assetTokenAddress) {
        Storage storage $ = getStorage();
        return address($.baseAsset);
    }

    function maxCapacity() public view returns (uint256) {
        Storage storage $ = getStorage();
        return $.maximumCapacity;
    }
    function availableCapacity() public view returns (uint256) {
        Storage storage $ = getStorage();
        return $.maximumCapacity - $.totalAssets;
    }
}
