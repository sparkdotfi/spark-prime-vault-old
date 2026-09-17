// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    DoubleEndedQueue
} from "@openzeppelin/contracts/utils/structs/DoubleEndedQueue.sol";
import {TransactionQueue} from "../libraries/TransactionQueue.sol";

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IVault} from "../interfaces/IVault.sol";
import {
    ERC4626Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {InterestLib} from "../libraries/InterestLib.sol";

abstract contract VaultBase is ERC4626Upgradeable, IVault {
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

    /** ERC 7540 overrides */
    /// @dev We have no concept of requestIDs, therefore this is just a `maxDeposit`
    /// @notice Wraps `maxDeposit` of ERC4626 to support ERC7540 spec
    function claimableDepositRequest(
        uint256,
        address controller
    ) public view override returns (uint256 claimableAssets) {
        claimableAssets = maxDeposit(controller);
    }

    /// @dev We have no concept of requestIDs, therefore just a `maxRedeem`
    /// @notice Wraps `maxRedeem` of ERC4626 to support ERC7540 spec
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
    )
        public
        view
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256 claimableShares)
    {
        Storage storage $ = getStorage();
        claimableShares = $.ledger[owner].sharesOut;
    }

    /// @dev Overridenn to provide maximum amount of claimable assets
    function maxDeposit(
        address receiver
    )
        public
        view
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256 claimableAssets)
    {
        Storage storage $ = getStorage();
        claimableAssets = $.ledger[receiver].assetsIn;
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
    function convertToShares(
        uint256 assets
    )
        public
        view
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256 shares)
    {
        Storage storage $ = getStorage();
        shares = (assets * InterestLib.RAY) / $.indexRate;
    }

    function convertToAssets(
        uint256 shares
    )
        public
        view
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256 assets)
    {
        Storage storage $ = getStorage();
        assets = (shares * $.indexRate) / InterestLib.RAY;
    }

    /// @dev Overridden to return the maximum claimable amount, converted to shares
    function maxMint(
        address receiver
    )
        public
        view
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256 claimableShares)
    {
        claimableShares = convertToShares(maxDeposit(receiver));
    }

    /// @dev Overriden to provide the value of maximum claim in base asset
    function maxWithdraw(
        address owner
    )
        public
        view
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256 claimValue)
    {
        claimValue = convertToAssets(maxRedeem(owner));
    }
    function totalAssets()
        public
        view
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256)
    {
        Storage storage $ = getStorage();
        return $.totalAssets;
    }
    function lastAccrual() public view returns (uint256) {
        Storage storage $ = getStorage();
        return $.lastAccrualTimestamp;
    }

    function share() public view override returns (address shareTokenAddress) {
        shareTokenAddress = address(this);
    }
    function maxCapacity() public view returns (uint256) {
        Storage storage $ = getStorage();
        return $.maximumCapacity;
    }
    function availableCapacity() public view returns (uint256) {
        Storage storage $ = getStorage();
        return $.maximumCapacity - $.totalAssets;
    }
    function previewDeposit(
        uint256
    ) public pure override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        revert();
    }

    function previewMint(
        uint256
    ) public pure override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        revert();
    }

    function previewWithdraw(
        uint256
    ) public pure override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        revert();
    }

    function previewRedeem(
        uint256
    ) public pure override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        revert();
    }
}
