// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VaultHandler} from "./VaultHandler.t.sol";
import {IVault} from "src/interfaces/IVault.sol";
import {ISparkPrimeVault} from "src/interfaces/ISparkPrimeVault.sol";
import {IVaultManagement} from "src/interfaces/IVaultManagement.sol";
import {USDC} from "./mocks/USDC.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {console} from "forge-std/console.sol";
import {QueueHelper} from "./utils/QueueHelper.sol";

contract RequestDepositUnitTests is QueueHelper {


    function setUp() public {
        _deployVault();
    }
    /// @dev If older deposit claims consume the available liquidity, a new requestor shoudn't be able to request and claim instant liquidty
    function test_cannot_claimDeposit_WhenOlderClaimsNotSettled() public {
        uint256 userDepositSize = vault.availableCapacity();

        _fundAndDeposit(vault, user, baseAsset, userDepositSize); // user gets instant claim, but they never settle it
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
        uint256 userDepositSize = vault.availableCapacity();
        _fundAndDeposit(vault, user, baseAsset, userDepositSize);
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
        vm.startPrank(user);
        deal(address(baseAsset), user, 200 ether);
        assertEq(vault.availableCapacity(), vault.maxCapacity());

        baseAsset.approve(address(vault), 200 ether);
        vault.requestDeposit(200 ether, user, user);

        assertEq(100 ether, vault.maxDeposit(user)); /// Only 100 ether (max vault capacity) immedietely claimable
        uint256 shares = vault.convertToShares(100 ether);

        assertEq(vault.totalPendingDeposits(), 100 ether); /// My remaining 100 ether should be pending (total value of queue)

        VaultHandler.Transaction memory data = vault.depositQueueHead();
        assertEq(data.amount, 100 ether);
        assertEq(data.controller, user);
        assertEq(data.nonce, 1);

        /// It should reject a 200 ether request, because only 100 is actually claimable at the moment
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.InsufficientClaimableBalance.selector,
                200 ether,
                100 ether
            )
        );
        vault.deposit(200 ether, user);

        /// Because the vault is over capacity, and no withdraw queue exists to fulfill, I cannot claim my 100 ether.
        /// @dev Curator must rebalance
        vault.deposit(100 ether, user);

        shares = vault.balanceOf(user);
        assertApproxEqAbs(shares, vault.convertToShares(100 ether), 1 wei);
    }
    function _fundAndDeposit(address _user, uint256 amount) internal {
        vm.startPrank(_user);

        deal(address(baseAsset), _user, amount);
        baseAsset.approve(address(vault), amount);

        vault.requestDeposit(amount, _user, _user);

        vm.stopPrank();
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
        _fundAndDeposit(makeAddr("CapacityEater"), vault.availableCapacity());

        vm.startPrank(user);
        deal(address(baseAsset), user, 10 ether);
        assertEq(vault.availableCapacity(), 0, "capaciry");

        uint256 prevTotalAssets = vault.totalAssets();
        console.log("total assets before requestDeposit: %e", prevTotalAssets);
        baseAsset.approve(address(vault), 10 ether);
        vault.requestDeposit(10 ether, user, user);

        assertEq(0, vault.maxDeposit(user), "Max deposit zero"); /// Nothing immediately claimable
        assertEq(vault.totalPendingDeposits(), 10 ether, "pending deposits"); /// My remaining 10 ether should be pending (total value of queue)

        VaultHandler.Transaction memory data = vault.depositQueueHead();
        assertEq(data.amount, 10 ether);
        assertEq(data.controller, user);
        assertEq(data.nonce, 1);
    }

    function test_overCapacity_fullAmountQueued_capacityEaterHasClaimed()
        public
    {
        // A previous user has eat all the available capacity
        address capacityEater = makeAddr("CapacityEater");
        uint256 totalVaultCapacity = vault.availableCapacity();

        _fundAndDeposit(capacityEater, totalVaultCapacity);

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
        assertEq(
            vault.totalPendingDeposits(),
            10 ether,
            "total pending deposits is 10 ether (only user in queue)"
        );

        VaultHandler.Transaction memory data = vault.depositQueueHead();
        assertEq(data.amount, 10 ether, "amount matches queue");
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
                ISparkPrimeVault.MustExceedMinimumRequestAmount.selector,
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
                ISparkPrimeVault.MustExceedMinimumRequestAmount.selector,
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
                ISparkPrimeVault.MustExceedMinimumRequestAmount.selector,
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

    function test_requestDeposit_anyAmountWhenNoMinimumConfigured() public {
        _deployVaultWithMinimums(0, 0);

        assertEq(vault.minimumDeposit(), 0);
        _requestDeposit(user, 1 wei);

        assertEq(vault.maxDeposit(user), 1 wei);
    }
}
