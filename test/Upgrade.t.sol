// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import "./TestBase.t.sol";

contract InvalidSparkPrimeVault1 {

    function proxiableUUID() external pure returns (bytes32) {
        return bytes32(0);
    }

}

contract InvalidSparkPrimeVault2 {}

contract SparkPrimeVaultUpgradeFailureTest is SparkPrimeVaultTestBase {

    function test_upgradeToAndCall_notAdmin() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        vault.upgradeToAndCall(makeAddr("newImplementation"), "");
    }

    function test_upgradeToAndCall_implementationUUIDNotSupported() public {
        address invalidImplementation = address(new InvalidSparkPrimeVault1());

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature(
            "UUPSUnsupportedProxiableUUID(bytes32)",
            bytes32(0)
        ));
        vault.upgradeToAndCall(invalidImplementation, "");
    }

    function test_upgradeToAndCall_implementationHasNoUUID() public {
        address invalidImplementation = address(new InvalidSparkPrimeVault2());

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature(
            "ERC1967InvalidImplementation(address)",
            invalidImplementation
        ));
        vault.upgradeToAndCall(invalidImplementation, "");
    }

}

contract SparkPrimeVaultUpgradeTest is SparkPrimeVaultTestBase {

    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");

    SparkPrimeVault newVaultImplementation;

    uint256 setVsrTimestamp;

    // Do some deposits and requests to get some non-zero state
    function setUp() public override {
        super.setUp();

        newVaultImplementation = new SparkPrimeVault();

        vm.startPrank(admin);
        vault.setVsrBounds(ONE_PCT_VSR, FOUR_PCT_VSR);
        vault.setMaxWithdrawFee(0.01e18);
        vault.setMinimums(100e6, 50e6);
        vm.stopPrank();

        vm.prank(riskManager);
        vault.setWithdrawFee(0.005e18);

        vm.prank(setter);
        vault.setVsr(FOUR_PCT_VSR);

        setVsrTimestamp = block.timestamp;

        deal(address(asset), user1, 1_000_000e6);
        deal(address(asset), user2, 1000e6);

        vm.startPrank(user1);
        asset.approve(address(vault), 1_000_000e6);
        vault.requestDeposit(1_000_000e6, user1, user1);
        vault.requestRedeem(100_000e6, user1, user1);  // Paid out instantly, less the 0.5% fee
        vm.stopPrank();

        // Capacity is full, user2's deposit is queued
        vm.prank(admin);
        vault.setCapacity(900_000e6);

        vm.startPrank(user2);
        asset.approve(address(vault), 1000e6);
        vault.requestDeposit(1000e6, user2, user2);
        vm.stopPrank();

        skip(1 days);
    }

    // Check initial state and that no state changes
    function test_upgradeToAndCall() public {
        assertEq(vault.asset(),           address(asset));
        assertEq(address(vault.spUsdc()), address(spUsdc));
        assertEq(vault.name(),            "Spark Prime USDC");
        assertEq(vault.symbol(),          "spPRIME");
        assertEq(vault.decimals(),        6);

        assertEq(vault.minVsr(), ONE_PCT_VSR);
        assertEq(vault.maxVsr(), FOUR_PCT_VSR);

        assertEq(uint256(vault.rho()), setVsrTimestamp);
        assertEq(uint256(vault.chi()), uint192(1e27));
        assertEq(uint256(vault.vsr()), FOUR_PCT_VSR);

        assertEq(vault.maxCapacity(),    900_000e6);
        assertEq(vault.minDeposit(),     100e6);
        assertEq(vault.minWithdraw(),    50e6);
        assertEq(vault.withdrawFee(),    0.005e18);
        assertEq(vault.maxWithdrawFee(), 0.01e18);

        assertFalse(vault.paused());

        address[] memory defaultAdmins = vault.getRoleMembers(DEFAULT_ADMIN_ROLE);
        address[] memory guardians     = vault.getRoleMembers(GUARDIAN_ROLE);
        address[] memory rebalancers   = vault.getRoleMembers(REBALANCER_ROLE);
        address[] memory riskManagers  = vault.getRoleMembers(RISK_MANAGER_ROLE);
        address[] memory setters       = vault.getRoleMembers(SETTER_ROLE);
        address[] memory takers        = vault.getRoleMembers(TAKER_ROLE);
        address[] memory unpausers     = vault.getRoleMembers(UNPAUSER_ROLE);

        assertEq(defaultAdmins.length, 1);
        assertEq(guardians.length,     1);
        assertEq(rebalancers.length,   1);
        assertEq(riskManagers.length,  1);
        assertEq(setters.length,       1);
        assertEq(takers.length,        1);
        assertEq(unpausers.length,     1);

        assertEq(defaultAdmins[0], admin);
        assertEq(guardians[0],     guardian);
        assertEq(rebalancers[0],   rebalancer);
        assertEq(riskManagers[0],  riskManager);
        assertEq(setters[0],       setter);
        assertEq(takers[0],        taker);
        assertEq(unpausers[0],     unpauser);

        assertGt(vault.totalAssets(),   900_000e6);  // Some accrued interest
        assertGt(vault.assetsOf(user1), 900_000e6);

        assertEq(vault.totalSupply(),    900_000e6);
        assertEq(vault.balanceOf(user1), 900_000e6);

        assertEq(vault.totalQueuedDepositShares(), 1000e6);
        assertEq(vault.totalQueuedRedeemShares(),  0);

        assertEq(asset.balanceOf(user1),          99_500e6);
        assertEq(asset.balanceOf(address(vault)), 900_500e6);  // 1M in, 99.5k out, 1k queued in spUSDC
        assertEq(spUsdc.balanceOf(address(vault)), 1000e6);

        assertEq(vault.pendingDepositShares(user2), 1000e6);

        assertEq(vault.depositHead(),  0);
        assertEq(vault.withdrawHead(), 1);

        uint256 totalAssets = vault.totalAssets();

        assertTrue(vault.getImplementation() != address(newVaultImplementation));

        vm.prank(admin);
        vault.upgradeToAndCall(address(newVaultImplementation), "");

        assertEq(vault.asset(),           address(asset));
        assertEq(address(vault.spUsdc()), address(spUsdc));
        assertEq(vault.name(),            "Spark Prime USDC");
        assertEq(vault.symbol(),          "spPRIME");
        assertEq(vault.decimals(),        6);

        assertEq(vault.minVsr(), ONE_PCT_VSR);
        assertEq(vault.maxVsr(), FOUR_PCT_VSR);

        assertEq(uint256(vault.rho()), setVsrTimestamp);
        assertEq(uint256(vault.chi()), uint192(1e27));
        assertEq(uint256(vault.vsr()), FOUR_PCT_VSR);

        assertEq(vault.maxCapacity(),    900_000e6);
        assertEq(vault.minDeposit(),     100e6);
        assertEq(vault.minWithdraw(),    50e6);
        assertEq(vault.withdrawFee(),    0.005e18);
        assertEq(vault.maxWithdrawFee(), 0.01e18);

        assertFalse(vault.paused());

        defaultAdmins = vault.getRoleMembers(DEFAULT_ADMIN_ROLE);
        guardians     = vault.getRoleMembers(GUARDIAN_ROLE);
        rebalancers   = vault.getRoleMembers(REBALANCER_ROLE);
        riskManagers  = vault.getRoleMembers(RISK_MANAGER_ROLE);
        setters       = vault.getRoleMembers(SETTER_ROLE);
        takers        = vault.getRoleMembers(TAKER_ROLE);
        unpausers     = vault.getRoleMembers(UNPAUSER_ROLE);

        assertEq(defaultAdmins.length, 1);
        assertEq(guardians.length,     1);
        assertEq(rebalancers.length,   1);
        assertEq(riskManagers.length,  1);
        assertEq(setters.length,       1);
        assertEq(takers.length,        1);
        assertEq(unpausers.length,     1);

        assertEq(defaultAdmins[0], admin);
        assertEq(guardians[0],     guardian);
        assertEq(rebalancers[0],   rebalancer);
        assertEq(riskManagers[0],  riskManager);
        assertEq(setters[0],       setter);
        assertEq(takers[0],        taker);
        assertEq(unpausers[0],     unpauser);

        assertEq(vault.totalAssets(),   totalAssets);
        assertEq(vault.assetsOf(user1), totalAssets);

        assertEq(vault.totalSupply(),    900_000e6);
        assertEq(vault.balanceOf(user1), 900_000e6);

        assertEq(vault.totalQueuedDepositShares(), 1000e6);
        assertEq(vault.totalQueuedRedeemShares(),  0);

        assertEq(asset.balanceOf(user1),          99_500e6);
        assertEq(asset.balanceOf(address(vault)), 900_500e6);  // 1M in, 99.5k out, 1k queued in spUSDC
        assertEq(spUsdc.balanceOf(address(vault)), 1000e6);

        assertEq(vault.pendingDepositShares(user2), 1000e6);

        assertEq(vault.depositHead(),  0);
        assertEq(vault.withdrawHead(), 1);

        assertTrue(vault.getImplementation() == address(newVaultImplementation));
    }

}
