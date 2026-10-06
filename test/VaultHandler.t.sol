// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import { Test } from "../lib/forge-std/src/Test.sol";
import { Vault } from "../src/Vault.sol";
import { IVault } from "../src/interfaces/IVault.sol";
import { USDC } from "./mocks/USDC.sol";
import { IERC20 } from "../lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import { IERC4626 } from "../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import { Math } from "../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

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
        VaultStorage storage $ = _getStorage();
        $.indexRate = value;
    }

    function setOperatorForUser(
        address user,
        address operator,
        bool value
    ) external {
        VaultStorage storage $ = _getStorage();
        $.operators[user][operator] = value;
    }

    function setTotalClaimableDepositShares(uint256 value) external {
        VaultStorage storage $ = _getStorage();
        $.totalClaimableDepositShares = value;
    }

    function setMaximumCapacity(uint256 value) external {
        VaultStorage storage $ = _getStorage();
        $.maximumCapacity = value;
    }

    function setTotalClaimableWithdrawAssets(uint256 value) external {
        VaultStorage storage $ = _getStorage();
        $.totalClaimableWithdrawAssets = value;
    }

    function pushToDepositQueue(IVault.Transaction memory data) external {
        VaultStorage storage $ = _getStorage();
        data.nonce = ++$.nonces[data.controller];
        _pushToDepositQueue($, data);
    }

    function pushToWithdrawQueue(IVault.Transaction memory data) external {
        VaultStorage storage $ = _getStorage();
        data.nonce = ++$.nonces[data.controller];
        _pushToWithdrawQueue($, data);
    }

    function fillWithdrawQueue() external {
        VaultStorage storage $ = _getStorage();
        _fillUnbounded($, $.withdrawQueue, _markClaimableWithdraw);
    }

    function fillUntilWithdrawQueue(uint256 capacity) external {
        VaultStorage storage $ = _getStorage();
        _fillUntil($, $.withdrawQueue, _markClaimableWithdraw, capacity);
    }
}
