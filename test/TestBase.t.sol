// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";

import { ERC20Mock as MockERC20 } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { ERC1967Proxy }           from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { SparkVault } from "spark-vaults-v2/SparkVault.sol";

import { SparkPrimeVault } from "../src/SparkPrimeVault.sol";

contract MockERC20SixDecimals is MockERC20 {

    function decimals() public pure override returns (uint8) {
        return 6;
    }

}

contract SparkPrimeVaultTestBase is Test {

    uint256 constant ONE_PCT_VSR  = 1.000000000315522921573372069e27;
    uint256 constant FOUR_PCT_VSR = 1.000000001243680656318820312e27;
    uint256 constant FIVE_PCT_VSR = 1.000000001547125957863212448e27;
    uint256 constant MAX_VSR      = 1.000000021979553151239153027e27;  // 100% APY

    address admin       = makeAddr("admin");
    address guardian    = makeAddr("guardian");
    address rebalancer  = makeAddr("rebalancer");
    address riskManager = makeAddr("riskManager");
    address setter      = makeAddr("setter");
    address taker       = makeAddr("taker");
    address unpauser    = makeAddr("unpauser");

    bytes32 DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 GUARDIAN_ROLE      = keccak256("GUARDIAN_ROLE");
    bytes32 REBALANCER_ROLE    = keccak256("REBALANCER_ROLE");
    bytes32 RISK_MANAGER_ROLE  = keccak256("RISK_MANAGER_ROLE");
    bytes32 SETTER_ROLE        = keccak256("SETTER_ROLE");
    bytes32 TAKER_ROLE         = keccak256("TAKER_ROLE");
    bytes32 UNPAUSER_ROLE      = keccak256("UNPAUSER_ROLE");

    MockERC20       asset;
    SparkVault      spUsdc;
    SparkPrimeVault vault;

    function setUp() public virtual {
        asset = new MockERC20SixDecimals();

        spUsdc = SparkVault(
            address(new ERC1967Proxy(
                address(new SparkVault()),
                abi.encodeCall(
                    SparkVault.initialize,
                    (address(asset), "Spark Savings USDC V2", "spUSDC", admin)
                )
            ))
        );

        vault = SparkPrimeVault(
            address(new ERC1967Proxy(
                address(new SparkPrimeVault()),
                abi.encodeCall(
                    SparkPrimeVault.initialize,
                    (address(asset), address(spUsdc), "Spark Prime USDC", "spPRIME", admin)
                )
            ))
        );

        vm.startPrank(admin);
        spUsdc.grantRole(SETTER_ROLE, setter);
        spUsdc.setDepositCap(type(uint256).max);
        spUsdc.setVsrBounds(1e27, MAX_VSR);

        vault.grantRole(GUARDIAN_ROLE,     guardian);
        vault.grantRole(REBALANCER_ROLE,   rebalancer);
        vault.grantRole(RISK_MANAGER_ROLE, riskManager);
        vault.grantRole(SETTER_ROLE,       setter);
        vault.grantRole(TAKER_ROLE,        taker);
        vault.grantRole(UNPAUSER_ROLE,     unpauser);
        vault.setCapacity(1_000_000e6);
        vm.stopPrank();
    }

}
