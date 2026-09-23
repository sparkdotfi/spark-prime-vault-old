// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Vault} from "src/Vault.sol";
import {IVault} from "src/interfaces/IVault.sol";
import {VaultHandler} from "../VaultHandler.t.sol";

library VaultDeployer {
    uint256 internal constant TEN_PERCENT_APY = 1000000003022265980097387650;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant MAXIMUM_VAULT_CAPACITY = 100 ether;
    uint256 internal constant MINIMUM_DEPOSIT = 0.01 ether;
    uint256 internal constant MINIMUM_WITHDRAW = 0.01 ether;

    string internal constant NAME = "spPrime Vault";
    string internal constant SYMBOL = "spPRIME";

    function deploy(
        IERC20 baseAsset,
        IERC4626 savingsVault,
        address admin,
        address vaultManager,
        address liquidityManager,
        address rebalancer
    ) internal returns (VaultHandler vault) {
        return
            deploy(
                baseAsset,
                savingsVault,
                admin,
                vaultManager,
                liquidityManager,
                rebalancer,
                MINIMUM_DEPOSIT,
                MINIMUM_WITHDRAW,
                MAXIMUM_VAULT_CAPACITY,
                TEN_PERCENT_APY
            );
    }

    function deploy(
        IERC20 baseAsset,
        IERC4626 savingsVault,
        address admin,
        address vaultManager,
        address liquidityManager,
        address rebalancer,
        uint256 minimumDeposit,
        uint256 minimumWithdraw,
        uint256 capacity,
        uint256 ratePerSecond
    ) internal returns (VaultHandler vault) {
        VaultHandler implementation = new VaultHandler();

        IVault.InitParams memory params = IVault.InitParams({
            name: NAME,
            symbol: SYMBOL,
            baseAsset: baseAsset,
            savingsVault: savingsVault,
            minimumDeposit: minimumDeposit,
            minimumWithdraw: minimumWithdraw,
            capacity: capacity,
            ratePerSecond: ratePerSecond,
            admin: admin,
            vaultManager: vaultManager,
            liquidityManager: liquidityManager,
            rebalancer: rebalancer
        });

        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(Vault.initialize, (params))
        );

        vault = VaultHandler(address(proxy));
    }
}
