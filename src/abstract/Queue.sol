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
            _fillableDepositValue().toInt256();
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

    function _fillWithdrawQueue(Storage storage $, uint256 tradeVolume) internal {
        TransactionQueue.RequestQueue storage queue = $.withdrawQueue;

        uint256 queuedBefore = queue.pending;

        uint256 shares = tradeVolume >= convertToAssets(queue.pending)
            ? queue.pending
            : convertToShares(tradeVolume);

        _fill($, queue, _markClaimableWithdraw, shares);

        uint256 matched = queuedBefore - queue.pending;
        if (matched > 0) {
            _burn(address(this), matched);
            emit WithdrawQueueValuation(queue.pending);
        }
    }

    function _fillDepositQueue(
        Storage storage $,
        uint256 tradeVolume
    ) internal {
        TransactionQueue.RequestQueue storage queue = $.depositQueue;

        uint256 totalSavingsSharesInQueue = queue.pending;
        uint256 claimableBefore = $.totalClaimableDepositShares;
        uint256 queueValue = _depositQueueValuation();
        uint256 volume = Math.min(tradeVolume, _fillableDepositValue());

        bool fillAll = volume >= queueValue;

        uint256 shares = fillAll
            ? totalSavingsSharesInQueue
            : _savingsSharesFor(volume);
        uint256 credit = fillAll ? queueValue : volume;

        SAVINGS_VAULT_PRICE_PER_SHARE.asUint256().tstore(
            shares == 0 ? 0 : Math.mulDiv(credit, InterestLib.RAY, shares)
        );

        _fill($, queue, _markClaimableDeposit, shares);

        SAVINGS_VAULT_PRICE_PER_SHARE.asUint256().tstore(0);

        uint256 minted = $.totalClaimableDepositShares - claimableBefore;
        if (minted > 0) _mint(address(this), minted);

        uint256 processedSavingsShares = totalSavingsSharesInQueue - queue.pending;

        if (processedSavingsShares > 0) {
            $.savingsVault.redeem(
                processedSavingsShares,
                address(this),
                address(this)
            );
            emit DepositQueueValuation(queue.pending);
        }
    }

    function _fill(
        Storage storage $,
        TransactionQueue.RequestQueue storage queue,
        function(Storage storage, Transaction memory, uint256, bool) claim,
        uint256 remainder
    ) internal {
        if (remainder > queue.pending) revert PartialFillFailure();

        while (remainder > 0) {
            (uint256 slot, Transaction storage t) = queue.peek();
            uint256 fill = Math.min(t.amount, remainder);

            claim($, t, fill, false);
            queue.take(slot, fill);

            remainder -= fill;
        }
    }

    function _pushToDepositQueue(
        VaultBase.Storage storage $,
        VaultBase.Transaction memory data
    ) internal returns (uint256 slot) {
        slot = $.depositQueue.push(data);
        $.ledger[data.controller].pendingSavingsShares += data.amount;
        emit DepositQueueValuation($.depositQueue.pending);
    }

    function _markClaimableDeposit(
        VaultBase.Storage storage $,
        Transaction memory data,
        uint256 amount,
        bool instantClaim
    ) internal {
        address controller = data.controller;
        uint256 baseAssets = instantClaim
            ? amount
            : Math.mulDiv(
                amount,
                SAVINGS_VAULT_PRICE_PER_SHARE.asUint256().tload(),
                InterestLib.RAY
            );

        uint256 shares = convertToShares(baseAssets);
        if (shares == 0) baseAssets = 0;

        $.ledger[controller].depositedAssets += baseAssets;
        $.ledger[controller].sharesOwed += shares;

        if (!instantClaim) {
            $.ledger[controller].pendingSavingsShares -= amount;
        }

        $.totalClaimableDepositShares += shares;
        if (instantClaim) _mint(address(this), shares);
        emit ClaimableDeposit(controller, $.ledger[controller].depositedAssets);
    }

    function _pushToWithdrawQueue(
        Storage storage $,
        IVault.Transaction memory data
    ) internal returns (uint256 slot) {
        slot = $.withdrawQueue.push(data);
        $.ledger[data.controller].pendingSharesOut += data.amount;
        emit WithdrawQueueValuation($.withdrawQueue.pending);
    }

    function _markClaimableWithdraw(
        VaultBase.Storage storage $,
        Transaction memory data,
        uint256 amount,
        bool instantClaim
    ) internal {
        address controller = data.controller;
        uint256 assets = convertToAssets(amount);
        assets -= Math.mulDiv(assets, data.fee, BPS, Math.Rounding.Ceil);

        $.ledger[controller].withdrawnShares += amount;
        $.ledger[controller].assetsOwed += assets;
        $.totalClaimableWithdrawAssets += assets;

        if (instantClaim) {
            _burn(address(this), amount);
        } else {
            $.ledger[controller].pendingSharesOut -= amount;
        }

        emit ClaimableWithdraw(controller, $.ledger[controller].assetsOwed);
        emit TotalClaimableWithdraws($.totalClaimableWithdrawAssets);
    }

    function totalPendingDeposits() public view returns (uint256 shares) {
        Storage storage $ = getStorage();
        shares = $.depositQueue.pending;
    }

    function _depositQueueValuation() internal view returns (uint256 assets) {
        Storage storage $ = getStorage();
        uint256 shares = $.depositQueue.pending;
        assets = shares == 0 ? 0 : $.savingsVault.convertToAssets(shares);
    }

    function _fillableDepositValue() internal view returns (uint256) {
        uint256 queued = _depositQueueValuation();
        if (queued == 0) return 0;
        Storage storage $ = getStorage();
        uint256 redeemable = $.savingsVault.convertToAssets(
            $.savingsVault.maxRedeem(address(this))
        );
        return Math.min(queued, redeemable);
    }

    function _savingsSharesFor(
        uint256 assets
    ) internal view returns (uint256 shares) {
        Storage storage $ = getStorage();
        shares = $.savingsVault.convertToShares(assets);
        if ($.savingsVault.convertToAssets(shares) < assets) ++shares;
    }

    function depositQueueSlots()
        public
        view
        returns (uint256 consumed, uint256 issued)
    {
        Storage storage $ = getStorage();
        (consumed, issued) = ($.depositQueue.consumed, $.depositQueue.issued);
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
        shares = $.withdrawQueue.pending;
    }

    function withdrawQueueSlots()
        public
        view
        returns (uint256 consumed, uint256 issued)
    {
        Storage storage $ = getStorage();
        (consumed, issued) = ($.withdrawQueue.consumed, $.withdrawQueue.issued);
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
