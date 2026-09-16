// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISparkPrimeVault} from "./interfaces/ISparkPrimeVault.sol";
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
//import {ERC7540} from "./ERC7540.sol";
import {
    IERC7540
} from "@openzeppelin/community-contracts/interfaces/IERC7540.sol";
import {
    DoubleEndedQueue
} from "@openzeppelin/contracts/utils/structs/DoubleEndedQueue.sol";
import {TransactionQueue} from "./libraries/TransactionQueue.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {
    ERC20Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

contract Vault is
    ERC20Upgradeable,
    IERC7540,
    ISparkPrimeVault,
    PausableUpgradeable,
    AccessControlUpgradeable
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
        mapping(address => address) operators;
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

    function getStorage() private returns (Storage storage $) {
        assembly {
            $.slot := sload(STORAGE_SLOT)
        }
    }

    function previewDeposit(
        uint256 assets
    ) public view returns (uint256 shares) {
        revert();
    }

    function previewMint(uint256 shares) public view returns (uint256 assets) {
        revert();
    }

    function previewWithdraw(
        uint256 assets
    ) public view returns (uint256 shares) {
        revert();
    }

    function previewRedeem(
        uint256 shares
    ) public view returns (uint256 assets) {
        revert();
    }

    function withdrawQueueLength() public view returns (uint256) {
        Storage storage $ = getStorage();
        return TransactionQueue.length($.withdrawQueue);
    }

    function withdrawQueueHead()
        public
        view
        returns (address controller, uint256 assets)
    {
        Storage storage $ = getStorage();
        (controller, assets) = TransactionQueue.front($.withdrawQueue);
    }

    function depositQueueLength() public view returns (uint256) {
        Storage storage $ = getStorage();
        return TransactionQueue.length($.depositQueue);
    }

    function depositQueueHead()
        public
        view
        returns (address controller, uint256 assets)
    {
        Storage storage $ = getStorage();
        (controller, assets) = TransactionQueue.front($.withdrawQueue);
    }

    function take(uint256 baseAmount) public onlyRole(LIQUIDITY_MANAGER_ROLE) {
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
    ) public onlyRole(LIQUIDITY_MANAGER_ROLE) {
        Storage storage $ = getStorage();
        $.maximumCapacity = newCapacity;
    }

    function pendingDepositRequest(
        uint256 requestId,
        address controller
    ) public view returns (uint256 pendingAssets) {
        Storage storage $ = getStorage();
        return $.ledger[controller].pendingAssetsIn;
    }

    function pendingRedeemRequest(
        uint256 requestId,
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

    /** ERC4626 overrides **/

    /// @dev Overriden to provide the maximum claimable share amount for a user. Return amount in shares
    function maxRedeem(
        address owner
    ) public view returns (uint256 claimableShares) {
        Storage storage $ = getStorage();
        claimableShares = $.ledger[owner].sharesOut;
    }

    /// @dev Overriden to provide the value of maximum claim in base asset
    function maxWithdraw(
        address owner
    ) public view returns (uint256 claimValue) {
        claimValue = convertToAssets(maxRedeem(owner));
    }

    /// @dev Overridenn to provide maximum amount of claimable assets
    function maxDeposit(
        address receiver
    ) public view returns (uint256 claimableAssets) {
        Storage storage $ = getStorage();
        claimableAssets = $.ledger[receiver].assetsIn;
    }

    /// @dev Overridden to return the maximum claimable amount, converted to shares
    function maxMint(
        address receiver
    ) public view returns (uint256 claimableShares) {
        claimableShares = convertToShares(maxDeposit(receiver));
    }

    /// @dev Synchronous 4626 deposits are converted to async. The caller is assigned to controller
    function deposit(
        uint256 assets,
        address receiver
    ) public returns (uint256 shares) {
        return deposit(assets, receiver, msg.sender);
    }
    /** ERC7540 overrides **/

    /// @dev We have no concept of requestIDs, therefore this is just a `maxDeposit`
    function claimableDepositRequest(
        uint256 requestId,
        address controller
    ) public view returns (uint256 claimableAssets) {
        claimableAssets = maxDeposit(controller);
    }

    /// @dev We have no concept of requestIDs, therefore just a `maxRedeem`
    function claimableRedeemRequest(
        uint256 requestId,
        address controller
    ) public view returns (uint256 claimableShares) {
        claimableShares = maxRedeem(controller);
    }
    function deposit(
        uint256 assets,
        address receiver,
        address controller
    ) public returns (uint256 shares) {}

    function requestDeposit(
        uint256 assets,
        address controller,
        address owner
    ) public returns (uint256 requestId) {}

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
    }

    function isOperator(
        address controller,
        address operator
    ) public view returns (bool status) {
        Storage storage $ = getStorage();
        status = $.operators[controller] == operator;
    }

    function totalPendingWithdraws() public view returns (uint256 shares) {
        Storage storage $ = getStorage();
        shares = $.totalWithdrawQueueShares;
    }

    function totalPendingDeposits() public view returns (uint256 assets) {
        Storage storage $ = getStorage();
        assets = $.totalDepositQueueAssets;
    }

    function convertToShares(
        uint256 assets
    ) public view virtual returns (uint256) {}

    function convertToAssets(
        uint256 shares
    ) public view virtual returns (uint256) {}

    function totalAssets() public view override returns (uint256) {
        Storage storage $ = getStorage();
        return $.totalAssets;
    }

    function setInterestRate(
        uint256 newRate
    ) public onlyRole(LIQUIDITY_MANAGER_ROLE) {
        Storage storage $ = getStorage();
        uint256 oldRate = $.ratePerSecond;
        $.ratePerSecond = newRate;
        emit RateUpdated(oldRate, newRate);
    }
    function claimableWithdrawTotal() public view returns (uint256) {
        Storage storage $ = getStorage();
        return $.totalClaimableWithdraws;
    }
    function claimableDepositTotal() public view returns (uint256) {
        Storage storage $ = getStorage();
        return $.totalClaimableDeposits;
    }
    function lastAccrual() public view returns (uint256) {
        Storage storage $ = getStorage();
        return $.lastAccrualTimestamp;
    }
    function share() public view returns (address shareTokenAddress) {
        shareTokenAddress = address(this);
    }

    function updateWithdrawFee(
        uint256 bps
    ) public onlyRole(LIQUIDITY_MANAGER_ROLE) {}

    function interestRate() public view returns (uint256) {
        Storage storage $ = getStorage();
        return $.ratePerSecond;
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
    function availableLiquidShares()
        public
        view
        returns (int256 totalSPPrimeTokens)
    {
        Storage storage $ = getStorage();
        totalSPPrimeTokens = int256(
            this.balanceOf(address(this)) -
                convertToShares($.totalClaimableDeposits)
        );
    }

    function availableLiquidAssets()
        public
        view
        returns (int256 totalBaseAssets)
    {
        Storage storage $ = getStorage();
        IERC4626 savingsVault = $.savingsVault;
        totalBaseAssets = int256(
            $.baseAsset.balanceOf(address(this)) +
                savingsVault.convertToAssets(
                    savingsVault.balanceOf(address(this))
                ) -
                convertToAssets($.totalClaimableWithdraws)
        );
    }
}
