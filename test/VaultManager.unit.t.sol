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
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {USDC} from "./mocks/USDC.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {console} from "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {QueueHelper} from "./utils/QueueHelper.sol";
import {InterestLib} from "src/libraries/InterestLib.sol";
import {Vault} from "src/Vault.sol";
import {SavingsVault} from "./mocks/SavingsVault.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract VaultManagerUnitTests is QueueHelper {
    function setUp() public {
        _deployVault();
    }

    function test_cannot_setCapacity_belowCommitedSharesPlusMinted() public {
        _depositAndClaim(user, 50 ether);
        _requestDeposit(userTwo, 10 ether);
        uint256 committed = vault.totalSupply();
        assertGt(vault.claimableDepositTotal(), 0);

        vm.prank(vaultManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultManagement
                    .MaximumCapacityCannotExceedCurrentTotal
                    .selector
            )
        );
        vault.setCapacity(committed - 1);

        vm.prank(vaultManager);
        vault.setCapacity(committed);
        assertEq(vault.availableCapacity(), 0);
    }

    function test_depositToSavings() public {
        _depositAndClaim(user, 100 ether);
        uint256 expected = savingsVault.previewDeposit(40 ether);
        uint256 venueBefore = baseAsset.balanceOf(address(savingsVault));

        vm.prank(rebalancer);
        uint256 shares = vault.depositToSavings(40 ether);

        assertEq(shares, expected);
        assertEq(baseAsset.balanceOf(address(vault)), 60 ether);
        assertEq(
            baseAsset.balanceOf(address(savingsVault)),
            venueBefore + 40 ether
        );
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
        uint256 expected = savingsVault.previewRedeem(shares);

        vm.prank(rebalancer);
        uint256 assets = vault.withdrawFromSavings(shares);

        assertEq(assets, expected);
        assertApproxEqAbs(assets, 40 ether, 2);
        assertEq(baseAsset.balanceOf(address(vault)), 60 ether + assets);
        assertEq(savingsVault.balanceOf(address(vault)), 0);
    }

    function test_withdrawFromSavings_emitsSavingsWithdraw() public {
        _depositAndClaim(user, 100 ether);

        vm.prank(rebalancer);
        uint256 shares = vault.depositToSavings(40 ether);
        uint256 expected = savingsVault.previewRedeem(shares);

        vm.expectEmit(address(vault));
        emit IRebalancer.SavingsWithdraw(shares, expected);

        vm.prank(rebalancer);
        vault.withdrawFromSavings(shares);
    }

    function test_savingsRoundTrip_isValuePreserving() public {
        _depositAndClaim(user, 100 ether);
        uint256 before = baseAsset.balanceOf(address(vault));
        uint256 assetsBefore = vault.totalAssets();

        vm.startPrank(rebalancer);
        uint256 shares = vault.depositToSavings(before);
        vault.withdrawFromSavings(shares);
        vm.stopPrank();

        assertApproxEqAbs(baseAsset.balanceOf(address(vault)), before, 2);
        assertLe(baseAsset.balanceOf(address(vault)), before);
        assertEq(vault.totalAssets(), assetsBefore);
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
        uint256 assetsBefore = vault.totalAssets();

        vm.prank(rebalancer);
        vault.depositToSavings(40 ether);

        assertEq(vault.availableLiquidAssets(), int256(60 ether));
        assertEq(vault.totalAssets(), assetsBefore);
        assertApproxEqAbs(
            baseAsset.balanceOf(address(vault)) +
                savingsVault.convertToAssets(
                    savingsVault.balanceOf(address(vault))
                ),
            100 ether,
            2
        );
    }

    function test_depositToSavings_canStrandAClaimableRedeemer() public {
        _depositAndClaim(user, 100 ether);
        uint256 shares = vault.balanceOf(user);
        _coverRedemption(shares);

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

        uint256 atMinimum = vault.convertToSharesRounded(
            5 ether,
            Math.Rounding.Ceil
        );
        vm.prank(user);
        vault.requestRedeem(atMinimum, user, user);
        assertEq(vault.withdrawQueueLength(), 1);
    }

    function test_setMinimums_toZeroDisablesThem() public {
        vm.startPrank(vaultManager);
        vault.setMinimumDeposit(0);
        vault.setMinimumWithdraw(0);
        vm.stopPrank();

        uint256 smallest = vault.convertToAssetsRounded(2, Math.Rounding.Ceil);
        _requestDeposit(user, smallest);
        assertEq(vault.maxDeposit(user), smallest);
        assertGt(vault.maxMint(user), 0);
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

    function _pause() internal {
        vm.prank(vaultManager);
        vault.pause();
    }

    function _expectPaused() internal {
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    }

    function test_pause() public {
        assertFalse(vault.paused());

        vm.expectEmit(address(vault));
        emit PausableUpgradeable.Paused(vaultManager);
        _pause();

        assertTrue(vault.paused());
    }

    function test_unpause() public {
        _pause();

        vm.expectEmit(address(vault));
        emit PausableUpgradeable.Unpaused(admin);
        vm.prank(admin);
        vault.unpause();

        assertFalse(vault.paused());
    }

    function test_cannot_pause_withoutVaultManagerRole() public {
        vm.prank(rebalancer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                rebalancer,
                VAULT_MANAGER_ROLE
            )
        );
        vault.pause();
    }

    function test_cannot_unpause_withoutAdminRole() public {
        _pause();

        vm.prank(vaultManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                vaultManager,
                DEFAULT_ADMIN_ROLE
            )
        );
        vault.unpause();
    }

    function test_paused_blocksRequestDeposit() public {
        _fund(user, 10 ether);
        _pause();

        vm.prank(user);
        _expectPaused();
        vault.requestDeposit(10 ether, user, user);
    }

    function test_paused_blocksDeposit() public {
        _requestDeposit(user, 10 ether);
        _pause();

        vm.prank(user);
        _expectPaused();
        vault.deposit(10 ether, user);

        vm.prank(user);
        _expectPaused();
        vault.deposit(10 ether, user, user);

        vm.prank(user);
        _expectPaused();
        vault.deposit(10 ether, user, user, 1);
    }

    function test_paused_blocksMint() public {
        _requestDeposit(user, 10 ether);
        uint256 shares = vault.convertToShares(10 ether);
        _pause();

        vm.prank(user);
        _expectPaused();
        vault.mint(shares, user);

        vm.prank(user);
        _expectPaused();
        vault.mint(shares, user, user);
    }

    function test_paused_blocksRequestRedeem() public {
        _depositAndClaim(user, 50 ether);
        _drainLiquidity();
        uint256 shares = vault.balanceOf(user);
        _pause();

        vm.prank(user);
        _expectPaused();
        vault.requestRedeem(shares, user, user);
    }

    function test_paused_blocksRedeemAndWithdraw() public {
        _depositAndClaim(user, 50 ether);
        uint256 shares = vault.balanceOf(user);
        vm.prank(user);
        vault.requestRedeem(shares, user, user);

        uint256 claimable = vault.maxRedeem(user);
        uint256 claimValue = vault.maxWithdraw(user);
        _pause();

        vm.prank(user);
        _expectPaused();
        vault.redeem(claimable, user, user);

        vm.prank(user);
        _expectPaused();
        vault.withdraw(claimValue, user, user);
    }

    function test_paused_doesNotBlockProcessQueueOrTake() public {
        _depositAndClaim(user, 50 ether);
        _drainLiquidity();

        uint256 shares = vault.balanceOf(user);
        vm.prank(user);
        vault.requestRedeem(shares, user, user);
        assertEq(vault.withdrawQueueLength(), 1);

        uint256 volume = vault.convertToAssets(vault.totalPendingWithdraws());
        _injectLiquidity(volume);
        _pause();

        vm.prank(rebalancer);
        vault.processQueue(volume);
        assertEq(vault.withdrawQueueLength(), 0);

        vm.prank(liquidityManager);
        vault.take(1 ether);
    }

    function test_paused_maxViewsReportNothingClaimable() public {
        _depositAndClaim(user, 50 ether);
        uint256 half = vault.balanceOf(user) / 2;
        _coverRedemption(half);
        _requestRedeem(user, half);
        _requestDeposit(user, 10 ether);

        uint256 claimableAssets = vault.maxDeposit(user);
        uint256 lockedShares = vault.maxMint(user);
        uint256 claimableShares = vault.maxRedeem(user);
        uint256 owed = vault.maxWithdraw(user);
        assertGt(claimableAssets, 0);
        assertGt(lockedShares, 0);
        assertGt(claimableShares, 0);
        assertGt(owed, 0);

        _pause();

        assertEq(vault.maxDeposit(user), 0);
        assertEq(vault.maxMint(user), 0);
        assertEq(vault.maxRedeem(user), 0);
        assertEq(vault.maxWithdraw(user), 0);
        assertEq(vault.claimableDepositRequest(0, user), claimableAssets);
        assertEq(vault.claimableRedeemRequest(0, user), claimableShares);

        vm.prank(admin);
        vault.unpause();

        assertEq(vault.maxDeposit(user), claimableAssets);
        assertEq(vault.maxMint(user), lockedShares);
        assertEq(vault.maxRedeem(user), claimableShares);
        assertEq(vault.maxWithdraw(user), owed);
    }

    function test_paused_doesNotBlockSetOperator() public {
        _pause();

        vm.prank(user);
        vault.setOperator(operator, true);
        assertTrue(vault.isOperator(user, operator));
    }

    function test_unpause_restoresEveryEntryPoint() public {
        _depositAndClaim(user, 50 ether);
        uint256 shares = vault.balanceOf(user);
        _pause();

        vm.prank(admin);
        vault.unpause();

        _requestDeposit(userTwo, 10 ether);
        vm.prank(userTwo);
        vault.deposit(10 ether, userTwo);

        vm.prank(user);
        vault.requestRedeem(shares, user, user);

        uint256 claimable = vault.maxRedeem(user);
        vm.prank(user);
        vault.redeem(claimable, user, user);
    }

    function test_cannot_setInterestRate_belowRay() public {
        vm.prank(vaultManager);
        vm.expectRevert(IVaultManagement.InterestRateBelowRay.selector);
        vault.setInterestRate(RAY - 1);

        vm.prank(vaultManager);
        vault.setInterestRate(RAY);
        assertEq(vault.interestRate(), RAY);
    }

    function test_setInterestRate_accruesAtTheOldRateFirst() public {
        vm.warp(block.timestamp + 365 days);
        uint256 accrued = vault.previewIndex();
        assertGt(accrued, vault.index());

        vm.prank(vaultManager);
        vault.setInterestRate(RAY);

        assertEq(vault.index(), accrued);
        assertEq(vault.lastAccrual(), block.timestamp);

        vm.warp(block.timestamp + 365 days);
        assertEq(vault.previewIndex(), accrued);
    }

    function test_setTotalAssets_reportsTheLoss() public {
        _depositAndClaim(user, 50 ether);
        uint256 indexValue = vault.totalAssets();
        uint256 held = vault.convertToAssets(vault.balanceOf(user));
        uint256 target = (indexValue * 9) / 10;

        _pause();
        vm.prank(vaultManager);
        vault.setTotalAssets(target);

        assertEq(vault.totalAssets(), target);
        assertApproxEqAbs(
            vault.convertToAssets(vault.balanceOf(user)),
            (held * 9) / 10,
            1
        );
    }

    function test_setTotalAssets_keepsTrackingSupplyAndInterest() public {
        _depositAndClaim(user, 50 ether);
        uint256 target = vault.totalAssets() / 2;
        _pause();
        vm.prank(vaultManager);
        vault.setTotalAssets(target);
        vm.prank(admin);
        vault.unpause();

        vm.warp(block.timestamp + 365 days);
        _depositAndClaim(userTwo, 10 ether);

        assertGt(vault.totalAssets(), target);
        assertApproxEqAbs(
            vault.convertToAssets(vault.balanceOf(user)),
            vault.totalAssets() - 10 ether,
            _drift(10 ether)
        );
    }

    function test_setTotalAssets_sharesTheLossProRata() public {
        _depositAndClaim(user, 50 ether);
        _depositAndClaim(userTwo, 50 ether);
        uint256 target = (vault.totalAssets() * 6) / 10;
        _pause();
        vm.prank(vaultManager);
        vault.setTotalAssets(target);
        vm.prank(admin);
        vault.unpause();

        uint256 shares = vault.balanceOf(user);
        _coverRedemption(shares);
        _requestRedeem(user, shares);

        assertApproxEqAbs(vault.maxWithdraw(user), 30 ether, _drift(30 ether));
        assertApproxEqAbs(
            vault.convertToAssets(vault.balanceOf(userTwo)),
            30 ether,
            _drift(30 ether)
        );
    }

    function test_setTotalAssets_accruesFirst() public {
        _depositAndClaim(user, 50 ether);
        vm.warp(block.timestamp + 30 days);
        uint256 indexValue = Math.mulDiv(
            vault.totalSupply(),
            vault.previewIndex(),
            RAY
        );
        uint256 target = indexValue / 2;

        _pause();
        vm.prank(vaultManager);
        vault.setTotalAssets(target);

        assertEq(vault.lastAccrual(), block.timestamp);
        assertEq(vault.totalAssets(), target);
    }

    function test_cannot_setTotalAssets_aboveTheIndexValue() public {
        _depositAndClaim(user, 50 ether);
        uint256 indexValue = vault.totalAssets();

        _pause();
        vm.prank(vaultManager);
        vm.expectRevert(IVaultManagement.TotalAssetsExceedIndexValue.selector);
        vault.setTotalAssets(indexValue + 1);
    }

    function test_cannot_setTotalAssets_whenNotPaused() public {
        _depositAndClaim(user, 50 ether);
        uint256 target = vault.totalAssets() / 2;

        vm.prank(vaultManager);
        vm.expectRevert(PausableUpgradeable.ExpectedPause.selector);
        vault.setTotalAssets(target);
    }

    function test_cannot_setTotalAssets_toZero() public {
        _depositAndClaim(user, 50 ether);

        _pause();
        vm.prank(vaultManager);
        vm.expectRevert(ISparkPrimeVault.ZeroValueProvided.selector);
        vault.setTotalAssets(0);
    }

    function test_cannot_setTotalAssets_withoutVaultManagerRole() public {
        _depositAndClaim(user, 50 ether);
        uint256 target = vault.totalAssets() / 2;

        vm.prank(rebalancer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                rebalancer,
                VAULT_MANAGER_ROLE
            )
        );
        vault.setTotalAssets(target);
    }

    function test_setTotalAssets_emitsTotalAssetsUpdated() public {
        _depositAndClaim(user, 50 ether);
        uint256 current = vault.totalAssets();

        _pause();
        vm.expectEmit(address(vault));
        emit IVaultManagement.TotalAssetsUpdated(current, current / 2);
        vm.prank(vaultManager);
        vault.setTotalAssets(current / 2);
    }


    function test_setCapacity_emitsCapacityUpdated() public {
        uint256 old = vault.maxCapacity();

        vm.expectEmit(address(vault));
        emit IVaultManagement.CapacityUpdated(old, old + 50 ether);

        vm.prank(vaultManager);
        vault.setCapacity(old + 50 ether);

        assertEq(vault.maxCapacity(), old + 50 ether);
    }

    function test_accrueInterest_emitsAccruedInterest() public {
        _requestDeposit(user, 10 ether);
        vm.warp(block.timestamp + 365 days);

        uint256 expected = vault.previewIndex();

        vm.expectEmit(address(vault));
        emit IVault.AccruedInterest(expected, block.timestamp);

        vm.prank(user);
        vault.deposit(10 ether, user);

        assertEq(vault.index(), expected);
        assertGt(expected, RAY);
    }

    function test_cannot_accrueInterest_emitTwiceInTheSameBlock() public {
        _requestDeposit(user, 10 ether);
        vm.warp(block.timestamp + 365 days);

        vm.prank(user);
        vault.deposit(5 ether, user);
        uint256 index = vault.index();

        vm.recordLogs();
        vm.prank(user);
        vault.deposit(5 ether, user);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0] != IVault.AccruedInterest.selector,
                "accrued with no time elapsed"
            );
        }
        assertEq(vault.index(), index);
    }

    function test_convertToShares_honoursTheRoundingArgument() public {
        vault.setIndexRate(3e27);

        assertEq(
            vault.convertToSharesRounded(10, Math.Rounding.Floor),
            3,
            "floor"
        );
        assertEq(
            vault.convertToSharesRounded(10, Math.Rounding.Ceil),
            4,
            "ceil"
        );
    }

    function test_convertToAssets_honoursTheRoundingArgument() public {
        vault.setIndexRate((RAY * 10) / 3);

        assertEq(
            vault.convertToAssetsRounded(1, Math.Rounding.Floor),
            3,
            "floor"
        );
        assertEq(
            vault.convertToAssetsRounded(1, Math.Rounding.Ceil),
            4,
            "ceil"
        );
    }

    function test_publicConvertersStillFloor() public {
        vault.setIndexRate(3e27);

        assertEq(vault.convertToShares(10), 3);
        assertEq(vault.convertToAssets(1), 3);
    }

    function _initParams(
        IERC4626 venue
    ) internal view returns (IVault.InitParams memory) {
        return
            IVault.InitParams({
                name: "spPrime Vault",
                symbol: "spPRIME",
                baseAsset: baseAsset,
                savingsVault: venue,
                minimumDeposit: MINIMUM_DEPOSIT,
                minimumWithdraw: MINIMUM_WITHDRAW,
                capacity: MAXIMUM_VAULT_CAPACITY,
                ratePerSecond: TEN_PERCENT_APY,
                admin: admin,
                vaultManager: vaultManager,
                liquidityManager: liquidityManager,
                rebalancer: rebalancer
            });
    }

    function test_cannot_initialize_withASavingsVaultForAnotherAsset() public {
        IERC4626 venue = new SavingsVault(new USDC());
        VaultHandler implementation = new VaultHandler();
        IVault.InitParams memory params = _initParams(venue);

        vm.expectRevert(IVault.AssetMismatch.selector);
        new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(Vault.initialize, (params))
        );
    }

    function test_cannot_initialize_withoutASavingsVault() public {
        VaultHandler implementation = new VaultHandler();
        IVault.InitParams memory params = _initParams(IERC4626(address(0)));

        vm.expectRevert();
        new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(Vault.initialize, (params))
        );
    }

    function _rpowNearest(
        uint256 x,
        uint256 n
    ) internal pure returns (uint256 z) {
        z = n % 2 == 1 ? x : RAY;
        for (n /= 2; n != 0; n /= 2) {
            x = (x * x + RAY / 2) / RAY;
            if (n % 2 == 1) z = (z * x + RAY / 2) / RAY;
        }
    }

    function testFuzz_rpow_roundsToNearestLikeSky(
        uint256 rate,
        uint256 elapsed
    ) public pure {
        rate = bound(rate, RAY, RAY + 1e19);
        elapsed = bound(elapsed, 0, 10 * 365 days);

        assertEq(InterestLib._rpow(rate, elapsed), _rpowNearest(rate, elapsed));
    }

    function test_rpow_compoundsTheConfiguredRate() public pure {
        assertEq(InterestLib._rpow(TEN_PERCENT_APY, 0), RAY);
        assertEq(InterestLib._rpow(TEN_PERCENT_APY, 1), TEN_PERCENT_APY);
        assertEq(InterestLib._rpow(RAY, 365 days), RAY);
        assertEq(InterestLib._rpow(0, 0), RAY);
        assertEq(InterestLib._rpow(0, 365 days), 0);
        assertApproxEqRel(
            InterestLib._rpow(TEN_PERCENT_APY, 365 days),
            (RAY * 11) / 10,
            1e9
        );
    }
}
