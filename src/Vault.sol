// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISparkPrimeVault} from "./interfaces/ISparkPrimeVault.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
//import {ERC7540} from "./ERC7540.sol";
import {
    IERC7540
} from "@openzeppelin/community-contracts/interfaces/IERC7540.sol";
import {
    DoubleEndedQueue
} from "@openzeppelin/contracts/utils/structs/DoubleEndedQueue.sol";
import {TransactionQueue} from "./libraries/TransactionQueue.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

contract Vault is IERC7540, ISparkPrimeVault, Pausable, AccessControl {
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

    struct Settlement {
        address beneficiary;
        uint256 assetsIn;
        uint256 pendingAssetsIn;
        uint256 sharesOut;
        uint256 pendingSharesOut;
    }

    struct Transaction {
        address beneficiary;
        uint256 amount;
    }

    bytes32 constant LIQUIDITY_MANAGER_ROLE =
        0x77e60b99a50d27fb027f6912a507d956105b4148adab27a86d235c8bcca8fa2f; /// keccak256("LIQUIDITY_MANAGER_ROLE")
    bytes32 constant REBALANCER_ROLER =
        0xccc64574297998b6c3edf6078cc5e01268465ff116954e3af02ff3a70a730f46; /// keccak256("REBALANCER_ROLER")
    bytes32 constant VAULT_MANAGER_ROLE =
        0xd1473398bb66596de5d1ea1fc8e303ff2ac23265adc9144b1b52065dc4f0934b; /// keccak256("VAULT_MANAGER_ROLE")

    /// @custom:storage-location erc7201:sparkprime.vault.v1
    struct Storage {
        mapping(address => Settlement) ledger;
        mapping(address => uint256) lockedShares;
        DoubleEndedQueue.Bytes32Deque withdrawQueue;
        DoubleEndedQueue.Bytes32Deque depositQueue;
        IERC20 baseAsset;
        IERC4626 savingsVault;
        uint256 totalAssets;
        uint256 totalShares;
        uint256 maximumCapacity;
        uint256 lastAccrualTimestamp;
        uint256 indexRate;
        uint256 totalDepositQueueAssets;
        uint256 totalWithdrawQueueShares;
        uint256 totalClaimableDeposits; //in base asset
        uint256 totalClaimableWithdraws; //in shares
    }

    bytes32 constant STORAGE_SLOT =
        0x4faf50102ef2be52bfa2d60ecf6f23274b1323fa1b201fbdd5281067b242f900; // cast index-erc7201 erc7201:sparkprime.vault.v1

    function getStorage() private returns (Storage storage $) {
        assembly {
            $.slot := sload(STORAGE_SLOT)
        }
    }

    function previewDeposit(
        uint256 assets
    ) external view returns (uint256 shares) {
        revert();
    }

    function previewMint(
        uint256 shares
    ) external view returns (uint256 assets) {
        revert();
    }

    function previewWithdraw(
        uint256 assets
    ) external view returns (uint256 shares) {
        revert();
    }

    function previewRedeem(
        uint256 shares
    ) external view returns (uint256 assets) {
        revert();
    }

    function withdrawQueueLength() external view returns (uint256) {
        Storage storage $ = getStorage();
        return TransactionQueue.length($.withdrawQueue);
    }

    function withdrawQueueHead()
        external
        view
        returns (address controller, uint256 assets)
    {
        Storage storage $ = getStorage();
        (controller, assets) = TransactionQueue.front($.withdrawQueue);
    }

    function depositQueueLength() external view returns (uint256) {
        Storage storage $ = getStorage();
        return TransactionQueue.length($.depositQueue);
    }

    function depositQueueHead()
        external
        view
        returns (address controller, uint256 assets)
    {
        Storage storage $ = getStorage();
        (controller, assets) = TransactionQueue.front($.withdrawQueue);
    }

    function take(
        uint256 baseAmount
    ) external onlyRole(LIQUIDITY_MANAGER_ROLE) {
        Storage storage $ = getStorage();
        $.baseAsset.safeTransfer(msg.sender, baseAmount);
    }

    /// @dev Trusts the planner/rebalancer for a reasonable `baseAssets` amount
    function withdrawFromSavings(
        uint256 baseAssets
    ) public onlyRole(REBALANCER_ROLER) {
        Storage storage $ = getStorage();
        $.savingsVault.withdraw(baseAssets, msg.sender, address(this));
    }

    /// @dev Trusts the planner/rebalancer for a reasonable `baseAssets` amount
    function depositToSavings(
        uint256 baseAmount
    ) public onlyRole(REBALANCER_ROLER) {
        Storage storage $ = getStorage();
        $.savingsVault.deposit(baseAmount, address(this));
    }

    function setCapacity(
        uint256 newCapacity
    ) external onlyRole(LIQUIDITY_MANAGER_ROLE) {
        Storage storage $ = getStorage();
        $.maximumCapacity = newCapacity;
    }

    function pendingDepositRequest(
        uint256 requestId,
        address controller
    ) external view returns (uint256 pendingAssets) {
        Storage storage $ = getStorage();
        return $.ledger[controller].pendingAssetsIn;
    }

    function pendingRedeemRequest(
        uint256 requestId,
        address controller
    ) external view returns (uint256 pendingShares) {
        Storage storage $ = getStorage();
        return $.ledger[controller].pendingSharesOut;
    }

    function pendingWithdrawAmount(
        address controller
    ) external view returns (uint256) {
        Storage storage $ = getStorage();
        return $.ledger[controller].pendingSharesOut;
    }
    function maxWithdraw(
        address owner
    ) external view returns (uint256 maxAssets) {
        Storage storage $ = getStorage();
        return super.convertToAssets($.ledger[owner].sharesOut);
    }
    function maxRedeem(
        address owner
    ) external view returns (uint256 maxShares) {
        Storage storage $ = getStorage();
        return $.ledger[owner].sharesOut;
    }
    function totalPendingWithdraws() external view returns (uint256 shares) {
        Storage storage $ = getStorage();
        shares = $.totalWithdrawQueueShares;
    }

    function totalPendingDeposits() external view returns (uint256 assets) {
        Storage storage $ = getStorage();
        assets = $.totalDepositQueueAssets;
    }

    function requestDeposit(
        uint256 assets,
        address controller,
        address owner
    ) public returns (uint256 requestId) {}

    function requestRedeem(
        uint256 shares,
        address controller,
        address owner
    ) external returns (uint256 requestId) {}
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets) {
        /**
         * Insert redeem queue order whilst abiding by FIFO principles listed above
         */
    }
    function asset() external view returns (address assetTokenAddress) {
        Storage storage $ = getStorage();
        return address($.baseAsset);
    }

    /*function availableLiquidShares()
        public
        returns (int256 totalSPPrimeTokens)
    {
        Storage storage $ = getStorage();
        totalSPPrimeTokens =
            balanceOf(address(this)) -
            convertToShares($.totalClaimableDeposits);
    }

    function availableLiquidAssets() public returns (int256 totalBaseAssets) {
        Storage storage $ = getStorage();
        IERC4626 savingsVault = $.savingsVault;
        totalBaseAssets =
            $.baseAsset.balanceOf(address(this)) +
            savingsVault.convertToAssets(
                savingsVault.balanceOf(address(this))
            ) -
            super.convertToAssets($.totalClaimableWithdraws);
    }*/
}
