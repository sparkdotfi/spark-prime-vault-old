// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VaultHandler} from "./VaultHandler.t.sol";
import {IVault} from "src/interfaces/IVault.sol";
import {USDC} from "./mocks/USDC.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {QueueHelper} from "./utils/QueueHelper.sol";

contract OperatorUnitTests is QueueHelper {
    VaultHandler public vault;
    address user = makeAddr("User");
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
    //Operator Rules

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
        vault.deposit(5 ether, user, user);
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
}
