// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vault} from "src/Vault.sol";
import {IVault} from "src/interfaces/IVault.sol";
import {USDC} from "./mocks/USDC.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract VaultHandler is Vault {
    function convertToSharesRounded(
        uint256 assets,
        Math.Rounding rounding
    ) external view returns (uint256) {
        return _convertToShares(assets, rounding);
    }

    function convertToAssetsRounded(
        uint256 shares,
        Math.Rounding rounding
    ) external view returns (uint256) {
        return _convertToAssets(shares, rounding);
    }

    function setIndexRate(uint256 value) external {
        Storage storage $ = getStorage();
        $.indexRate = value;
    }

    function setOperatorForUser(
        address user,
        address operator,
        bool value
    ) external {
        Storage storage $ = getStorage();
        $.operators[user] = value ? operator : address(0);
    }

    function setTotalClaimableDeposits(uint256 value) external {
        Storage storage $ = getStorage();
        $.totalClaimableDeposits = value;
    }

    function setTotalClaimableWithdraws(uint256 value) external {
        Storage storage $ = getStorage();
        $.totalClaimableWithdraws = value;
    }

    function pushToDepositQueue(IVault.Transaction memory data) external {
        Storage storage $ = getStorage();
        data.nonce = ++$.nonces[data.controller];
        _pushToDepositQueue($, data);
    }

    function pushToWithdrawQueue(IVault.Transaction memory data) external {
        Storage storage $ = getStorage();
        data.nonce = ++$.nonces[data.controller];
        _pushToWithdrawQueue($, data);
    }

    function fillDepositQueue() external {
        Storage storage $ = getStorage();
        fillUnbounded($, $.depositQueue, _markClaimableDeposit);
    }

    function fillUntilDepositQueue(uint256 capacity) external {
        Storage storage $ = getStorage();
        fillUntil($, $.depositQueue, _markClaimableDeposit, capacity);
    }

    function fillWithdrawQueue() external {
        Storage storage $ = getStorage();
        fillUnbounded($, $.withdrawQueue, _markClaimableWithdraw);
    }

    function fillUntilWithdrawQueue(uint256 capacity) external {
        Storage storage $ = getStorage();
        fillUntil($, $.withdrawQueue, _markClaimableWithdraw, capacity);
    }
}
