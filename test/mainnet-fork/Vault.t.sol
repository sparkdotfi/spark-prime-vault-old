// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC7540Deposit }  from "../../src/interfaces/IERC7540.sol";
import { IQueue }           from "../../src/interfaces/IQueue.sol";
import { ISparkPrimeVault } from "../../src/interfaces/ISparkPrimeVault.sol";
import { IVault }           from "../../src/interfaces/IVault.sol";

import { ForkTestBase, IERC4626Like } from "./ForkTestBase.t.sol";

contract RequestDepositTests is ForkTestBase {
    // TODO : Add failure tests

    // Success tests

    function test_requestDeposit_instantClaim() external {
        deal(address(usdc), user, 100e6);

        assertEq(usdc.balanceOf(user),                                  100e6);
        assertEq(usdc.balanceOf(address(spPrimeVaultUsdc)),             0);
        assertEq(usdc.allowance(user, address(spPrimeVaultUsdc)),       0);
        assertEq(spPrimeVaultUsdc.balanceOf(user),                      0);
        assertEq(spPrimeVaultUsdc.balanceOf(address(spPrimeVaultUsdc)), 0);
        assertEq(spUSDCVault.balanceOf(user),                           0);
        assertEq(spUSDCVault.balanceOf(address(spPrimeVaultUsdc)),      0);

        _assertDepositState(DepositState({
            controller              : user,
            totalSupply             : 0,
            totalAssets             : 0,
            availableCapacity       : VAULT_CAPACITY,
            availableLiquidAssets   : 0,
            claimableDepositRequest : 0,
            maxDeposit              : 0,
            maxMint                 : 0,
            claimableDepositTotal   : 0,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 0,
            index                   : RAY,
            lastAccrual             : block.timestamp
        }));

        vm.startPrank(user);
        usdc.approve(address(spPrimeVaultUsdc), 100e6);

        vm.expectEmit(address(spPrimeVaultUsdc));
        emit IQueue.ClaimableDeposit(user, 100e6);
        vm.expectEmit(address(spPrimeVaultUsdc));
        emit IERC7540Deposit.DepositRequest(user, user, 0, user, 100e6);

        spPrimeVaultUsdc.requestDeposit(100e6, user, user);
        vm.stopPrank();

        assertEq(usdc.balanceOf(user),                                  0);
        assertEq(usdc.balanceOf(address(spPrimeVaultUsdc)),             100e6);
        assertEq(usdc.allowance(user, address(spPrimeVaultUsdc)),       0);
        assertEq(spPrimeVaultUsdc.balanceOf(user),                      0);
        assertEq(spPrimeVaultUsdc.balanceOf(address(spPrimeVaultUsdc)), 100e6);
        assertEq(spUSDCVault.balanceOf(user),                           0);
        assertEq(spUSDCVault.balanceOf(address(spPrimeVaultUsdc)),      0);

        _assertDepositState(DepositState({
            controller              : user,
            totalSupply             : 100e6,
            totalAssets             : 100e6,
            availableCapacity       : VAULT_CAPACITY - 100e6,
            availableLiquidAssets   : int256(100e6),
            claimableDepositRequest : 100e6,
            maxDeposit              : 100e6,
            maxMint                 : 100e6,
            claimableDepositTotal   : 100e6,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 1,
            index                   : RAY,
            lastAccrual             : block.timestamp
        }));
    }

    function test_requestDeposit_instantClaim_exactCapacity() external {
        deal(address(usdc), user, VAULT_CAPACITY);

        assertEq(usdc.balanceOf(user),                                  VAULT_CAPACITY);
        assertEq(usdc.balanceOf(address(spPrimeVaultUsdc)),             0);
        assertEq(usdc.allowance(user, address(spPrimeVaultUsdc)),       0);
        assertEq(spPrimeVaultUsdc.balanceOf(user),                      0);
        assertEq(spPrimeVaultUsdc.balanceOf(address(spPrimeVaultUsdc)), 0);
        assertEq(spUSDCVault.balanceOf(user),                           0);
        assertEq(spUSDCVault.balanceOf(address(spPrimeVaultUsdc)),      0);

        _assertDepositState(DepositState({
            controller              : user,
            totalSupply             : 0,
            totalAssets             : 0,
            availableCapacity       : VAULT_CAPACITY,
            availableLiquidAssets   : 0,
            claimableDepositRequest : 0,
            maxDeposit              : 0,
            maxMint                 : 0,
            claimableDepositTotal   : 0,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 0,
            index                   : RAY,
            lastAccrual             : block.timestamp
        }));

        vm.startPrank(user);
        usdc.approve(address(spPrimeVaultUsdc), VAULT_CAPACITY);

        vm.expectEmit(address(spPrimeVaultUsdc));
        emit IQueue.ClaimableDeposit(user, VAULT_CAPACITY);
        vm.expectEmit(address(spPrimeVaultUsdc));
        emit IERC7540Deposit.DepositRequest(user, user, 0, user, VAULT_CAPACITY);

        spPrimeVaultUsdc.requestDeposit(VAULT_CAPACITY, user, user);
        vm.stopPrank();

        assertEq(usdc.balanceOf(user),                                  0);
        assertEq(usdc.balanceOf(address(spPrimeVaultUsdc)),             VAULT_CAPACITY);
        assertEq(usdc.allowance(user, address(spPrimeVaultUsdc)),       0);
        assertEq(spPrimeVaultUsdc.balanceOf(user),                      0);
        assertEq(spPrimeVaultUsdc.balanceOf(address(spPrimeVaultUsdc)), VAULT_CAPACITY);
        assertEq(spUSDCVault.balanceOf(user),                           0);
        assertEq(spUSDCVault.balanceOf(address(spPrimeVaultUsdc)),      0);

        _assertDepositState(DepositState({
            controller              : user,
            totalSupply             : VAULT_CAPACITY,
            totalAssets             : VAULT_CAPACITY,
            availableCapacity       : 0,
            availableLiquidAssets   : int256(VAULT_CAPACITY),
            claimableDepositRequest : VAULT_CAPACITY,
            maxDeposit              : VAULT_CAPACITY,
            maxMint                 : VAULT_CAPACITY,
            claimableDepositTotal   : VAULT_CAPACITY,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 1,
            index                   : RAY,
            lastAccrual             : block.timestamp
        }));
    }

    function test_requestDeposit_partialInstantClaim() external {
        uint256 amount       = VAULT_CAPACITY + 500e6;
        uint256 queuedShares = spUSDCVault.previewDeposit(500e6);  // spUSDC shares backing this request

        deal(address(usdc), user, amount);

        assertEq(usdc.balanceOf(user),                                            amount);
        assertEq(usdc.balanceOf(address(spPrimeVaultUsdc)),                       0);
        assertEq(usdc.allowance(user, address(spPrimeVaultUsdc)),                 0);
        assertEq(usdc.allowance(address(spPrimeVaultUsdc), address(spUSDCVault)), 0);
        assertEq(spPrimeVaultUsdc.balanceOf(user),                                0);
        assertEq(spPrimeVaultUsdc.balanceOf(address(spPrimeVaultUsdc)),           0);
        assertEq(spUSDCVault.balanceOf(user),                                     0);
        assertEq(spUSDCVault.balanceOf(address(spPrimeVaultUsdc)),                0);

        _assertDepositState(DepositState({
            controller              : user,
            totalSupply             : 0,
            totalAssets             : 0,
            availableCapacity       : VAULT_CAPACITY,
            availableLiquidAssets   : 0,
            claimableDepositRequest : 0,
            maxDeposit              : 0,
            maxMint                 : 0,
            claimableDepositTotal   : 0,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 0,
            index                   : RAY,
            lastAccrual             : block.timestamp
        }));

        _assertQueuedDepositRequest(user, 1, IVault.Transaction(address(0), address(0), 0, 0, 0));

        vm.startPrank(user);
        usdc.approve(address(spPrimeVaultUsdc), amount);

        vm.expectEmit(address(spPrimeVaultUsdc));
        emit IQueue.ClaimableDeposit(user, VAULT_CAPACITY);
        vm.expectEmit(address(spPrimeVaultUsdc));
        emit IQueue.DepositQueueValuation(queuedShares);
        vm.expectEmit(address(spPrimeVaultUsdc));
        emit ISparkPrimeVault.DepositQueued(user, user, 1, queuedShares);
        vm.expectEmit(address(spPrimeVaultUsdc));
        emit IERC7540Deposit.DepositRequest(user, user, 0, user, amount);

        spPrimeVaultUsdc.requestDeposit(amount, user, user);
        vm.stopPrank();

        assertEq(usdc.balanceOf(user),                                            0);
        assertEq(usdc.balanceOf(address(spPrimeVaultUsdc)),                       VAULT_CAPACITY);
        assertEq(usdc.allowance(user, address(spPrimeVaultUsdc)),                 0);
        assertEq(usdc.allowance(address(spPrimeVaultUsdc), address(spUSDCVault)), 0);
        assertEq(spPrimeVaultUsdc.balanceOf(user),                                0);
        assertEq(spPrimeVaultUsdc.balanceOf(address(spPrimeVaultUsdc)),           VAULT_CAPACITY);
        assertEq(spUSDCVault.balanceOf(user),                                     0);
        assertEq(spUSDCVault.balanceOf(address(spPrimeVaultUsdc)),                queuedShares);

        _assertDepositState(DepositState({
            controller              : user,
            totalSupply             : VAULT_CAPACITY,
            totalAssets             : VAULT_CAPACITY,
            availableCapacity       : 0,
            availableLiquidAssets   : int256(VAULT_CAPACITY),
            claimableDepositRequest : VAULT_CAPACITY,
            maxDeposit              : VAULT_CAPACITY,
            maxMint                 : VAULT_CAPACITY,
            claimableDepositTotal   : VAULT_CAPACITY,
            pendingDepositRequest   : spUSDCVault.convertToAssets(queuedShares),
            totalPendingDeposits    : queuedShares,
            depositQueueLength      : 1,
            requestNonce            : 1,
            index                   : RAY,
            lastAccrual             : block.timestamp
        }));

        _assertQueuedDepositRequest(user, 1, IVault.Transaction(user, user, queuedShares, 1, 0));

        assertEq(spPrimeVaultUsdc.pendingDepositRequest(0, user), 500e6 - 1);
    }

    function test_requestDeposit_queued_noCapacity() external {
        _requestDeposit(user2, VAULT_CAPACITY); // Consumed all capacity

        uint256 queuedShares = spUSDCVault.previewDeposit(100e6);  // spUSDC shares backing this request

        deal(address(usdc), user, 100e6);

        assertEq(usdc.balanceOf(user),                                            100e6);
        assertEq(usdc.balanceOf(address(spPrimeVaultUsdc)),                       VAULT_CAPACITY);
        assertEq(usdc.allowance(user, address(spPrimeVaultUsdc)),                 0);
        assertEq(usdc.allowance(address(spPrimeVaultUsdc), address(spUSDCVault)), 0);
        assertEq(spPrimeVaultUsdc.balanceOf(user),                                0);
        assertEq(spPrimeVaultUsdc.balanceOf(address(spPrimeVaultUsdc)),           VAULT_CAPACITY);
        assertEq(spUSDCVault.balanceOf(user),                                     0);
        assertEq(spUSDCVault.balanceOf(address(spPrimeVaultUsdc)),                0);

        _assertDepositState(DepositState({
            controller              : user,
            totalSupply             : VAULT_CAPACITY,
            totalAssets             : VAULT_CAPACITY,
            availableCapacity       : 0,
            availableLiquidAssets   : int256(VAULT_CAPACITY),
            claimableDepositRequest : 0,
            maxDeposit              : 0,
            maxMint                 : 0,
            claimableDepositTotal   : VAULT_CAPACITY,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 0,
            index                   : RAY,
            lastAccrual             : block.timestamp
        }));

        _assertQueuedDepositRequest(user, 1, IVault.Transaction(address(0), address(0), 0, 0, 0));

        vm.startPrank(user);
        usdc.approve(address(spPrimeVaultUsdc), 100e6);

        vm.expectEmit(address(spPrimeVaultUsdc));
        emit IQueue.DepositQueueValuation(queuedShares);
        vm.expectEmit(address(spPrimeVaultUsdc));
        emit ISparkPrimeVault.DepositQueued(user, user, 1, queuedShares);
        vm.expectEmit(address(spPrimeVaultUsdc));
        emit IERC7540Deposit.DepositRequest(user, user, 0, user, 100e6);

        spPrimeVaultUsdc.requestDeposit(100e6, user, user);
        vm.stopPrank();

        assertEq(usdc.balanceOf(user),                                            0);
        assertEq(usdc.balanceOf(address(spPrimeVaultUsdc)),                       VAULT_CAPACITY);
        assertEq(usdc.allowance(user, address(spPrimeVaultUsdc)),                 0);
        assertEq(usdc.allowance(address(spPrimeVaultUsdc), address(spUSDCVault)), 0);
        assertEq(spPrimeVaultUsdc.balanceOf(user),                                0);
        assertEq(spPrimeVaultUsdc.balanceOf(address(spPrimeVaultUsdc)),           VAULT_CAPACITY);
        assertEq(spUSDCVault.balanceOf(user),                                     0);
        assertEq(spUSDCVault.balanceOf(address(spPrimeVaultUsdc)),                queuedShares);

        _assertDepositState(DepositState({
            controller              : user,
            totalSupply             : VAULT_CAPACITY,
            totalAssets             : VAULT_CAPACITY,
            availableCapacity       : 0,
            availableLiquidAssets   : int256(VAULT_CAPACITY),
            claimableDepositRequest : 0,
            maxDeposit              : 0,
            maxMint                 : 0,
            claimableDepositTotal   : VAULT_CAPACITY,
            pendingDepositRequest   : spUSDCVault.convertToAssets(queuedShares),
            totalPendingDeposits    : queuedShares,
            depositQueueLength      : 1,
            requestNonce            : 1,
            index                   : RAY,
            lastAccrual             : block.timestamp
        }));

        _assertQueuedDepositRequest(user, 1, IVault.Transaction(user, user, queuedShares, 1, 0));

        assertEq(spPrimeVaultUsdc.pendingDepositRequest(0, user), 100e6 - 1);
    }

    function test_requestDeposit_queued_queueNotEmpty() external {
        _requestDeposit(user2, VAULT_CAPACITY); // Consumed all capacity
        _requestDeposit(user2, 100e6);          // Queued, no capacity left

        // Increase capacity, but the queue is not empty
        vm.prank(VAULT_MANAGER);
        spPrimeVaultUsdc.setCapacity(VAULT_CAPACITY + 1_000e6);

        uint256 totalQueuedShares = spPrimeVaultUsdc.totalPendingDeposits();  // spUSDC shares backing all queued deposits
        uint256 queuedShares      = spUSDCVault.previewDeposit(100e6);        // spUSDC shares backing this request

        deal(address(usdc), user, 100e6);

        assertEq(usdc.balanceOf(user),                                            100e6);
        assertEq(usdc.balanceOf(address(spPrimeVaultUsdc)),                       VAULT_CAPACITY);
        assertEq(usdc.allowance(user, address(spPrimeVaultUsdc)),                 0);
        assertEq(usdc.allowance(address(spPrimeVaultUsdc), address(spUSDCVault)), 0);
        assertEq(spPrimeVaultUsdc.balanceOf(user),                                0);
        assertEq(spPrimeVaultUsdc.balanceOf(address(spPrimeVaultUsdc)),           VAULT_CAPACITY);
        assertEq(spUSDCVault.balanceOf(user),                                     0);
        assertEq(spUSDCVault.balanceOf(address(spPrimeVaultUsdc)),                totalQueuedShares);

        _assertDepositState(DepositState({
            controller              : user,
            totalSupply             : VAULT_CAPACITY,
            totalAssets             : VAULT_CAPACITY,
            availableCapacity       : 1_000e6,
            availableLiquidAssets   : int256(VAULT_CAPACITY),
            claimableDepositRequest : 0,
            maxDeposit              : 0,
            maxMint                 : 0,
            claimableDepositTotal   : VAULT_CAPACITY,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : totalQueuedShares,
            depositQueueLength      : 1,
            requestNonce            : 0,
            index                   : RAY,
            lastAccrual             : block.timestamp
        }));

        _assertQueuedDepositRequest(user, 1, IVault.Transaction(address(0), address(0), 0, 0, 0));

        assertEq(spPrimeVaultUsdc.depositQueueHead().controller, user2);

        vm.startPrank(user);
        usdc.approve(address(spPrimeVaultUsdc), 100e6);

        vm.expectEmit(address(spPrimeVaultUsdc));
        emit IQueue.DepositQueueValuation(totalQueuedShares + queuedShares);
        vm.expectEmit(address(spPrimeVaultUsdc));
        emit ISparkPrimeVault.DepositQueued(user, user, 1, queuedShares);
        vm.expectEmit(address(spPrimeVaultUsdc));
        emit IERC7540Deposit.DepositRequest(user, user, 0, user, 100e6);

        spPrimeVaultUsdc.requestDeposit(100e6, user, user);
        vm.stopPrank();

        // Capacity is free, but the request still queues behind the existing entry (FIFO)
        assertEq(usdc.balanceOf(user),                                            0);
        assertEq(usdc.balanceOf(address(spPrimeVaultUsdc)),                       VAULT_CAPACITY);
        assertEq(usdc.allowance(user, address(spPrimeVaultUsdc)),                 0);
        assertEq(usdc.allowance(address(spPrimeVaultUsdc), address(spUSDCVault)), 0);
        assertEq(spPrimeVaultUsdc.balanceOf(user),                                0);
        assertEq(spPrimeVaultUsdc.balanceOf(address(spPrimeVaultUsdc)),           VAULT_CAPACITY);
        assertEq(spUSDCVault.balanceOf(user),                                     0);
        assertEq(spUSDCVault.balanceOf(address(spPrimeVaultUsdc)),                totalQueuedShares + queuedShares);

        _assertDepositState(DepositState({
            controller              : user,
            totalSupply             : VAULT_CAPACITY,
            totalAssets             : VAULT_CAPACITY,
            availableCapacity       : 1_000e6,
            availableLiquidAssets   : int256(VAULT_CAPACITY),
            claimableDepositRequest : 0,
            maxDeposit              : 0,
            maxMint                 : 0,
            claimableDepositTotal   : VAULT_CAPACITY,
            pendingDepositRequest   : spUSDCVault.convertToAssets(queuedShares),
            totalPendingDeposits    : totalQueuedShares + queuedShares,
            depositQueueLength      : 2,
            requestNonce            : 1,
            index                   : RAY,
            lastAccrual             : block.timestamp
        }));

        _assertQueuedDepositRequest(user, 1, IVault.Transaction(user, user, queuedShares, 1, 0));

        assertEq(spPrimeVaultUsdc.depositQueueHead().controller, user2);
    }

    function test_requestDeposit_instantAfterQueueFullyCancelled() external {
        _requestDeposit(user2, VAULT_CAPACITY); // Consumed all capacity
        _requestDeposit(user,  100e6);          // Queued as nonce 1, no capacity left

        vm.prank(VAULT_MANAGER);
        spPrimeVaultUsdc.setCapacity(VAULT_CAPACITY + 100e6);

        vm.prank(user);
        spPrimeVaultUsdc.cancelDepositRequest(user, 1);

        deal(address(usdc), user, 100e6);

        assertEq(usdc.balanceOf(user),                                  100e6);
        assertEq(usdc.balanceOf(address(spPrimeVaultUsdc)),             VAULT_CAPACITY);
        assertEq(usdc.allowance(user, address(spPrimeVaultUsdc)),       0);
        assertEq(spPrimeVaultUsdc.balanceOf(user),                      0);
        assertEq(spPrimeVaultUsdc.balanceOf(address(spPrimeVaultUsdc)), VAULT_CAPACITY);
        assertEq(spUSDCVault.balanceOf(user),                           0);
        assertEq(spUSDCVault.balanceOf(address(spPrimeVaultUsdc)),      0);

        _assertDepositState(DepositState({
            controller              : user,
            totalSupply             : VAULT_CAPACITY,
            totalAssets             : VAULT_CAPACITY,
            availableCapacity       : 100e6,
            availableLiquidAssets   : int256(VAULT_CAPACITY),
            claimableDepositRequest : 0,
            maxDeposit              : 0,
            maxMint                 : 0,
            claimableDepositTotal   : VAULT_CAPACITY,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 1,
            index                   : RAY,
            lastAccrual             : block.timestamp
        }));

        _assertQueuedDepositRequest(user, 1, IVault.Transaction(address(0), address(0), 0, 0, 0));

        vm.startPrank(user);
        usdc.approve(address(spPrimeVaultUsdc), 100e6);

        vm.expectEmit(address(spPrimeVaultUsdc));
        emit IQueue.ClaimableDeposit(user, 100e6);
        vm.expectEmit(address(spPrimeVaultUsdc));
        emit IERC7540Deposit.DepositRequest(user, user, 0, user, 100e6);

        spPrimeVaultUsdc.requestDeposit(100e6, user, user);
        vm.stopPrank();

        // The cancelled entry no longer counts as a queue, so the request fills instantly
        assertEq(usdc.balanceOf(user),                                  0);
        assertEq(usdc.balanceOf(address(spPrimeVaultUsdc)),             VAULT_CAPACITY + 100e6);
        assertEq(usdc.allowance(user, address(spPrimeVaultUsdc)),       0);
        assertEq(spPrimeVaultUsdc.balanceOf(user),                      0);
        assertEq(spPrimeVaultUsdc.balanceOf(address(spPrimeVaultUsdc)), VAULT_CAPACITY + 100e6);
        assertEq(spUSDCVault.balanceOf(user),                           0);
        assertEq(spUSDCVault.balanceOf(address(spPrimeVaultUsdc)),      0);

        _assertDepositState(DepositState({
            controller              : user,
            totalSupply             : VAULT_CAPACITY + 100e6,
            totalAssets             : VAULT_CAPACITY + 100e6,
            availableCapacity       : 0,
            availableLiquidAssets   : int256(VAULT_CAPACITY + 100e6),
            claimableDepositRequest : 100e6,
            maxDeposit              : 100e6,
            maxMint                 : 100e6,
            claimableDepositTotal   : VAULT_CAPACITY + 100e6,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 2,
            index                   : RAY,
            lastAccrual             : block.timestamp
        }));
    }

    function test_requestDeposit_afterInterestAccrual() external {
        uint256 deployTimestamp = block.timestamp;

        skip(365 days);

        uint256 expectedIndex  = spPrimeVaultUsdc.previewIndex();
        uint256 expectedShares = 100e6 * RAY / expectedIndex;

        // 10% APY over one year
        assertApproxEqRel(expectedIndex, 1.1e27, 0.0001e18);

        deal(address(usdc), user, 100e6);

        assertEq(usdc.balanceOf(user),                                  100e6);
        assertEq(usdc.balanceOf(address(spPrimeVaultUsdc)),             0);
        assertEq(usdc.allowance(user, address(spPrimeVaultUsdc)),       0);
        assertEq(spPrimeVaultUsdc.balanceOf(user),                      0);
        assertEq(spPrimeVaultUsdc.balanceOf(address(spPrimeVaultUsdc)), 0);
        assertEq(spUSDCVault.balanceOf(user),                           0);
        assertEq(spUSDCVault.balanceOf(address(spPrimeVaultUsdc)),      0);

        _assertDepositState(DepositState({
            controller              : user,
            totalSupply             : 0,
            totalAssets             : 0,
            availableCapacity       : VAULT_CAPACITY,
            availableLiquidAssets   : 0,
            claimableDepositRequest : 0,
            maxDeposit              : 0,
            maxMint                 : 0,
            claimableDepositTotal   : 0,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 0,
            index                   : RAY,
            lastAccrual             : deployTimestamp
        }));

        vm.startPrank(user);
        usdc.approve(address(spPrimeVaultUsdc), 100e6);

        vm.expectEmit(address(spPrimeVaultUsdc));
        emit IVault.AccruedInterest(expectedIndex, block.timestamp);
        vm.expectEmit(address(spPrimeVaultUsdc));
        emit IQueue.ClaimableDeposit(user, 100e6);
        vm.expectEmit(address(spPrimeVaultUsdc));
        emit IERC7540Deposit.DepositRequest(user, user, 0, user, 100e6);

        spPrimeVaultUsdc.requestDeposit(100e6, user, user);
        vm.stopPrank();

        // Shares are minted at the accrued index, so fewer shares than assets
        assertLt(expectedShares, 100e6);

        assertEq(usdc.balanceOf(user),                                  0);
        assertEq(usdc.balanceOf(address(spPrimeVaultUsdc)),             100e6);
        assertEq(usdc.allowance(user, address(spPrimeVaultUsdc)),       0);
        assertEq(spPrimeVaultUsdc.balanceOf(user),                      0);
        assertEq(spPrimeVaultUsdc.balanceOf(address(spPrimeVaultUsdc)), expectedShares);
        assertEq(spUSDCVault.balanceOf(user),                           0);
        assertEq(spUSDCVault.balanceOf(address(spPrimeVaultUsdc)),      0);

        _assertDepositState(DepositState({
            controller              : user,
            totalSupply             : expectedShares,
            totalAssets             : expectedShares * expectedIndex / RAY,
            availableCapacity       : VAULT_CAPACITY - expectedShares,
            availableLiquidAssets   : int256(100e6),
            claimableDepositRequest : 100e6,
            maxDeposit              : 100e6,
            maxMint                 : expectedShares,
            claimableDepositTotal   : expectedShares,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 1,
            index                   : expectedIndex,
            lastAccrual             : block.timestamp
        }));
    }

    function test_requestDeposit_queued_pendingValueAccruesSavingsYield() external {
        uint256 deployTimestamp = block.timestamp;

        _requestDeposit(user2, VAULT_CAPACITY); // Consumed all capacity

        uint256 queuedShares = spUSDCVault.previewDeposit(100e6);  // spUSDC shares backing this request

        _requestDeposit(user, 100e6);  // Queued as nonce 1, no capacity left

        uint256 pendingBefore = spPrimeVaultUsdc.pendingDepositRequest(0, user);

        assertEq(pendingBefore, 100e6 - 1);

        assertEq(spPrimeVaultUsdc.balanceOf(address(spPrimeVaultUsdc)), VAULT_CAPACITY);
        assertEq(spUSDCVault.balanceOf(address(spPrimeVaultUsdc)),      queuedShares);

        _assertDepositState(DepositState({
            controller              : user,
            totalSupply             : VAULT_CAPACITY,
            totalAssets             : VAULT_CAPACITY,
            availableCapacity       : 0,
            availableLiquidAssets   : int256(VAULT_CAPACITY),
            claimableDepositRequest : 0,
            maxDeposit              : 0,
            maxMint                 : 0,
            claimableDepositTotal   : VAULT_CAPACITY,
            pendingDepositRequest   : spUSDCVault.convertToAssets(queuedShares),
            totalPendingDeposits    : queuedShares,
            depositQueueLength      : 1,
            requestNonce            : 1,
            index                   : RAY,
            lastAccrual             : deployTimestamp
        }));

        _assertQueuedDepositRequest(user, 1, IVault.Transaction(user, user, queuedShares, 1, 0));

        skip(30 days);

        uint256 expectedIndex = spPrimeVaultUsdc.previewIndex();

        // The spUSDC share count is unchanged, its value grows with the spUSDC rate
        assertGt(spPrimeVaultUsdc.pendingDepositRequest(0, user), pendingBefore);

        assertEq(spPrimeVaultUsdc.balanceOf(address(spPrimeVaultUsdc)), VAULT_CAPACITY);
        assertEq(spUSDCVault.balanceOf(address(spPrimeVaultUsdc)),      queuedShares);

        _assertDepositState(DepositState({
            controller              : user,
            totalSupply             : VAULT_CAPACITY,
            totalAssets             : VAULT_CAPACITY * expectedIndex / RAY,
            availableCapacity       : 0,
            availableLiquidAssets   : int256(VAULT_CAPACITY),
            claimableDepositRequest : 0,
            maxDeposit              : 0,
            maxMint                 : 0,
            claimableDepositTotal   : VAULT_CAPACITY,
            pendingDepositRequest   : spUSDCVault.convertToAssets(queuedShares),
            totalPendingDeposits    : queuedShares,
            depositQueueLength      : 1,
            requestNonce            : 1,
            index                   : RAY,
            lastAccrual             : deployTimestamp
        }));

        _assertQueuedDepositRequest(user, 1, IVault.Transaction(user, user, queuedShares, 1, 0));
    }

}

