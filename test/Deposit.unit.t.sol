// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VaultHandler} from "./VaultHandler.t.sol";
import {IVault} from "src/interfaces/IVault.sol";
import {ISparkPrimeVault} from "src/interfaces/ISparkPrimeVault.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {
    IERC20Errors
} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IVaultManagement} from "src/interfaces/IVaultManagement.sol";
import {USDC} from "./mocks/USDC.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {console} from "forge-std/console.sol";
import {QueueHelper} from "./utils/QueueHelper.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract RequestDepositUnitTests is QueueHelper {
    function setUp() public {
        _deployVault();
    }
    /// @dev If older deposit claims consume the available liquidity, a new requestor shoudn't be able to request and claim instant liquidty
    function test_cannot_claimDeposit_WhenOlderClaimsNotSettled() public {
        uint256 userDepositSize = _fillCapacity(user); // user gets instant claim, but they never settle it
        _fundAndDeposit(vault, userTwo, baseAsset, userDepositSize); // should go directly to queue, nothing instant claimable

        vm.prank(userTwo);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.InsufficientClaimableBalance.selector,
                userDepositSize,
                0
            )
        );
        vault.deposit(userDepositSize, userTwo);
    }

    function test_claimDeposit() public {
        uint256 userDepositSize = _fillCapacity(user);
        // The user claims all the funds this time
        vm.startPrank(user);
        vault.deposit(userDepositSize, user);
        vm.stopPrank();
    }
    function test_cannot_claimDeposit_whenNoClaimableBalance() public {
        deal(address(baseAsset), user, 10 ether);
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.InsufficientClaimableBalance.selector,
                5 ether,
                0
            )
        );
        vault.deposit(5 ether, user, user);
    }
    function test_cannot_claimDeposit_whenNotAuthorized() public {
        deal(address(baseAsset), user, 10 ether);
        vm.startPrank(address(123));
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.UnauthorizedCaller.selector,
                address(123)
            )
        );
        vault.deposit(5 ether, user, user);
        vm.stopPrank();
    }

    function test_cannot_claimDeposit_forceControllerStatus() public {
        deal(address(baseAsset), user, 10 ether);
        vm.startPrank(address(123));
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.UnauthorizedCaller.selector,
                address(123)
            )
        );
        // I cannot pass myself as `reciever` and call on behalf of a user
        vault.deposit(5 ether, address(123), user);
        vm.stopPrank();
    }

    function test_cannot_requestDepositforOthers() public {
        vm.startPrank(user);
        deal(address(baseAsset), user, 10 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IVault.UnauthorizedCaller.selector, user)
        );
        vault.requestDeposit(10 ether, user, victim);
    }

    /// @dev When vault has available capacity and no queues exist, a deposit size smaller than available capacity should become immediately claimable
    function test_belowCapacity_fullInstantClaim() public {
        vm.startPrank(user);
        deal(address(baseAsset), user, 10 ether);
        assertEq(uint256(vault.availableCapacity()), vault.maxCapacity());

        baseAsset.approve(address(vault), 10 ether);
        vault.requestDeposit(10 ether, user, user);

        assertEq(10 ether, vault.maxDeposit(user));
        uint256 shares = vault.convertToShares(10 ether);

        vault.deposit(10 ether, user);
        shares = vault.balanceOf(user);
        assertApproxEqAbs(shares, vault.convertToShares(10 ether), 1 wei);
    }

    /// @dev When vault has available capacity, but not as much as user needs. Partial instant claim, remainder queued
    function test_belowCapacity_partialInstantClaim_remainderQueued() public {
        _openCapacity(100 ether);
        uint256 instant = _capacityValue();
        vm.startPrank(user);
        deal(address(baseAsset), user, 200 ether);
        assertEq(vault.availableCapacity(), vault.maxCapacity());

        baseAsset.approve(address(vault), 200 ether);
        vault.requestDeposit(200 ether, user, user);

        assertEq(instant, vault.maxDeposit(user)); /// Only max vault capacity immedietely claimable
        uint256 shares = vault.convertToShares(instant);

        assertApproxEqAbs(
            savingsVault.previewRedeem(vault.totalPendingDeposits()),
            200 ether - instant,
            ROUNDING_DUST
        ); /// My remaining ether should be pending (total value of queue)

        VaultHandler.Transaction memory data = vault.depositQueueHead();
        assertEq(data.amount, vault.totalPendingDeposits());
        assertEq(data.controller, user);
        assertEq(data.nonce, 1);

        /// It should reject a 200 ether request, because only 100 is actually claimable at the moment
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.InsufficientClaimableBalance.selector,
                200 ether,
                instant
            )
        );
        vault.deposit(200 ether, user);

        /// Because the vault is over capacity, and no withdraw queue exists to fulfill, I cannot claim my 100 ether.
        /// @dev Curator must rebalance
        vault.deposit(instant, user);

        shares = vault.balanceOf(user);
        assertEq(shares, vault.maxCapacity());
    }
    function _fundAndDeposit(address _user, uint256 amount) internal {
        _nextBlock();
        vm.startPrank(_user);

        deal(address(baseAsset), _user, amount);
        baseAsset.approve(address(vault), amount);

        vault.requestDeposit(amount, _user, _user);

        vm.stopPrank();
    }

    function test_deposit_transfersSharesToVault() public {
        _requestDeposit(user, 10 ether);
        uint256 shares = vault.maxMint(user);
        uint256 supply = vault.totalSupply();
        assertEq(vault.balanceOf(address(vault)), shares);

        vm.expectEmit(address(vault));
        emit IERC20.Transfer(address(vault), user, shares);
        vm.prank(user);
        vault.deposit(10 ether, user);

        assertEq(vault.balanceOf(user), shares);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.totalSupply(), supply);
    }

    function test_claimable_reducesAvailableCapacity() public {
        // A previous user has eat all the available capacity
        address capacityEater = makeAddr("CapacityEater");
        uint256 previous = vault.availableCapacity();
        _fundAndDeposit(capacityEater, 100 ether);
        uint256 post = vault.availableCapacity();
        assertLt(post, previous);
    }

    /// @dev FIFO principles should apply even when I don't claim i.e user cannot frontrun 'CapacityEater' just because they havent claimed yet
    function test_overCapacity_fullAmountQueued_capacityEaterHasntClaimed()
        public
    {
        // A previous user has eat all the available capacity
        _fillCapacity(makeAddr("CapacityEater"));

        vm.startPrank(user);
        deal(address(baseAsset), user, 10 ether);
        assertEq(vault.availableCapacity(), 0, "capaciry");

        uint256 prevTotalAssets = vault.totalAssets();
        console.log("total assets before requestDeposit: %e", prevTotalAssets);
        baseAsset.approve(address(vault), 10 ether);
        vault.requestDeposit(10 ether, user, user);

        assertEq(0, vault.maxDeposit(user), "Max deposit zero"); /// Nothing immediately claimable
        assertApproxEqAbs(
            savingsVault.previewRedeem(vault.totalPendingDeposits()),
            10 ether,
            ROUNDING_DUST,
            "pending deposits"
        ); /// My remaining 10 ether should be pending (total value of queue)

        VaultHandler.Transaction memory data = vault.depositQueueHead();
        assertEq(data.amount, vault.totalPendingDeposits());
        assertEq(data.controller, user);
        assertEq(data.nonce, 1);
    }

    function test_overCapacity_fullAmountQueued_capacityEaterHasClaimed()
        public
    {
        // A previous user has eat all the available capacity
        address capacityEater = makeAddr("CapacityEater");
        uint256 totalVaultCapacity = _fillCapacity(capacityEater);

        assertEq(
            vault.maxDeposit(capacityEater),
            totalVaultCapacity,
            "Capacity Eater can instant claim entire vault capacity"
        );

        uint256 prevTotalAssets = vault.totalAssets();
        // The user claims all the funds this time
        vm.startPrank(capacityEater);
        vault.deposit(totalVaultCapacity, capacityEater);
        vm.stopPrank();
        uint256 postTotalAssets = vault.totalAssets();

        vm.startPrank(user);
        deal(address(baseAsset), user, 10 ether);

        assertEq(vault.availableCapacity(), 0);

        baseAsset.approve(address(vault), 10 ether);
        vault.requestDeposit(10 ether, user, user);

        assertEq(0, vault.maxDeposit(user), "max deposit is zero"); /// Nothing immediately claimable
        assertApproxEqAbs(
            savingsVault.previewRedeem(vault.totalPendingDeposits()),
            10 ether,
            ROUNDING_DUST,
            "total pending deposits is 10 ether (only user in queue)"
        );

        VaultHandler.Transaction memory data = vault.depositQueueHead();
        assertEq(
            data.amount,
            vault.totalPendingDeposits(),
            "amount matches queue"
        );
        assertEq(data.controller, user, "controller is user");
        assertEq(data.nonce, 1, "nonce is 1");
    }

    function test_minimumDeposit_isSetByInitialize() public view {
        assertEq(vault.minimumDeposit(), MINIMUM_DEPOSIT);
    }

    function test_cannot_requestDeposit_belowMinimum() public {
        uint256 amount = MINIMUM_DEPOSIT - 1;
        _fund(user, amount);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISparkPrimeVault.BelowMinimumRequestAmount.selector,
                MINIMUM_DEPOSIT
            )
        );
        vault.requestDeposit(amount, user, user);
    }

    function test_requestDeposit_atMinimum() public {
        _requestDeposit(user, MINIMUM_DEPOSIT);

        assertEq(vault.maxDeposit(user), MINIMUM_DEPOSIT);
        assertEq(baseAsset.balanceOf(address(vault)), MINIMUM_DEPOSIT);
    }

    function test_requestDeposit_belowMinimum_doesNotMoveAssets() public {
        uint256 amount = MINIMUM_DEPOSIT - 1;
        _fund(user, amount);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISparkPrimeVault.BelowMinimumRequestAmount.selector,
                MINIMUM_DEPOSIT
            )
        );
        vault.requestDeposit(amount, user, user);

        assertEq(baseAsset.balanceOf(user), amount);
        assertEq(baseAsset.balanceOf(address(vault)), 0);
        assertEq(vault.depositQueueLength(), 0);
    }

    function test_cannot_requestDeposit_belowMinimum_whenQueueExists() public {
        _closeCapacity();
        _requestDeposit(user, 10 ether);
        assertEq(vault.depositQueueLength(), 1);

        uint256 amount = MINIMUM_DEPOSIT - 1;
        _fund(userTwo, amount);

        vm.prank(userTwo);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISparkPrimeVault.BelowMinimumRequestAmount.selector,
                MINIMUM_DEPOSIT
            )
        );
        vault.requestDeposit(amount, userTwo, userTwo);

        assertEq(vault.depositQueueLength(), 1);
    }

    function test_requestDeposit_zeroRevertsBeforeTheMinimumCheck() public {
        _fund(user, 1 ether);

        vm.prank(user);
        vm.expectRevert(ISparkPrimeVault.ZeroValueProvided.selector);
        vault.requestDeposit(0, user, user);
    }

    function test_cannot_requestDeposit_forZeroController() public {
        _fund(user, 10 ether);

        vm.prank(user);
        vm.expectRevert(ISparkPrimeVault.ZeroValueProvided.selector);
        vault.requestDeposit(10 ether, address(0), user);
    }

    function test_requestDeposit_anyAmountWhenNoMinimumConfigured() public {
        _deployVaultWithMinimums(0, 0);

        assertEq(vault.minimumDeposit(), 0);
        uint256 smallest = vault.convertToAssetsRounded(2, Math.Rounding.Ceil);
        _requestDeposit(user, smallest);

        assertEq(vault.maxDeposit(user), smallest);
        assertGt(vault.maxMint(user), 0);
    }

    function test_mint_claimsAgainstAClaimableBalance() public {
        _requestDeposit(user, 40 ether);
        uint256 shares = vault.convertToShares(40 ether);

        vm.prank(user);
        uint256 assets = vault.mint(shares, user);

        assertEq(assets, 40 ether);
        assertEq(vault.balanceOf(user), shares);
        assertEq(vault.maxDeposit(user), 0);
        assertEq(vault.totalAssets(), vault.convertToAssets(shares));
    }

    function test_mint_partiallyConsumesTheClaimableBalance() public {
        _requestDeposit(user, 40 ether);
        uint256 shares = vault.convertToShares(10 ether);

        vm.prank(user);
        uint256 assets = vault.mint(shares, user);

        assertEq(vault.balanceOf(user), shares);
        assertEq(vault.maxDeposit(user), 40 ether - assets);
        assertApproxEqAbs(
            vault.maxDeposit(user),
            30 ether,
            vault.convertToAssets(1) + 1
        );
    }

    function test_mint_withExplicitController() public {
        _requestDeposit(user, 40 ether);
        uint256 shares = vault.convertToShares(40 ether);

        vm.prank(user);
        uint256 assets = vault.mint(shares, user, user);

        assertEq(assets, 40 ether);
        assertEq(vault.balanceOf(user), shares);
    }

    function test_mint_asOperator() public {
        _requestDeposit(user, 40 ether);
        vault.setOperatorForUser(user, operator, true);
        uint256 shares = vault.convertToShares(40 ether);

        vm.prank(operator);
        vault.mint(shares, user, user);

        assertEq(vault.balanceOf(user), shares);
        assertEq(vault.balanceOf(operator), 0);
    }

    function test_cannot_mint_beyondClaimableBalance() public {
        _requestDeposit(user, 10 ether);
        uint256 shares = vault.convertToShares(20 ether);
        uint256 locked = vault.maxMint(user);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.InsufficientClaimableBalance.selector,
                shares,
                locked
            )
        );
        vault.mint(shares, user);
    }

    function test_mint_emitsDeposit() public {
        _requestDeposit(user, 40 ether);
        uint256 shares = vault.convertToShares(40 ether);

        vm.expectEmit(address(vault));
        emit IERC4626.Deposit(user, user, 40 ether, shares);

        vm.prank(user);
        vault.mint(shares, user);
    }

    function test_depositWithReferralCode_emitsReferralCode() public {
        _requestDeposit(user, 40 ether);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.ReferralCode(user, 7);

        vm.prank(user);
        vault.deposit(40 ether, user, user, 7);
    }

    function test_depositWithReferralCode_matchesPlainDeposit() public {
        _requestDeposit(user, 40 ether);
        uint256 expected = vault.convertToShares(40 ether);

        vm.prank(user);
        uint256 shares = vault.deposit(40 ether, user, user, 99);

        assertEq(shares, expected);
        assertEq(vault.balanceOf(user), expected);
        assertEq(vault.maxDeposit(user), 0);
        assertEq(vault.totalAssets(), vault.convertToAssets(expected));
    }

    function test_mintWithReferralCode_emitsReferralCode() public {
        _requestDeposit(user, 40 ether);
        uint256 shares = vault.maxMint(user);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.ReferralCode(user, 7);

        vm.prank(user);
        vault.mint(shares, user, user, 7);

        assertEq(vault.balanceOf(user), shares);
        assertEq(vault.maxMint(user), 0);
    }

    function test_cannot_depositWithReferralCode_asUnauthorizedCaller() public {
        _requestDeposit(user, 40 ether);

        vm.prank(userTwo);
        vm.expectRevert(
            abi.encodeWithSelector(IVault.UnauthorizedCaller.selector, userTwo)
        );
        vault.deposit(40 ether, userTwo, user, 7);
    }

    function test_deposit_emitsDepositWithControllerThenReceiver() public {
        _requestDeposit(user, 40 ether);
        uint256 shares = vault.convertToShares(40 ether);

        vm.expectEmit(address(vault));
        emit IERC4626.Deposit(user, userTwo, 40 ether, shares);

        vm.prank(user);
        vault.deposit(40 ether, userTwo, user);

        assertEq(vault.balanceOf(userTwo), shares);
        assertEq(vault.balanceOf(user), 0);
    }

    function test_deposit_asOperator_emitsControllerNotOperator() public {
        _requestDeposit(user, 40 ether);
        vault.setOperatorForUser(user, operator, true);
        uint256 shares = vault.convertToShares(40 ether);

        vm.expectEmit(address(vault));
        emit IERC4626.Deposit(user, user, 40 ether, shares);

        vm.prank(operator);
        vault.deposit(40 ether, user, user);
    }

    function test_depositWithReferralCode_emitsDepositWithSpecParameters()
        public
    {
        _requestDeposit(user, 40 ether);
        uint256 shares = vault.convertToShares(40 ether);

        vm.expectEmit(address(vault));
        emit IERC4626.Deposit(user, userTwo, 40 ether, shares);

        vm.prank(user);
        vault.deposit(40 ether, userTwo, user, 3);
    }

    function test_requestDeposit_queuedAssetsAreHeldAsSavingsShares() public {
        _closeCapacity();

        _requestDeposit(user, 10 ether);
        uint256 shares = savingsVault.balanceOf(address(vault));

        assertEq(baseAsset.balanceOf(address(vault)), 0);
        assertEq(vault.totalPendingDeposits(), shares);
        assertEq(vault.depositQueueHead().amount, shares);
        assertApproxEqAbs(savingsVault.previewRedeem(shares), 10 ether, 2);
        assertEq(
            vault.pendingDepositRequest(0, user),
            savingsVault.convertToAssets(shares)
        );
    }

    function test_requestDeposit_onlyTheQueuedRemainderIsSaved() public {
        _openCapacity(30 ether);
        _nextBlock();
        uint256 instant = _capacityValue();
        _fund(user, 40 ether);
        vm.prank(user);
        vault.requestDeposit(40 ether, user, user);
        uint256 shares = savingsVault.balanceOf(address(vault));

        assertEq(vault.maxDeposit(user), instant);
        assertEq(baseAsset.balanceOf(address(vault)), instant);
        assertEq(vault.totalPendingDeposits(), shares);
        assertApproxEqAbs(
            savingsVault.previewRedeem(shares),
            40 ether - instant,
            2
        );
    }

    function test_cannot_requestDeposit_whenTheQueuedRemainderBuysNoSavingsShares()
        public
    {
        _depositAndClaim(user, 50 ether);
        vm.prank(rebalancer);
        vault.depositToSavings(50 ether);
        _accrueSavings(1_000);

        uint256 capacity = _capacityValue();
        _fund(userTwo, capacity + 1);

        vm.prank(userTwo);
        vm.expectRevert(
            abi.encodeWithSelector(IVault.ShareConversionFailure.selector, 1)
        );
        vault.requestDeposit(capacity + 1, userTwo, userTwo);
    }

    function test_requestDeposit_queuesARemainderBelowTheMinimum() public {
        _openCapacity(30 ether);
        _nextBlock();
        uint256 capacity = _capacityValue();
        uint256 remainder = MINIMUM_DEPOSIT - 1;
        _fund(user, capacity + remainder);

        vm.prank(user);
        vault.requestDeposit(capacity + remainder, user, user);

        assertEq(vault.maxDeposit(user), capacity);
        assertEq(vault.depositQueueLength(), 1);
        assertApproxEqAbs(
            savingsVault.previewRedeem(vault.totalPendingDeposits()),
            remainder,
            2
        );
    }

    function test_pendingDepositRequest_tracksSavingsYield() public {
        _closeCapacity();
        _requestDeposit(user, 100 ether);
        uint256 shares = vault.totalPendingDeposits();

        _accrueSavings(1_000);

        assertEq(vault.totalPendingDeposits(), shares);
        assertEq(
            vault.pendingDepositRequest(0, user),
            savingsVault.convertToAssets(shares)
        );
        assertGt(vault.pendingDepositRequest(0, user), 100 ether);
    }

    function test_deposit_claimTimingDoesNotChangeTheShares() public {
        _requestDeposit(user, 50 ether);
        uint256 locked = vault.maxMint(user);

        vm.warp(block.timestamp + 365 days);

        vm.prank(user);
        uint256 shares = vault.deposit(50 ether, user);

        assertEq(shares, locked);
        assertEq(vault.balanceOf(user), locked);
        assertGt(vault.convertToAssets(shares), 50 ether);
    }

    function test_deposit_partialClaimsUseTheFrozenRatio() public {
        vault.setIndexRate((RAY * 10) / 3);
        _requestDeposit(user, 50 ether);
        uint256 locked = vault.maxMint(user);

        vm.warp(block.timestamp + 365 days);

        vm.startPrank(user);
        uint256 first = vault.deposit(20 ether, user);
        uint256 second = vault.deposit(vault.maxDeposit(user), user);
        vm.stopPrank();

        assertEq(first + second, locked);
        assertEq(vault.maxMint(user), 0);
        assertEq(vault.maxDeposit(user), 0);
        assertEq(vault.claimableDepositTotal(), 0);
    }

    function testFuzz_mint_mintsExactlyTheRequestedShares(
        uint256 index,
        uint256 amount,
        uint256 shares
    ) public {
        vault.setIndexRate(bound(index, RAY, 10 * RAY));
        amount = bound(amount, MINIMUM_DEPOSIT, 50 ether);
        _requestDeposit(user, amount);
        uint256 locked = vault.maxMint(user);
        shares = bound(shares, 1, locked);

        vm.prank(user);
        uint256 assets = vault.mint(shares, user);

        assertEq(vault.balanceOf(user), shares);
        assertEq(vault.maxDeposit(user), amount - assets);
        assertEq(vault.maxMint(user), locked - shares);

        uint256 rest = vault.maxMint(user);
        if (rest > 0) {
            vm.prank(user);
            vault.mint(rest, user);
        }

        assertEq(vault.balanceOf(user), locked);
        assertEq(vault.maxDeposit(user), 0);
        assertEq(vault.maxMint(user), 0);
    }

    function testFuzz_deposit_fullClaimLeavesNothingBehind(
        uint256 index,
        uint256 amount,
        uint256 part
    ) public {
        vault.setIndexRate(bound(index, RAY, 10 * RAY));
        amount = bound(amount, MINIMUM_DEPOSIT, 50 ether);
        _requestDeposit(user, amount);
        uint256 locked = vault.maxMint(user);
        uint256 smallest = (amount + locked - 1) / locked;
        part = bound(part, smallest, amount);

        vm.startPrank(user);
        vault.deposit(part, user);
        if (vault.maxDeposit(user) > 0)
            vault.deposit(vault.maxDeposit(user), user);
        vm.stopPrank();

        assertEq(vault.balanceOf(user), locked);
        assertEq(vault.maxDeposit(user), 0);
        assertEq(vault.maxMint(user), 0);
        assertEq(vault.claimableDepositTotal(), 0);
    }

    function test_cannot_mint_asUnauthorizedCaller() public {
        _requestDeposit(user, 40 ether);
        uint256 shares = vault.maxMint(user);

        vm.prank(userTwo);
        vm.expectRevert(
            abi.encodeWithSelector(IVault.UnauthorizedCaller.selector, userTwo)
        );
        vault.mint(shares, userTwo, user);
    }

    function test_cannot_mint_asOperatorToAnotherReceiver() public {
        _requestDeposit(user, 40 ether);
        vault.setOperatorForUser(user, operator, true);
        uint256 shares = vault.maxMint(user);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.OperatorMaliciousAction.selector,
                operator,
                user
            )
        );
        vault.mint(shares, operator, user);
    }

    function test_cannot_claimDeposit_toTheVaultOrZeroAddress() public {
        _requestDeposit(user, 40 ether);
        uint256 shares = vault.maxMint(user);

        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InvalidReceiver.selector,
                address(vault)
            )
        );
        vault.deposit(40 ether, address(vault), user);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InvalidReceiver.selector,
                address(0)
            )
        );
        vault.mint(shares, address(0), user);
        vm.stopPrank();
    }

    function test_cannot_mint_zeroShares() public {
        _requestDeposit(user, 40 ether);

        vm.prank(user);
        vm.expectRevert(ISparkPrimeVault.ZeroValueProvided.selector);
        vault.mint(0, user);
    }

    function test_mint_roundsTheAssetsInTheVaultsFavour() public {
        _deployCleanVault(MINIMUM_DEPOSIT, MINIMUM_WITHDRAW);
        vault.setIndexRate((RAY * 10) / 3);
        _requestDeposit(user, 10 ether);
        assertEq(vault.maxMint(user), 3 ether);

        vm.prank(user);
        uint256 assets = vault.mint(1, user);

        assertEq(assets, 4);
        assertEq(vault.maxDeposit(user), 10 ether - 4);
    }

    function test_requestDeposit_instantlyCreditsTheLastShareOfCapacity()
        public
    {
        _deployCleanVault(MINIMUM_DEPOSIT, MINIMUM_WITHDRAW);
        vault.setIndexRate((RAY * 3) / 2);
        _setCapacity(1);
        _requestDeposit(user, 10 ether);

        assertEq(vault.maxMint(user), 1);
        assertEq(vault.maxDeposit(user), 2);
        assertEq(vault.availableCapacity(), 0);
        assertEq(vault.depositQueueLength(), 1);

        _claim(user, 2);
        assertEq(vault.balanceOf(user), 1);
    }

    function test_cannot_requestDeposit_anAmountThatBuysNoShare() public {
        _deployCleanVault(0, 0);
        vault.setIndexRate((RAY * 3) / 2);
        _fund(user, 1);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IVault.ShareConversionFailure.selector, 1)
        );
        vault.requestDeposit(1, user, user);
    }
}
