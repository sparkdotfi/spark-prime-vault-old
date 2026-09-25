// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {QueueHelper} from "./utils/QueueHelper.sol";
import {IQueue} from "src/interfaces/IQueue.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract QueueSolvencyTests is QueueHelper {
    bytes32 constant TRANSFER_SIG =
        keccak256("Transfer(address,address,uint256)");

    function setUp() public {
        _deployVault();
    }

    function createOneUserList(
        address who
    ) internal pure returns (address[] memory u) {
        u = new address[](1);
        u[0] = who;
    }

    function test_depositQueue_isFunded() public {
        _closeCapacity();
        uint256 queued = createDepositQueue(10, 100 ether, defaultUsers());

        assertEq(vault.depositQueueLength(), 10, "ten entries");
        assertEq(assetsHeld(), 0, "queued assets leave the vault balance");
        assertEq(
            vault.totalPendingDeposits(),
            savingsVault.balanceOf(address(vault)),
            "queue total is the savings position"
        );
        assertApproxEqAbs(
            savingsVault.previewRedeem(vault.totalPendingDeposits()),
            queued,
            _drift(queued),
            "vault holds queued assets in savings"
        );
        assertSolvent();
    }

    function test_withdrawQueue_isFunded() public {
        _ensureCapacity(50 ether);
        _mintShares(5, 50 ether, defaultUsers());

        _drainLiquidity();

        uint256 queued = createWithdrawQueue(
            5,
            vault.convertToShares(50 ether),
            defaultUsers()
        );

        assertEq(vault.withdrawQueueLength(), 5, "five entries");
        assertEq(
            vault.totalPendingWithdraws(),
            queued,
            "queued total becomes pending"
        );
        assertGt(vault.totalSupply(), 0, "shares granted");
        assertSolvent();
    }

    function test_withdrawQueueCanExistWithoutDepositQueue() public {
        _ensureCapacity(40 ether);
        _mintShares(4, 40 ether, defaultUsers());
        _drainLiquidity();

        createWithdrawQueue(4, vault.convertToShares(40 ether), defaultUsers());

        assertEq(vault.withdrawQueueLength(), 4, "withdraw queue exists");
        assertEq(vault.depositQueueLength(), 0, "deposit queue doesnt exist");
    }

    function test_symmetricMatch_staysSolvent() public {
        _ensureCapacity(50 ether);
        _mintShares(5, 50 ether, defaultUsers());
        _drainLiquidity();
        createWithdrawQueue(5, vault.convertToShares(50 ether), defaultUsers());

        _closeCapacity();
        uint256 deposits = createDepositQueue(5, 50 ether, defaultUsers());

        assertEq(assetsHeld(), 0, "deposited funds wait in savings");
        assertApproxEqAbs(
            savingsVault.previewRedeem(vault.totalPendingDeposits()),
            deposits,
            _drift(deposits),
            "deposited funds become liquidity for withdrawers"
        );

        uint256 volume = _matchVolume();
        _absorbAccruedYield();
        vm.prank(rebalancer);
        vault.processQueue(volume);

        assertApproxEqAbs(
            vault.convertToAssets(vault.totalPendingWithdraws()),
            0,
            _drift(volume),
            "fulfilled withdrawers"
        );
        assertApproxEqAbs(
            savingsVault.previewRedeem(vault.totalPendingDeposits()),
            0,
            _drift(volume),
            "depositors fulfilled with potential dust"
        );
        assertSolvent();
    }

    function test_symmetricMatch_dustIsSweptByNextCall() public {
        _ensureCapacity(50 ether);

        vm.warp(block.timestamp + 1);

        _mintShares(5, 50 ether, defaultUsers());
        _drainLiquidity();
        createWithdrawQueue(5, vault.convertToShares(50 ether), defaultUsers());

        _closeCapacity();
        createDepositQueue(5, 50.001 ether + _drift(50 ether), defaultUsers());

        uint256 volume = vault.convertToAssets(vault.totalPendingWithdraws());
        _absorbAccruedYield();
        vm.prank(rebalancer);
        vault.processQueue(volume);

        uint256 dust = savingsVault.previewRedeem(vault.totalPendingDeposits());
        assertGt(dust, 0, "dust entry survives");
        assertEq(vault.depositQueueLength(), 1, "queue not empty");

        /// cant sweep immediately because no liquidity
        vm.prank(rebalancer);
        vm.expectRevert(IQueue.CapacityExceedsLiquidity.selector);
        vault.processQueue(dust);

        // boost capacity to give liquidity
        _setCapacity(vault.totalAssets() + 51 ether + dust);

        vm.prank(rebalancer);
        vault.processQueue(dust);

        assertEq(
            vault.depositQueueLength(),
            0,
            "second process queue collects dust"
        );
        assertSolvent();
    }

    function test_cannotMatchMoreThanTheVaultCanFund() public {
        _ensureCapacity(100 ether);
        _mintShares(5, 100 ether, defaultUsers());
        _drainLiquidity();
        uint256 shares = createWithdrawQueue(
            5,
            vault.convertToShares(100 ether),
            defaultUsers()
        );

        _closeCapacity();
        createDepositQueue(2, 20 ether, defaultUsers());
        assertEq(assetsHeld(), 0);
        assertApproxEqAbs(
            savingsVault.previewRedeem(vault.totalPendingDeposits()),
            20 ether,
            ROUNDING_DUST
        );

        uint256 fullDemand = vault.convertToAssets(shares);
        vm.prank(rebalancer);
        vm.expectRevert(IQueue.CapacityExceedsLiquidity.selector);
        vault.processQueue(fullDemand);

        _absorbAccruedYield();
        vm.prank(rebalancer);
        vault.processQueue(20 ether);
        assertSolvent();
    }

    function test_oneSidedWithdrawQueue_fundedByInjectedCapital() public {
        _ensureCapacity(40 ether);
        _mintShares(4, 40 ether, defaultUsers());
        _drainLiquidity();
        uint256 shares = createWithdrawQueue(
            4,
            vault.convertToShares(40 ether),
            defaultUsers()
        );
        assertEq(assetsHeld(), 0, "no liquidity");

        vm.prank(rebalancer);
        vm.expectRevert(IQueue.CapacityExceedsLiquidity.selector);
        vault.processQueue(1 ether);

        uint256 volume = vault.convertToAssets(shares);
        _injectLiquidity(volume);

        vm.prank(rebalancer);
        vault.processQueue(volume);

        assertEq(vault.withdrawQueueLength(), 0, "withdraws fulfilled");
        assertEq(vault.depositQueueLength(), 0, "deposits empty");

        assertSolvent();
    }

    function test_asymmetricLengths() public {
        _ensureCapacity(80 ether);
        _mintShares(20, 80 ether, defaultUsers());
        _drainLiquidity();
        createWithdrawQueue(
            20,
            vault.convertToShares(80 ether),
            defaultUsers()
        );

        _closeCapacity();
        createDepositQueue(3, 30 ether, defaultUsers());

        uint256 volume = savingsVault.previewRedeem(vault.totalPendingDeposits());
        _absorbAccruedYield();
        vm.prank(rebalancer);
        vault.processQueue(volume);

        assertEq(vault.depositQueueLength(), 0, "smaller queue fulfilled");
        assertGt(
            vault.withdrawQueueLength(),
            0,
            "larger queue partially fulfilled"
        );

        assertSolvent();
    }

    function test_takeAfterMatching_makesVaultInsolvent() public {
        _ensureCapacity(40 ether);
        _mintShares(4, 40 ether, defaultUsers());
        _drainLiquidity();
        uint256 shares = createWithdrawQueue(
            4,
            vault.convertToShares(40 ether),
            defaultUsers()
        );

        uint256 volume = vault.convertToAssets(shares);
        _injectLiquidity(volume);
        vm.prank(rebalancer);
        vault.processQueue(volume);
        assertSolvent();

        /// simulate PAU pulling funds that were commited to claimers
        _drainLiquidity();

        assertInsolvent();
    }

    function test_pendingEscrowIsHeldButNotDeliverable() public {
        _mintShares(1, 100 ether, defaultUsers());
        _drainLiquidity();

        uint256 shares = createWithdrawQueue(
            1,
            vault.balanceOf(user),
            defaultUsers()
        );

        assertEq(
            vault.balanceOf(address(vault)),
            shares,
            "vault holds shares in escrow"
        );
        assertEq(vault.balanceOf(user), 0, "no longer in owner custody");
        assertEq(
            vault.totalMintableShares(),
            0,
            "mintable shares shouldnt increase"
        );
        assertEq(
            vault.availableLiquidShares(),
            0,
            "liquid shares shouldnt increase"
        );
        assertSolvent();
    }

    function test_matchedDepositIsClaimableBeforeTheRedeemerClaims() public {
        _mintShares(1, 100 ether, defaultUsers());
        _drainLiquidity();
        uint256 shares = createWithdrawQueue(
            1,
            vault.convertToShares(100 ether),
            defaultUsers()
        );

        createDepositQueue(1, 101 ether, createOneUserList(userTwo));

        uint256 volume = vault.convertToAssets(shares);
        _absorbAccruedYield();
        vm.prank(rebalancer);
        vault.processQueue(volume);

        uint256 claimable = vault.claimableDepositRequest(0, userTwo);
        assertGt(claimable, 0, "amount claimable");
        assertGt(vault.claimableRedeemRequest(0, user), 0, "redeem claimable");

        vm.prank(userTwo);
        vault.deposit(claimable, userTwo);

        assertGt(vault.balanceOf(userTwo), 0, "depositor claims first");

        uint256 redeemable = vault.maxRedeem(user);
        vm.prank(user);
        vault.redeem(redeemable, user, user);

        assertEq(
            baseAsset.balanceOf(user),
            volume,
            "withdrawer still fulfilled"
        );
        assertSolvent();
    }

    function test_matchedEscrowIsBurnedAtProcessing() public {
        _mintShares(1, 100 ether, defaultUsers());
        _drainLiquidity();
        uint256 shares = createWithdrawQueue(
            1,
            vault.balanceOf(user),
            defaultUsers()
        );
        createDepositQueue(1, 101 ether, createOneUserList(userTwo));

        assertEq(vault.availableLiquidShares(), 0, "escrow in pending");

        uint256 volume = vault.convertToAssets(shares);
        _absorbAccruedYield();
        vm.prank(rebalancer);
        vault.processQueue(volume);

        assertEq(vault.totalPendingWithdraws(), 0, "escrow no longer pending");
        assertEq(
            vault.balanceOf(address(vault)),
            0,
            "matched escrow is burned, not retained"
        );
        assertEq(vault.totalSupply(), 0, "supply retired with it");
        assertSolvent();
    }

    function test_escrowIsPendingOnlyAcrossAFullCycle() public {
        _mintShares(1, 100 ether, defaultUsers());
        _drainLiquidity();
        uint256 shares = createWithdrawQueue(
            1,
            vault.convertToShares(100 ether),
            defaultUsers()
        );

        assertEq(vault.balanceOf(address(vault)), shares);
        assertEq(vault.totalPendingWithdraws(), shares);
        assertSolvent();

        uint256 volume = vault.convertToAssets(shares);
        _injectLiquidity(volume);
        vm.prank(rebalancer);
        vault.processQueue(volume);

        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.totalPendingWithdraws(), 0);
        assertSolvent();
    }

    function test_fullRoundTripRestoresCapacity() public {
        assertEq(vault.availableCapacity(), MAXIMUM_VAULT_CAPACITY);

        _depositAndClaim(user, 100 ether);
        assertEq(vault.availableCapacity(), 0, "cap consumed");

        uint256 shares = vault.balanceOf(user);
        _coverRedemption(shares);
        _requestRedeem(user, shares);
        uint256 claimable = vault.maxRedeem(user);
        vm.prank(user);
        vault.redeem(claimable, user, user);

        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);
        assertEq(
            vault.availableCapacity(),
            MAXIMUM_VAULT_CAPACITY,
            "capacity returns, vault reopens"
        );
    }

    function test_capacityIsUnchangedAcrossADepositClaim() public {
        _requestDeposit(user, 40 ether);

        uint256 before = vault.availableCapacity();
        vm.prank(user);
        vault.deposit(40 ether, user);

        assertEq(vault.availableCapacity(), before);
    }

    function test_accruedYieldDoesNotStrandCapacity() public {
        _depositAndClaim(user, 50 ether);
        vm.warp(block.timestamp + 365 days);
        _injectLiquidity(50 ether);

        uint256 shares = vault.balanceOf(user);
        _requestRedeem(user, shares);

        uint256 owed = vault.maxWithdraw(user);
        assertGt(owed, 50 ether, "redeeming more than was deposited");

        uint256 claimable = vault.maxRedeem(user);
        vm.prank(user);
        vault.redeem(claimable, user, user);

        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);
        assertEq(
            vault.availableCapacity(),
            MAXIMUM_VAULT_CAPACITY,
            "a stored totalAssets would have underflowed here"
        );
    }

    function test_instantRedeemBurnsImmediately() public {
        _depositAndClaim(user, 50 ether);
        uint256 shares = vault.balanceOf(user);
        _coverRedemption(shares);

        vm.recordLogs();
        _requestRedeem(user, shares);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 burns;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != TRANSFER_SIG) continue;
            if (address(uint160(uint256(logs[i].topics[2]))) == address(0))
                ++burns;
        }

        assertEq(burns, 1);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.totalPendingWithdraws(), 0);
    }

    function test_processQueue_creditsDepositorsWithSavingsYield() public {
        _closeCapacity();
        _requestDeposit(userTwo, 100 ether);
        _accrueSavings(1_000);
        uint256 owed = savingsVault.previewRedeem(vault.totalPendingDeposits());
        _setCapacity(vault.totalAssets() + 200 ether);

        vm.prank(rebalancer);
        vault.processQueue(owed);

        assertApproxEqAbs(vault.maxDeposit(userTwo), owed, 1);
        assertLe(vault.maxDeposit(userTwo), owed);
        assertEq(assetsHeld(), owed);
        assertEq(savingsVault.balanceOf(address(vault)), 0);
        assertGt(owed, 100 ether);
        assertSolvent();
    }

    function test_processQueue_neverCreditsMoreThanTheRedemptionReturns()
        public
    {
        _deployCleanVault(MINIMUM_DEPOSIT, MINIMUM_WITHDRAW);
        _closeCapacity();
        _requestDeposit(user, 10 ether);
        _requestDeposit(userTwo, 20 ether);
        _requestDeposit(userThree, 70 ether + 7);
        _accrueSavings(1_000);
        uint256 volume = savingsVault.previewRedeem(vault.totalPendingDeposits());
        _setCapacity(vault.totalAssets() + 200 ether);

        vm.prank(rebalancer);
        vault.processQueue(volume);

        uint256 credited = vault.maxDeposit(user) +
            vault.maxDeposit(userTwo) +
            vault.maxDeposit(userThree);
        assertLe(credited, assetsHeld());
        assertLe(assetsHeld() - credited, 4);
        assertSolvent();
    }

    function test_processQueue_partiallyFillsDepositsInSavingsShares() public {
        _closeCapacity();
        _requestDeposit(userTwo, 100 ether);
        _accrueSavings(1_000);
        _setCapacity(vault.totalAssets() + 200 ether);
        uint256 queued = vault.totalPendingDeposits();
        uint256 consumed = savingsVault.previewWithdraw(50 ether);

        vm.prank(rebalancer);
        vault.processQueue(50 ether);

        assertEq(vault.totalPendingDeposits(), queued - consumed);
        assertEq(vault.depositQueueHead().amount, queued - consumed);
        assertGe(assetsHeld(), 50 ether);
        assertApproxEqAbs(vault.maxDeposit(userTwo), 50 ether, 1);
        assertLe(vault.maxDeposit(userTwo), 50 ether);
        assertSolvent();
    }

    function test_processQueue_redeemsSavingsOncePerCall() public {
        _closeCapacity();
        createDepositQueue(5, 50 ether, defaultUsers());
        _setCapacity(vault.totalAssets() + 100 ether);
        uint256 volume = savingsVault.previewRedeem(vault.totalPendingDeposits());

        vm.recordLogs();
        vm.prank(rebalancer);
        vault.processQueue(volume);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 redemptions;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(savingsVault)) continue;
            if (logs[i].topics[0] == IERC4626.Withdraw.selector) ++redemptions;
        }

        assertEq(redemptions, 1);
        assertEq(vault.depositQueueLength(), 0);
        assertSolvent();
    }

    function test_processQueue_withoutDepositsNeverCallsTheSavingsVault()
        public
    {
        _mintSharesTo(user, 50 ether);
        _drainLiquidity();
        _requestRedeem(user, vault.balanceOf(user));
        uint256 volume = vault.convertToAssets(vault.totalPendingWithdraws());
        _injectLiquidity(volume);

        vm.mockCallRevert(
            address(savingsVault),
            bytes(""),
            bytes("savings paused")
        );
        vm.prank(rebalancer);
        vault.processQueue(volume);

        assertEq(vault.withdrawQueueLength(), 0);
    }

    function test_processQueue_partialFillNeverCreditsBeyondTheVolume() public {
        _deployCleanVault(MINIMUM_DEPOSIT, MINIMUM_WITHDRAW);
        uint256 volume = 55e18 - 1;
        _mintSharesTo(user, volume);
        _drainLiquidity();
        _requestRedeem(user, vault.balanceOf(user));
        _closeCapacity();
        _requestDeposit(userTwo, 1e20 - 1);
        deal(address(baseAsset), address(savingsVault), 11e19 - 1);
        assertEq(savingsVault.previewWithdraw(volume), 5e19);

        vm.prank(rebalancer);
        vault.processQueue(volume);

        assertLe(vault.maxDeposit(userTwo), volume);
        assertSolvent();
    }

    function test_cannot_processQueue_afterTheSavingsBackingIsWithdrawn()
        public
    {
        _closeCapacity();
        _requestDeposit(userTwo, 10 ether);
        uint256 backing = savingsVault.balanceOf(address(vault));

        vm.prank(rebalancer);
        uint256 unwound = vault.withdrawFromSavings(backing);
        _setCapacity(vault.totalAssets() + 50 ether);

        vm.prank(rebalancer);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC4626ExceededMaxRedeem(address,uint256,uint256)",
                address(vault),
                backing,
                0
            )
        );
        vault.processQueue(10 ether);

        uint256 needed = savingsVault.previewMint(backing);
        if (needed > unwound) _injectLiquidity(needed - unwound);
        vm.prank(rebalancer);
        vault.depositToSavings(needed);

        uint256 value = savingsVault.previewRedeem(vault.totalPendingDeposits());
        vm.prank(rebalancer);
        vault.processQueue(value);

        assertApproxEqAbs(vault.maxDeposit(userTwo), value, 1);
        assertSolvent();
    }

    function testFuzz_processQueue_atTheShareBoundary(
        uint256 mintValue,
        uint256 extra,
        uint256 bps
    ) public {
        mintValue = bound(mintValue, 1 ether, 50 ether);
        extra = bound(extra, 1 ether, mintValue);
        bps = bound(bps, 1, 5_000);
        _mintSharesTo(user, mintValue);
        _drainLiquidity();
        _requestRedeem(user, vault.balanceOf(user));
        _closeCapacity();
        _requestDeposit(userTwo, mintValue + extra);
        _accrueSavings(bps);

        uint256 volume = vault.convertToAssets(vault.totalPendingWithdraws());
        _absorbAccruedYield();
        vm.prank(rebalancer);
        vault.processQueue(volume);

        assertEq(vault.withdrawQueueLength(), 0);
        assertSolvent();
    }

    function testFuzz_processQueue_atTheAssetBoundary(
        uint256 mintValue,
        uint256 depositValue,
        uint256 bps
    ) public {
        mintValue = bound(mintValue, 2 ether, 90 ether);
        depositValue = bound(depositValue, 1 ether, mintValue / 2);
        bps = bound(bps, 1, 5_000);
        _mintSharesTo(user, mintValue);
        _drainLiquidity();
        _requestRedeem(user, vault.balanceOf(user));
        _closeCapacity();
        _requestDeposit(userTwo, depositValue);
        _accrueSavings(bps);

        uint256 volume = savingsVault.previewRedeem(vault.totalPendingDeposits());
        _absorbAccruedYield();
        vm.prank(rebalancer);
        vault.processQueue(volume);

        assertEq(vault.depositQueueLength(), 0);
        assertSolvent();
    }

    function test_availableCapacity_reservesTheGrowingValueOfLockedShares()
        public
    {
        _requestDeposit(user, 40 ether);
        uint256 before = vault.availableCapacity();

        vm.warp(block.timestamp + 365 days);
        vm.prank(rebalancer);
        vault.processQueue(0);

        assertLt(vault.availableCapacity(), before);
        assertApproxEqAbs(
            vault.maxCapacity() - vault.availableCapacity(),
            vault.convertToAssets(vault.maxMint(user)),
            1
        );
    }

    function test_processQueue_locksSharesAtTheClaimableTransition() public {
        _closeCapacity();
        _requestDeposit(userTwo, 10 ether);
        _setCapacity(vault.totalAssets() + 50 ether);
        vm.warp(block.timestamp + 30 days);
        uint256 value = savingsVault.previewRedeem(vault.totalPendingDeposits());

        vm.prank(rebalancer);
        vault.processQueue(value);

        uint256 locked = vault.maxMint(userTwo);
        uint256 claimable = vault.maxDeposit(userTwo);
        assertEq(locked, vault.convertToShares(claimable));

        vm.warp(block.timestamp + 365 days);
        vm.prank(rebalancer);
        vault.processQueue(0);

        assertEq(vault.maxMint(userTwo), locked);
        assertLt(vault.convertToShares(claimable), locked);

        vm.prank(userTwo);
        uint256 shares = vault.deposit(claimable, userTwo);
        assertEq(shares, locked);
        assertSolvent();
    }

    function testFuzz_processQueue_atTheNaturalBoundaryForAnyIndex(
        uint256 index,
        uint256 withdrawValue,
        uint256 depositValue
    ) public {
        vault.setIndexRate(bound(index, RAY, 10 * RAY));
        withdrawValue = bound(withdrawValue, 1 ether, 50 ether);
        depositValue = bound(depositValue, 1 ether, 50 ether);
        _mintSharesTo(user, withdrawValue);
        _drainLiquidity();
        _requestRedeem(user, vault.balanceOf(user));
        _closeCapacity();
        _requestDeposit(userTwo, depositValue);

        uint256 volume = _matchVolume();
        _absorbAccruedYield();
        vm.prank(rebalancer);
        vault.processQueue(volume);

        assertLe(vault.maxDeposit(userTwo), volume);
        assertLe(
            volume - vault.maxDeposit(userTwo),
            vault.convertToAssets(2) + 2
        );
        assertTrue(
            vault.maxDeposit(userTwo) == 0 || vault.maxMint(userTwo) > 0
        );
        assertSolvent();
    }

    function test_cannot_processQueue_creditDepositsTheVaultCannotMint() public {
        _depositAndClaim(user, 50 ether);
        _requestDeposit(userThree, 5 ether);
        _drainLiquidity();
        _requestRedeem(user, vault.convertToShares(10 ether));
        _setCapacity(vault.totalAssets());
        _requestDeposit(userTwo, 10 ether);

        int256 overCommitted = vault.availableLiquidShares();
        assertLt(overCommitted, -1);
        assertGt(
            int256(vault.totalPendingWithdraws()) + overCommitted,
            0
        );

        uint256 volume = _matchVolume();
        vm.prank(rebalancer);
        vm.expectPartialRevert(IQueue.ShareInvariantBroken.selector);
        vault.processQueue(volume);
    }

    function testFuzz_requestDeposit_fillingTheCapacityNeverOverCommitsShares(
        uint256 index,
        uint256 capacity,
        uint256 first
    ) public {
        _deployCleanVault(MINIMUM_DEPOSIT, MINIMUM_WITHDRAW);
        vault.setIndexRate(bound(index, RAY, 10 * RAY));
        capacity = bound(capacity, 2 ether, 1_000 ether);
        _setCapacity(capacity);
        first = bound(first, 1 ether, capacity - 1 ether);

        _requestDeposit(user, first);
        _requestDeposit(userTwo, vault.availableCapacity());

        assertEq(vault.depositQueueLength(), 0);
        assertGe(vault.availableLiquidShares(), 0);
        assertGt(vault.maxMint(userTwo), 0);
    }

    function test_processQueue_trimLeavesNoLockedShareUnbacked() public {
        _deployCleanVault(0, 0);
        vault.setIndexRate((RAY * 7) / 4);
        _depositAndClaim(user, 15_802_500);
        _requestDeposit(userThree, 21);
        assertEq(vault.balanceOf(user), 9_030_000);
        assertEq(vault.maxMint(userThree), 12);

        _setCapacity(15_802_520);
        _drainLiquidity();
        _requestRedeem(user, 6_908_342);
        _requestDeposit(userTwo, 2_125);

        vm.prank(rebalancer);
        vault.processQueue(1_316);

        assertLe(vault.maxDeposit(userTwo), 1_316);
        assertSolvent();
    }

    function test_processQueue_revertsOnceAccruedYieldPushesAFullVaultOverItsCap()
        public
    {
        _mintSharesTo(user, 50 ether);
        _drainLiquidity();
        _requestRedeem(user, vault.balanceOf(user));
        _closeCapacity();
        vm.warp(block.timestamp + 1 days);
        _requestDeposit(userTwo, 60 ether);
        assertGt(vault.totalAssets(), vault.maxCapacity());

        uint256 volume = _matchVolume();
        vm.prank(rebalancer);
        vm.expectPartialRevert(IQueue.ShareInvariantBroken.selector);
        vault.processQueue(volume);

        _absorbAccruedYield();
        vm.prank(rebalancer);
        vault.processQueue(volume);
        assertSolvent();
    }

    function test_processQueue_forfeitsACreditTooSmallForAShare() public {
        _deployCleanVault(MINIMUM_DEPOSIT, MINIMUM_WITHDRAW);
        vault.setIndexRate((RAY * 3) / 2);
        _closeCapacity();
        _requestDeposit(user, 10 ether);
        _requestDeposit(userTwo, 10 ether);
        _setCapacity(vault.totalAssets() + 50 ether);

        vm.prank(rebalancer);
        vault.processQueue(10 ether + 1);

        assertGt(vault.maxMint(user), 0);
        assertEq(vault.maxDeposit(userTwo), 0);
        assertEq(vault.maxMint(userTwo), 0);
        assertEq(vault.pendingDepositRequest(0, userTwo), 10 ether - 1);
        assertSolvent();
    }

    function test_processQueue_keepsTheRoundingSurplusOfAPartialFill() public {
        _deployCleanVault(MINIMUM_DEPOSIT, MINIMUM_WITHDRAW);
        uint256 volume = 55e18 - 1;
        _closeCapacity();
        _requestDeposit(userTwo, 1e20 - 1);
        deal(address(baseAsset), address(savingsVault), 11e19 - 1);
        assertEq(savingsVault.previewWithdraw(volume), 5e19);
        assertEq(savingsVault.previewRedeem(5e19), volume + 1);
        _setCapacity(vault.totalAssets() + 200 ether);

        vm.prank(rebalancer);
        vault.processQueue(volume);

        assertEq(vault.maxDeposit(userTwo), volume);
        assertEq(assetsHeld(), volume + 1);
        assertSolvent();
    }
}