contract DepositTests is ForkTestBase {

    // TODO : Add failure tests

    // Success tests

    function test_deposit_fullClaim() external {
        _requestDeposit(user, 100e6);  // Instant claim, 100e6 shares at index 1

        assertEq(usdc.balanceOf(user),                                  0);
        assertEq(usdc.balanceOf(address(spPrimeVaultUsdc)),             100e6);
        assertEq(spPrimeVaultUsdc.balanceOf(user),                      0);
        assertEq(spPrimeVaultUsdc.balanceOf(address(spPrimeVaultUsdc)), 100e6);
        assertEq(spUSDCVault.balanceOf(user),                           0);
        assertEq(spUSDCVault.balanceOf(address(spPrimeVaultUsdc)),      0);

        _assertDepositState(DepositState({
            controller              : user,
            totalSupply             : 100e6,
            totalAssets             : 100e6,
            availableCapacity       : VAULT_CAPACITY - 100e6,
            availableLiquidAssets   : int256(100e6),
            claimableDepositRequest : 100e6,
            maxDeposit              : 100e6,
            maxMint                 : 100e6,
            claimableDepositTotal   : 100e6,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 1,
            index                   : RAY,
            lastAccrual             : block.timestamp
        }));

        vm.expectEmit(address(spPrimeVaultUsdc));
        emit IQueue.ClaimableDeposit(user, 0);
        vm.expectEmit(address(spPrimeVaultUsdc));
        emit IERC4626Like.Deposit(user, user, 100e6, 100e6);

        vm.prank(user);
        uint256 shares = spPrimeVaultUsdc.deposit(100e6, user, user);

        assertEq(shares, 100e6);

        // Claiming only moves escrowed shares from the vault to the receiver
        assertEq(usdc.balanceOf(user),                                  0);
        assertEq(usdc.balanceOf(address(spPrimeVaultUsdc)),             100e6);
        assertEq(spPrimeVaultUsdc.balanceOf(user),                      100e6);
        assertEq(spPrimeVaultUsdc.balanceOf(address(spPrimeVaultUsdc)), 0);
        assertEq(spUSDCVault.balanceOf(user),                           0);
        assertEq(spUSDCVault.balanceOf(address(spPrimeVaultUsdc)),      0);

        _assertDepositState(DepositState({
            controller              : user,
            totalSupply             : 100e6,
            totalAssets             : 100e6,
            availableCapacity       : VAULT_CAPACITY - 100e6,
            availableLiquidAssets   : int256(100e6),
            claimableDepositRequest : 0,
            maxDeposit              : 0,
            maxMint                 : 0,
            claimableDepositTotal   : 0,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 1,
            index                   : RAY,
            lastAccrual             : block.timestamp
        }));
    }

    function test_deposit_partialClaim() external {
        _requestDeposit(user, 100e6);  // Instant claim, 100e6 shares at index 1

        assertEq(usdc.balanceOf(user),                                  0);
        assertEq(usdc.balanceOf(address(spPrimeVaultUsdc)),             100e6);
        assertEq(spPrimeVaultUsdc.balanceOf(user),                      0);
        assertEq(spPrimeVaultUsdc.balanceOf(address(spPrimeVaultUsdc)), 100e6);
        assertEq(spUSDCVault.balanceOf(user),                           0);
        assertEq(spUSDCVault.balanceOf(address(spPrimeVaultUsdc)),      0);

        _assertDepositState(DepositState({
            controller              : user,
            totalSupply             : 100e6,
            totalAssets             : 100e6,
            availableCapacity       : VAULT_CAPACITY - 100e6,
            availableLiquidAssets   : int256(100e6),
            claimableDepositRequest : 100e6,
            maxDeposit              : 100e6,
            maxMint                 : 100e6,
            claimableDepositTotal   : 100e6,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 1,
            index                   : RAY,
            lastAccrual             : block.timestamp
        }));

        vm.expectEmit(address(spPrimeVaultUsdc));
        emit IQueue.ClaimableDeposit(user, 60e6);
        vm.expectEmit(address(spPrimeVaultUsdc));
        emit IERC4626Like.Deposit(user, user, 40e6, 40e6);

        vm.prank(user);
        uint256 shares = spPrimeVaultUsdc.deposit(40e6, user, user);

        assertEq(shares, 40e6);

        assertEq(usdc.balanceOf(user),                                  0);
        assertEq(usdc.balanceOf(address(spPrimeVaultUsdc)),             100e6);
        assertEq(spPrimeVaultUsdc.balanceOf(user),                      40e6);
        assertEq(spPrimeVaultUsdc.balanceOf(address(spPrimeVaultUsdc)), 60e6);
        assertEq(spUSDCVault.balanceOf(user),                           0);
        assertEq(spUSDCVault.balanceOf(address(spPrimeVaultUsdc)),      0);

        _assertDepositState(DepositState({
            controller              : user,
            totalSupply             : 100e6,
            totalAssets             : 100e6,
            availableCapacity       : VAULT_CAPACITY - 100e6,
            availableLiquidAssets   : int256(100e6),
            claimableDepositRequest : 60e6,
            maxDeposit              : 60e6,
            maxMint                 : 60e6,
            claimableDepositTotal   : 60e6,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 1,
            index                   : RAY,
            lastAccrual             : block.timestamp
        }));
    }

    function test_deposit_multiplePartialClaims() external {
        // Request at an accrued index so shares owed differ from assets and every claim rounds
        skip(365 days);

        _requestDeposit(user, 100e6);

        uint256 index = spPrimeVaultUsdc.index();

        // 10% APY over one year
        assertApproxEqRel(index, 1.1e27, 0.0001e18);

        uint256 sharesOwed = 100e6 * RAY / index;

        uint256 shares1 = sharesOwed * 30e6 / 100e6;
        uint256 shares2 = (sharesOwed - shares1) * 30e6 / 70e6;
        uint256 shares3 = sharesOwed - shares1 - shares2;  // Last claim takes every remaining share

        assertEq(spPrimeVaultUsdc.balanceOf(user),                      0);
        assertEq(spPrimeVaultUsdc.balanceOf(address(spPrimeVaultUsdc)), sharesOwed);

        _assertDepositState(DepositState({
            controller              : user,
            totalSupply             : sharesOwed,
            totalAssets             : sharesOwed * index / RAY,
            availableCapacity       : VAULT_CAPACITY - sharesOwed,
            availableLiquidAssets   : int256(100e6),
            claimableDepositRequest : 100e6,
            maxDeposit              : 100e6,
            maxMint                 : sharesOwed,
            claimableDepositTotal   : sharesOwed,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 1,
            index                   : index,
            lastAccrual             : block.timestamp
        }));

        vm.prank(user);
        uint256 shares = spPrimeVaultUsdc.deposit(30e6, user, user);

        assertEq(shares, shares1);

        assertEq(spPrimeVaultUsdc.balanceOf(user),                      shares1);
        assertEq(spPrimeVaultUsdc.balanceOf(address(spPrimeVaultUsdc)), sharesOwed - shares1);

        _assertDepositState(DepositState({
            controller              : user,
            totalSupply             : sharesOwed,
            totalAssets             : sharesOwed * index / RAY,
            availableCapacity       : VAULT_CAPACITY - sharesOwed,
            availableLiquidAssets   : int256(100e6),
            claimableDepositRequest : 70e6,
            maxDeposit              : 70e6,
            maxMint                 : sharesOwed - shares1,
            claimableDepositTotal   : sharesOwed - shares1,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 1,
            index                   : index,
            lastAccrual             : block.timestamp
        }));

        vm.prank(user);
        shares = spPrimeVaultUsdc.deposit(30e6, user, user);

        assertEq(shares, shares2);

        assertEq(spPrimeVaultUsdc.balanceOf(user),                      shares1 + shares2);
        assertEq(spPrimeVaultUsdc.balanceOf(address(spPrimeVaultUsdc)), shares3);

        _assertDepositState(DepositState({
            controller              : user,
            totalSupply             : sharesOwed,
            totalAssets             : sharesOwed * index / RAY,
            availableCapacity       : VAULT_CAPACITY - sharesOwed,
            availableLiquidAssets   : int256(100e6),
            claimableDepositRequest : 40e6,
            maxDeposit              : 40e6,
            maxMint                 : shares3,
            claimableDepositTotal   : shares3,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 1,
            index                   : index,
            lastAccrual             : block.timestamp
        }));

        vm.prank(user);
        shares = spPrimeVaultUsdc.deposit(40e6, user, user);

        assertEq(shares, shares3);

        // Every owed share reaches the user, no dust is left in escrow
        assertEq(spPrimeVaultUsdc.balanceOf(user),                      sharesOwed);
        assertEq(spPrimeVaultUsdc.balanceOf(address(spPrimeVaultUsdc)), 0);

        _assertDepositState(DepositState({
            controller              : user,
            totalSupply             : sharesOwed,
            totalAssets             : sharesOwed * index / RAY,
            availableCapacity       : VAULT_CAPACITY - sharesOwed,
            availableLiquidAssets   : int256(100e6),
            claimableDepositRequest : 0,
            maxDeposit              : 0,
            maxMint                 : 0,
            claimableDepositTotal   : 0,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 1,
            index                   : index,
            lastAccrual             : block.timestamp
        }));
    }

    function test_deposit_operatorAndDifferentReceiver() external {
        address operator = makeAddr("operator");

        _requestDeposit(user, 100e6);  // Instant claim, 100e6 shares at index 1

        vm.prank(user);
        spPrimeVaultUsdc.setOperator(operator, true);

        assertEq(spPrimeVaultUsdc.balanceOf(user),                      0);
        assertEq(spPrimeVaultUsdc.balanceOf(user2),                     0);
        assertEq(spPrimeVaultUsdc.balanceOf(operator),                  0);
        assertEq(spPrimeVaultUsdc.balanceOf(address(spPrimeVaultUsdc)), 100e6);

        _assertDepositState(DepositState({
            controller              : user,
            totalSupply             : 100e6,
            totalAssets             : 100e6,
            availableCapacity       : VAULT_CAPACITY - 100e6,
            availableLiquidAssets   : int256(100e6),
            claimableDepositRequest : 100e6,
            maxDeposit              : 100e6,
            maxMint                 : 100e6,
            claimableDepositTotal   : 100e6,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 1,
            index                   : RAY,
            lastAccrual             : block.timestamp
        }));

        // Operator claims for the controller, and can only send to the controller
        vm.expectEmit(address(spPrimeVaultUsdc));
        emit IQueue.ClaimableDeposit(user, 60e6);
        vm.expectEmit(address(spPrimeVaultUsdc));
        emit IERC4626Like.Deposit(user, user, 40e6, 40e6);

        vm.prank(operator);
        uint256 shares = spPrimeVaultUsdc.deposit(40e6, user, user);

        assertEq(shares, 40e6);

        assertEq(spPrimeVaultUsdc.balanceOf(user),                      40e6);
        assertEq(spPrimeVaultUsdc.balanceOf(user2),                     0);
        assertEq(spPrimeVaultUsdc.balanceOf(operator),                  0);
        assertEq(spPrimeVaultUsdc.balanceOf(address(spPrimeVaultUsdc)), 60e6);

        _assertDepositState(DepositState({
            controller              : user,
            totalSupply             : 100e6,
            totalAssets             : 100e6,
            availableCapacity       : VAULT_CAPACITY - 100e6,
            availableLiquidAssets   : int256(100e6),
            claimableDepositRequest : 60e6,
            maxDeposit              : 60e6,
            maxMint                 : 60e6,
            claimableDepositTotal   : 60e6,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 1,
            index                   : RAY,
            lastAccrual             : block.timestamp
        }));

        // Controller claims the rest to a different receiver
        vm.expectEmit(address(spPrimeVaultUsdc));
        emit IQueue.ClaimableDeposit(user, 0);
        vm.expectEmit(address(spPrimeVaultUsdc));
        emit IERC4626Like.Deposit(user, user2, 60e6, 60e6);

        vm.prank(user); // user is the controller
        shares = spPrimeVaultUsdc.deposit(60e6, user2, user);

        assertEq(shares, 60e6);

        assertEq(spPrimeVaultUsdc.balanceOf(user),                      40e6);
        assertEq(spPrimeVaultUsdc.balanceOf(user2),                     60e6);
        assertEq(spPrimeVaultUsdc.balanceOf(operator),                  0);
        assertEq(spPrimeVaultUsdc.balanceOf(address(spPrimeVaultUsdc)), 0);

        _assertDepositState(DepositState({
            controller              : user,
            totalSupply             : 100e6,
            totalAssets             : 100e6,
            availableCapacity       : VAULT_CAPACITY - 100e6,
            availableLiquidAssets   : int256(100e6),
            claimableDepositRequest : 0,
            maxDeposit              : 0,
            maxMint                 : 0,
            claimableDepositTotal   : 0,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 1,
            index                   : RAY,
            lastAccrual             : block.timestamp
        }));
    }

    function test_deposit_erc4626Overload() external {
        _requestDeposit(user, 100e6);  // Instant claim, 100e6 shares at index 1

        assertEq(spPrimeVaultUsdc.balanceOf(user),                      0);
        assertEq(spPrimeVaultUsdc.balanceOf(address(spPrimeVaultUsdc)), 100e6);

        _assertDepositState(DepositState({
            controller              : user,
            totalSupply             : 100e6,
            totalAssets             : 100e6,
            availableCapacity       : VAULT_CAPACITY - 100e6,
            availableLiquidAssets   : int256(100e6),
            claimableDepositRequest : 100e6,
            maxDeposit              : 100e6,
            maxMint                 : 100e6,
            claimableDepositTotal   : 100e6,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 1,
            index                   : RAY,
            lastAccrual             : block.timestamp
        }));

        // deposit(assets, receiver) uses msg.sender as the controller
        vm.expectEmit(address(spPrimeVaultUsdc));
        emit IQueue.ClaimableDeposit(user, 0);
        vm.expectEmit(address(spPrimeVaultUsdc));
        emit IERC4626Like.Deposit(user, user, 100e6, 100e6);

        vm.prank(user);
        uint256 shares = spPrimeVaultUsdc.deposit(100e6, user);

        assertEq(shares, 100e6);

        assertEq(spPrimeVaultUsdc.balanceOf(user),                      100e6);
        assertEq(spPrimeVaultUsdc.balanceOf(address(spPrimeVaultUsdc)), 0);

        _assertDepositState(DepositState({
            controller              : user,
            totalSupply             : 100e6,
            totalAssets             : 100e6,
            availableCapacity       : VAULT_CAPACITY - 100e6,
            availableLiquidAssets   : int256(100e6),
            claimableDepositRequest : 0,
            maxDeposit              : 0,
            maxMint                 : 0,
            claimableDepositTotal   : 0,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 1,
            index                   : RAY,
            lastAccrual             : block.timestamp
        }));
    }

    function test_deposit_withReferral() external {
        _requestDeposit(user, 100e6);  // Instant claim, 100e6 shares at index 1

        assertEq(spPrimeVaultUsdc.balanceOf(user),                      0);
        assertEq(spPrimeVaultUsdc.balanceOf(address(spPrimeVaultUsdc)), 100e6);

        _assertDepositState(DepositState({
            controller              : user,
            totalSupply             : 100e6,
            totalAssets             : 100e6,
            availableCapacity       : VAULT_CAPACITY - 100e6,
            availableLiquidAssets   : int256(100e6),
            claimableDepositRequest : 100e6,
            maxDeposit              : 100e6,
            maxMint                 : 100e6,
            claimableDepositTotal   : 100e6,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 1,
            index                   : RAY,
            lastAccrual             : block.timestamp
        }));

        vm.expectEmit(address(spPrimeVaultUsdc));
        emit ISparkPrimeVault.ReferralCode(user, 1);
        vm.expectEmit(address(spPrimeVaultUsdc));
        emit IQueue.ClaimableDeposit(user, 0);
        vm.expectEmit(address(spPrimeVaultUsdc));
        emit IERC4626Like.Deposit(user, user, 100e6, 100e6);

        vm.prank(user);
        uint256 shares = spPrimeVaultUsdc.deposit(100e6, user, user, 1);

        assertEq(shares, 100e6);

        assertEq(spPrimeVaultUsdc.balanceOf(user),                      100e6);
        assertEq(spPrimeVaultUsdc.balanceOf(address(spPrimeVaultUsdc)), 0);

        _assertDepositState(DepositState({
            controller              : user,
            totalSupply             : 100e6,
            totalAssets             : 100e6,
            availableCapacity       : VAULT_CAPACITY - 100e6,
            availableLiquidAssets   : int256(100e6),
            claimableDepositRequest : 0,
            maxDeposit              : 0,
            maxMint                 : 0,
            claimableDepositTotal   : 0,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 1,
            index                   : RAY,
            lastAccrual             : block.timestamp
        }));
    }

    function test_deposit_afterProcessQueue() external {
        // TODO
    }

    function test_deposit_combinedInstantAndQueuedFill() external {
        // TODO
    }

    function test_deposit_afterInterestAccrual() external {
        uint256 requestTimestamp = block.timestamp;

        _requestDeposit(user, 100e6);  // Instant claim, 100e6 shares at index 1

        assertEq(spPrimeVaultUsdc.convertToAssets(100e6), 100e6);

        skip(365 days);

        uint256 expectedIndex = spPrimeVaultUsdc.previewIndex();

        // 10% APY over one year
        assertApproxEqRel(expectedIndex, 1.1e27, 0.0001e18);

        assertEq(spPrimeVaultUsdc.balanceOf(user),                      0);
        assertEq(spPrimeVaultUsdc.balanceOf(address(spPrimeVaultUsdc)), 100e6);

        _assertDepositState(DepositState({
            controller              : user,
            totalSupply             : 100e6,
            totalAssets             : 100e6 * expectedIndex / RAY,
            availableCapacity       : VAULT_CAPACITY - 100e6,
            availableLiquidAssets   : int256(100e6),
            claimableDepositRequest : 100e6,
            maxDeposit              : 100e6,
            maxMint                 : 100e6,
            claimableDepositTotal   : 100e6,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 1,
            index                   : RAY,
            lastAccrual             : requestTimestamp
        }));

        vm.expectEmit(address(spPrimeVaultUsdc));
        emit IVault.AccruedInterest(expectedIndex, block.timestamp);
        vm.expectEmit(address(spPrimeVaultUsdc));
        emit IQueue.ClaimableDeposit(user, 0);
        vm.expectEmit(address(spPrimeVaultUsdc));
        emit IERC4626Like.Deposit(user, user, 100e6, 100e6);

        vm.prank(user);
        uint256 shares = spPrimeVaultUsdc.deposit(100e6, user, user);

        // Share count is fixed at request time, the shares gained value while escrowed
        assertEq(shares, 100e6);

        assertEq(spPrimeVaultUsdc.balanceOf(user),                      100e6);
        assertEq(spPrimeVaultUsdc.balanceOf(address(spPrimeVaultUsdc)), 0);
        assertEq(spPrimeVaultUsdc.convertToAssets(100e6),               109.999999e6);

        _assertDepositState(DepositState({
            controller              : user,
            totalSupply             : 100e6,
            totalAssets             : 100e6 * expectedIndex / RAY,
            availableCapacity       : VAULT_CAPACITY - 100e6,
            availableLiquidAssets   : int256(100e6),
            claimableDepositRequest : 0,
            maxDeposit              : 0,
            maxMint                 : 0,
            claimableDepositTotal   : 0,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 1,
            index                   : expectedIndex,
            lastAccrual             : block.timestamp
        }));
    }

}
