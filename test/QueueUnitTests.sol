// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VaultHandler} from "./VaultHandler.t.sol";
import {IVault} from "src/interfaces/IVault.sol";
import {USDC} from "./mocks/USDC.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {console} from "forge-std/console.sol";
import {QueueHelper} from "./utils/QueueHelper.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
contract QueueUnitTests is QueueHelper {
    function setUp() public {
        _deployVault();
    }

    //  function test_cannot_processWhenCapacityOutOfBounds() public {}
    function test_orderMatching_sameValue_SameLengths() public {
        address[] memory users = defaultUsers();

        _ensureCapacity(vault.totalAssets() + 100 ether);
        _mintShares(10, 100 ether, users);
        _drainLiquidity();

        createWithdrawQueue(10, vault.convertToShares(100 ether), users);

        _closeCapacity();
        createDepositQueue(10, 100 ether, users);

        uint256 volume = _matchVolume();

        vm.prank(rebalancer);
        vault.processQueue(volume);

        assertApproxEqAbs(vault.totalPendingDeposits(), 0, _drift(volume));
        assertApproxEqAbs(vault.totalPendingWithdraws(), 0, _drift(volume));
        assertSolvent();
    }

    function test_orderMatching_sameValue_DifferentLengths() public {
        address[] memory users = defaultUsers();
        _ensureCapacity(vault.totalAssets() + 100 ether);
        _mintShares(5, 100 ether, users);
        _drainLiquidity();
        createWithdrawQueue(5, vault.convertToShares(100 ether), users);

        _closeCapacity();
        createDepositQueue(10, 100 ether, users);

        uint256 volume = _matchVolume();

        vm.prank(rebalancer);
        vault.processQueue(volume);

        assertApproxEqAbs(vault.totalPendingDeposits(), 0, _drift(volume));
        assertApproxEqAbs(vault.totalPendingWithdraws(), 0, _drift(volume));
        assertApproxEqAbs(
            vault.claimableDepositTotal(),
            vault.convertToShares(volume),
            ROUNDING_DUST
        );
        assertApproxEqAbs(
            vault.claimableWithdrawTotal(),
            volume,
            ROUNDING_DUST
        );
        assertSolvent();
    }

    /// @dev 10 depositors, 100 ether total. 50 withdrawers, 200 ether total. Curator wants only 50 ether of volume exchanged
    function test_orderMatching_depositsSmallerThanWithdraws_curatorRequestsHalfDepositQueueValue()
        public
    {
        uint256 curatorCapacity = 50 ether;
        uint256 totalDepositValue = 100 ether;
        uint256 totalWithdrawValue = 200 ether;

        address[] memory users = defaultUsers();
        _ensureCapacity(vault.totalAssets() + totalWithdrawValue);
        _mintShares(50, totalWithdrawValue, users);
        _drainLiquidity();
        createWithdrawQueue(
            50,
            vault.convertToShares(totalWithdrawValue),
            users
        );
        _closeCapacity();
        createDepositQueue(10, totalDepositValue, users);
        uint256 depositValue = savingsVault.previewRedeem(
            vault.totalPendingDeposits()
        );
        uint256 withdrawValue = vault.convertToAssets(
            vault.totalPendingWithdraws()
        );

        vm.prank(rebalancer);
        vault.processQueue(curatorCapacity);

        assertApproxEqAbs(
            savingsVault.previewRedeem(vault.totalPendingDeposits()),
            depositValue - curatorCapacity,
            ROUNDING_DUST
        );
        assertApproxEqAbs(
            vault.convertToAssets(vault.totalPendingWithdraws()),
            withdrawValue - curatorCapacity,
            ROUNDING_DUST
        );
        assertApproxEqAbs(
            vault.claimableDepositTotal(),
            vault.convertToShares(curatorCapacity),
            ROUNDING_DUST
        );
        assertApproxEqAbs(
            vault.claimableWithdrawTotal(),
            curatorCapacity,
            ROUNDING_DUST
        );
        assertSolvent();
        /// Neither queues are fully fulfilled
        assertGt(vault.depositQueueLength(), 0);
        assertGt(vault.withdrawQueueLength(), 0);
    }

    /// @dev 10 depositors, 100 ether total. 50 withdrawers, 200 ether total. Curator wants 100 ether (totalDepositQueue) exchanged

    function test_orderMatching_symmetricCuratorRequest_fulfillDepositors_partiallyFulfillWithdrawers()
        public
    {
        address[] memory users = defaultUsers();
        uint256 totalDepositValue = 100 ether;
        uint256 totalWithdrawValue = 200 ether;
        uint256 totalWithdrawers = 50;
        _ensureCapacity(vault.totalAssets() + totalWithdrawValue);
        _mintShares(totalWithdrawers, totalWithdrawValue, users);
        _drainLiquidity();
        createWithdrawQueue(
            totalWithdrawers,
            vault.convertToShares(totalWithdrawValue),
            users
        );
        _closeCapacity();
        createDepositQueue(10, totalDepositValue, users);
        uint256 depositValue = savingsVault.previewRedeem(
            vault.totalPendingDeposits()
        );
        uint256 withdrawValue = vault.convertToAssets(
            vault.totalPendingWithdraws()
        );

        uint256 curatorCapacity = depositValue;
        vm.prank(rebalancer);
        vault.processQueue(curatorCapacity);

        assertApproxEqAbs(
            savingsVault.previewRedeem(vault.totalPendingDeposits()),
            depositValue - curatorCapacity,
            ROUNDING_DUST
        );
        assertApproxEqAbs(
            vault.convertToAssets(vault.totalPendingWithdraws()),
            withdrawValue - curatorCapacity,
            ROUNDING_DUST
        );
        assertApproxEqAbs(
            vault.claimableDepositTotal(),
            vault.convertToShares(curatorCapacity),
            ROUNDING_DUST
        );
        assertApproxEqAbs(
            vault.claimableWithdrawTotal(),
            curatorCapacity,
            ROUNDING_DUST
        );
        assertSolvent();
        assertEq(vault.depositQueueLength(), 0); // Deposits entirely fulfilled
        // Withdraws partially fulfilled
        assertLt(vault.withdrawQueueLength(), totalWithdrawers);
        assertLt(
            vault.convertToAssets(vault.totalPendingWithdraws()),
            totalWithdrawValue
        );
    }

    /// @dev 15 depositors, 120 ether total. 5 withdrawers, 75 ether total. Curator wants 75 ether (totalWithdrawQueue) exchanged

    function test_orderMatching_symmetricCuratorRequest_fulfillWithdrawers_partiallyFulfillDepositors()
        public
    {
        address[] memory users = defaultUsers();
        uint256 totalDepositValue = 120 ether;
        uint256 totalDepositors = 15;
        uint256 totalWithdrawValue = 75 ether;
        uint256 totalWithdrawers = 5;
        _ensureCapacity(vault.totalAssets() + totalWithdrawValue);
        _mintShares(totalWithdrawers, totalWithdrawValue, users);
        _drainLiquidity();
        uint256 queuedShares = createWithdrawQueue(
            totalWithdrawers,
            vault.convertToShares(totalWithdrawValue),
            users
        );
        _closeCapacity();
        createDepositQueue(totalDepositors, totalDepositValue, users);
        uint256 depositValue = savingsVault.previewRedeem(
            vault.totalPendingDeposits()
        );
        uint256 withdrawValue = vault.convertToAssets(
            vault.totalPendingWithdraws()
        );

        uint256 curatorCapacity = vault.convertToAssets(queuedShares);
        vm.prank(rebalancer);
        vault.processQueue(curatorCapacity);

        assertApproxEqAbs(
            savingsVault.previewRedeem(vault.totalPendingDeposits()),
            depositValue - curatorCapacity,
            ROUNDING_DUST
        );
        assertApproxEqAbs(
            vault.convertToAssets(vault.totalPendingWithdraws()),
            withdrawValue - curatorCapacity,
            ROUNDING_DUST
        );
        assertApproxEqAbs(
            vault.claimableDepositTotal(),
            vault.convertToShares(curatorCapacity),
            ROUNDING_DUST
        );
        assertApproxEqAbs(
            vault.claimableWithdrawTotal(),
            curatorCapacity,
            ROUNDING_DUST
        );
        assertSolvent();
        assertEq(vault.withdrawQueueLength(), 0); // Withdrawers entirely fulfilled
        // Depositors partially fulfilled
        assertLt(vault.depositQueueLength(), totalDepositors);
        assertLt(
            savingsVault.previewRedeem(vault.totalPendingDeposits()),
            totalDepositValue
        );
    }

    /// @dev 10 depositors, 100 ether total. 50 withdrawers, 200 ether total. There is no additional liquidity (mintable shares/idle base asset) Curator wants 200 ether in volume exchanged (non-symmetric)
    function test_orderMatching_clampsANonSymmetricCuratorRequest() public {
        address[] memory users = defaultUsers();
        uint256 totalDepositValue = 100 ether;
        uint256 totalWithdrawValue = 200 ether;
        _ensureCapacity(vault.totalAssets() + totalWithdrawValue);
        _mintShares(50, totalWithdrawValue, users);
        _drainLiquidity();
        createWithdrawQueue(
            50,
            vault.convertToShares(totalWithdrawValue),
            users
        );
        _closeCapacity();
        createDepositQueue(10, totalDepositValue, users);

        uint256 curatorCapacity = totalWithdrawValue; // I'm requesting an non-symmetric amount
        vm.prank(rebalancer);
        vault.processQueue(curatorCapacity);

        assertEq(vault.depositQueueLength(), 0);
        assertGt(vault.withdrawQueueLength(), 0);
    }
}
