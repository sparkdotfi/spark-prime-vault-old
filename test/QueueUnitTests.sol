// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VaultHandler} from "./VaultHandler.t.sol";
import {IVault} from "src/interfaces/IVault.sol";
import {IQueue} from "src/interfaces/IQueue.sol";
import {USDC} from "./mocks/USDC.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {console} from "forge-std/console.sol";
import {QueueHelper} from "./utils/QueueHelper.sol";

contract QueueUnitTests is QueueHelper {
    VaultHandler public vault;
    address user = makeAddr("User");
    address userTwo = makeAddr("UserTwo");
    address userThree = makeAddr("userThree");
    address userFour = makeAddr("userFour");
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

    //  function test_cannot_processWhenCapacityOutOfBounds() public {}
    function test_orderMatching_sameValue_SameLengths() public {
        address[] memory users = new address[](4);
        users[0] = user;
        users[1] = userTwo;
        users[2] = userThree;
        users[3] = userFour;

        createDepositQueue(vault, 10, 100 ether, users);

        createWithdrawQueue(vault, 10, 100 ether, users);

        vm.prank(rebalancer);
        vault.processQueue(100 ether);

        assertEq(vault.totalPendingDeposits(), 0);
        assertEq(vault.totalPendingWithdraws(), 0);
        assertEq(vault.depositQueueLength(), 0);
        assertEq(vault.withdrawQueueLength(), 0);
    }

    function test_orderMatching_sameValue_DifferentLengths() public {
        address[] memory users = new address[](4);
        users[0] = user;
        users[1] = userTwo;
        users[2] = userThree;
        users[3] = userFour;

        createDepositQueue(vault, 10, 100 ether, users);
        createWithdrawQueue(vault, 5, 100 ether, users);

        vm.prank(rebalancer);
        vault.processQueue(100 ether);

        assertEq(vault.totalPendingDeposits(), 0);
        assertEq(vault.totalPendingWithdraws(), 0);
        assertEq(vault.claimableDepositTotal(), 100 ether);
        assertEq(
            vault.claimableWithdrawTotal(),
            vault.convertToShares(100 ether)
        );
        assertEq(vault.depositQueueLength(), 0);
        assertEq(vault.withdrawQueueLength(), 0);
    }

    /// @dev 10 depositors, 100 ether total. 50 withdrawers, 200 ether total. Curator wants only 50 ether of volume exchanged
    function test_orderMatching_depositsSmallerThanWithdraws_curatorRequestsHalfDepositQueueValue()
        public
    {
        address[] memory users = new address[](4);
        users[0] = user;
        users[1] = userTwo;
        users[2] = userThree;
        users[3] = userFour;

        uint256 totalDepositValue = 100 ether;
        createDepositQueue(vault, 10, totalDepositValue, users);
        uint256 totalWithdrawValue = 200 ether;
        createWithdrawQueue(vault, 50, totalWithdrawValue, users);

        uint256 curatorCapacity = 50 ether;
        vm.prank(rebalancer);
        vault.processQueue(curatorCapacity);

        assertEq(
            vault.totalPendingDeposits(),
            totalDepositValue - curatorCapacity
        );
        assertEq(
            vault.totalPendingWithdraws(),
            totalWithdrawValue - curatorCapacity
        );
        assertEq(vault.claimableDepositTotal(), curatorCapacity);
        assertEq(
            vault.claimableWithdrawTotal(),
            vault.convertToShares(curatorCapacity)
        );
        /// Neither queues are fully fulfilled
        assertGt(vault.depositQueueLength(), 0);
        assertGt(vault.withdrawQueueLength(), 0);
    }

    /// @dev 10 depositors, 100 ether total. 50 withdrawers, 200 ether total. Curator wants 100 ether (totalDepositQueue) exchanged

    function test_orderMatching_symmetricCuratorRequest_fulfillDepositors_partiallyFulfillWithdrawers()
        public
    {
        address[] memory users = new address[](4);
        users[0] = user;
        users[1] = userTwo;
        users[2] = userThree;
        users[3] = userFour;

        uint256 totalDepositValue = 100 ether;
        createDepositQueue(vault, 10, totalDepositValue, users);
        uint256 totalWithdrawValue = 200 ether;
        uint256 totalWithdrawers = 50;
        createWithdrawQueue(vault, totalWithdrawers, totalWithdrawValue, users);

        uint256 curatorCapacity = totalDepositValue;
        vm.prank(rebalancer);
        vault.processQueue(curatorCapacity);

        assertEq(
            vault.totalPendingDeposits(),
            totalDepositValue - curatorCapacity
        );
        assertEq(
            vault.totalPendingWithdraws(),
            totalWithdrawValue - curatorCapacity
        );
        assertEq(vault.claimableDepositTotal(), curatorCapacity);
        assertEq(
            vault.claimableWithdrawTotal(),
            vault.convertToShares(curatorCapacity)
        );
        assertEq(vault.depositQueueLength(), 0); // Deposits entirely fulfilled
        // Withdraws partially fulfilled
        assertLt(vault.withdrawQueueLength(), totalWithdrawers);
        assertLt(vault.totalPendingWithdraws(), totalWithdrawValue);
    }

    /// @dev 15 depositors, 120 ether total. 5 withdrawers, 75 ether total. Curator wants 75 ether (totalWithdrawQueue) exchanged

    function test_orderMatching_symmetricCuratorRequest_fulfillWithdrawers_partiallyFulfillDepositors()
        public
    {
        address[] memory users = new address[](4);
        users[0] = user;
        users[1] = userTwo;
        users[2] = userThree;
        users[3] = userFour;

        uint256 totalDepositValue = 120 ether;
        uint256 totalDepositors = 15;
        createDepositQueue(vault, totalDepositors, totalDepositValue, users);
        uint256 totalWithdrawValue = 75 ether;
        uint256 totalWithdrawers = 5;
        createWithdrawQueue(vault, totalWithdrawers, totalWithdrawValue, users);

        uint256 curatorCapacity = totalWithdrawValue;
        vm.prank(rebalancer);
        vault.processQueue(curatorCapacity);

        assertEq(
            vault.totalPendingDeposits(),
            totalDepositValue - curatorCapacity
        );
        assertEq(
            vault.totalPendingWithdraws(),
            totalWithdrawValue - curatorCapacity
        );
        assertEq(vault.claimableDepositTotal(), curatorCapacity);
        assertEq(
            vault.claimableWithdrawTotal(),
            vault.convertToShares(curatorCapacity)
        );
        assertEq(vault.withdrawQueueLength(), 0); // Withdrawers entirely fulfilled
        // Depositors partially fulfilled
        assertLt(vault.depositQueueLength(), totalDepositors);
        assertLt(vault.totalPendingDeposits(), totalDepositValue);
    }
    /// @dev 10 depositors, 100 ether total. 50 withdrawers, 200 ether total. Curator wants 200 ether in volume exchanged (non-symmetric)
    function test_cannot_orderMatching_nonSymmetricCuratorRequest() public {
        address[] memory users = new address[](4);
        users[0] = user;
        users[1] = userTwo;
        users[2] = userThree;
        users[3] = userFour;

        uint256 totalDepositValue = 100 ether;
        createDepositQueue(vault, 10, totalDepositValue, users);
        uint256 totalWithdrawValue = 200 ether;
        createWithdrawQueue(vault, 50, totalWithdrawValue, users);

        uint256 curatorCapacity = totalWithdrawValue; // I'm requesting an non-symmetric amount
        vm.prank(rebalancer);
        vm.expectRevert(
            abi.encodeWithSelector(IQueue.CapacityOutOfBounds.selector)
        );
        vault.processQueue(curatorCapacity);
    }
}
