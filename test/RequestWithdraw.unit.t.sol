// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VaultHandler} from "./VaultHandler.t.sol";
import {IVault} from "../src/interfaces/IVault.sol";
import {USDC} from "./mocks/USDC.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {console} from "forge-std/console.sol";
import {DepositHelper} from "./utils/DepositHelper.sol";

contract RequestWithdrawUnitTests is DepositHelper {
    VaultHandler public vault;
    address user = makeAddr("User");
    address userTwo = makeAddr("UserTwo");
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

    /// @dev FIFO principles: If a withdraw queue already exists, immedetialy join it.
    function test_requestWithdraw_queueExists() public {
        uint256 depositAmount = 50 ether;

        _fundAndDeposit(vault, user, baseAsset, depositAmount);
        _claimDeposit(vault, user, depositAmount);

        _fundAndDeposit(vault, userTwo, baseAsset, depositAmount);
        _claimDeposit(vault, userTwo, depositAmount);

        vm.prank(liquidityManager);
        vault.take(2 * depositAmount); // Take out both users deposited baseAssets a.k.a all the vaults liquidity

        uint256 shares = vault.convertToShares(depositAmount);

        vm.prank(user);
        vault.requestRedeem(shares, user, user);
        vm.prank(userTwo);
        vault.requestRedeem(shares, userTwo, userTwo);

        assertEq(vault.withdrawQueueLength(), 2);
        assertEq(vault.withdrawQueueHead().beneficiary, user);
        assertEq(vault.totalPendingWithdraws(), 2 * depositAmount); // Both users queued

        assertEq(vault.maxRedeem(user), 0);
        assertEq(vault.maxRedeem(userTwo), 0);
        vm.stopPrank();
    }

    function test_requestWithdraw_noQueue_vaultInsolvent() public {
        uint256 depositAmount = 50 ether;

        _fundAndDeposit(vault, user, baseAsset, depositAmount);
        _claimDeposit(vault, user, depositAmount);

        _fundAndDeposit(vault, userTwo, baseAsset, depositAmount);
        _claimDeposit(vault, userTwo, depositAmount);

        vm.prank(liquidityManager);
        vault.take(2 * depositAmount); // Take out both users deposited baseAssets a.k.a all the vaults liquidity

        /// No Withdraw queue exists yet but the user should immediately be queued because the vault is insolvent.
        uint256 shares = vault.convertToShares(depositAmount);
        vm.prank(user);
        vault.requestRedeem(shares, user, user);

        IVault.Transaction memory data = vault.withdrawQueueHead();
        assertEq(data.amount, depositAmount);
        assertEq(data.beneficiary, user);
    }

    /// @dev When no withdraw queue exists and the availableLiquidAssets can cover the entire withdraw amont, instant claim entire amount
    function test_requestWithdraw_fullInstantClaim() public {
        uint256 assets = 10 ether;

        _fundAndDeposit(vault, user, baseAsset, assets);
        _claimDeposit(vault, user, assets);

        vm.startPrank(user);
        uint256 shares = vault.convertToShares(assets);
        vault.requestRedeem(shares, user, user);

        assertEq(vault.maxRedeem(user), shares); // All shares instant claimab;e
        vm.stopPrank();
    }

    /// @dev When no withdraw queue exists and the availableLiquidAssets can cover only partial entire withdraw amont, remainder queud
    function test_requestWithdraw_partialInstantClaim_queueRemainder() public {
        uint256 userDeposit = 10 ether;
        uint256 userTwoDeposit = 10 ether;

        _fundAndDeposit(vault, user, baseAsset, userDeposit);
        _claimDeposit(vault, user, userDeposit);
        _fundAndDeposit(vault, userTwo, baseAsset, userTwoDeposit);
        _claimDeposit(vault, userTwo, userTwoDeposit);

        assertEq(
            userDeposit + userTwoDeposit,
            baseAsset.balanceOf(address(vault))
        );
        assertEq(
            vault.availableLiquidAssets(),
            int256(userDeposit + userTwoDeposit)
        );

        /// @dev for a partial withdraw claim, we need to make a withdraw request larger than availableLiquidAssets
        /// Easiest way to test this is to just reduce the vault balance
        vm.prank(liquidityManager);
        vault.take(15 ether); // The vault only has 5 ether of baseAsset remaining in availableLiquidAssets

        vm.startPrank(user);

        uint256 shares = vault.convertToShares(userDeposit);

        vault.requestRedeem(shares, user, user); // Request 10 ether of baseAsset

        assertEq(vault.maxRedeem(user), 5 ether); // 5 ether is instantly claimable

        IVault.Transaction memory data = vault.withdrawQueueHead();
        assertEq(data.amount, 5 ether); // The remaining 5 ether is queued
        assertEq(data.beneficiary, user);

        vm.stopPrank();
    }
    function generateWithdrawQueue() internal {
        uint256 userDeposit = 50 ether;
        uint256 userTwoDeposit = 50 ether;

        _fundAndDeposit(vault, user, baseAsset, userDeposit);
        _claimDeposit(vault, user, vault.maxDeposit(user));
        _fundAndDeposit(vault, userTwo, baseAsset, userTwoDeposit);
        _claimDeposit(vault, userTwo, vault.maxDeposit(userTwo));

        // Force Withdraw Queue by removing liqudity
        vm.prank(liquidityManager);
        vault.take(userDeposit + userTwoDeposit);

        vm.prank(user);
        vault.requestRedeem(vault.convertToShares(50), user, user);
        assertEq(vault.withdrawQueueLength(), 1);
    }

    /// @dev If a withdraw queue exists, we enter the queue always.
    function test_requestWithdraw_alwaysFIFO() public {
        generateWithdrawQueue();
        vm.prank(userTwo);
        vault.requestRedeem(vault.convertToShares(5 ether), userTwo, userTwo);

        assertEq(vault.maxRedeem(userTwo), 0);
        assertEq(vault.withdrawQueueLength(), 2);
    }
}
