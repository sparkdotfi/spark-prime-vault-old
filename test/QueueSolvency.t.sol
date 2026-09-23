// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {QueueHelper} from "./utils/QueueHelper.sol";
import {IQueue} from "src/interfaces/IQueue.sol";

contract QueueSolvencyTests is QueueHelper {
    function setUp() public {
        _deployVault();
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
}
