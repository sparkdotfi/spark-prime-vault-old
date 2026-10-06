// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC7540Deposit }  from "../../src/interfaces/IERC7540.sol";
import { IQueue }           from "../../src/interfaces/IQueue.sol";
import { ISparkPrimeVault } from "../../src/interfaces/ISparkPrimeVault.sol";
import { IVault }           from "../../src/interfaces/IVault.sol";

import { ForkTestBase } from "./ForkTestBase.t.sol";

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

        _assertVaultState(VaultState({
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

        _assertVaultState(VaultState({
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

        _assertVaultState(VaultState({
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

        _assertVaultState(VaultState({
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
        uint256 queuedShares = spUSDCVault.previewDeposit(500e6);

        deal(address(usdc), user, amount);

        assertEq(usdc.balanceOf(user),                                            amount);
        assertEq(usdc.balanceOf(address(spPrimeVaultUsdc)),                       0);
        assertEq(usdc.allowance(user, address(spPrimeVaultUsdc)),                 0);
        assertEq(usdc.allowance(address(spPrimeVaultUsdc), address(spUSDCVault)), 0);
        assertEq(spPrimeVaultUsdc.balanceOf(user),                                0);
        assertEq(spPrimeVaultUsdc.balanceOf(address(spPrimeVaultUsdc)),           0);
        assertEq(spUSDCVault.balanceOf(user),                                     0);
        assertEq(spUSDCVault.balanceOf(address(spPrimeVaultUsdc)),                0);

        _assertVaultState(VaultState({
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

        _assertVaultState(VaultState({
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

        assertApproxEqAbs(spPrimeVaultUsdc.pendingDepositRequest(0, user), 500e6, 1);
    }

}

contract DepositTests is ForkTestBase {

}
