// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VaultHandler} from "./VaultHandler.t.sol";
import {IVault} from "src/interfaces/IVault.sol";
import {ISparkPrimeVault} from "src/interfaces/ISparkPrimeVault.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {USDC} from "./mocks/USDC.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {console} from "forge-std/console.sol";
import {QueueHelper} from "./utils/QueueHelper.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract RequestWithdrawUnitTests is QueueHelper {
    function setUp() public {
        _deployVault();
    }

    /// @dev FIFO principles: If a withdraw queue already exists, immedetialy join it.
    function test_requestWithdraw_queueExists() public {
        uint256 depositAmount = 50 ether;

        _depositAndClaim(user, depositAmount);
        _depositAndClaim(userTwo, depositAmount);

        _drainLiquidity(); // Take out both users deposited baseAssets a.k.a all the vaults liquidity

        uint256 shares = vault.convertToShares(depositAmount);

        vm.prank(user);
        vault.requestRedeem(shares, user, user);
        vm.prank(userTwo);
        vault.requestRedeem(shares, userTwo, userTwo);

        assertEq(vault.withdrawQueueLength(), 2);
        assertEq(vault.withdrawQueueHead().controller, user);
        assertEq(vault.totalPendingWithdraws(), 2 * shares); // Both users queued

        assertEq(vault.maxRedeem(user), 0);
        assertEq(vault.maxRedeem(userTwo), 0);
        vm.stopPrank();
    }

    function test_requestWithdraw_noQueue_vaultInsolvent() public {
        uint256 depositAmount = 50 ether;

        _depositAndClaim(user, depositAmount);
        _depositAndClaim(userTwo, depositAmount);

        _drainLiquidity(); // Take out both users deposited baseAssets a.k.a all the vaults liquidity

        /// No Withdraw queue exists yet but the user should immediately be queued because the vault is insolvent.
        uint256 shares = vault.convertToShares(depositAmount);
        vm.prank(user);
        vault.requestRedeem(shares, user, user);

        IVault.Transaction memory data = vault.withdrawQueueHead();
        assertEq(data.amount, shares);
        assertEq(data.controller, user);
    }

    /// @dev When no withdraw queue exists and the availableLiquidAssets can cover the entire withdraw amont, instant claim entire amount
    function test_requestWithdraw_fullInstantClaim() public {
        uint256 assets = 10 ether;

        _fundAndDeposit(vault, user, baseAsset, assets);
        _claimDeposit(vault, user, assets);
        // assertEq(vault.balanceOf(user), vault.convertToShares(assets));

        vm.startPrank(user);
        uint256 shares = vault.convertToShares(assets);

        vault.requestRedeem(shares, user, user);

        assertEq(vault.maxRedeem(user), vault.convertToShares(assets)); // All shares instant claimab;e
        uint256 balanceBefore = baseAsset.balanceOf(user);

        vault.redeem(shares, user, user);
        assertEq(
            baseAsset.balanceOf(user),
            balanceBefore + vault.convertToAssets(shares)
        );
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
        uint256 instantClaimableValue = vault.maxWithdraw(user);
        assertApproxEqAbs(instantClaimableValue, 5 ether, ROUNDING_DUST); // 5 ether is instantly claimable

        IVault.Transaction memory data = vault.withdrawQueueHead();
        assertApproxEqAbs(
            vault.convertToAssets(data.amount),
            5 ether,
            ROUNDING_DUST
        ); // The remaining 5 ether is queued
        assertEq(data.controller, user);

        uint256 balanceBefore = baseAsset.balanceOf(user);

        vault.redeem(vault.convertToShares(instantClaimableValue), user, user);
        assertApproxEqAbs(
            baseAsset.balanceOf(user),
            balanceBefore + instantClaimableValue,
            ROUNDING_DUST
        );
        vm.stopPrank();
    }
    function generateWithdrawQueue() internal {
        uint256 userDeposit = 50 ether;
        uint256 userTwoDeposit = 50 ether;

        _depositAndClaim(user, userDeposit);
        _depositAndClaim(userTwo, userTwoDeposit);

        // Force Withdraw Queue by removing liqudity
        _drainLiquidity();

        vm.startPrank(user);
        uint256 shares = vault.convertToShares(50 ether);
        vault.requestRedeem(shares, user, user);
        vm.stopPrank();

        assertEq(vault.withdrawQueueLength(), 1);
    }

    /// @dev If a withdraw queue exists, we enter the queue always.
    function test_requestWithdraw_alwaysFIFO() public {
        generateWithdrawQueue();

        vm.startPrank(userTwo);
        uint256 shares = vault.convertToShares(5 ether);
        vault.requestRedeem(shares, userTwo, userTwo);
        vm.stopPrank();

        assertEq(vault.maxRedeem(userTwo), 0);
        assertEq(vault.withdrawQueueLength(), 2);
    }

    function test_minimumWithdraw_isSetByInitialize() public view {
        assertEq(vault.minimumWithdraw(), MINIMUM_WITHDRAW);
    }

    function test_cannot_requestRedeem_belowMinimum() public {
        _depositAndClaim(user, 50 ether);
        _drainLiquidity();

        uint256 shares = vault.convertToShares(MINIMUM_WITHDRAW) - 1;

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISparkPrimeVault.MustExceedMinimumRequestAmount.selector,
                MINIMUM_WITHDRAW
            )
        );
        vault.requestRedeem(shares, user, user);
    }

    function test_requestRedeem_atMinimum() public {
        _depositAndClaim(user, 50 ether);
        _drainLiquidity();

        uint256 shares = vault.convertToSharesRounded(
            MINIMUM_WITHDRAW,
            Math.Rounding.Ceil
        );

        vm.prank(user);
        vault.requestRedeem(shares, user, user);

        assertEq(vault.withdrawQueueLength(), 1);
        assertEq(vault.totalPendingWithdraws(), shares);
    }

    function test_requestRedeem_belowMinimum_doesNotLockShares() public {
        _depositAndClaim(user, 50 ether);
        _drainLiquidity();

        uint256 balanceBefore = vault.balanceOf(user);
        uint256 shares = vault.convertToShares(MINIMUM_WITHDRAW) - 1;

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISparkPrimeVault.MustExceedMinimumRequestAmount.selector,
                MINIMUM_WITHDRAW
            )
        );
        vault.requestRedeem(shares, user, user);

        assertEq(vault.balanceOf(user), balanceBefore);
        assertEq(vault.withdrawQueueLength(), 0);
        assertEq(vault.totalPendingWithdraws(), 0);

        vm.prank(user);
        vault.transfer(userTwo, balanceBefore);
        assertEq(vault.balanceOf(user), 0);
    }

    function test_cannot_requestRedeem_belowMinimum_onTheInstantClaimPath()
        public
    {
        _depositAndClaim(user, 50 ether);

        assertGt(vault.availableLiquidAssets(), 0);
        uint256 shares = vault.convertToShares(MINIMUM_WITHDRAW) - 1;

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISparkPrimeVault.MustExceedMinimumRequestAmount.selector,
                MINIMUM_WITHDRAW
            )
        );
        vault.requestRedeem(shares, user, user);

        assertEq(vault.maxRedeem(user), 0);
    }

    function test_requestRedeem_minimumIsDenominatedInAssets() public {
        _depositAndClaim(user, 50 ether);
        vm.warp(block.timestamp + 365 days);
        _depositAndClaim(userTwo, 10 ether);
        _drainLiquidity();

        assertGt(vault.index(), RAY);

        uint256 minShares = vault.convertToShares(MINIMUM_WITHDRAW);
        assertLt(minShares, MINIMUM_WITHDRAW);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISparkPrimeVault.MustExceedMinimumRequestAmount.selector,
                MINIMUM_WITHDRAW
            )
        );
        vault.requestRedeem(minShares - 1, user, user);

        vm.prank(user);
        vault.requestRedeem(minShares + 1, user, user);

        assertEq(vault.withdrawQueueLength(), 1);
    }

    function test_requestRedeem_zeroRevertsBeforeTheMinimumCheck() public {
        _depositAndClaim(user, 50 ether);
        _drainLiquidity();

        vm.prank(user);
        vm.expectRevert(ISparkPrimeVault.ZeroValueProvided.selector);
        vault.requestRedeem(0, user, user);
    }

    function test_requestRedeem_anyAmountWhenNoMinimumConfigured() public {
        _deployVaultWithMinimums(0, 0);
        _depositAndClaim(user, 50 ether);
        _drainLiquidity();

        assertEq(vault.minimumWithdraw(), 0);

        vm.prank(user);
        vault.requestRedeem(1 wei, user, user);

        assertEq(vault.withdrawQueueLength(), 1);
    }

    function _claimableRedeemer(uint256 amount) internal returns (uint256) {
        _depositAndClaim(user, amount);
        uint256 shares = vault.balanceOf(user);
        _nextBlock();
        _coverRedemption(shares);
        vm.prank(user);
        vault.requestRedeem(shares, user, user);
        return vault.maxRedeem(user);
    }

    function test_withdraw_claimsAssets() public {
        uint256 claimable = _claimableRedeemer(50 ether);
        uint256 claimValue = vault.maxWithdraw(user);
        uint256 held = baseAsset.balanceOf(address(vault));

        vm.prank(user);
        uint256 burned = vault.withdraw(claimValue, user, user);

        assertEq(burned, claimable);
        assertEq(baseAsset.balanceOf(user), claimValue);
        assertEq(baseAsset.balanceOf(address(vault)), held - claimValue);
        assertEq(vault.maxRedeem(user), 0);
        assertEq(vault.maxWithdraw(user), 0);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.balanceOf(user), 0);
    }

    function test_withdraw_FullClaim_NoSharesLeftBehind() public {
        _depositAndClaim(user, 50 ether);
        uint256 shares = vault.balanceOf(user);
        _coverRedemption(shares);
        _requestRedeem(user, shares);

        vault.setIndexRate((vault.index() * 10) / 3);
        _injectLiquidity(vault.maxWithdraw(user));

        uint256 claimValue = vault.maxWithdraw(user);
        assertGt(vault.maxRedeem(user), vault.convertToShares(claimValue));

        vm.prank(user);
        uint256 burned = vault.withdraw(claimValue, user, user);

        assertEq(burned, shares);
        assertEq(vault.maxRedeem(user), 0);
    }

    function test_redeem_paysTheRateFrozenAtMatchNotAtClaim() public {
        _depositAndClaim(user, 50 ether);
        _injectLiquidity(50 ether);

        uint256 shares = vault.balanceOf(user);
        _requestRedeem(user, shares);
        uint256 owed = vault.maxWithdraw(user);

        vm.warp(block.timestamp + 365 days);
        _depositAndClaim(userTwo, 10 ether);

        assertGt(
            vault.convertToAssets(shares),
            owed,
            "index climbed since the match"
        );

        uint256 claimable = vault.maxRedeem(user);
        vm.prank(user);
        uint256 paid = vault.redeem(claimable, user, user);

        assertEq(paid, owed, "payout frozen at the Claimable transition");
        assertEq(baseAsset.balanceOf(user), owed);
        assertEq(vault.maxWithdraw(user), 0);
    }

    function test_redeem_partialClaimsUseTheFrozenRatio() public {
        _depositAndClaim(user, 50 ether);
        _injectLiquidity(50 ether);

        uint256 shares = vault.balanceOf(user);
        _requestRedeem(user, shares);
        uint256 owed = vault.maxWithdraw(user);

        vm.warp(block.timestamp + 365 days);
        _depositAndClaim(userTwo, 10 ether);

        vm.startPrank(user);
        uint256 first = vault.redeem(shares / 2, user, user);
        assertEq(vault.maxWithdraw(user), owed - first);

        uint256 second = vault.redeem(vault.maxRedeem(user), user, user);
        vm.stopPrank();

        assertEq(first + second, owed, "no dust stranded across partials");
        assertEq(vault.maxRedeem(user), 0);
        assertEq(vault.maxWithdraw(user), 0);
    }

    function test_withdraw_toADifferentReceiver() public {
        _claimableRedeemer(50 ether);
        uint256 claimValue = vault.maxWithdraw(user);

        vm.prank(user);
        vault.withdraw(claimValue, userTwo, user);

        assertEq(baseAsset.balanceOf(userTwo), claimValue);
        assertEq(baseAsset.balanceOf(user), 0);
    }

    function test_withdraw_partialLeavesTheRemainderClaimable() public {
        uint256 claimable = _claimableRedeemer(50 ether);
        uint256 owed = vault.maxWithdraw(user);
        uint256 half = owed / 2;

        vm.prank(user);
        vault.withdraw(half, user, user);

        assertEq(baseAsset.balanceOf(user), half);
        assertEq(
            vault.maxRedeem(user),
            claimable - Math.mulDiv(claimable, half, owed, Math.Rounding.Ceil)
        );
    }

    function test_cannot_withdraw_beyondClaimableAmount() public {
        _claimableRedeemer(50 ether);
        uint256 owed = vault.maxWithdraw(user);
        uint256 tooMuch = owed + 1 ether;

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISparkPrimeVault.InsufficientClaimableAmount.selector,
                tooMuch,
                owed
            )
        );
        vault.withdraw(tooMuch, user, user);
    }

    function test_cannot_withdraw_asUnauthorizedCaller() public {
        _claimableRedeemer(50 ether);
        uint256 claimValue = vault.maxWithdraw(user);

        vm.prank(userTwo);
        vm.expectRevert(
            abi.encodeWithSelector(IVault.UnauthorizedCaller.selector, userTwo)
        );
        vault.withdraw(claimValue, userTwo, user);
    }

    function test_redeem_emitsErc4626Withdraw() public {
        uint256 claimable = _claimableRedeemer(50 ether);
        uint256 assets = vault.convertToAssets(claimable);

        vm.expectEmit(address(vault));
        emit IERC4626.Withdraw(user, user, user, assets, claimable);

        vm.prank(user);
        vault.redeem(claimable, user, user);
    }

    function test_withdraw_emitsErc4626Withdraw() public {
        uint256 burned = _claimableRedeemer(50 ether);
        uint256 claimValue = vault.maxWithdraw(user);

        vm.expectEmit(address(vault));
        emit IERC4626.Withdraw(user, user, user, claimValue, burned);

        vm.prank(user);
        vault.withdraw(claimValue, user, user);
    }

    function test_redeem_emitsWithdrawWithTheOperatorAsSender() public {
        uint256 claimable = _claimableRedeemer(50 ether);
        vault.setOperatorForUser(user, operator, true);
        uint256 assets = vault.convertToAssets(claimable);

        vm.expectEmit(address(vault));
        emit IERC4626.Withdraw(operator, user, user, assets, claimable);

        vm.prank(operator);
        vault.redeem(claimable, user, user);
    }

    function test_requestRedeem_movesSharesOutOfOwnerCustody() public {
        _depositAndClaim(user, 50 ether);
        _drainLiquidity();

        uint256 shares = vault.balanceOf(user);
        uint256 supplyBefore = vault.totalSupply();

        vm.prank(user);
        vault.requestRedeem(shares, user, user);

        assertEq(vault.balanceOf(user), 0);
        assertEq(vault.balanceOf(address(vault)), shares);
        assertEq(vault.totalSupply(), supplyBefore);
        assertEq(vault.pendingRedeemRequest(0, user), shares);
    }

    function test_requestRedeem_emitsTransferToTheVault() public {
        _depositAndClaim(user, 50 ether);
        _drainLiquidity();
        uint256 shares = vault.balanceOf(user);

        vm.expectEmit(address(vault));
        emit IERC20.Transfer(user, address(vault), shares);

        vm.prank(user);
        vault.requestRedeem(shares, user, user);
    }

    function test_cannot_requestRedeem_moreSharesThanHeld() public {
        _depositAndClaim(user, 50 ether);
        _drainLiquidity();
        uint256 shares = vault.balanceOf(user);

        vm.prank(user);
        vm.expectRevert();
        vault.requestRedeem(shares + 1, user, user);

        assertEq(vault.balanceOf(user), shares);
        assertEq(vault.withdrawQueueLength(), 0);
    }

    function test_cannot_requestRedeem_twiceWithTheSameShares() public {
        _depositAndClaim(user, 50 ether);
        _drainLiquidity();
        uint256 shares = vault.balanceOf(user);

        vm.prank(user);
        vault.requestRedeem(shares, user, user);

        vm.prank(user);
        vm.expectRevert();
        vault.requestRedeem(shares, user, user);
    }

    function test_requestRedeem_withSeparateControllerEscrowsFromTheOwner()
        public
    {
        _depositAndClaim(user, 50 ether);
        _drainLiquidity();
        uint256 shares = vault.balanceOf(user);

        vm.prank(user);
        vault.requestRedeem(shares, userTwo, user);

        assertEq(vault.balanceOf(user), 0);
        assertEq(vault.balanceOf(userTwo), 0);
        assertEq(vault.balanceOf(address(vault)), shares);
        assertEq(vault.pendingRedeemRequest(0, userTwo), shares);
        assertEq(vault.pendingRedeemRequest(0, user), 0);
    }

    function test_requestRedeem_burnsTheEscrowWhenItBecomesClaimable() public {
        _depositAndClaim(user, 50 ether);
        uint256 shares = vault.balanceOf(user);
        uint256 supply = vault.totalSupply();
        _coverRedemption(shares);

        vm.prank(user);
        vault.requestRedeem(shares, user, user);

        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.totalSupply(), supply - shares);
        assertEq(vault.maxRedeem(user), shares);
        assertEq(vault.maxWithdraw(user), vault.convertToAssets(shares));
    }

    function test_redeem_afterTheBurnLeavesNothingOutstanding() public {
        _depositAndClaim(user, 50 ether);
        uint256 shares = vault.balanceOf(user);
        _coverRedemption(shares);

        vm.prank(user);
        vault.requestRedeem(shares, user, user);

        uint256 claimable = vault.maxRedeem(user);
        vm.prank(user);
        vault.redeem(claimable, user, user);

        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.balanceOf(user), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalPendingWithdraws(), 0);
        assertEq(vault.claimableWithdrawTotal(), 0);
        assertEq(vault.availableCapacity(), MAXIMUM_VAULT_CAPACITY);
    }

    function test_requestRedeem_isNotPaidFromQueuedDeposits() public {
        _depositAndClaim(user, 50 ether);
        _drainLiquidity();
        _closeCapacity();
        _requestDeposit(userTwo, 11 ether);
        uint256 backing = savingsVault.balanceOf(address(vault));

        _requestRedeem(user, vault.convertToShares(10 ether));

        assertEq(vault.maxWithdraw(user), 0);
        assertEq(vault.withdrawQueueLength(), 1);
        assertEq(savingsVault.balanceOf(address(vault)), backing);

        uint256 volume = vault.convertToAssets(vault.totalPendingWithdraws());
        _absorbAccruedYield();
        vm.prank(rebalancer);
        vault.processQueue(volume);

        assertEq(vault.maxWithdraw(user), volume);
        assertGe(baseAsset.balanceOf(address(vault)), volume);
    }
}
