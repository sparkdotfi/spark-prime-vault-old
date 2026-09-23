// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {QueueHelper} from "./utils/QueueHelper.sol";
import {IQueue} from "src/interfaces/IQueue.sol";
import {Vm} from "forge-std/Vm.sol";

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
        assertEq(vault.totalPendingDeposits(), queued, "queue total");
        assertEq(assetsHeld(), queued, "vault holds queued assets");
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
        uint256 shares = createWithdrawQueue(
            5,
            vault.convertToShares(50 ether),
            defaultUsers()
        );

        _closeCapacity();
        uint256 deposits = createDepositQueue(5, 50 ether, defaultUsers());

        assertEq(
            assetsHeld(),
            deposits,
            "deposited funds become liquidity for withdrawers"
        );

        uint256 volume = vault.convertToAssets(shares);
        vm.prank(rebalancer);
        vault.processQueue(volume);

        assertEq(vault.withdrawQueueLength(), 0, "fulfilled withdrawers");

        assertApproxEqAbs(
            vault.totalPendingDeposits(),
            0,
            ROUNDING_DUST,
            "depositors fulfilled with potential dust"
        );
        assertSolvent();
    }

    function test_symmetricMatch_dustIsSweptByNextCall() public {
        _ensureCapacity(50 ether);

        vm.warp(block.timestamp + 1);

        _mintShares(5, 50 ether, defaultUsers());
        _drainLiquidity();
        uint256 shares = createWithdrawQueue(
            5,
            vault.convertToShares(50 ether),
            defaultUsers()
        );

        _closeCapacity();
        createDepositQueue(5, 50 ether, defaultUsers());

        uint256 volume = vault.convertToAssets(shares);
        vm.prank(rebalancer);
        vault.processQueue(volume);

        uint256 dust = vault.totalPendingDeposits();
        assertGt(dust, 0, "dust entry survives");
        assertEq(vault.depositQueueLength(), 1, "queue not empty");

        /// cant sweep immediately because no liquidity
        vm.prank(rebalancer);
        vm.expectRevert(IQueue.CapacityExceedsLiquidity.selector);
        vault.processQueue(dust);

        // boost capacity to give liquidity
        _setCapacity(vault.totalAssets() + 51 ether);

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
        assertEq(assetsHeld(), 20 ether);

        uint256 fullDemand = vault.convertToAssets(shares);
        vm.prank(rebalancer);
        vm.expectRevert(IQueue.CapacityExceedsLiquidity.selector);
        vault.processQueue(fullDemand);

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

        _injectLiquidity(40 ether);

        uint256 volume = vault.convertToAssets(shares);
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

        vm.prank(rebalancer);
        vault.processQueue(30 ether);

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

        _injectLiquidity(40 ether);
        uint256 volume = vault.convertToAssets(shares);
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
            vault.convertToShares(100 ether),
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

        createDepositQueue(1, 100 ether, createOneUserList(userTwo));

        uint256 volume = vault.convertToAssets(shares);
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
            vault.convertToShares(100 ether),
            defaultUsers()
        );
        createDepositQueue(1, 100 ether, createOneUserList(userTwo));

        assertEq(vault.availableLiquidShares(), 0, "escrow in pending");

        uint256 volume = vault.convertToAssets(shares);
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

        _injectLiquidity(100 ether);
        uint256 volume = vault.convertToAssets(shares);
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
}
