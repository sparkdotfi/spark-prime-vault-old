// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    DoubleEndedQueue
} from "@openzeppelin/contracts/utils/structs/DoubleEndedQueue.sol";
import {TransactionQueue} from "../libraries/TransactionQueue.sol";

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {
    IERC7540
} from "@openzeppelin/community-contracts/interfaces/IERC7540.sol";

abstract contract VaultBase is IERC7540 {
    using TransactionQueue for DoubleEndedQueue.Bytes32Deque;

    bytes32 constant LIQUIDITY_MANAGER_ROLE =
        0x77e60b99a50d27fb027f6912a507d956105b4148adab27a86d235c8bcca8fa2f; /// keccak256("LIQUIDITY_MANAGER_ROLE")
    bytes32 constant REBALANCER_ROLER =
        0xccc64574297998b6c3edf6078cc5e01268465ff116954e3af02ff3a70a730f46; /// keccak256("REBALANCER_ROLER")
    bytes32 constant VAULT_MANAGER_ROLE =
        0xd1473398bb66596de5d1ea1fc8e303ff2ac23265adc9144b1b52065dc4f0934b; /// keccak256("VAULT_MANAGER_ROLE")

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
        address controller;
        uint256 nonce;
    }

    /// @custom:storage-location erc7201:sparkprime.vault.v1
    struct Storage {
        mapping(address => Settlement) ledger;
        mapping(address => uint256) lockedShares;
        mapping(address => address) operators;
        mapping(address => uint256) nonces;
        mapping(bytes32 => Transaction) transactionRegistry;
        DoubleEndedQueue.Bytes32Deque withdrawQueue;
        DoubleEndedQueue.Bytes32Deque depositQueue;
        IERC20 baseAsset;
        IERC4626 savingsVault;
        uint256 totalAssets;
        uint256 maximumCapacity;
        // Interest Rate
        uint256 ratePerSecond;
        uint256 lastAccrualTimestamp;
        uint256 indexRate;
        uint256 totalDepositQueueAssets;
        uint256 totalWithdrawQueueShares;
        uint256 totalClaimableDeposits; //in base asset
        uint256 totalClaimableWithdraws; //in shares
    }

    bytes32 constant STORAGE_SLOT =
        0x4faf50102ef2be52bfa2d60ecf6f23274b1323fa1b201fbdd5281067b242f900; // cast index-erc7201 erc7201:sparkprime.vault.v1

    function getStorage() internal view returns (Storage storage $) {
        assembly {
            $.slot := sload(STORAGE_SLOT)
        }
    }

    function convertToShares(
        uint256 assets
    ) public view override returns (uint256) {}

    function convertToAssets(
        uint256 shares
    ) public view override returns (uint256) {}

    /** ERC 7540 overrides */
    /// @dev We have no concept of requestIDs, therefore this is just a `maxDeposit`
    function claimableDepositRequest(
        uint256,
        address controller
    ) public view override returns (uint256 claimableAssets) {
        claimableAssets = maxDeposit(controller);
    }

    /// @dev We have no concept of requestIDs, therefore just a `maxRedeem`
    function claimableRedeemRequest(
        uint256,
        address controller
    ) public view override returns (uint256 claimableShares) {
        claimableShares = maxRedeem(controller);
    }

    /** ERC4626 overrides **/

    /// @dev Overriden to provide the maximum claimable share amount for a user. Return amount in shares
    function maxRedeem(
        address owner
    ) public view override returns (uint256 claimableShares) {
        Storage storage $ = getStorage();
        claimableShares = $.ledger[owner].sharesOut;
    }

    /// @dev Overriden to provide the value of maximum claim in base asset
    function maxWithdraw(
        address owner
    ) public view override returns (uint256 claimValue) {
        claimValue = convertToAssets(maxRedeem(owner));
    }

    /// @dev Overridenn to provide maximum amount of claimable assets
    function maxDeposit(
        address receiver
    ) public view override returns (uint256 claimableAssets) {
        Storage storage $ = getStorage();
        claimableAssets = $.ledger[receiver].assetsIn;
    }

    /// @dev Overridden to return the maximum claimable amount, converted to shares
    function maxMint(
        address receiver
    ) public view override returns (uint256 claimableShares) {
        claimableShares = convertToShares(maxDeposit(receiver));
    }
    function previewDeposit(uint256) public pure override returns (uint256) {
        revert();
    }

    function previewMint(uint256) public pure override returns (uint256) {
        revert();
    }

    function previewWithdraw(uint256) public pure override returns (uint256) {
        revert();
    }

    function previewRedeem(uint256) public pure override returns (uint256) {
        revert();
    }
}
