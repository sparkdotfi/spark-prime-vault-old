// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultBase} from "./VaultBase.sol";
import {IVault} from "../interfaces/IVault.sol";
import {IQueue} from "../interfaces/IQueue.sol";
import {TransactionQueue} from "../libraries/TransactionQueue.sol";
import {LiquidityManagement} from "./LiquidityManagement.sol";
import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {InterestLib} from "../libraries/InterestLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {console} from "forge-std/console.sol";

abstract contract Queue is LiquidityManagement, IQueue {
    using TransactionQueue for TransactionQueue.RequestQueue;
    using TransientSlot for *;
    using SafeCast for uint256;

    bytes32 private constant SAVINGS_VAULT_PRICE_PER_SHARE =
        keccak256("sparkprime.vault.depositFillRate");

    /// @notice The total share amount in the Withdraw Queue
    function totalPendingWithdraws() public view returns (uint256 shares) {
        Storage storage $ = getStorage();
        shares = $.totalWithdrawQueueShares;
    }

    /// @notice Total Savings Vault shares currently in the deposit queue
    function totalPendingDeposits() public view returns (uint256 shares) {
        Storage storage $ = getStorage();
        shares = $.totalDepositQueueSavingsShares;
    }

    function _pendingDepositValue() internal view returns (uint256 assets) {
        Storage storage $ = getStorage();
        uint256 shares = $.totalDepositQueueSavingsShares;
        assets = shares == 0 ? 0 : $.savingsVault.previewRedeem(shares);
    }

    function claimableWithdrawTotal() public view returns (uint256) {
        Storage storage $ = getStorage();
        return $.totalClaimableWithdrawAssets;
    }

    function claimableDepositTotal() public view returns (uint256) {
        Storage storage $ = getStorage();
        return $.totalClaimableDepositShares;
    }

    /// @notice Provides the number of requests present in the FIFO Withdraw Queue
    function withdrawQueueLength() public view returns (uint256) {
        Storage storage $ = getStorage();
        return TransactionQueue.length($.withdrawQueue);
    }

    /// @notice Provides the first entry in the FIFO Withdraw Queue
    /// @dev Can revert with QueueEmpty
    function withdrawQueueHead()
        public
        view
        returns (Transaction memory transaction)
    {
        Storage storage $ = getStorage();
        transaction = TransactionQueue.front($.withdrawQueue);
    }

    /// @notice Provides the number of requests present in the FIFO Deposit Queue
    function depositQueueLength() public view returns (uint256) {
        Storage storage $ = getStorage();
        return TransactionQueue.length($.depositQueue);
    }

    /// @notice Provides the first entry in the FIFO Deposit Queue
    /// @dev Can revert with QueueEmpty
    function depositQueueHead()
        public
        view
        returns (Transaction memory transaction)
    {
        Storage storage $ = getStorage();
        transaction = TransactionQueue.front($.depositQueue);
    }

    /// @notice Process pending deposits/withdrawals against eachother
    /// @dev Trusts the planner/rebalancer for a reasonable `tradeVolume` amount to bound the loop
    function processQueue(
        uint256 tradeVolume
    ) public onlyRole(REBALANCER_ROLER) nonReentrant {
        Storage storage $ = getStorage();
        InterestLib.accrueInterest($);

        int256 liquidAssets = availableLiquidAssets() +
            _pendingDepositValue().toInt256();
        uint256 totalAssetLiquidity = uint256(
            liquidAssets > 0 ? liquidAssets : int256(0)
        );

        int256 liquidShares = availableLiquidShares();

        uint256 totalShareLiquidity = totalPendingWithdraws() +
            uint256(liquidShares > 0 ? liquidShares : int256(0));

        /// We can only ever eat uptil the smaller queue

        /// baseAsset = 100
        /// shares = 500 ==> 400,
        /// tradeVolume = 200

        /// TODO: Send examples of each use case to Lucas via Slack
        if (
            tradeVolume >
            Math.min(totalAssetLiquidity, convertToAssets(totalShareLiquidity))
        ) revert CapacityExceedsLiquidity();

        /// Process the Withdraw Queue first, burning all matched shares to increase totalMintableShares
        _fillWithdrawQueue($, tradeVolume);

        /// Process the Deposit Queue second, so every claim has access to totalMintableShares
        _fillDepositQueue($, tradeVolume);

        // Sanity Invariants: Never allow claims to exceed current balance resulting in debt

        /// Order Matching should never result in base asset insolvency
        int256 assetsLeft = availableLiquidAssets();
        if (assetsLeft < 0) revert AssetInvariantBroken(assetsLeft);

        /// Order Matching should never result in share insolvency
        int256 sharesLeft = availableLiquidShares();
        if (sharesLeft < 0) revert ShareInvariantBroken(sharesLeft);
    }

    function _fillWithdrawQueue(
        Storage storage $,
        uint256 tradeVolume
    ) internal {
        uint256 queuedBefore = $.totalWithdrawQueueShares;

        tradeVolume >= convertToAssets(totalPendingWithdraws())
            ? fillUnbounded($, $.withdrawQueue, _markClaimableWithdraw)
            : fillUntil(
                $,
                $.withdrawQueue,
                _markClaimableWithdraw,
                convertToShares(tradeVolume)
            );

        uint256 matched = queuedBefore - $.totalWithdrawQueueShares;
        if (matched > 0) _burn(address(this), matched);
    }

    function _fillDepositQueue(
        Storage storage $,
        uint256 tradeVolume
    ) internal {
        uint256 queuedBefore = $.totalDepositQueueSavingsShares;
        uint256 queueValue = _pendingDepositValue();
        bool fillAll = tradeVolume >= queueValue;

        uint256 shares = fillAll
            ? queuedBefore
            : $.savingsVault.previewWithdraw(tradeVolume);
        uint256 credit = _fitToMintableShares(
            fillAll ? queueValue : tradeVolume
        );

        SAVINGS_VAULT_PRICE_PER_SHARE.asUint256().tstore(
            shares == 0 ? 0 : Math.mulDiv(credit, InterestLib.RAY, shares)
        );

        fillAll
            ? fillUnbounded($, $.depositQueue, _markClaimableDeposit)
            : fillUntil($, $.depositQueue, _markClaimableDeposit, shares);

        SAVINGS_VAULT_PRICE_PER_SHARE.asUint256().tstore(0);

        uint256 matched = queuedBefore - $.totalDepositQueueSavingsShares;
        if (matched > 0)
            $.savingsVault.redeem(matched, address(this), address(this));
    }

    function _fitToMintableShares(
        uint256 assets
    ) internal view returns (uint256) {
        int256 room = availableLiquidShares();
        if (room >= 0 && convertToShares(assets) == uint256(room) + 1)
            return convertToAssets(uint256(room));
        return assets;
    }

    /// @dev Iterate over entire queue and eat until EOF
    function fillUnbounded(
        Storage storage $,
        TransactionQueue.RequestQueue storage queue,
        function(Storage storage, address, uint256, bool) claim
    ) internal {
        console.log("FILL UNBOUNDED");
        uint256 n = queue.length();

        for (n; n > 0; --n) {
            (bool active, Transaction memory data) = queue.pop();
            if (!active) continue;
            claim($, data.controller, data.amount, false);
        }
    }
    /// @dev Iterate queue and accumulate claims until we hit required capacity. Reverts on pre-mature EOF
    function fillUntil(
        Storage storage $,
        TransactionQueue.RequestQueue storage queue,
        function(Storage storage, address, uint256, bool) claim,
        uint256 remainder
    ) internal {
        uint256 length = queue.length();
        console.log("FILL UNTIL: %e", remainder);
        while (remainder > 0) {
            if (length == 0) revert PartialFillFailure();

            (bool active, Transaction memory data) = queue.pop();
            --length;
            if (!active) continue;
            if (data.amount >= remainder) {
                /// @dev Base case, occurs exactly once at the last processed element
                claim($, data.controller, remainder, false);
                if (data.amount == remainder) break;
                _insertHeadWithNewAmount(queue, data, data.amount - remainder);
                break;
            } else {
                /// @dev Recursive case
                claim($, data.controller, data.amount, false);
                remainder -= data.amount;
            }
        }
    }

    function _markClaimableDeposit(
        VaultBase.Storage storage $,
        address owner,
        uint256 amount,
        bool instantClaim
    ) internal {
        uint256 assets = instantClaim
            ? amount
            : Math.mulDiv(
                amount,
                SAVINGS_VAULT_PRICE_PER_SHARE.asUint256().tload(),
                InterestLib.RAY
            );

        uint256 shares = convertToShares(assets);
        if (shares == 0) assets = 0;

        $.ledger[owner].assetsIn += assets;
        $.ledger[owner].sharesIn += shares;

        if (!instantClaim) {
            $.ledger[owner].pendingSavingsShares -= amount;
            $.totalDepositQueueSavingsShares -= amount;
        }

        $.totalClaimableDepositShares += shares;
        emit ClaimableDeposit(owner, $.ledger[owner].assetsIn);
    }

    function _markClaimableWithdraw(
        VaultBase.Storage storage $,
        address owner,
        uint256 amount,
        bool instantClaim
    ) internal {
        uint256 assets = convertToAssets(amount);

        $.ledger[owner].sharesOut += amount;
        $.ledger[owner].assetsOut += assets;
        $.totalClaimableWithdrawAssets += assets;

        if (instantClaim) {
            _burn(address(this), amount);
        } else {
            $.ledger[owner].pendingSharesOut -= amount;
            $.totalWithdrawQueueShares -= amount;
        }

        emit ClaimableWithdraw(owner, $.ledger[owner].assetsOut);
    }

    /// @notice Cleans up void registry entries and links new data
    /// @dev Restricted usage to modify an existing element to head (partial fills).
    function _insertHeadWithNewAmount(
        TransactionQueue.RequestQueue storage queue,
        Transaction memory data,
        uint256 newAmount
    ) private {
        data.amount = newAmount;
        queue.pushFront(data);
    }

    function _pushToWithdrawQueue(
        Storage storage $,
        IVault.Transaction memory data
    ) internal {
        $.withdrawQueue.push(data);
        $.totalWithdrawQueueShares += data.amount;
        $.ledger[data.controller].pendingSharesOut += data.amount;
        emit WithdrawQueueValuation($.totalWithdrawQueueShares);
    }

    function _pushToDepositQueue(
        VaultBase.Storage storage $,
        VaultBase.Transaction memory data
    ) internal {
        console.log("Pushing to deposit queue amount: %e", data.amount);
        $.depositQueue.push(data);
        $.totalDepositQueueSavingsShares += data.amount;
        $.ledger[data.controller].pendingSavingsShares += data.amount;
        emit DepositQueueValuation($.totalDepositQueueSavingsShares);
    }
}
