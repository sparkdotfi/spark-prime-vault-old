// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VaultHandler} from "./VaultHandler.t.sol";
import {IVault} from "src/interfaces/IVault.sol";
import {ISparkPrimeVault} from "src/interfaces/ISparkPrimeVault.sol";
import {IVaultManagement} from "src/interfaces/IVaultManagement.sol";
import {IRebalancer} from "src/interfaces/IRebalancer.sol";
import {
    IAccessControl
} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {USDC} from "./mocks/USDC.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {console} from "forge-std/console.sol";
import {QueueHelper} from "./utils/QueueHelper.sol";

contract VaultManagerUnitTests is QueueHelper {
    function setUp() public {
        _deployVault();
    }

    function test_cannot_setCapacity_overTotalAssets() public {
        _fundAndDeposit(vault, user, baseAsset, 100 ether);

        vm.prank(user);
        vault.deposit(100 ether, user);

        assertEq(vault.totalAssets(), 100 ether);

        vm.prank(vaultManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultManagement
                    .MaximumCapacityCannotExceedCurrentTotal
                    .selector
            )
        );
        vault.setCapacity(50 ether);
    }

    function test_depositToSavings() public {
        _depositAndClaim(user, 100 ether);

        vm.prank(rebalancer);
        uint256 shares = vault.depositToSavings(40 ether);

        assertEq(shares, savingsVault.convertToShares(40 ether));
        assertEq(baseAsset.balanceOf(address(vault)), 60 ether);
        assertEq(baseAsset.balanceOf(address(savingsVault)), 40 ether);
        assertEq(savingsVault.balanceOf(address(vault)), shares);
    }

    function test_depositToSavings_emitsSavingsDeposit() public {
        _depositAndClaim(user, 100 ether);

        uint256 expected = savingsVault.convertToShares(40 ether);
        vm.expectEmit(address(vault));
        emit IRebalancer.SavingsDeposit(40 ether, expected);

        vm.prank(rebalancer);
        vault.depositToSavings(40 ether);
    }

    function test_withdrawFromSavings() public {
        _depositAndClaim(user, 100 ether);

        vm.prank(rebalancer);
        uint256 shares = vault.depositToSavings(40 ether);

        vm.prank(rebalancer);
        uint256 assets = vault.withdrawFromSavings(shares);

        assertEq(assets, 40 ether);
        assertEq(baseAsset.balanceOf(address(vault)), 100 ether);
        assertEq(savingsVault.balanceOf(address(vault)), 0);
    }

    function test_withdrawFromSavings_emitsSavingsWithdraw() public {
        _depositAndClaim(user, 100 ether);

        vm.prank(rebalancer);
        uint256 shares = vault.depositToSavings(40 ether);

        vm.expectEmit(address(vault));
        emit IRebalancer.SavingsWithdraw(shares, 40 ether);

        vm.prank(rebalancer);
        vault.withdrawFromSavings(shares);
    }

    function test_savingsRoundTrip_isValuePreserving() public {
        _depositAndClaim(user, 100 ether);
        uint256 before = baseAsset.balanceOf(address(vault));

        vm.startPrank(rebalancer);
        uint256 shares = vault.depositToSavings(before);
        vault.withdrawFromSavings(shares);
        vm.stopPrank();

        assertEq(baseAsset.balanceOf(address(vault)), before);
        assertEq(vault.totalAssets(), 100 ether);
    }

    function test_cannot_depositToSavings_withoutRebalancerRole() public {
        _depositAndClaim(user, 100 ether);

        vm.prank(vaultManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                vaultManager,
                REBALANCER_ROLER
            )
        );
        vault.depositToSavings(1 ether);
    }

    function test_cannot_withdrawFromSavings_withoutRebalancerRole() public {
        _depositAndClaim(user, 100 ether);

        vm.prank(rebalancer);
        uint256 shares = vault.depositToSavings(40 ether);

        vm.prank(liquidityManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                liquidityManager,
                REBALANCER_ROLER
            )
        );
        vault.withdrawFromSavings(shares);
    }

    function test_cannot_withdrawFromSavings_moreThanTheVaultHolds() public {
        _depositAndClaim(user, 100 ether);

        vm.prank(rebalancer);
        uint256 shares = vault.depositToSavings(40 ether);

        vm.prank(rebalancer);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC4626ExceededMaxRedeem(address,uint256,uint256)",
                address(vault),
                shares + 1,
                shares
            )
        );
        vault.withdrawFromSavings(shares + 1);
    }

    function test_cannot_depositToSavings_moreThanTheVaultHolds() public {
        _depositAndClaim(user, 100 ether);

        vm.prank(rebalancer);
        vm.expectRevert();
        vault.depositToSavings(101 ether);
    }

    function test_depositToSavings_isInvisibleToAvailableLiquidAssets() public {
        _depositAndClaim(user, 100 ether);
        assertEq(vault.availableLiquidAssets(), int256(100 ether));

        vm.prank(rebalancer);
        vault.depositToSavings(40 ether);

        assertEq(vault.availableLiquidAssets(), int256(60 ether));
        assertEq(vault.totalAssets(), 100 ether);
        assertEq(
            baseAsset.balanceOf(address(vault)) +
                savingsVault.convertToAssets(
                    savingsVault.balanceOf(address(vault))
                ),
            100 ether
        );
    }

    function test_depositToSavings_canStrandAClaimableRedeemer() public {
        _depositAndClaim(user, 100 ether);
        uint256 shares = vault.balanceOf(user);

        vm.prank(user);
        vault.requestRedeem(shares, user, user);
        assertEq(vault.maxRedeem(user), shares);

        vm.prank(rebalancer);
        vault.depositToSavings(40 ether);

        vm.prank(user);
        vm.expectRevert();
        vault.redeem(shares, user, user);
    }

    function test_setMinimumDeposit() public {
        vm.expectEmit(address(vault));
        emit IVaultManagement.MinimumDepositUpdated(5 ether);

        vm.prank(vaultManager);
        vault.setMinimumDeposit(5 ether);

        assertEq(vault.minimumDeposit(), 5 ether);
    }

    function test_setMinimumDeposit_isEnforcedOnTheNextRequest() public {
        vm.prank(vaultManager);
        vault.setMinimumDeposit(5 ether);

        _fund(user, 4 ether);
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISparkPrimeVault.MustExceedMinimumRequestAmount.selector,
                5 ether
            )
        );
        vault.requestDeposit(4 ether, user, user);

        _requestDeposit(user, 5 ether);
        assertEq(vault.maxDeposit(user), 5 ether);
    }

    function test_setMinimumWithdraw() public {
        vm.expectEmit(address(vault));
        emit IVaultManagement.MinimumWithdrawUpdated(5 ether);

        vm.prank(vaultManager);
        vault.setMinimumWithdraw(5 ether);

        assertEq(vault.minimumWithdraw(), 5 ether);
    }

    function test_setMinimumWithdraw_isEnforcedOnTheNextRequest() public {
        _depositAndClaim(user, 50 ether);
        _drainLiquidity();

        vm.prank(vaultManager);
        vault.setMinimumWithdraw(5 ether);

        uint256 shares = vault.convertToShares(4 ether);
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISparkPrimeVault.MustExceedMinimumRequestAmount.selector,
                5 ether
            )
        );
        vault.requestRedeem(shares, user, user);

        uint256 atMinimum = vault.convertToShares(5 ether);
        vm.prank(user);
        vault.requestRedeem(atMinimum, user, user);
        assertEq(vault.withdrawQueueLength(), 1);
    }

    function test_setMinimums_toZeroDisablesThem() public {
        vm.startPrank(vaultManager);
        vault.setMinimumDeposit(0);
        vault.setMinimumWithdraw(0);
        vm.stopPrank();

        _requestDeposit(user, 1 wei);
        assertEq(vault.maxDeposit(user), 1 wei);
    }

    function test_cannot_setMinimumDeposit_withoutVaultManagerRole() public {
        vm.prank(rebalancer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                rebalancer,
                VAULT_MANAGER_ROLE
            )
        );
        vault.setMinimumDeposit(5 ether);
    }

    function test_cannot_setMinimumWithdraw_withoutVaultManagerRole() public {
        vm.prank(rebalancer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                rebalancer,
                VAULT_MANAGER_ROLE
            )
        );
        vault.setMinimumWithdraw(5 ether);
    }
}
