// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TransactionQueue} from "../libraries/TransactionQueue.sol";

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IVault} from "../interfaces/IVault.sol";
import {
    ERC4626Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {InterestLib} from "../libraries/InterestLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

abstract contract VaultBase is
    ERC4626Upgradeable,
    ReentrancyGuardTransient,
    PausableUpgradeable,
    IVault
{
    bytes32 constant LIQUIDITY_MANAGER_ROLE =
        keccak256("LIQUIDITY_MANAGER_ROLE");
    bytes32 constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE");
    bytes32 constant VAULT_MANAGER_ROLE = keccak256("VAULT_MANAGER_ROLE");

    /// @custom:storage-location erc7201:sparkprime.vault.v1
    struct Storage {
        mapping(address => Settlement) ledger;
        mapping(address => mapping(address => bool)) operators;
        mapping(address => uint256) nonces;
        TransactionQueue.RequestQueue withdrawQueue;
        TransactionQueue.RequestQueue depositQueue;
        IERC20 baseAsset;
        IERC4626 savingsVault;
        uint256 maximumCapacity;
        uint256 minimumDeposit;
        uint256 minimumWithdraw;
        uint256 ratePerSecond;
        uint256 lastAccrualTimestamp;
        uint256 indexRate;
        uint256 totalDepositQueueSavingsShares;
        uint256 totalWithdrawQueueShares;
        uint256 totalClaimableDepositShares;
        uint256 totalClaimableWithdrawAssets;
    }

    bytes32 constant STORAGE_SLOT =
        0x2821b8486074f0bcecf57719e783aa08965d4369cb8c36759327d2e985b90600;

    function getStorage() internal view returns (Storage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }

    function convertToShares(
        uint256 assets
    )
        public
        view
        virtual
        override(IERC4626, ERC4626Upgradeable)
        returns (uint256)
    {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    function convertToAssets(
        uint256 shares
    ) public view override(IERC4626, ERC4626Upgradeable) returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    function _convertToShares(
        uint256 assets,
        Math.Rounding rounding
    ) internal view override(ERC4626Upgradeable) returns (uint256) {
        Storage storage $ = getStorage();
        uint256 shares = Math.mulDiv(
            assets,
            InterestLib.RAY,
            InterestLib.simulateAccrue($),
            rounding
        );
        return shares;
    }

    function _convertToAssets(
        uint256 shares,
        Math.Rounding rounding
    ) internal view override(ERC4626Upgradeable) returns (uint256) {
        Storage storage $ = getStorage();
        uint256 assets = Math.mulDiv(
            shares,
            InterestLib.simulateAccrue($),
            InterestLib.RAY,
            rounding
        );
        return assets;
    }

    function totalAssets()
        public
        view
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256)
    {
        return convertToAssets(totalSupply());
    }

    function interestRate() public view returns (uint256) {
        Storage storage $ = getStorage();
        return $.ratePerSecond;
    }

    function index() external view returns (uint256) {
        Storage storage $ = getStorage();
        return $.indexRate;
    }

    function previewIndex() external view returns (uint256 newIndexRate) {
        Storage storage $ = getStorage();
        return InterestLib.simulateAccrue($);
    }

    function lastAccrual() public view returns (uint256) {
        Storage storage $ = getStorage();
        return $.lastAccrualTimestamp;
    }

    function maxCapacity() public view returns (uint256) {
        Storage storage $ = getStorage();
        return $.maximumCapacity;
    }

    function availableCapacity() public view returns (uint256 available) {
        Storage storage $ = getStorage();
        uint256 supply = totalSupply();
        available = $.maximumCapacity > supply ? $.maximumCapacity - supply : 0;
    }

    function minimumDeposit() public view returns (uint256) {
        Storage storage $ = getStorage();
        return $.minimumDeposit;
    }

    function minimumWithdraw() public view returns (uint256) {
        Storage storage $ = getStorage();
        return $.minimumWithdraw;
    }

    function claimableDepositRequest(
        uint256,
        address controller
    ) public view override returns (uint256 claimableAssets) {
        Storage storage $ = getStorage();
        claimableAssets = $.ledger[controller].depositedAssets;
    }

    function maxDeposit(
        address controller
    )
        public
        view
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256 claimableAssets)
    {
        if (paused()) return 0;
        Storage storage $ = getStorage();
        claimableAssets = $.ledger[controller].depositedAssets;
    }

    function maxMint(
        address controller
    )
        public
        view
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256 claimableShares)
    {
        if (paused()) return 0;
        Storage storage $ = getStorage();
        claimableShares = $.ledger[controller].sharesOwed;
    }

    function claimableRedeemRequest(
        uint256,
        address controller
    ) public view override returns (uint256 claimableShares) {
        Storage storage $ = getStorage();
        claimableShares = $.ledger[controller].withdrawnShares;
    }

    function maxWithdraw(
        address controller
    )
        public
        view
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256 claimValue)
    {
        if (paused()) return 0;
        Storage storage $ = getStorage();
        claimValue = $.ledger[controller].assetsOwed;
    }

    function maxRedeem(
        address controller
    )
        public
        view
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256 claimableShares)
    {
        if (paused()) return 0;
        Storage storage $ = getStorage();
        claimableShares = $.ledger[controller].withdrawnShares;
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

    function share() public view override returns (address shareTokenAddress) {
        shareTokenAddress = address(this);
    }

    function vault(address asset_) external view returns (address) {
        return asset_ == asset() ? address(this) : address(0);
    }
}
