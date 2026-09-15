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

contract Vault is IERC7540, ISparkPrimeVault, Pausable {
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

    struct Settlement {
        address beneficiary;
        uint256 assetsIn;
        uint256 sharesOut;
    }

    struct Transaction {
        address beneficiary;
        uint256 amount;
    }

    /// @custom:storage-location erc7201:sparkprime.vault.v1
    struct Storage {
        mapping(address => Settlement) ledger;
        mapping(address => uint256) lockedShares;
        DoubleEndedQueue.Bytes32Deque withdrawQueue;
        DoubleEndedQueue.Bytes32Deque depositQueue;
        IERC4626 savingsVault;
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
