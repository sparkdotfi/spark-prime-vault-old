// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ERC1967Utils }             from "../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol";
import { UUPSUpgradeable }          from "../lib/openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 }                   from "../lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import { IERC165 }                  from "../lib/openzeppelin-contracts/contracts/interfaces/IERC165.sol";
import { IERC4626 }                 from "../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import { SafeERC20 }                from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math }                     from "../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { SafeCast }                 from "../lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import { ReentrancyGuardTransient } from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";

import { AccessControlEnumerableUpgradeable } from "../lib/openzeppelin-contracts-upgradeable/contracts/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { ERC20Upgradeable }                   from "../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
import { ERC4626Upgradeable }                 from "../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { PausableUpgradeable }                from "../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";

import {
    ISpPrime,
    IERC7540Deposit,
    IERC7540Operator,
    IERC7540Redeem,
    IERC7575
} from "./ISpPrime.sol";

import { SpPrimeQueue } from "./libraries/SpPrimeQueue.sol";

contract SpPrime is
    ISpPrime,
    ERC4626Upgradeable,
    AccessControlEnumerableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardTransient,
    UUPSUpgradeable
{

    using SpPrimeQueue for SpPrimeQueue.RequestQueue;
    using SafeERC20    for IERC20;
    using SafeCast     for int256;
    using SafeCast     for uint256;

    /**********************************************************************************************/
    /*** Constants                                                                              ***/
    /**********************************************************************************************/

    bytes32 public constant LIQUIDITY_MANAGER_ROLE = keccak256("LIQUIDITY_MANAGER_ROLE");
    bytes32 public constant REBALANCER_ROLE        = keccak256("REBALANCER_ROLE");
    bytes32 public constant VAULT_MANAGER_ROLE     = keccak256("VAULT_MANAGER_ROLE");

    uint256 public constant RAY = 1e27;

    /**********************************************************************************************/
    /*** State variables                                                                        ***/
    /**********************************************************************************************/

    // Savings Vault price per share (RAY), set once per processQueue so every queued entry fills at the same price
    uint256 private transient savingsSharePrice;

    IERC4626 public savingsVault;

    // Users
    mapping(address => Settlement) internal ledger;
    mapping(address => address)    internal operators;
    mapping(address => uint256)    internal nonces;

    // Queues
    SpPrimeQueue.RequestQueue internal withdrawQueue;
    SpPrimeQueue.RequestQueue internal depositQueue;

    // Limits
    uint256 internal maximumCapacity;
    uint256 public   minimumDeposit;
    uint256 public   minimumWithdraw;

    // Interest rate
    uint256 internal ratePerSecond;
    uint256 internal lastAccrualTimestamp;
    uint256 internal indexRate;

    // Queue accounting
    uint256 internal totalDepositQueueSavingsShares;
    uint256 internal totalWithdrawQueueShares;
    uint256 internal totalClaimableDepositShares;   // in vault shares, frozen at fill
    uint256 internal totalClaimableWithdrawAssets;  // in base asset, frozen at fill
    uint256 public   totalLoss;

    /**********************************************************************************************/
    /*** Initialization                                                                         ***/
    /**********************************************************************************************/

    constructor() {
        _disableInitializers();  // Avoid initializing in the context of the implementation
    }

    function initialize(InitParams calldata params) external initializer {
        if (params.savingsVault.asset() != address(params.baseAsset)) revert AssetMismatch();

        __ERC20_init(params.name, params.symbol);
        __ERC4626_init(params.baseAsset);
        __AccessControlEnumerable_init();
        __Pausable_init();

        savingsVault         = params.savingsVault;
        maximumCapacity      = params.capacity;
        minimumDeposit       = params.minimumDeposit;
        minimumWithdraw      = params.minimumWithdraw;
        ratePerSecond        = params.ratePerSecond;
        indexRate            = RAY;
        lastAccrualTimestamp = block.timestamp;

        _grantRole(DEFAULT_ADMIN_ROLE,     params.admin);
        _grantRole(VAULT_MANAGER_ROLE,     params.vaultManager);
        _grantRole(LIQUIDITY_MANAGER_ROLE, params.liquidityManager);
        _grantRole(REBALANCER_ROLE,        params.rebalancer);
    }

    /**********************************************************************************************/
    /*** Admin functions                                                                        ***/
    /**********************************************************************************************/

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // Only DEFAULT_ADMIN_ROLE can upgrade the implementation
    function _authorizeUpgrade(address) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /**********************************************************************************************/
    /*** Vault manager functions                                                                ***/
    /**********************************************************************************************/

    function pause() external onlyRole(VAULT_MANAGER_ROLE) {
        _pause();
    }

    // Accrues at the old rate up to now, then switches. RAY = 0% (no negative rates).
    function setInterestRate(uint256 newRate) external onlyRole(VAULT_MANAGER_ROLE) {
        require(newRate >= RAY, InterestRateBelowRay());

        _accrueInterest();

        emit RateUpdated(ratePerSecond, newRate);

        ratePerSecond = newRate;
    }

    // Records a loss: totalAssets() drops to `newTotalAssets`. The index and share price are unchanged.
    function setTotalAssets(uint256 newTotalAssets) external onlyRole(VAULT_MANAGER_ROLE) {
        _accrueInterest();

        uint256 indexValue = convertToAssets(totalSupply());

        require(newTotalAssets <= indexValue, TotalAssetsExceedIndexValue());

        emit TotalAssetsUpdated(totalAssets(), newTotalAssets);

        totalLoss = indexValue - newTotalAssets;
    }

    // Cap on total vault shares, including shares escrowed for claims and queued redeems
    function setCapacity(uint256 newCapacity) external onlyRole(VAULT_MANAGER_ROLE) {
        require(newCapacity >= totalSupply(), MaximumCapacityCannotExceedCurrentTotal());

        emit CapacityUpdated(maximumCapacity, newCapacity);

        maximumCapacity = newCapacity;
    }

    // Must be > 0 so _split never leaves a dust remainder
    function setMinimumDeposit(uint256 amount) external onlyRole(VAULT_MANAGER_ROLE) {
        require(amount > 0, ZeroValueProvided());

        minimumDeposit = amount;

        emit MinimumDepositUpdated(amount);
    }

    // Must be > 0 so _split never leaves a dust remainder
    function setMinimumWithdraw(uint256 amount) external onlyRole(VAULT_MANAGER_ROLE) {
        require(amount > 0, ZeroValueProvided());

        minimumWithdraw = amount;

        emit MinimumWithdrawUpdated(amount);
    }

    // @audit: REVISIT
    function updateWithdrawFee(uint256) external onlyRole(VAULT_MANAGER_ROLE) {}

    /**********************************************************************************************/
    /*** Liquidity manager functions                                                            ***/
    /**********************************************************************************************/

    // Provides Spark PAU ability to withdraw the vaults baseAsset balance
    function take(uint256 baseAmount) public nonReentrant onlyRole(LIQUIDITY_MANAGER_ROLE) {
        IERC20(asset()).safeTransfer(msg.sender, baseAmount);
    }

    /**********************************************************************************************/
    /*** Rebalancer functions                                                                   ***/
    /**********************************************************************************************/

    // processQueue,

    // @audit: REVISIT this to implement proper guards and role access
    // Allows Rebalance Roler to increase Savings Vault position by depositing vault baseAsset balance
    // Trusts the planner/rebalancer for a reasonable `baseAssets` amount
    function depositToSavings(uint256 assets)
        public
        onlyRole(REBALANCER_ROLE)
        nonReentrant
        returns (uint256 shares)
    {
        IERC20(asset()).forceApprove(address(savingsVault), assets);
        shares = savingsVault.deposit(assets, address(this));
        emit SavingsDeposit(assets, shares);
    }

    // @audit: REVISIT this to implement proper guards and role access
    // Allows Rebalancer Role to increase baseAsset position by unwinding Savings Vault deposits
    // Trusts the planner/rebalancer for a reasonable `share` amount
    function withdrawFromSavings(uint256 shares)
        public
        onlyRole(REBALANCER_ROLE)
        nonReentrant
        returns (uint256 assets)
    {
        assets = savingsVault.redeem(shares, address(this), address(this));
        emit SavingsWithdraw(shares, assets);
    }

    /**********************************************************************************************/
    /*** Operator functions                                                                     ***/
    /**********************************************************************************************/

    // Each controller has at most one operator. Approving replaces it, revoking clears it.
    function setOperator(address operator, bool approved) external returns (bool) {
        require(operator != address(0), ZeroValueProvided());

        if (approved) {
            operators[msg.sender] = operator;
        } else if (operators[msg.sender] == operator) {
            delete operators[msg.sender];
        }

        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    function isOperator(address controller, address operator) public view returns (bool) {
        return operator != address(0) && operators[controller] == operator;
    }

    /**********************************************************************************************/
    /*** Request functions                                                                      ***/
    /**********************************************************************************************/

    function requestDeposit(
        uint256 assets,
        address controller,
        address owner
    ) public whenNotPaused nonReentrant returns (uint256) {
        require(assets > 0,               ZeroValueProvided());
        require(assets >= minimumDeposit, MustExceedMinimumRequestAmount(minimumDeposit));
        require(msg.sender == owner,      UnauthorizedCaller(msg.sender)); // @audit: Is it intended? or can a operator call this function?

        _accrueInterest(); // @audit: accrueing during request phase is needed? Or should be in the claim paths only?

        require(convertToShares(assets) > 0, ShareConversionFailure(assets));

        Transaction memory transaction = Transaction(
            controller,
            owner,
            assets,
            ++nonces[controller]
        );

        // Transfer baseAsset from user to vault
        IERC20 baseAsset = IERC20(asset());

        uint256 before = baseAsset.balanceOf(address(this));

        baseAsset.safeTransferFrom(owner, address(this), assets);

        require(baseAsset.balanceOf(address(this)) - before == assets, DeltaMismatch()); // @audit: I dont think we need this check?

        // FIFO: nothing fills instantly while a queue exists
        uint256 available = depositQueue.isEmpty()
            ? _convertToAssets(availableCapacity(), Math.Rounding.Ceil)
            : 0;

        ( uint256 instant, uint256 queued ) = _split(assets, available, minimumDeposit);

        if (instant > 0) _markClaimableInstantDeposit(controller, instant);

        if (queued > 0) {
            baseAsset.forceApprove(address(savingsVault), queued);

            uint256 shares = savingsVault.deposit(queued, address(this));

            require(shares > 0, ShareConversionFailure(queued));

            transaction.amount = shares;

            depositQueue.push(transaction);

            totalDepositQueueSavingsShares                      += shares;
            ledger[transaction.controller].pendingSavingsShares += shares;

            emit DepositQueueValuation(totalDepositQueueSavingsShares);
        }

        emit DepositRequest(controller, owner, 0, msg.sender, assets);
        return 0;
    }

    function requestRedeem(
        uint256 shares,
        address controller,
        address owner
    ) public whenNotPaused nonReentrant returns (uint256) {
        require(shares > 0,                                 ZeroValueProvided());
        require(convertToAssets(shares) >= minimumWithdraw, MustExceedMinimumRequestAmount(minimumWithdraw));
        require(owner == msg.sender,                        UnauthorizedCaller(msg.sender)); // @audit: Is it intended? or can a operator call this function?

        Transaction memory transaction = Transaction(
            controller,
            owner,
            shares,
            ++nonces[controller]
        );

        emit RedeemRequest(controller, owner, 0, msg.sender, shares);

        // Vault locks the users shares by taking ownership of them
        _transfer(owner, address(this), shares);

        _accrueInterest();

        // Amount of baseAsset the vault holds (subtracting amounts commited to claimable withdraws)
        int256 liquid = availableLiquidAssets();

        uint256 available = (withdrawQueue.isEmpty() && liquid > 0)
            ? convertToShares(liquid.toUint256())
            : 0;

        ( uint256 instant, uint256 queued ) =
            _split(shares, available, _convertToShares(minimumWithdraw, Math.Rounding.Ceil));

        if (instant > 0) _markClaimableInstantWithdraw(controller, instant);

        if (queued > 0) {
            transaction.amount = queued;

            withdrawQueue.push(transaction);

            totalWithdrawQueueShares            += queued;
            ledger[controller].pendingSharesOut += queued;

            emit WithdrawQueueValuation(totalWithdrawQueueShares);
        }

        return 0;
    }

    function cancelDepositRequest(address controller, uint256 nonce) external nonReentrant {
        bytes32 element = SpPrimeQueue.key(controller, nonce);

        ( bool active, Transaction memory transaction ) = SpPrimeQueue.tryGet(depositQueue, element);

        require(active, RequestNotQueued(controller, nonce));

        // Authorize the caller
        require (
            msg.sender == transaction.owner ||
            msg.sender == controller ||
            isOperator(controller, msg.sender) ||
            hasRole(VAULT_MANAGER_ROLE, msg.sender),
            UnauthorizedCaller(msg.sender)
        );

        _accrueInterest();

        delete depositQueue.entries[element];

        totalDepositQueueSavingsShares          -= transaction.amount;
        ledger[controller].pendingSavingsShares -= transaction.amount;

        uint256 assets = savingsVault.redeem(transaction.amount, transaction.owner, address(this));

        emit DepositRequestCancelled(controller, transaction.owner, nonce, assets);
        emit DepositQueueValuation(totalDepositQueueSavingsShares);
    }

    /**********************************************************************************************/
    /*** Claim functions                                                                        ***/
    /**********************************************************************************************/

    /// @dev Synchronous 4626 deposits are converted to async. The caller is assigned to controller
    // @audit: original deposit function dont have whenNotPaused and nonReentrant modifiers
    function deposit(uint256 assets, address receiver)
        public
        whenNotPaused
        nonReentrant
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256 shares)
    {
        return deposit(assets, receiver, msg.sender);
    }

    // @audit: original deposit function dont have whenNotPaused and nonReentrant modifiers
    function deposit(
        uint256 assets,
        address receiver,
        address controller,
        uint256 referralCode
    ) public whenNotPaused nonReentrant returns (uint256 shares) {
        emit ReferralCode(receiver, referralCode);

        return deposit(assets, receiver, controller);
    }

    /// @dev Should always revert if entire claimable amount cannot be fulfilled
    /// @notice Only user themselves or their approved operator can call
    function deposit(
        uint256 assets,
        address receiver,
        address controller
    ) public whenNotPaused nonReentrant returns (uint256 shares) {
        _authorizeClaim(receiver, controller);

        require(assets > 0, ZeroValueProvided());

        Settlement storage settlement = ledger[controller];

        require(
            assets <= settlement.depositedAssets,
            InsufficientClaimableBalance(assets, settlement.depositedAssets)
        );

        _accrueInterest();

        shares = Math.mulDiv(settlement.sharesOwed, assets, settlement.depositedAssets, Math.Rounding.Floor);

        require(shares > 0, ShareConversionFailure(assets));

        _claimDeposit(receiver, controller, assets, shares);
    }

    /// @dev When user calls 4626 sync functions, we transform to async assuming they are their own controller
    function mint(uint256 shares, address receiver)
        public
        whenNotPaused
        nonReentrant
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256 assets)
    {
        return mint(shares, receiver, msg.sender);
    }

    function mint(
        uint256 shares,
        address receiver,
        address controller
    ) public whenNotPaused nonReentrant returns (uint256 assets) {
        _authorizeClaim(receiver, controller);

        require(shares > 0, ZeroValueProvided());

        Settlement storage settlement = ledger[controller];

        require(
            shares <= settlement.sharesOwed,
            InsufficientClaimableBalance(shares, settlement.sharesOwed)
        );

        _accrueInterest();

        assets = Math.mulDiv(settlement.depositedAssets, shares, settlement.sharesOwed, Math.Rounding.Ceil);

        _claimDeposit(receiver, controller, assets, shares);
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address controller
    )
        public
        whenNotPaused
        nonReentrant
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256 shares)
    {
        _authorizeClaim(receiver, controller);

        Settlement storage settlement = ledger[controller];

        require(
            assets <= settlement.assetsOwed,
            InsufficientClaimableAmount(assets, settlement.assetsOwed)
        );

        /// Calculate the amount owed to user, based on their withdrawnShares and assetsOwed at fill time
        shares = Math.mulDiv(settlement.withdrawnShares, assets, settlement.assetsOwed, Math.Rounding.Ceil);

        _claimRedeem(receiver, controller, shares, assets);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address controller
    ) public override(ERC4626Upgradeable, IERC4626) whenNotPaused nonReentrant returns (uint256 assets) {
        _authorizeClaim(receiver, controller);

        Settlement storage settlement = ledger[controller];

        if (settlement.withdrawnShares < shares) {
            revert InsufficientClaimableAmount(shares, settlement.withdrawnShares);
        }

        /// Calculate the amount owed to user, based on their withdrawnShares and assetsOwed at fill time
        assets = Math.mulDiv(settlement.assetsOwed, shares, settlement.withdrawnShares);

        _claimRedeem(receiver, controller, shares, assets);
    }

    /**********************************************************************************************/
    /*** View functions                                                                         ***/
    /**********************************************************************************************/

    // ERC-4626 overrides
    // totalAssets, maxDeposit, maxMint, maxWithdraw, maxRedeem,
    // previewDeposit, previewMint, previewWithdraw, previewRedeem

    function totalAssets() public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        uint256 assets = convertToAssets(totalSupply());
        return assets > totalLoss ? assets - totalLoss : 0;
    }

    function maxDeposit(address receiver) public view override(ERC4626Upgradeable, IERC4626)
        returns (uint256)
    {
        return paused() ? 0 : ledger[receiver].depositedAssets;
    }

    // TODO: START from here overriding ERC4626 functions

    // ERC-7540 request views

    function pendingDepositRequest(uint256, address controller) public view returns (uint256 pendingAssets) {
        return savingsVault.convertToAssets(ledger[controller].pendingSavingsShares);
    }

    function claimableDepositRequest(
        uint256,
        address controller
    ) public view returns (uint256 claimableAssets) {
        claimableAssets = ledger[controller].depositedAssets;
    }

    function pendingRedeemRequest(uint256, address controller) public view returns (uint256 pendingShares) {
        return ledger[controller].pendingSharesOut;
    }

    function claimableRedeemRequest(
        uint256,
        address controller
    ) public view returns (uint256 claimableShares) {
        claimableShares = ledger[controller].withdrawnShares;
    }

    // Request lookups

    function requestNonce(address controller) public view returns (uint256) {
        return nonces[controller];
    }

    function queuedDepositRequest(
        address controller,
        uint256 nonce
    ) public view returns (Transaction memory transaction) {
        transaction = depositQueue.entries[SpPrimeQueue.key(controller, nonce)];
    }

    function pendingWithdrawAmount(address controller) public view returns (uint256) {
        return ledger[controller].pendingSharesOut;
    }

    // Capacity and liquidity

    function availableCapacity() public view returns (uint256 available) {
        uint256 supply = totalSupply();
        available = maximumCapacity > supply ? maximumCapacity - supply : 0;
    }

    // @audit: totalBaseAssets can be negative because there is no guards on the `take()` and `depositToSavings()`
    // and those functions can move funds without respecting the totalClaimableWithdrawAssets.
    function availableLiquidAssets() public view returns (int256 totalBaseAssets) {
        totalBaseAssets =
            IERC20(asset()).balanceOf(address(this)).toInt256() -
            totalClaimableWithdrawAssets.toInt256();
    }

    // Rate

    // Index after accruing up to now, without writing state
    function previewIndex() public view returns (uint256) {
        uint256 timeDelta = block.timestamp - lastAccrualTimestamp;
        if (timeDelta == 0) return indexRate;

        return Math.mulDiv(indexRate, _rpow(ratePerSecond, timeDelta), RAY);
    }

    // ERC-7575 / ERC-165 and upgrade

    function share() public view returns (address shareTokenAddress) {
        shareTokenAddress = address(this);
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(AccessControlEnumerableUpgradeable, IERC165) returns (bool) {
        return
            interfaceId == type(IERC7540Operator).interfaceId ||
            interfaceId == type(IERC7540Deposit).interfaceId  ||
            interfaceId == type(IERC7540Redeem).interfaceId   ||
            // ERC-7575 ID covers the ERC-4626 functions plus share(); type() excludes inherited functions
            interfaceId == (type(IERC4626).interfaceId ^ type(IERC7575).interfaceId) ||
            super.supportsInterface(interfaceId);
    }

    function getImplementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }

    /**********************************************************************************************/
    /*** Internal helper functions                                                              ***/
    /**********************************************************************************************/

    // ERC-4626 overrides

    function _convertToShares(
        uint256       assets,
        Math.Rounding rounding
    )
        internal
        view
        override(ERC4626Upgradeable)
        returns (uint256)
    {
        return Math.mulDiv(assets, RAY, indexRate, rounding);
    }

    function _convertToAssets(
        uint256       shares,
        Math.Rounding rounding
    )
        internal
        view
        override(ERC4626Upgradeable)
        returns (uint256)
    {
        return Math.mulDiv(shares, indexRate, RAY, rounding);
    }

    // Authorization helpers

    function _authorizeClaim(address receiver, address controller) internal view {
        if (controller != msg.sender && !isOperator(controller, msg.sender)) revert UnauthorizedCaller(msg.sender);
        if (msg.sender != controller && receiver != controller) revert OperatorMaliciousAction(receiver, controller);
    }

    // Queue helpers
    // _fillWithdrawQueue, _fillDepositQueue,
    // _fillUnbounded, _fillUntil, _insertHeadWithNewAmount

    /// @dev Split `amount` into an instant fill and a queued remainder.
    ///      Neither part may be dust: a queued part below `minimum` takes the minimum back from the
    ///      instant part, and an instant part below `minimum` is moved to the queue entirely.
    ///      Caller guarantees amount >= minimum.
    function _split(uint256 amount, uint256 available, uint256 minimum)
        internal
        pure
        returns (uint256 instant, uint256 queued)
    {
        instant = Math.min(amount, available);
        queued  = amount - instant;

        if (queued != 0 && queued < minimum) {
            instant = amount - minimum;
            queued  = minimum;
        }

        if (instant < minimum) {
            instant = 0;
            queued  = amount;
        }
    }

    // Settlement helpers

    // Instant fill from requestDeposit. `assets` is base asset. Mints the shares into escrow now.
    function _markClaimableInstantDeposit(address controller, uint256 assets) internal {
        uint256 shares = _creditDeposit(controller, assets);
        _mint(address(this), shares);
    }

    // Queued fill from processQueue. `savingsShares` is Savings Vault shares.
    // Shares are minted in bulk by _fillDepositQueue after the loop.
    function _markClaimableQueuedDeposit(address controller, uint256 savingsShares) internal {
        ledger[controller].pendingSavingsShares -= savingsShares;
        totalDepositQueueSavingsShares          -= savingsShares;

        uint256 assets = Math.mulDiv(savingsShares, savingsSharePrice, RAY);

        _creditDeposit(controller, assets);
    }

    // Credit `assets` worth of vault shares to the controller's claimable deposit
    function _creditDeposit(address controller, uint256 assets) internal returns (uint256 shares) {
        shares = convertToShares(assets);
        if (shares == 0) return 0;

        Settlement storage settlement = ledger[controller];

        settlement.depositedAssets  += assets;
        settlement.sharesOwed       += shares;
        totalClaimableDepositShares += shares;

        emit ClaimableDeposit(controller, settlement.depositedAssets);
    }

    // Instant fill from requestRedeem. `shares` is vault shares already held by the vault. Burns them now.
    function _markClaimableInstantWithdraw(address controller, uint256 shares) internal {
        _creditWithdraw(controller, shares);
        _burn(address(this), shares);
    }

    // Queued fill from processQueue. `shares` is vault shares.
    // Shares are burned in bulk by _fillWithdrawQueue after the loop.
    function _markClaimableQueuedWithdraw(address controller, uint256 shares) internal {
        ledger[controller].pendingSharesOut -= shares;
        totalWithdrawQueueShares            -= shares;

        _creditWithdraw(controller, shares);
    }

    // Credit `shares` to the controller's claimable withdraw, with assets fixed at the current index
    function _creditWithdraw(address controller, uint256 shares) internal returns (uint256 assets) {
        assets = convertToAssets(shares);

        Settlement storage settlement = ledger[controller];

        settlement.withdrawnShares   += shares;
        settlement.assetsOwed        += assets;
        totalClaimableWithdrawAssets += assets;

        emit ClaimableWithdraw(controller, settlement.assetsOwed);
    }

    function _claimDeposit(
        address receiver,
        address controller,
        uint256 assets,
        uint256 shares
    ) internal {
        Settlement storage settlement = ledger[controller];

        settlement.depositedAssets  -= assets;
        settlement.sharesOwed       -= shares;
        totalClaimableDepositShares -= shares;

        _transfer(address(this), receiver, shares);

        emit Deposit(controller, receiver, assets, shares);
    }

    function _claimRedeem(
        address receiver,
        address controller,
        uint256 shares,
        uint256 assets
    ) internal {
        Settlement storage settlement = ledger[controller];

        settlement.withdrawnShares   -= shares;
        settlement.assetsOwed        -= assets;
        totalClaimableWithdrawAssets -= assets;

        IERC20 baseAsset = IERC20(asset());

        require(assets <= baseAsset.balanceOf(address(this)), Insolvency());

        baseAsset.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    // Interest helpers

    /// @dev Compounds indexRate by ratePerSecond^(seconds since last accrual)
    function _accrueInterest() internal {
        uint256 timeDelta = block.timestamp - lastAccrualTimestamp;
        if (timeDelta == 0) return;

        lastAccrualTimestamp = block.timestamp;
        indexRate            = Math.mulDiv(indexRate, _rpow(ratePerSecond, timeDelta), RAY);

        emit AccruedInterest(indexRate, block.timestamp);
    }

    /// @dev x^n in RAY precision, exponentiation by squaring (MakerDAO rpow)
    function _rpow(uint256 x, uint256 n) internal pure returns (uint256 z) {
        assembly {
            switch x case 0 {switch n case 0 {z := RAY} default {z := 0}}
            default {
                switch mod(n, 2) case 0 { z := RAY } default { z := x }
                let half := div(RAY, 2)  // for rounding.
                for { n := div(n, 2) } n { n := div(n,2) } {
                    let xx := mul(x, x)
                    if iszero(eq(div(xx, x), x)) { revert(0,0) }
                    let xxRound := add(xx, half)
                    if lt(xxRound, xx) { revert(0,0) }
                    x := div(xxRound, RAY)
                    if mod(n,2) {
                        let zx := mul(z, x)
                        if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) { revert(0,0) }
                        let zxRound := add(zx, half)
                        if lt(zxRound, zx) { revert(0,0) }
                        z := div(zxRound, RAY)
                    }
                }
            }
        }
    }

}
