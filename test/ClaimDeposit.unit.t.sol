// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VaultHandler} from "./VaultHandler.t.sol";
import {IVault} from "../src/interfaces/IVault.sol";
import {USDC} from "./mocks/USDC.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {DepositHelper} from "./utils/DepositHelper.sol";
// Deposit Claim Rules
//Test: Always consume claimableDepositTotal(), any remainder is minted (if below capacity). Always revert if total amount cannot be claimed (Insolvency)

contract ClaimDepositUnitTests is DepositHelper {
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

    /// @dev If older deposit claims consume the available liquidity, a new requestor shoudn't be able to request and claim instant liquidty
    function test_cannot_claimDeposit_WhenOlderClaimsNotSettled() public {
        address userTwo = makeAddr("UserTwO");
        uint256 userDepositSize = vault.availableCapacity();

        _fundAndDeposit(vault, user, baseAsset, userDepositSize); // user gets instant claim, but they never settle it
        _fundAndDeposit(vault, userTwo, baseAsset, userDepositSize); // should go directly to queue, nothing instant claimable

        vm.prank(userTwo);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.InsufficientClaimableBalance.selector,
                userDepositSize,
                0
            )
        );
        vault.deposit(userDepositSize, userTwo);
    }

    function test_claimDeposit() public {
        uint256 userDepositSize = vault.availableCapacity();
        _fundAndDeposit(vault, user, baseAsset, userDepositSize);
        // The user claims all the funds this time
        vm.startPrank(user);
        vault.deposit(userDepositSize, user);
        vm.stopPrank();
    }
    function test_cannot_claimDeposit_whenNoClaimableBalance() public {
        deal(address(baseAsset), user, 10 ether);
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.InsufficientClaimableBalance.selector,
                5 ether,
                0
            )
        );
        vault.deposit(5 ether, user, user);
    }
    function test_cannot_claimDeposit_whenNotAuthorized() public {
        deal(address(baseAsset), user, 10 ether);
        vm.startPrank(address(123));
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.UnauthorizedCaller.selector,
                address(123)
            )
        );
        vault.deposit(5 ether, user, user);
        vm.stopPrank();
    }

    function test_cannot_claimDeposit_forceControllerStatus() public {
        deal(address(baseAsset), user, 10 ether);
        vm.startPrank(address(123));
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.UnauthorizedCaller.selector,
                address(123)
            )
        );
        // I cannot pass myself as `reciever` and call on behalf of a user
        vault.deposit(5 ether, address(123), user);
        vm.stopPrank();
    }
}
