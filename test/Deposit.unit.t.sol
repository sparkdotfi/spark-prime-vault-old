// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VaultHandler} from "./VaultHandler.t.sol";
import {IVault} from "src/interfaces/IVault.sol";
import {USDC} from "./mocks/USDC.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {console} from "forge-std/console.sol";
import {DepositHelper} from "./utils/DepositHelper.sol";

contract RequestDepositUnitTests is DepositHelper {
    VaultHandler public vault;
    address user = makeAddr("User");
    address victim = makeAddr("victim");
    address rebalancer = makeAddr("rebalancer");
    address vaultManager = makeAddr("vault_manager");
    address liquidityManager = makeAddr("liquidity_manager");
    address operator = makeAddr("operator");

    IERC20 baseAsset;

    function setUp() public {
        baseAsset = new USDC();
        vault = new VaultHandler(
            baseAsset,
            rebalancer,
            vaultManager,
            liquidityManager
        );
    }
    /// @dev If older deposit claims consume the available liquidity, a new requestor shoudn't be able to request and claim instant liquidty
    function test_cannot_claimDeposit_WhenOlderClaimsNotSettled() public {
        address userTwo = makeAddr("UserTwO");
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
        assertEq(data.beneficiary, user);
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
        assertEq(data.beneficiary, user);
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
        assertEq(data.beneficiary, user, "beneficary matches");
        assertEq(data.controller, user, "controller is user");
        assertEq(data.nonce, 1, "nonce is 1");
    }
}
