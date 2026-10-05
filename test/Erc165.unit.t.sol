// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {QueueHelper} from "./utils/QueueHelper.sol";
import {IERC7575} from "src/interfaces/IERC7575.sol";
import {IQueue} from "src/interfaces/IQueue.sol";
import {
    IERC7540Operator
} from "src/interfaces/IERC7540.sol";
import {
    IAccessControl
} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {
    IERC165
} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract Erc165UnitTests is QueueHelper {
    bytes4 constant ERC7540_OPERATOR = 0xe3bc4e65;
    bytes4 constant ERC7575 = 0x2f0a18c5;
    bytes4 constant ERC7540_DEPOSIT = 0xce3bbe50;
    bytes4 constant ERC7540_REDEEM = 0x620ee8e4;
    bytes4 constant ERC7575_SHARE = 0xf815c03d;

    function setUp() public {
        _deployVault();
    }

    function test_supportsInterface_erc7540OperatorMethods() public view {
        assertTrue(vault.supportsInterface(ERC7540_OPERATOR));
    }

    function test_supportsInterface_erc7575() public view {
        assertTrue(vault.supportsInterface(ERC7575));
    }

    function test_cannot_supportsInterface_vendoredIERC7575Id() public view {
        assertEq(type(IERC7575).interfaceId, bytes4(0xa8d5fd65));
        assertFalse(vault.supportsInterface(type(IERC7575).interfaceId));
    }

    function test_iQueueProcessQueueSelectorMatchesTheVault() public view {
        assertEq(IQueue.processQueue.selector, vault.processQueue.selector);
    }

    function test_supportsInterface_erc7575Share() public view {
        assertTrue(vault.supportsInterface(ERC7575_SHARE));
    }

    function test_vault_isTheShareTokensVaultForTheBaseAssetOnly() public view {
        assertEq(vault.vault(address(baseAsset)), address(vault));
        assertEq(vault.vault(address(savingsVault)), address(0));
    }

    function test_supportsInterface_erc7540AsyncDeposit() public view {
        assertTrue(vault.supportsInterface(ERC7540_DEPOSIT));
    }

    function test_supportsInterface_erc7540AsyncRedeem() public view {
        assertTrue(vault.supportsInterface(ERC7540_REDEEM));
    }

    function test_supportsInterface_erc165() public view {
        assertTrue(vault.supportsInterface(type(IERC165).interfaceId));
    }

    function test_supportsInterface_accessControlStillReported() public view {
        assertTrue(vault.supportsInterface(type(IAccessControl).interfaceId));
    }

    function test_cannot_supportsInterface_invalidId() public view {
        assertFalse(vault.supportsInterface(0xffffffff));
    }

    function test_cannot_supportsInterface_unknownId() public view {
        assertFalse(vault.supportsInterface(0xdeadbeef));
    }

    function test_operatorInterfaceIdMatchesTheSpecLiteral() public pure {
        assertEq(
            type(IERC7540Operator).interfaceId,
            ERC7540_OPERATOR,
            "OZ interface diverged from the EIP"
        );
    }

    function test_shareTokenReportsErc7575() public view {
        assertEq(vault.share(), address(vault));
        assertTrue(IERC165(vault.share()).supportsInterface(ERC7575));
    }
}
