// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vault} from "src/Vault.sol";
import {IVault} from "src/interfaces/IVault.sol";
import {USDC} from "./mocks/USDC.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

contract VaultHandler is Vault {
    uint256 constant TEN_PERCENT_APY = 1000000003022265980097387650;
    uint256 constant RAY = 1e27;
    uint256 constant MAXIMUM_VAULT_CAPACITY = 100 ether;
    constructor(
        IERC20 baseAsset,
        address rebalancer,
        address vaultManager,
        address liquidityManager
    ) initializer {
        _grantRole(VAULT_MANAGER_ROLE, vaultManager);
        _grantRole(LIQUIDITY_MANAGER_ROLE, liquidityManager);
        _grantRole(REBALANCER_ROLER, rebalancer);

        __ERC20_init("spPRIME Vault", "spPRIME");
        __ERC4626_init(baseAsset);

        Storage storage $ = getStorage();
        $.maximumCapacity = MAXIMUM_VAULT_CAPACITY;
        $.indexRate = RAY;
        $.ratePerSecond = TEN_PERCENT_APY;
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
        data.nonce = ++$.nonces[data.beneficiary];
        _pushToDepositQueue($, data);
    }

    function pushToWithdrawQueue(IVault.Transaction memory data) external {
        Storage storage $ = getStorage();
        data.nonce = ++$.nonces[data.beneficiary];
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
