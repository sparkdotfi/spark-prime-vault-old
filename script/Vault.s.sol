// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {Vault} from "../src/Vault.sol";
import {IVault} from "../src/interfaces/IVault.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract VaultScript is Script {
    Vault public vault;
    address public implementation;

    function run() public returns (Vault) {
        IVault.InitParams memory params = IVault.InitParams({
            name: vm.envString("VAULT_NAME"),
            symbol: vm.envString("VAULT_SYMBOL"),
            baseAsset: IERC20(vm.envAddress("BASE_ASSET")),
            savingsVault: IERC4626(vm.envAddress("SAVINGS_VAULT")),
            minimumDeposit: vm.envUint("MINIMUM_DEPOSIT"),
            minimumWithdraw: vm.envUint("MINIMUM_WITHDRAW"),
            capacity: vm.envUint("MAXIMUM_CAPACITY"),
            ratePerSecond: vm.envUint("RATE_PER_SECOND"),
            admin: vm.envAddress("ADMIN"),
            vaultManager: vm.envAddress("VAULT_MANAGER"),
            liquidityManager: vm.envAddress("LIQUIDITY_MANAGER"),
            rebalancer: vm.envAddress("REBALANCER")
        });

        vm.startBroadcast();

        implementation = address(new Vault());
        ERC1967Proxy proxy = new ERC1967Proxy(
            implementation,
            abi.encodeCall(Vault.initialize, (params))
        );
        vault = Vault(address(proxy));

        vm.stopBroadcast();

        return vault;
    }
}
