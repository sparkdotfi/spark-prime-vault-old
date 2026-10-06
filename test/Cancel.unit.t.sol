// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { Vm }   from "forge-std/Vm.sol";

import { IVault }           from "src/interfaces/IVault.sol";
import { ISparkPrimeVault } from "src/interfaces/ISparkPrimeVault.sol";
import { IQueue }           from "src/interfaces/IQueue.sol";

import { QueueHelper } from "./utils/QueueHelper.sol";

contract CancelUnitTests is QueueHelper {

    function setUp() public {
        _deployVault();
    }

    function _queueDeposit(
        address owner_,
        address controller_,
        uint256 amount
    ) internal returns (uint256) {
        _nextBlock();
        deal(address(baseAsset), owner_, amount);
        vm.startPrank(owner_);
        baseAsset.approve(address(vault), amount);
        vault.requestDeposit(amount, controller_, owner_);
        vm.stopPrank();
        return vault.lastDepositId();
    }

    function _queueRedeem(
        address owner_,
        address controller_,
        uint256 assetValue
    ) internal returns (uint256 shares, uint256 id) {
        _depositAndClaim(owner_, assetValue);
        shares = vault.balanceOf(owner_);
        _drainLiquidity();
        _nextBlock();
        vm.prank(owner_);
        vault.requestRedeem(shares, controller_, owner_);
        id = vault.lastWithdrawId();
    }

    function test_processQueue_toleratesAFrontRunCancel() public {
        _queueRedeem(user, user, 50 ether);
        _closeCapacity();
        _queueDeposit(userTwo, userTwo, 10 ether);
        uint256 id = _queueDeposit(userThree, userThree, 10 ether);
        uint256 volume = vault.maxTradeVolume();

        vm.prank(userThree);
        vault.cancelDepositRequest(userThree, id);
        assertLt(vault.maxTradeVolume(), volume);

        vm.prank(rebalancer);
        vault.processQueue(volume);

        assertEq(vault.depositQueueLength(), 0);
        assertGt(vault.maxMint(userTwo), 0);
        assertSolvent();
    }

    function test_cancelDepositRequest_refundsTheOwner() public {
        _closeCapacity();
        uint256 id = _queueDeposit(user, user, 10 ether);
        uint256 shares = vault.queuedDepositRequest(id).amount;
        uint256 refund = savingsVault.previewRedeem(shares);

        assertEq(vault.totalPendingDeposits(), shares);
        assertEq(
            vault.pendingDepositRequest(0, user),
            savingsVault.convertToAssets(shares)
        );
        assertApproxEqAbs(vault.pendingDepositRequest(0, user), 10 ether, 2);

        vm.prank(user);
        vault.cancelDepositRequest(user, id);

        assertEq(baseAsset.balanceOf(user), refund);
        assertEq(baseAsset.balanceOf(address(vault)), 0);
        assertEq(vault.totalPendingDeposits(), 0);
        assertEq(vault.pendingDepositRequest(0, user), 0);
        assertEq(
            vault.queuedDepositRequest(id).controller,
            address(0)
        );
        assertSolvent();
    }

    function test_cancelDepositRequest_refundsTheOwnerNotTheController()
        public
    {
        _closeCapacity();
        uint256 id = _queueDeposit(user, userTwo, 10 ether);
        uint256 refund = savingsVault.previewRedeem(
            vault.queuedDepositRequest(id).amount
        );

        vm.prank(userTwo);
        vault.cancelDepositRequest(userTwo, id);

        assertEq(baseAsset.balanceOf(user), refund);
        assertEq(baseAsset.balanceOf(userTwo), 0);
    }

    function test_cancelDepositRequest_byGuardian() public {
        _closeCapacity();
        uint256 id = _queueDeposit(user, user, 10 ether);
        uint256 refund = savingsVault.previewRedeem(
            vault.queuedDepositRequest(id).amount
        );

        vm.prank(guardian);
        vault.cancelDepositRequest(user, id);

        assertEq(baseAsset.balanceOf(user), refund);
        assertEq(vault.totalPendingDeposits(), 0);
    }

    function test_cannot_cancelDepositRequest_asOperator() public {
        _closeCapacity();
        uint256 id = _queueDeposit(user, user, 10 ether);
        vault.setOperatorForUser(user, operator, true);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IVault.UnauthorizedCaller.selector, operator)
        );
        vault.cancelDepositRequest(user, id);
    }

    function test_cannot_cancelDepositRequest_asVaultManager() public {
        _closeCapacity();
        uint256 id = _queueDeposit(user, user, 10 ether);

        vm.prank(vaultManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.UnauthorizedCaller.selector,
                vaultManager
            )
        );
        vault.cancelDepositRequest(user, id);
    }

    function test_cancelDepositRequest_whilePaused() public {
        _closeCapacity();
        uint256 id = _queueDeposit(user, user, 10 ether);

        vm.prank(guardian);
        vault.pause();
        uint256 refund = savingsVault.previewRedeem(
            vault.queuedDepositRequest(id).amount
        );

        vm.prank(user);
        vault.cancelDepositRequest(user, id);

        assertEq(baseAsset.balanceOf(user), refund);
    }

    function test_cancelDepositRequest_emitsCancellation() public {
        _closeCapacity();
        uint256 id = _queueDeposit(user, user, 10 ether);
        uint256 refund = savingsVault.previewRedeem(
            vault.queuedDepositRequest(id).amount
        );

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositRequestCancelled(
            user,
            user,
            id,
            refund
        );

        vm.prank(user);
        vault.cancelDepositRequest(user, id);
    }

    function test_cancelDepositRequest_ofAPartiallyFilledRequest() public {
        _depositAndClaim(user, 50 ether);
        _closeCapacity();
        uint256 id = _queueDeposit(userTwo, userTwo, 10 ether);
        _setCapacity(100 ether);

        vm.prank(rebalancer);
        vault.processQueue(4 ether);

        uint256 credited = vault.maxDeposit(userTwo);
        uint256 remaining = vault.queuedDepositRequest(id).amount;
        uint256 refund = savingsVault.previewRedeem(remaining);
        assertApproxEqAbs(vault.pendingDepositRequest(0, userTwo), 6 ether, 2);
        assertApproxEqAbs(credited, 4 ether, 1);
        assertLe(credited, 4 ether);

        vm.prank(userTwo);
        vault.cancelDepositRequest(userTwo, id);

        assertEq(baseAsset.balanceOf(userTwo), refund);
        assertEq(vault.pendingDepositRequest(0, userTwo), 0);
        assertEq(vault.maxDeposit(userTwo), credited);
        assertSolvent();
    }

    function test_cannot_cancelDepositRequest_thatIsClaimable() public {
        _requestDeposit(user, 10 ether);
        uint256 id = vault.lastDepositId();

        assertEq(vault.maxDeposit(user), 10 ether);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISparkPrimeVault.RequestNotQueued.selector,
                user,
                id
            )
        );
        vault.cancelDepositRequest(user, id);
    }

    function test_cannot_cancelDepositRequest_afterProcessing() public {
        _closeCapacity();
        uint256 id = _queueDeposit(user, user, 10 ether);
        _setCapacity(100 ether);
        uint256 volume = savingsVault.previewRedeem(vault.totalPendingDeposits());

        vm.prank(rebalancer);
        vault.processQueue(volume);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISparkPrimeVault.RequestNotQueued.selector,
                user,
                id
            )
        );
        vault.cancelDepositRequest(user, id);
    }

    function test_cannot_cancelDepositRequest_twice() public {
        _closeCapacity();
        uint256 id = _queueDeposit(user, user, 10 ether);

        vm.prank(user);
        vault.cancelDepositRequest(user, id);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISparkPrimeVault.RequestNotQueued.selector,
                user,
                id
            )
        );
        vault.cancelDepositRequest(user, id);
    }

    function test_cannot_cancelDepositRequest_asStranger() public {
        _closeCapacity();
        uint256 id = _queueDeposit(user, user, 10 ether);

        vm.prank(userTwo);
        vm.expectRevert(
            abi.encodeWithSelector(IVault.UnauthorizedCaller.selector, userTwo)
        );
        vault.cancelDepositRequest(user, id);
    }

    function test_cannot_cancelDepositRequest_withARedeemId() public {
        (, uint256 id) = _queueRedeem(user, user, 50 ether);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISparkPrimeVault.RequestNotQueued.selector,
                user,
                id
            )
        );
        vault.cancelDepositRequest(user, id);
    }

    function test_cannot_withdrawFromSavings_theBackingOfACancellableDeposit()
        public
    {
        _closeCapacity();
        uint256 id = _queueDeposit(userTwo, userTwo, 10 ether);
        uint256 backing = savingsVault.balanceOf(address(vault));
        uint256 refund = savingsVault.previewRedeem(backing);

        vm.prank(rebalancer);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ExceedsFreeSavingsShares(uint256,uint256)",
                backing,
                0
            )
        );
        vault.withdrawFromSavings(backing);

        vm.prank(userTwo);
        vault.cancelDepositRequest(userTwo, id);

        assertEq(baseAsset.balanceOf(userTwo), refund);
    }

    function test_requestDeposit_emitsDepositQueuedWithTheId() public {
        _closeCapacity();
        _fund(user, 10 ether);
        uint256 id = vault.lastDepositId() + 1;
        uint256 shares = savingsVault.previewDeposit(10 ether);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositQueued(user, user, id, shares);

        vm.prank(user);
        vault.requestDeposit(10 ether, user, user);
    }

    function test_cancelDepositRequest_byTheEmittedIdAfterAnotherFunder()
        public
    {
        _closeCapacity();
        _fund(user, 10 ether);

        vm.recordLogs();
        vm.prank(user);
        vault.requestDeposit(10 ether, user, user);
        uint256 id = _queuedId(vm.getRecordedLogs());

        _queueDeposit(userTwo, user, 10 ether);
        assertEq(vault.lastDepositId(), id + 1);

        vm.prank(user);
        vault.cancelDepositRequest(user, id);

        assertEq(vault.queuedDepositRequest(id).owner, address(0));
        assertEq(vault.queuedDepositRequest(id + 1).owner, userTwo);
        assertGt(baseAsset.balanceOf(user), 0);
    }

    function _queuedId(
        Vm.Log[] memory logs
    ) internal view returns (uint256 id) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(vault) &&
                logs[i].topics[0] == ISparkPrimeVault.DepositQueued.selector
            ) {
                (id, ) = abi.decode(logs[i].data, (uint256, uint256));
                return id;
            }
        }
        revert("no DepositQueued");
    }

    function test_cancelDepositRequest_afterLiquidityIsTaken() public {
        _depositAndClaim(user, 50 ether);
        uint256 shares = vault.balanceOf(user);
        _requestRedeem(user, shares);
        _closeCapacity();
        uint256 id = _queueDeposit(userTwo, userTwo, 10 ether);
        uint256 refund = savingsVault.previewRedeem(
            vault.queuedDepositRequest(id).amount
        );

        _drainLiquidity();
        assertEq(vault.availableLiquidAssets(), 0);

        vm.prank(userTwo);
        vault.cancelDepositRequest(userTwo, id);

        assertEq(baseAsset.balanceOf(userTwo), refund);
    }

    function test_cancelDepositRequest_refundsSavingsYield() public {
        _closeCapacity();
        uint256 id = _queueDeposit(user, user, 100 ether);
        _accrueSavings(1_000);
        uint256 refund = savingsVault.previewRedeem(
            vault.queuedDepositRequest(id).amount
        );

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositRequestCancelled(user, user, id, refund);

        vm.prank(user);
        vault.cancelDepositRequest(user, id);

        assertEq(baseAsset.balanceOf(user), refund);
        assertGt(refund, 100 ether);
        assertSolvent();
    }

    function test_processQueue_skipsACancelledEntry() public {
        _closeCapacity();
        uint256 idOne = _queueDeposit(user, user, 10 ether);
        uint256 idTwo = _queueDeposit(userTwo, userTwo, 10 ether);
        uint256 idThree = _queueDeposit(userThree, userThree, 10 ether);

        vm.prank(guardian);
        vault.cancelDepositRequest(userTwo, idTwo);

        _setCapacity(100 ether);
        uint256 owedOne = savingsVault.previewRedeem(
            vault.queuedDepositRequest(idOne).amount
        );
        uint256 owedThree = savingsVault.previewRedeem(
            vault.queuedDepositRequest(idThree).amount
        );
        uint256 volume = savingsVault.previewRedeem(vault.totalPendingDeposits());

        vm.prank(rebalancer);
        vault.processQueue(volume);

        assertApproxEqAbs(vault.maxDeposit(user), owedOne, 2);
        assertEq(vault.maxDeposit(userTwo), 0);
        assertApproxEqAbs(vault.maxDeposit(userThree), owedThree, 2);
        assertEq(vault.depositQueueLength(), 0);
        assertSolvent();
    }

    function test_processQueue_doesNotClaimForACancelledDeposit() public {
        _closeCapacity();
        uint256 id = _queueDeposit(user, user, 10 ether);
        _queueDeposit(userTwo, userTwo, 10 ether);

        vm.prank(user);
        vault.cancelDepositRequest(user, id);

        _setCapacity(100 ether);
        uint256 volume = savingsVault.previewRedeem(vault.totalPendingDeposits());

        vm.recordLogs();
        vm.prank(rebalancer);
        vault.processQueue(volume);

        assertEq(_activeClaims(IQueue.ClaimableDeposit.selector), 1);
    }

    function test_processQueue_doesNotClaimForACancelledEntryWhenPartiallyFilling()
        public
    {
        _closeCapacity();
        uint256 id = _queueDeposit(user, user, 10 ether);
        _queueDeposit(userTwo, userTwo, 10 ether);

        vm.prank(user);
        vault.cancelDepositRequest(user, id);

        _setCapacity(100 ether);

        vm.recordLogs();
        vm.prank(rebalancer);
        vault.processQueue(5 ether);

        assertEq(_activeClaims(IQueue.ClaimableDeposit.selector), 1);
        assertApproxEqAbs(vault.maxDeposit(userTwo), 5 ether, 1);
        assertLe(vault.maxDeposit(userTwo), 5 ether);
    }

    function test_processQueue_afterCancellingTheHead() public {
        _closeCapacity();
        uint256 idOne = _queueDeposit(user, user, 10 ether);
        _queueDeposit(userTwo, userTwo, 10 ether);

        vm.prank(user);
        vault.cancelDepositRequest(user, idOne);

        _setCapacity(100 ether);
        uint256 volume = savingsVault.previewRedeem(vault.totalPendingDeposits());

        vm.prank(rebalancer);
        vault.processQueue(volume);

        assertEq(vault.maxDeposit(user), 0);
        assertApproxEqAbs(vault.maxDeposit(userTwo), volume, 1);
        assertEq(vault.depositQueueLength(), 0);
    }

    function test_processQueue_afterCancellingEveryEntry() public {
        _closeCapacity();
        uint256 idOne = _queueDeposit(user, user, 10 ether);
        uint256 idTwo = _queueDeposit(userTwo, userTwo, 10 ether);

        vm.startPrank(guardian);
        vault.cancelDepositRequest(user, idOne);
        vault.cancelDepositRequest(userTwo, idTwo);
        vm.stopPrank();

        assertEq(vault.totalPendingDeposits(), 0);
        assertEq(vault.depositQueueLength(), 0);

        vm.prank(rebalancer);
        vault.processQueue(0);

        assertEq(vault.depositQueueLength(), 0);
        assertEq(vault.maxDeposit(user), 0);
        assertEq(vault.maxDeposit(userTwo), 0);
    }

    function test_queueHead_skipsCancelledEntries() public {
        _closeCapacity();
        uint256 idOne = _queueDeposit(user, user, 10 ether);
        _queueDeposit(userTwo, userTwo, 10 ether);

        assertEq(vault.depositQueueHead().controller, user);

        vm.prank(user);
        vault.cancelDepositRequest(user, idOne);

        assertEq(vault.depositQueueHead().controller, userTwo);
    }

    function test_depositQueueLength_ignoresCancelledEntries() public {
        _closeCapacity();
        uint256 id = _queueDeposit(user, user, 10 ether);

        assertEq(vault.depositQueueLength(), 1);

        vm.prank(user);
        vault.cancelDepositRequest(user, id);

        assertEq(vault.depositQueueLength(), 0);
        assertEq(vault.totalPendingDeposits(), 0);
    }

    function test_requestDeposit_fillsInstantlyWhenOnlyCancelledEntriesAreQueued()
        public
    {
        _closeCapacity();
        uint256 id = _queueDeposit(user, user, 10 ether);

        vm.prank(user);
        vault.cancelDepositRequest(user, id);

        _setCapacity(100 ether);
        _queueDeposit(userTwo, userTwo, 10 ether);

        assertEq(vault.maxDeposit(userTwo), 10 ether);
        assertEq(vault.totalPendingDeposits(), 0);
    }

    function test_requestDeposit_queuesBehindALiveEntryAfterACancelledHeadIsFilled()
        public
    {
        _closeCapacity();
        uint256 id = _queueDeposit(user, user, 10 ether);
        _queueDeposit(userTwo, userTwo, 10 ether);

        vm.prank(user);
        vault.cancelDepositRequest(user, id);

        _setCapacity(100 ether);

        vm.prank(rebalancer);
        vault.processQueue(5 ether);

        _queueDeposit(userThree, userThree, 10 ether);

        assertEq(vault.maxDeposit(userThree), 0);
        assertEq(vault.depositQueueLength(), 2);
        assertEq(vault.depositQueueHead().controller, userTwo);
    }

    function test_processQueue_walksOverARunOfCancelledEntries() public {
        _closeCapacity();
        uint256 idOne = _queueDeposit(user, user, 10 ether);
        for (uint256 i; i < 5; ++i) {
            uint256 id = _queueDeposit(userTwo, userTwo, 10 ether);
            vm.prank(userTwo);
            vault.cancelDepositRequest(userTwo, id);
        }
        uint256 idThree = _queueDeposit(userThree, userThree, 10 ether);

        assertEq(vault.depositQueueHead().controller, user);
        assertEq(vault.depositQueueLength(), 2);
        (, uint256 issued) = vault.depositQueueSlots();
        assertEq(issued, 7);

        _setCapacity(100 ether);
        uint256 owedOne = savingsVault.previewRedeem(
            vault.queuedDepositRequest(idOne).amount
        );
        uint256 owedThree = savingsVault.previewRedeem(
            vault.queuedDepositRequest(idThree).amount
        );
        uint256 volume = savingsVault.previewRedeem(vault.totalPendingDeposits());

        vm.prank(rebalancer);
        vault.processQueue(volume);

        assertApproxEqAbs(vault.maxDeposit(user), owedOne, 2);
        assertApproxEqAbs(vault.maxDeposit(userThree), owedThree, 2);
        assertEq(vault.depositQueueLength(), 0);
        assertSolvent();
    }

    function test_queuedDepositRequest_reportsOwnerAndAmount() public {
        _closeCapacity();
        uint256 id = _queueDeposit(user, userTwo, 10 ether);

        assertEq(vault.queuedDepositRequest(id).owner, user);
        assertEq(
            vault.queuedDepositRequest(id).controller,
            userTwo
        );
        assertEq(
            vault.queuedDepositRequest(id).amount,
            vault.totalPendingDeposits()
        );
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
