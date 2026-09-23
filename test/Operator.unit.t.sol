// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VaultHandler} from "./VaultHandler.t.sol";
import {IVault} from "src/interfaces/IVault.sol";
import {
    IERC7540Operator
} from "@openzeppelin/community-contracts/interfaces/IERC7540.sol";
import {USDC} from "./mocks/USDC.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ISparkPrimeVault} from "src/interfaces/ISparkPrimeVault.sol";
import {QueueHelper} from "./utils/QueueHelper.sol";

contract OperatorUnitTests is QueueHelper {
    function setUp() public {
        _deployVault();
    }

    /// @dev Operator cannot claim deposit to any address other than the controller
    function test_claimDeposit_ToNonUserWallet_asOperator() public {
        deal(address(baseAsset), user, 10 ether);
        vault.setOperatorForUser(user, operator, true);

        vm.startPrank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.OperatorMaliciousAction.selector,
                operator,
                user
            )
        );
        vault.deposit(5 ether, operator, user);
        vm.stopPrank();
    }

    /// @dev Operator cannot claim for a controller that hasn't assigned him
    function test_cannot_claimDeposit_notSetAsOperator() public {
        vm.startPrank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IVault.UnauthorizedCaller.selector, operator)
        );
        vault.redeem(5 ether, user, user);
        vm.stopPrank();
    }

    /// @dev Operator cannot create a deposit request
    function test_cannot_requestDeposit_AsOperator() public {
        deal(address(baseAsset), user, 10 ether);
        vault.setOperatorForUser(user, operator, true);

        vm.startPrank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IVault.UnauthorizedCaller.selector, operator)
        );
        vault.requestDeposit(5 ether, user, user);
        vm.stopPrank();
    }

    /// @dev Operator cannot create a withdraw request
    function test_cannot_requestWithdraw_AsOperator() public {
        deal(address(baseAsset), user, 10 ether);
        vault.setOperatorForUser(user, operator, true);

        vm.startPrank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IVault.UnauthorizedCaller.selector, operator)
        );
        vault.requestRedeem(5 ether, user, user);
        vm.stopPrank();
    }
    function test_claimDeposit_asOperator() public {
        _fundAndDeposit(vault, user, baseAsset, 10 ether);

        vault.setOperatorForUser(user, operator, true);

        vm.startPrank(operator);
        vault.deposit(5 ether, user, user);
        vm.stopPrank();
    }
    function testFuzz_SetNumber(uint256) public pure {
        // counter.setNumber(x);
        // assertEq(counter.number(), x);
        assertTrue(true);
    }

    function test_setOperator_emitsOperatorSetOnGrant() public {
        vm.expectEmit(address(vault));
        emit IERC7540Operator.OperatorSet(user, operator, true);

        vm.prank(user);
        bool ok = vault.setOperator(operator, true);

        assertTrue(ok);
        assertTrue(vault.isOperator(user, operator));
    }

    function test_setOperator_emitsOperatorSetOnRevoke() public {
        vm.prank(user);
        vault.setOperator(operator, true);

        vm.expectEmit(address(vault));
        emit IERC7540Operator.OperatorSet(user, operator, false);

        vm.prank(user);
        bool ok = vault.setOperator(operator, false);

        assertTrue(ok);
        assertFalse(vault.isOperator(user, operator));
    }

    function test_setOperator_revokingANonOperatorIsANoOp() public {
        vm.prank(user);
        vault.setOperator(operator, true);

        address stranger = makeAddr("stranger");
        vm.expectEmit(address(vault));
        emit IERC7540Operator.OperatorSet(user, stranger, false);

        vm.prank(user);
        bool ok = vault.setOperator(stranger, false);

        assertTrue(ok);
        assertTrue(vault.isOperator(user, operator));
    }

    function test_setOperator_revokeIsIdempotent() public {
        vm.startPrank(user);
        vault.setOperator(operator, true);
        vault.setOperator(operator, false);
        vault.setOperator(operator, false);
        vm.stopPrank();

        assertFalse(vault.isOperator(user, operator));
    }

    function test_cannot_isOperator_forTheZeroAddress() public view {
        assertFalse(vault.isOperator(user, address(0)));
        assertFalse(vault.isOperator(userTwo, address(0)));
        assertFalse(vault.isOperator(address(0), address(0)));
    }

    function test_cannot_isOperator_forTheZeroAddressAfterSetting() public {
        vm.prank(user);
        vault.setOperator(operator, true);

        assertFalse(vault.isOperator(user, address(0)));
    }

    function test_cannot_setOperator_approvingTheZeroAddress() public {
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(ISparkPrimeVault.ZeroValueProvided.selector)
        );
        vault.setOperator(address(0), true);
    }

    function test_setOperator_revokingTheZeroAddressNoOp() public {
        vm.prank(user);
        vault.setOperator(operator, true);

        vm.prank(user);
        bool ok = vault.setOperator(address(0), false);

        assertTrue(ok);
        assertTrue(vault.isOperator(user, operator));
    }

    function test_setOperator_isPerController() public {
        vm.prank(user);
        vault.setOperator(operator, true);

        vm.prank(userTwo);
        vault.setOperator(operator, false);

        assertTrue(vault.isOperator(user, operator));
        assertFalse(vault.isOperator(userTwo, operator));
    }
}
