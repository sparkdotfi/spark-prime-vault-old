// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.13;

import { Script } from "../lib/forge-std/src/Script.sol";
import { Vault } from "../src/Vault.sol";
import { IVault } from "../src/interfaces/IVault.sol";

import {
    ERC1967Proxy
} from "../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract VaultScript is Script {

    function run() public returns (address proxy) {
        IVault.InitParams memory params = IVault.InitParams({
            name: vm.envString("VAULT_NAME"),
            symbol: vm.envString("VAULT_SYMBOL"),
            baseAsset: vm.envAddress("BASE_ASSET"),
            savingsVault: vm.envAddress("SAVINGS_VAULT"),
            minimumDeposit: vm.envUint("MINIMUM_DEPOSIT"),
            minimumWithdraw: vm.envUint("MINIMUM_WITHDRAW"),
            capacity: vm.envUint("MAXIMUM_CAPACITY"),
            ratePerSecond: vm.envUint("RATE_PER_SECOND"),
            admin: vm.envAddress("ADMIN"),
            vaultManager: vm.envAddress("VAULT_MANAGER"),
            liquidityManager: vm.envAddress("LIQUIDITY_MANAGER"),
            rebalancer: vm.envAddress("REBALANCER"),
            guardian: vm.envAddress("GUARDIAN"),
            riskManager: vm.envAddress("RISK_MANAGER")
        });

        vm.startBroadcast();

        address implementation = address(new Vault());

        proxy = address(new ERC1967Proxy(
            implementation,
            abi.encodeCall(Vault.initialize, (params))
        ));

        vm.stopBroadcast();
    }

}
