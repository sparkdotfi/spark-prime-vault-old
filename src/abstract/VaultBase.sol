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
import {console} from "forge-std/console.sol";
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
        0x77e60b99a50d27fb027f6912a507d956105b4148adab27a86d235c8bcca8fa2f; /// keccak256("LIQUIDITY_MANAGER_ROLE")
    bytes32 constant REBALANCER_ROLER =
        0xccc64574297998b6c3edf6078cc5e01268465ff116954e3af02ff3a70a730f46; /// keccak256("REBALANCER_ROLER")
    bytes32 constant VAULT_MANAGER_ROLE =
        0xd1473398bb66596de5d1ea1fc8e303ff2ac23265adc9144b1b52065dc4f0934b; /// keccak256("VAULT_MANAGER_ROLE")

    /// @custom:storage-location erc7201:sparkprime.vault.v1
    struct Storage {
        mapping(address => Settlement) ledger;
        mapping(address => address) operators;
        mapping(address => uint256) nonces;
        TransactionQueue.RequestQueue withdrawQueue;
        TransactionQueue.RequestQueue depositQueue;
        // Vault Management
        IERC20 baseAsset;
        IERC4626 savingsVault;
        uint256 maximumCapacity;
        uint256 minimumDeposit;
        uint256 minimumWithdraw;
        // Interest Rate
        uint256 ratePerSecond;
        uint256 lastAccrualTimestamp;
        uint256 indexRate;
        // Queue Accounting
        uint256 totalDepositQueueSavingsShares;
        uint256 totalWithdrawQueueShares;
        uint256 totalClaimableDepositShares; //in spPRIME shares, frozen at match
        uint256 totalClaimableWithdrawAssets; //in base asset, frozen at match
    }

    bytes32 constant STORAGE_SLOT =
        0x4faf50102ef2be52bfa2d60ecf6f23274b1323fa1b201fbdd5281067b242f900; // cast index-erc7201 erc7201:sparkprime.vault.v1

    function getStorage() internal view returns (Storage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }

    /** ERC 7540 overrides */
    /// @dev We have no concept of requestIDs, therefore this is the controller's claimable balance
    /// @notice Unlike `maxDeposit`, works when paused
    function claimableDepositRequest(
        uint256,
        address controller
    ) public view override returns (uint256 claimableAssets) {
        Storage storage $ = getStorage();
        claimableAssets = $.ledger[controller].assetsIn;
    }

    /// @dev We have no concept of requestIDs, therefore this is the controller's claimable balance
    /// @notice Unlike `maxRedeem`, works when paused
    function claimableRedeemRequest(
        uint256,
        address controller
    ) public view override returns (uint256 claimableShares) {
        Storage storage $ = getStorage();
        claimableShares = $.ledger[controller].sharesOut;
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
        if (paused()) return 0;
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
        if (paused()) return 0;
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
    /// @inheritdoc IERC4626
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

    /// @inheritdoc IERC4626
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
        console.log("Converting to shares..");
        uint256 shares = Math.mulDiv(
            assets,
            InterestLib.RAY,
            $.indexRate,
            rounding
        );
        console.log("shares = %e", shares);
        return shares;
    }

    function _convertToAssets(
        uint256 shares,
        Math.Rounding rounding
    ) internal view override(ERC4626Upgradeable) returns (uint256) {
        Storage storage $ = getStorage();

        console.log("Converting to assets..");
        uint256 assets = Math.mulDiv(
            shares,
            $.indexRate,
            InterestLib.RAY,
            rounding
        );
        console.log("assets = %e", assets);
        return assets;
    }

    /// @dev Overridden to return the shares locked for the receiver's claimable deposits
    function maxMint(
        address receiver
    )
        public
        view
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256 claimableShares)
    {
        if (paused()) return 0;
        Storage storage $ = getStorage();
        claimableShares = $.ledger[receiver].sharesIn;
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
        if (paused()) return 0;
        Storage storage $ = getStorage();
        claimValue = $.ledger[owner].assetsOut;
    }
    function totalAssets()
        public
        view
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256)
    {
        return convertToAssets(totalSupply());
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

    function minimumDeposit() public view returns (uint256) {
        Storage storage $ = getStorage();
        return $.minimumDeposit;
    }

    function minimumWithdraw() public view returns (uint256) {
        Storage storage $ = getStorage();
        return $.minimumWithdraw;
    }

    function availableCapacity() public view returns (uint256 available) {
        Storage storage $ = getStorage();
        uint256 total = _convertToAssets(totalSupply(), Math.Rounding.Ceil);
        available = $.maximumCapacity > total ? $.maximumCapacity - total : 0;
        uint256 locked = _convertToAssets(
            $.totalClaimableDepositShares,
            Math.Rounding.Ceil
        );
        if (locked >= available) available = 0;
        else available -= locked;
        if (convertToShares(available) == 0) available = 0;
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
