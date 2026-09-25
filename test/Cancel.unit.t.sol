// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IVault} from "src/interfaces/IVault.sol";
import {ISparkPrimeVault} from "src/interfaces/ISparkPrimeVault.sol";
import {IQueue} from "src/interfaces/IQueue.sol";
import {QueueHelper} from "./utils/QueueHelper.sol";

contract CancelUnitTests is QueueHelper {
    function setUp() public {
        _deployVault();
    }

    function _queueDeposit(
        address owner_,
        address controller_,
        uint256 amount
    ) internal returns (uint256) {
        deal(address(baseAsset), owner_, amount);
        vm.startPrank(owner_);
        baseAsset.approve(address(vault), amount);
        vault.requestDeposit(amount, controller_, owner_);
        vm.stopPrank();
        return vault.requestNonce(controller_);
    }

    function _queueRedeem(
        address owner_,
        address controller_,
        uint256 assetValue
    ) internal returns (uint256 shares, uint256 nonce) {
        _depositAndClaim(owner_, assetValue);
        shares = vault.balanceOf(owner_);
        _drainLiquidity();
        vm.prank(owner_);
        vault.requestRedeem(shares, controller_, owner_);
        nonce = vault.requestNonce(controller_);
    }

    function test_cancelDepositRequest_refundsTheOwner() public {
        _closeCapacity();
        uint256 nonce = _queueDeposit(user, user, 10 ether);

        assertEq(vault.totalPendingDeposits(), 10 ether);
        assertEq(vault.pendingDepositRequest(0, user), 10 ether);

        vm.prank(user);
        vault.cancelDepositRequest(user, nonce);

        assertEq(baseAsset.balanceOf(user), 10 ether);
        assertEq(baseAsset.balanceOf(address(vault)), 0);
        assertEq(vault.totalPendingDeposits(), 0);
        assertEq(vault.pendingDepositRequest(0, user), 0);
        assertEq(
            vault.queuedDepositRequest(user, nonce).controller,
            address(0)
        );
        assertSolvent();
    }

    function test_cancelDepositRequest_refundsTheOwnerNotTheController()
        public
    {
        _closeCapacity();
        uint256 nonce = _queueDeposit(user, userTwo, 10 ether);

        vm.prank(userTwo);
        vault.cancelDepositRequest(userTwo, nonce);

        assertEq(baseAsset.balanceOf(user), 10 ether);
        assertEq(baseAsset.balanceOf(userTwo), 0);
    }

    function test_cancelDepositRequest_byVaultManager() public {
        _closeCapacity();
        uint256 nonce = _queueDeposit(user, user, 10 ether);

        vm.prank(vaultManager);
        vault.cancelDepositRequest(user, nonce);

        assertEq(baseAsset.balanceOf(user), 10 ether);
        assertEq(vault.totalPendingDeposits(), 0);
    }

    function test_cancelDepositRequest_byOperator() public {
        _closeCapacity();
        uint256 nonce = _queueDeposit(user, user, 10 ether);
        vault.setOperatorForUser(user, operator, true);

        vm.prank(operator);
        vault.cancelDepositRequest(user, nonce);

        assertEq(baseAsset.balanceOf(user), 10 ether);
    }

    function test_cancelDepositRequest_whilePaused() public {
        _closeCapacity();
        uint256 nonce = _queueDeposit(user, user, 10 ether);

        vm.prank(vaultManager);
        vault.pause();

        vm.prank(user);
        vault.cancelDepositRequest(user, nonce);

        assertEq(baseAsset.balanceOf(user), 10 ether);
    }

    function test_cancelDepositRequest_emitsCancellation() public {
        _closeCapacity();
        uint256 nonce = _queueDeposit(user, user, 10 ether);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositRequestCancelled(
            user,
            user,
            nonce,
            10 ether
        );

        vm.prank(user);
        vault.cancelDepositRequest(user, nonce);
    }

    function test_cancelDepositRequest_ofAPartiallyFilledRequest() public {
        _depositAndClaim(user, 50 ether);
        _closeCapacity();
        uint256 nonce = _queueDeposit(userTwo, userTwo, 10 ether);
        _setCapacity(100 ether);

        vm.prank(rebalancer);
        vault.processQueue(4 ether);

        assertEq(vault.pendingDepositRequest(0, userTwo), 6 ether);
        assertEq(vault.maxDeposit(userTwo), 4 ether);

        vm.prank(userTwo);
        vault.cancelDepositRequest(userTwo, nonce);

        assertEq(baseAsset.balanceOf(userTwo), 6 ether);
        assertEq(vault.pendingDepositRequest(0, userTwo), 0);
        assertEq(vault.maxDeposit(userTwo), 4 ether);
        assertSolvent();
    }

    function test_cannot_cancelDepositRequest_thatIsClaimable() public {
        _requestDeposit(user, 10 ether);
        uint256 nonce = vault.requestNonce(user);

        assertEq(vault.maxDeposit(user), 10 ether);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISparkPrimeVault.RequestNotQueued.selector,
                user,
                nonce
            )
        );
        vault.cancelDepositRequest(user, nonce);
    }

    function test_cannot_cancelDepositRequest_afterProcessing() public {
        _closeCapacity();
        uint256 nonce = _queueDeposit(user, user, 10 ether);
        _setCapacity(100 ether);

        vm.prank(rebalancer);
        vault.processQueue(10 ether);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISparkPrimeVault.RequestNotQueued.selector,
                user,
                nonce
            )
        );
        vault.cancelDepositRequest(user, nonce);
    }

    function test_cannot_cancelDepositRequest_twice() public {
        _closeCapacity();
        uint256 nonce = _queueDeposit(user, user, 10 ether);

        vm.prank(user);
        vault.cancelDepositRequest(user, nonce);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISparkPrimeVault.RequestNotQueued.selector,
                user,
                nonce
            )
        );
        vault.cancelDepositRequest(user, nonce);
    }

    function test_cannot_cancelDepositRequest_asStranger() public {
        _closeCapacity();
        uint256 nonce = _queueDeposit(user, user, 10 ether);

        vm.prank(userTwo);
        vm.expectRevert(
            abi.encodeWithSelector(IVault.UnauthorizedCaller.selector, userTwo)
        );
        vault.cancelDepositRequest(user, nonce);
    }

    function test_cannot_cancelDepositRequest_withARedeemNonce() public {
        (, uint256 nonce) = _queueRedeem(user, user, 50 ether);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISparkPrimeVault.RequestNotQueued.selector,
                user,
                nonce
            )
        );
        vault.cancelDepositRequest(user, nonce);
    }

    function test_cannot_cancelDepositRequest_whenInsolvent() public {
        _depositAndClaim(user, 50 ether);
        uint256 shares = vault.balanceOf(user);
        _requestRedeem(user, shares);
        _closeCapacity();
        uint256 nonce = _queueDeposit(userTwo, userTwo, 10 ether);

        _drainLiquidity();

        int256 free = vault.availableLiquidAssets();
        assertLt(free, int256(10 ether));

        vm.prank(userTwo);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISparkPrimeVault.InsufficientFreeLiquidity.selector,
                10 ether,
                free
            )
        );
        vault.cancelDepositRequest(userTwo, nonce);
    }

    function test_processQueue_skipsACancelledEntry() public {
        _closeCapacity();
        _queueDeposit(user, user, 10 ether);
        uint256 nonceTwo = _queueDeposit(userTwo, userTwo, 10 ether);
        _queueDeposit(userThree, userThree, 10 ether);

        vm.prank(vaultManager);
        vault.cancelDepositRequest(userTwo, nonceTwo);

        _setCapacity(100 ether);

        vm.prank(rebalancer);
        vault.processQueue(20 ether);

        assertEq(vault.maxDeposit(user), 10 ether);
        assertEq(vault.maxDeposit(userTwo), 0);
        assertEq(vault.maxDeposit(userThree), 10 ether);
        assertEq(vault.depositQueueLength(), 0);
        assertSolvent();
    }

    function test_processQueue_doesNotClaimForACancelledDeposit() public {
        _closeCapacity();
        uint256 nonce = _queueDeposit(user, user, 10 ether);
        _queueDeposit(userTwo, userTwo, 10 ether);

        vm.prank(user);
        vault.cancelDepositRequest(user, nonce);

        _setCapacity(100 ether);

        vm.recordLogs();
        vm.prank(rebalancer);
        vault.processQueue(10 ether);

        assertEq(_activeClaims(IQueue.ClaimableDeposit.selector), 1);
    }

    function test_processQueue_doesNotClaimForACancelledEntryWhenPartiallyFilling()
        public
    {
        _closeCapacity();
        uint256 nonce = _queueDeposit(user, user, 10 ether);
        _queueDeposit(userTwo, userTwo, 10 ether);

        vm.prank(user);
        vault.cancelDepositRequest(user, nonce);

        _setCapacity(100 ether);

        vm.recordLogs();
        vm.prank(rebalancer);
        vault.processQueue(5 ether);

        assertEq(_activeClaims(IQueue.ClaimableDeposit.selector), 1);
        assertEq(vault.maxDeposit(userTwo), 5 ether);
    }

    function test_processQueue_afterCancellingTheHead() public {
        _closeCapacity();
        uint256 nonceOne = _queueDeposit(user, user, 10 ether);
        _queueDeposit(userTwo, userTwo, 10 ether);

        vm.prank(user);
        vault.cancelDepositRequest(user, nonceOne);

        _setCapacity(100 ether);

        vm.prank(rebalancer);
        vault.processQueue(10 ether);

        assertEq(vault.maxDeposit(user), 0);
        assertEq(vault.maxDeposit(userTwo), 10 ether);
        assertEq(vault.depositQueueLength(), 0);
    }

    function test_processQueue_afterCancellingEveryEntry() public {
        _closeCapacity();
        uint256 nonceOne = _queueDeposit(user, user, 10 ether);
        uint256 nonceTwo = _queueDeposit(userTwo, userTwo, 10 ether);

        vm.startPrank(vaultManager);
        vault.cancelDepositRequest(user, nonceOne);
        vault.cancelDepositRequest(userTwo, nonceTwo);
        vm.stopPrank();

        assertEq(vault.totalPendingDeposits(), 0);
        assertEq(vault.depositQueueLength(), 2);

        vm.prank(rebalancer);
        vault.processQueue(0);

        assertEq(vault.depositQueueLength(), 0);
        assertEq(vault.maxDeposit(user), 0);
        assertEq(vault.maxDeposit(userTwo), 0);
    }

    function test_queueHead_skipsCancelledEntries() public {
        _closeCapacity();
        uint256 nonceOne = _queueDeposit(user, user, 10 ether);
        _queueDeposit(userTwo, userTwo, 10 ether);

        assertEq(vault.depositQueueHead().controller, user);

        vm.prank(user);
        vault.cancelDepositRequest(user, nonceOne);

        assertEq(vault.depositQueueHead().controller, userTwo);
    }

    function test_depositQueueLength_countsGhostsUntilProcessed() public {
        _closeCapacity();
        uint256 nonce = _queueDeposit(user, user, 10 ether);

        assertEq(vault.depositQueueLength(), 1);

        vm.prank(user);
        vault.cancelDepositRequest(user, nonce);

        assertEq(vault.depositQueueLength(), 1);
        assertEq(vault.totalPendingDeposits(), 0);
    }

    function test_queuedDepositRequest_reportsOwnerAndAmount() public {
        _closeCapacity();
        uint256 nonce = _queueDeposit(user, userTwo, 10 ether);

        assertEq(vault.queuedDepositRequest(userTwo, nonce).owner, user);
        assertEq(
            vault.queuedDepositRequest(userTwo, nonce).controller,
            userTwo
        );
        assertEq(vault.queuedDepositRequest(userTwo, nonce).amount, 10 ether);
    }

    function _activeClaims(bytes32 sig) internal returns (uint256 claims) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig) continue;
            (address beneficiary, ) = abi.decode(
                logs[i].data,
                (address, uint256)
            );
            assertTrue(beneficiary != address(0), "claimed a cancelled entry");
            ++claims;
        }
    }
}
