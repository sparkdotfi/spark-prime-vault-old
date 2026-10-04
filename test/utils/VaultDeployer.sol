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
        IVault.InitParams memory params
    ) internal returns (VaultHandler vault) {
        VaultHandler implementation = new VaultHandler();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(Vault.initialize, (params))
        );
        vault = VaultHandler(address(proxy));
    }
}
