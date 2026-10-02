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

abstract contract Queue is LiquidityManagement, IQueue {
    using TransactionQueue for TransactionQueue.RequestQueue;
    using TransientSlot for *;
    using SafeCast for uint256;

    bytes32 private constant SAVINGS_VAULT_PRICE_PER_SHARE =
        keccak256("sparkprime.vault.depositFillRate");

    function processQueue(
        uint256 tradeVolume
    ) public onlyRole(REBALANCER_ROLE) nonReentrant {
        Storage storage $ = getStorage();
        InterestLib.accrueInterest($);

        tradeVolume = Math.min(tradeVolume, maxTradeVolume());

        _fillWithdrawQueue($, tradeVolume);
        _fillDepositQueue($, tradeVolume);

        int256 assetsLeft = availableLiquidAssets();
        if (assetsLeft < 0) revert AssetInvariantBroken(assetsLeft);

        int256 sharesLeft = $.maximumCapacity.toInt256() -
            totalSupply().toInt256();
        if (sharesLeft < 0) revert ShareInvariantBroken(sharesLeft);
    }

    function maxTradeVolume() public view returns (uint256) {
        return
            Math.min(availableDepositLiquidity(), availableWithdrawLiquidity());
    }

    function availableDepositLiquidity()
        internal
        view
        returns (uint256 valueInBaseAssets)
    {
        int256 liquidAssets = availableLiquidAssets() +
            _depositQueueValuation().toInt256();
        valueInBaseAssets = uint256(
            liquidAssets > 0 ? liquidAssets : int256(0)
        );
    }

    function availableWithdrawLiquidity()
        internal
        view
        returns (uint256 valueInBaseAssets)
    {
        valueInBaseAssets = convertToAssets(
            totalPendingWithdraws() + availableCapacity()
        );
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
        uint256 totalSavingsSharesInQueue = $.totalDepositQueueSavingsShares;
        uint256 claimableBefore = $.totalClaimableDepositShares;
        uint256 queueValue = _depositQueueValuation();

        bool fillAll = tradeVolume >= queueValue;

        uint256 shares = fillAll
            ? totalSavingsSharesInQueue
            : $.savingsVault.previewWithdraw(tradeVolume);
        uint256 credit = fillAll ? queueValue : tradeVolume;

        SAVINGS_VAULT_PRICE_PER_SHARE.asUint256().tstore(
            shares == 0 ? 0 : Math.mulDiv(credit, InterestLib.RAY, shares)
        );

        fillAll
            ? fillUnbounded($, $.depositQueue, _markClaimableDeposit)
            : fillUntil($, $.depositQueue, _markClaimableDeposit, shares);

        SAVINGS_VAULT_PRICE_PER_SHARE.asUint256().tstore(0);

        uint256 minted = $.totalClaimableDepositShares - claimableBefore;
        if (minted > 0) _mint(address(this), minted);

        uint256 processedSavingsShares = totalSavingsSharesInQueue -
            $.totalDepositQueueSavingsShares;

        if (processedSavingsShares > 0)
            $.savingsVault.redeem(
                processedSavingsShares,
                address(this),
                address(this)
            );
    }

    function fillUnbounded(
        Storage storage $,
        TransactionQueue.RequestQueue storage queue,
        function(Storage storage, address, uint256, bool) claim
    ) internal {
        uint256 n = queue.length();

        for (n; n > 0; --n) {
            (bool active, Transaction memory data) = queue.pop();
            if (!active) continue;
            claim($, data.controller, data.amount, false);
        }
    }

    function fillUntil(
        Storage storage $,
        TransactionQueue.RequestQueue storage queue,
        function(Storage storage, address, uint256, bool) claim,
        uint256 remainder
    ) internal {
        uint256 length = queue.length();
        while (remainder > 0) {
            if (length == 0) revert PartialFillFailure();

            (bool active, Transaction memory data) = queue.pop();
            --length;
            if (!active) continue;
            if (data.amount >= remainder) {
                claim($, data.controller, remainder, false);
                if (data.amount == remainder) break;
                _insertHeadWithNewAmount(queue, data, data.amount - remainder);
                break;
            } else {
                claim($, data.controller, data.amount, false);
                remainder -= data.amount;
            }
        }
    }

    function _insertHeadWithNewAmount(
        TransactionQueue.RequestQueue storage queue,
        Transaction memory data,
        uint256 newAmount
    ) private {
        data.amount = newAmount;
        queue.pushFront(data);
    }

    function _pushToDepositQueue(
        VaultBase.Storage storage $,
        VaultBase.Transaction memory data
    ) internal {
        $.depositQueue.push(data);
        $.totalDepositQueueSavingsShares += data.amount;
        $.ledger[data.controller].pendingSavingsShares += data.amount;
        emit DepositQueueValuation($.totalDepositQueueSavingsShares);
    }

    function _markClaimableDeposit(
        VaultBase.Storage storage $,
        address owner,
        uint256 amount,
        bool instantClaim
    ) internal {
        uint256 baseAssets = instantClaim
            ? amount
            : Math.mulDiv(
                amount,
                SAVINGS_VAULT_PRICE_PER_SHARE.asUint256().tload(),
                InterestLib.RAY
            );

        uint256 shares = convertToShares(baseAssets);
        if (shares == 0) baseAssets = 0;

        $.ledger[owner].depositedAssets += baseAssets;
        $.ledger[owner].sharesOwed += shares;

        if (!instantClaim) {
            $.ledger[owner].pendingSavingsShares -= amount;
            $.totalDepositQueueSavingsShares -= amount;
        }

        $.totalClaimableDepositShares += shares;
        if (instantClaim) _mint(address(this), shares);
        emit ClaimableDeposit(owner, $.ledger[owner].depositedAssets);
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

    function _markClaimableWithdraw(
        VaultBase.Storage storage $,
        address owner,
        uint256 amount,
        bool instantClaim
    ) internal {
        uint256 assets = convertToAssets(amount);

        $.ledger[owner].withdrawnShares += amount;
        $.ledger[owner].assetsOwed += assets;
        $.totalClaimableWithdrawAssets += assets;

        if (instantClaim) {
            _burn(address(this), amount);
        } else {
            $.ledger[owner].pendingSharesOut -= amount;
            $.totalWithdrawQueueShares -= amount;
        }

        emit ClaimableWithdraw(owner, $.ledger[owner].assetsOwed);
        emit TotalClaimableWithdraws($.totalClaimableWithdrawAssets);
    }

    function sanitizeDepositQueue(
        uint256 maxIterations
    ) external returns (uint256 removed) {
        Storage storage $ = getStorage();
        removed = $.depositQueue.sanitize(maxIterations);
    }

    function totalPendingDeposits() public view returns (uint256 shares) {
        Storage storage $ = getStorage();
        shares = $.totalDepositQueueSavingsShares;
    }

    function _depositQueueValuation() internal view returns (uint256 assets) {
        Storage storage $ = getStorage();
        uint256 shares = $.totalDepositQueueSavingsShares;
        assets = shares == 0 ? 0 : $.savingsVault.previewRedeem(shares);
    }

    function depositQueueLength() public view returns (uint256) {
        Storage storage $ = getStorage();
        return
            TransactionQueue.length($.depositQueue) - $.depositQueue.cancelled;
    }

    function depositQueueHead()
        public
        view
        returns (Transaction memory transaction)
    {
        Storage storage $ = getStorage();
        transaction = TransactionQueue.front($.depositQueue);
    }

    function claimableDepositTotal() public view returns (uint256) {
        Storage storage $ = getStorage();
        return $.totalClaimableDepositShares;
    }

    function totalPendingWithdraws() public view returns (uint256 shares) {
        Storage storage $ = getStorage();
        shares = $.totalWithdrawQueueShares;
    }

    function withdrawQueueLength() public view returns (uint256) {
        Storage storage $ = getStorage();
        return TransactionQueue.length($.withdrawQueue);
    }

    function withdrawQueueHead()
        public
        view
        returns (Transaction memory transaction)
    {
        Storage storage $ = getStorage();
        transaction = TransactionQueue.front($.withdrawQueue);
    }

    function claimableWithdrawTotal() public view returns (uint256) {
        Storage storage $ = getStorage();
        return $.totalClaimableWithdrawAssets;
    }
}
