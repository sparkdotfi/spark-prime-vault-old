// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import "./TestBase.t.sol";

contract SparkPrimeVaultSetCapacityFailureTests is SparkPrimeVaultTestBase {

    function test_setCapacity_notAdmin() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        vault.setCapacity(2_000_000e6);
    }

    function test_setCapacity_capacityTooHighBoundary() public {
        vm.startPrank(admin);
        vm.expectRevert("SparkPrimeVault/capacity-too-high");
        vault.setCapacity(uint256(type(uint128).max) + 1);

        vault.setCapacity(type(uint128).max);
    }

}

contract SparkPrimeVaultSetCapacitySuccessTests is SparkPrimeVaultTestBase {

    event CapacitySet(uint256 oldCapacity, uint256 newCapacity);

    function test_setCapacity() public {
        assertEq(vault.maxCapacity(),       1_000_000e6);
        assertEq(vault.availableCapacity(), 1_000_000e6);

        vm.startPrank(admin);
        vm.expectEmit(address(vault));
        emit CapacitySet(1_000_000e6, 2_000_000e6);
        vault.setCapacity(2_000_000e6);

        assertEq(vault.maxCapacity(),       2_000_000e6);
        assertEq(vault.availableCapacity(), 2_000_000e6);

        vm.expectEmit(address(vault));
        emit CapacitySet(2_000_000e6, type(uint128).max);
        vault.setCapacity(type(uint128).max);

        assertEq(vault.maxCapacity(),       type(uint128).max);
        assertEq(vault.availableCapacity(), type(uint128).max);

        vm.expectEmit(address(vault));
        emit CapacitySet(type(uint128).max, 0);
        vault.setCapacity(0);

        assertEq(vault.maxCapacity(),       0);
        assertEq(vault.availableCapacity(), 0);

        // With no capacity a deposit request can't be approved instantly, it is queued instead
        address randomUser = makeAddr("randomUser");
        vm.startPrank(randomUser);
        deal(address(asset), randomUser, 1);
        asset.approve(address(vault), 1);
        vault.requestDeposit(1, randomUser, randomUser);
        vm.stopPrank();

        assertEq(vault.balanceOf(randomUser),            0);
        assertEq(vault.pendingDepositShares(randomUser), 1);
    }

    function test_setCapacity_belowTotalSupply() public {
        address user1 = makeAddr("user1");
        deal(address(asset), user1, 1000e6);

        vm.startPrank(user1);
        asset.approve(address(vault), 1000e6);
        vault.requestDeposit(1000e6, user1, user1);
        vm.stopPrank();

        assertEq(vault.totalSupply(),       1000e6);
        assertEq(vault.availableCapacity(), 1_000_000e6 - 1000e6);

        // Capacity can be set below the current supply, no room is left until supply drops
        vm.prank(admin);
        vm.expectEmit(address(vault));
        emit CapacitySet(1_000_000e6, 500e6);
        vault.setCapacity(500e6);

        assertEq(vault.maxCapacity(),       500e6);
        assertEq(vault.totalSupply(),       1000e6);
        assertEq(vault.availableCapacity(), 0);
    }

}

contract SparkPrimeVaultSetMaxWithdrawFeeFailureTests is SparkPrimeVaultTestBase {

    function test_setMaxWithdrawFee_notAdmin() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        vault.setMaxWithdrawFee(0.01e18);
    }

    function test_setMaxWithdrawFee_feeTooHighBoundary() public {
        vm.startPrank(admin);
        vm.expectRevert("SparkPrimeVault/fee-too-high");
        vault.setMaxWithdrawFee(0.01e18 + 1);

        vault.setMaxWithdrawFee(0.01e18);  // MAX_WITHDRAW_FEE is 1%
    }

}

contract SparkPrimeVaultSetMaxWithdrawFeeSuccessTests is SparkPrimeVaultTestBase {

    event MaxWithdrawFeeSet(uint256 oldFee, uint256 newFee);

    function test_setMaxWithdrawFee() public {
        assertEq(vault.maxWithdrawFee(), 0);
        assertEq(vault.withdrawFee(),    0);

        vm.prank(admin);
        vm.expectEmit(address(vault));
        emit MaxWithdrawFeeSet(0, 0.01e18);
        vault.setMaxWithdrawFee(0.01e18);

        assertEq(vault.maxWithdrawFee(), 0.01e18);
        assertEq(vault.withdrawFee(),    0);

        vm.prank(riskManager);
        vault.setWithdrawFee(0.01e18);

        assertEq(vault.maxWithdrawFee(), 0.01e18);
        assertEq(vault.withdrawFee(),    0.01e18);

        // Lowering the max fee below the live fee clamps the live fee
        vm.prank(admin);
        vm.expectEmit(address(vault));
        emit MaxWithdrawFeeSet(0.01e18, 0.002e18);
        vault.setMaxWithdrawFee(0.002e18);

        assertEq(vault.maxWithdrawFee(), 0.002e18);
        assertEq(vault.withdrawFee(),    0.002e18);

        // Raising the max fee again doesn't change the live fee
        vm.prank(admin);
        vm.expectEmit(address(vault));
        emit MaxWithdrawFeeSet(0.002e18, 0.005e18);
        vault.setMaxWithdrawFee(0.005e18);

        assertEq(vault.maxWithdrawFee(), 0.005e18);
        assertEq(vault.withdrawFee(),    0.002e18);
    }

}

contract SparkPrimeVaultSetMinimumsFailureTests is SparkPrimeVaultTestBase {

    function test_setMinimums_notAdmin() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        vault.setMinimums(100e6, 50e6);
    }

}

contract SparkPrimeVaultSetMinimumsSuccessTests is SparkPrimeVaultTestBase {

    event MinimumsSet(uint256 minDeposit, uint256 minWithdraw);

    function test_setMinimums() public {
        assertEq(vault.minDeposit(),  0);
        assertEq(vault.minWithdraw(), 0);

        vm.prank(admin);
        vm.expectEmit(address(vault));
        emit MinimumsSet(100e6, 50e6);
        vault.setMinimums(100e6, 50e6);

        assertEq(vault.minDeposit(),  100e6);
        assertEq(vault.minWithdraw(), 50e6);

        address randomUser = makeAddr("randomUser");
        vm.startPrank(randomUser);
        deal(address(asset), randomUser, 200e6);
        asset.approve(address(vault), 200e6);
        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestDeposit(100e6 - 1, randomUser, randomUser);

        vault.requestDeposit(100e6, randomUser, randomUser);

        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestRedeem(50e6 - 1, randomUser, randomUser);

        vault.requestRedeem(50e6, randomUser, randomUser);
        vm.stopPrank();

        vm.prank(admin);
        vm.expectEmit(address(vault));
        emit MinimumsSet(0, 0);
        vault.setMinimums(0, 0);

        assertEq(vault.minDeposit(),  0);
        assertEq(vault.minWithdraw(), 0);
    }

}

contract SparkPrimeVaultSetVsrBoundsFailureTests is SparkPrimeVaultTestBase {

    function test_setVsrBounds_notAdmin() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        vault.setVsrBounds(1e27, FOUR_PCT_VSR);
    }

    function test_setVsrBounds_belowRayBoundary() public {
        vm.startPrank(admin);
        vm.expectRevert("SparkPrimeVault/vsr-too-low");
        vault.setVsrBounds(1e27 - 1, FOUR_PCT_VSR);

        vault.setVsrBounds(1e27, FOUR_PCT_VSR);
    }

    function test_setVsrBounds_aboveMaxVsrBoundary() public {
        vm.startPrank(admin);
        vm.expectRevert("SparkPrimeVault/vsr-too-high");
        vault.setVsrBounds(1e27, MAX_VSR + 1);

        vault.setVsrBounds(1e27, MAX_VSR);
    }

    function test_setVsrBounds_minVsrGtMaxVsrBoundary() public {
        vm.startPrank(admin);
        vm.expectRevert("SparkPrimeVault/min-vsr-gt-max-vsr");
        vault.setVsrBounds(FOUR_PCT_VSR + 1, FOUR_PCT_VSR);

        vault.setVsrBounds(FOUR_PCT_VSR, FOUR_PCT_VSR);
    }

}

contract SparkPrimeVaultSetVsrBoundsSuccessTests is SparkPrimeVaultTestBase {

    event VsrBoundsSet(uint256 oldMinVsr, uint256 oldMaxVsr, uint256 newMinVsr, uint256 newMaxVsr);

    function test_setVsrBounds() public {
        assertEq(vault.minVsr(), 1e27);
        assertEq(vault.maxVsr(), 1e27);

        vm.startPrank(admin);
        vm.expectEmit(address(vault));
        emit VsrBoundsSet(1e27, 1e27, ONE_PCT_VSR, FOUR_PCT_VSR);
        vault.setVsrBounds(ONE_PCT_VSR, FOUR_PCT_VSR);

        assertEq(vault.minVsr(), ONE_PCT_VSR);
        assertEq(vault.maxVsr(), FOUR_PCT_VSR);
    }

}

contract SparkPrimeVaultSetVsrFailureTests is SparkPrimeVaultTestBase {

    function test_setVsr_notSetter() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            SETTER_ROLE
        ));
        vault.setVsr(ONE_PCT_VSR);
    }

    function test_setVsr_belowMinVsrBoundary() public {
        vm.startPrank(setter);
        vm.expectRevert("SparkPrimeVault/vsr-too-low");
        vault.setVsr(1e27 - 1);

        vault.setVsr(1e27);  // Min is 1e27 on deployment

        vm.stopPrank();

        vm.prank(admin);
        vault.setVsrBounds(ONE_PCT_VSR, FOUR_PCT_VSR);

        vm.startPrank(setter);
        vm.expectRevert("SparkPrimeVault/vsr-too-low");
        vault.setVsr(ONE_PCT_VSR - 1);

        vault.setVsr(ONE_PCT_VSR);
    }

    function test_setVsr_aboveMaxVsrBoundary() public {
        vm.startPrank(setter);
        vm.expectRevert("SparkPrimeVault/vsr-too-high");
        vault.setVsr(1e27 + 1);  // Can't set VSR until admin sets bounds

        vault.setVsr(1e27);  // Max is 1e27 on deployment

        vm.stopPrank();

        vm.prank(admin);
        vault.setVsrBounds(ONE_PCT_VSR, FOUR_PCT_VSR);

        vm.startPrank(setter);
        vm.expectRevert("SparkPrimeVault/vsr-too-high");
        vault.setVsr(FOUR_PCT_VSR + 1);

        vault.setVsr(FOUR_PCT_VSR);
    }

}

contract SparkPrimeVaultSetVsrSuccessTests is SparkPrimeVaultTestBase {

    event Drip(uint256 chi, uint256 diff);
    event VsrSet(address indexed sender, uint256 oldVsr, uint256 newVsr);

    function setUp() public override {
        super.setUp();
        vm.prank(admin);
        vault.setVsrBounds(1e27, FOUR_PCT_VSR);
    }

    function test_setVsr() public {
        uint256 deployTimestamp = block.timestamp;

        skip(10 days);

        assertEq(uint256(vault.chi()), 1e27);
        assertEq(uint256(vault.rho()), deployTimestamp);
        assertEq(uint256(vault.vsr()), 1e27);

        vm.prank(setter);
        vm.expectEmit(address(vault));
        emit Drip(1e27, 0);
        emit VsrSet(setter, 1e27, FOUR_PCT_VSR);
        vault.setVsr(FOUR_PCT_VSR);

        assertEq(uint256(vault.chi()), 1e27);
        assertEq(uint256(vault.rho()), block.timestamp);
        assertEq(uint256(vault.vsr()), FOUR_PCT_VSR);

        assertEq(vault.nowChi(), 1e27);

        skip(10 days);

        assertGt(vault.nowChi(), 1e27);
    }

}

contract SparkPrimeVaultTakeFailureTests is SparkPrimeVaultTestBase {

    function test_take_notTaker() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            TAKER_ROLE
        ));
        vault.take(1_000_000e6);
    }

    function test_take_insufficientLiquidityBoundary() public {
        deal(address(asset), address(vault), 1_000_000e6);

        vm.startPrank(taker);
        vm.expectRevert("SparkPrimeVault/insufficient-liquidity");
        vault.take(1_000_000e6 + 1);

        vault.take(1_000_000e6);
    }

    function test_take_afterRedeemPaidOutBoundary() public {
        address user1 = makeAddr("user1");
        deal(address(asset), user1, 1000e6);

        vm.startPrank(user1);
        asset.approve(address(vault), 1000e6);
        vault.requestDeposit(1000e6, user1, user1);
        vault.requestRedeem(200e6, user1, user1);  // Paid out instantly, 200e6 leaves the vault
        vm.stopPrank();

        assertEq(asset.balanceOf(address(vault)), 800e6);
        assertEq(asset.balanceOf(user1),          200e6);

        vm.startPrank(taker);
        vm.expectRevert("SparkPrimeVault/insufficient-liquidity");
        vault.take(800e6 + 1);

        vault.take(800e6);
    }

}

contract SparkPrimeVaultTakeSuccessTests is SparkPrimeVaultTestBase {

    event Take(address indexed to, uint256 value);

    function test_take() public {
        deal(address(asset), address(vault), 1_000_000e6);

        assertEq(asset.balanceOf(address(vault)), 1_000_000e6);
        assertEq(asset.balanceOf(taker),          0);

        vm.prank(taker);
        vm.expectEmit(address(vault));
        emit Take(taker, 1_000_000e6);
        vault.take(1_000_000e6);

        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(taker),          1_000_000e6);
    }

    function test_take_doesNotChangeAccounting() public {
        address user1 = makeAddr("user1");
        deal(address(asset), user1, 1000e6);

        vm.startPrank(user1);
        asset.approve(address(vault), 1000e6);
        vault.requestDeposit(1000e6, user1, user1);
        vm.stopPrank();

        assertEq(vault.totalSupply(),             1000e6);
        assertEq(vault.totalAssets(),             1000e6);
        assertEq(vault.assetsOf(user1),           1000e6);
        assertEq(vault.availableLiquidAssets(),   1000e6);
        assertEq(asset.balanceOf(address(vault)), 1000e6);

        vm.prank(taker);
        vault.take(1000e6);

        // Liabilities are unchanged, only the liquidity is gone
        assertEq(vault.totalSupply(),             1000e6);
        assertEq(vault.totalAssets(),             1000e6);
        assertEq(vault.assetsOf(user1),           1000e6);
        assertEq(vault.availableLiquidAssets(),   0);
        assertEq(asset.balanceOf(address(vault)), 0);
    }

}

contract SparkPrimeVaultDepositToSavingsFailureTests is SparkPrimeVaultTestBase {

    function test_depositToSavings_notRebalancer() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            REBALANCER_ROLE
        ));
        vault.depositToSavings(1_000_000e6);
    }

    function test_depositToSavings_insufficientLiquidityBoundary() public {
        deal(address(asset), address(vault), 1_000_000e6);

        vm.startPrank(rebalancer);
        vm.expectRevert("SparkPrimeVault/insufficient-liquidity");
        vault.depositToSavings(1_000_000e6 + 1);

        vault.depositToSavings(1_000_000e6);
    }

    function test_depositToSavings_savingsDepositCapExceededBoundary() public {
        deal(address(asset), address(vault), 1_000_000e6);

        vm.prank(admin);
        spUsdc.setDepositCap(500_000e6);

        vm.startPrank(rebalancer);
        vm.expectRevert("SparkVault/deposit-cap-exceeded");
        vault.depositToSavings(500_000e6 + 1);

        vault.depositToSavings(500_000e6);
    }

}

contract SparkPrimeVaultDepositToSavingsSuccessTests is SparkPrimeVaultTestBase {

    function test_depositToSavings() public {
        deal(address(asset), address(vault), 1_000_000e6);

        assertEq(asset.balanceOf(address(vault)),  1_000_000e6);
        assertEq(asset.balanceOf(address(spUsdc)), 0);
        assertEq(spUsdc.balanceOf(address(vault)), 0);
        assertEq(vault.availableLiquidAssets(),    1_000_000e6);

        vm.prank(rebalancer);
        vault.depositToSavings(600_000e6);

        // Moving idle cash into the sleeve doesn't change the liquidity available to redeemers
        assertEq(asset.balanceOf(address(vault)),  400_000e6);
        assertEq(asset.balanceOf(address(spUsdc)), 600_000e6);
        assertEq(spUsdc.balanceOf(address(vault)), 600_000e6);
        assertEq(vault.availableLiquidAssets(),    1_000_000e6);

        vm.prank(rebalancer);
        vault.depositToSavings(400_000e6);

        assertEq(asset.balanceOf(address(vault)),  0);
        assertEq(asset.balanceOf(address(spUsdc)), 1_000_000e6);
        assertEq(spUsdc.balanceOf(address(vault)), 1_000_000e6);
        assertEq(vault.availableLiquidAssets(),    1_000_000e6);
    }

}

contract SparkPrimeVaultWithdrawFromSavingsFailureTests is SparkPrimeVaultTestBase {

    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");

    function setUp() public override {
        super.setUp();

        deal(address(asset), user1, 1000e6);
        deal(address(asset), user2, 400e6);

        vm.startPrank(user1);
        asset.approve(address(vault), 1000e6);
        vault.requestDeposit(1000e6, user1, user1);
        vm.stopPrank();

        // 600e6 of free sleeve
        vm.prank(rebalancer);
        vault.depositToSavings(600e6);

        // Capacity is full, user2's deposit is queued and its spUSDC is locked
        vm.prank(admin);
        vault.setCapacity(1000e6);

        vm.startPrank(user2);
        asset.approve(address(vault), 400e6);
        vault.requestDeposit(400e6, user2, user2);
        vm.stopPrank();

        assertEq(spUsdc.balanceOf(address(vault)),  1000e6);
        assertEq(vault.totalQueuedDepositShares(),  400e6);
    }

    function test_withdrawFromSavings_notRebalancer() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            REBALANCER_ROLE
        ));
        vault.withdrawFromSavings(600e6);
    }

    function test_withdrawFromSavings_queuedSharesLockedBoundary() public {
        vm.startPrank(rebalancer);
        vm.expectRevert("SparkPrimeVault/queued-shares-locked");
        vault.withdrawFromSavings(600e6 + 1);

        vault.withdrawFromSavings(600e6);
    }

    function test_withdrawFromSavings_savingsInsufficientLiquidityBoundary() public {
        vm.prank(admin);
        spUsdc.grantRole(TAKER_ROLE, taker);

        // spUSDC only has 500e6 of its 1000e6 left
        vm.prank(taker);
        spUsdc.take(500e6);

        vm.startPrank(rebalancer);
        vm.expectRevert("SparkVault/insufficient-liquidity");
        vault.withdrawFromSavings(500e6 + 1);

        vault.withdrawFromSavings(500e6);
    }

}

contract SparkPrimeVaultWithdrawFromSavingsSuccessTests is SparkPrimeVaultTestBase {

    function test_withdrawFromSavings() public {
        deal(address(asset), address(vault), 1_000_000e6);

        vm.prank(rebalancer);
        vault.depositToSavings(1_000_000e6);

        assertEq(asset.balanceOf(address(vault)),  0);
        assertEq(asset.balanceOf(address(spUsdc)), 1_000_000e6);
        assertEq(spUsdc.balanceOf(address(vault)), 1_000_000e6);
        assertEq(vault.availableLiquidAssets(),    1_000_000e6);

        vm.prank(rebalancer);
        vault.withdrawFromSavings(600_000e6);

        // Moving the sleeve back to idle cash doesn't change the liquidity available to redeemers
        assertEq(asset.balanceOf(address(vault)),  600_000e6);
        assertEq(asset.balanceOf(address(spUsdc)), 400_000e6);
        assertEq(spUsdc.balanceOf(address(vault)), 400_000e6);
        assertEq(vault.availableLiquidAssets(),    1_000_000e6);

        vm.prank(rebalancer);
        vault.withdrawFromSavings(400_000e6);

        assertEq(asset.balanceOf(address(vault)),  1_000_000e6);
        assertEq(asset.balanceOf(address(spUsdc)), 0);
        assertEq(spUsdc.balanceOf(address(vault)), 0);
        assertEq(vault.availableLiquidAssets(),    1_000_000e6);
    }

    function test_withdrawFromSavings_withSavingsYield() public {
        deal(address(asset), address(vault), 1_000_000e6);

        vm.prank(rebalancer);
        vault.depositToSavings(1_000_000e6);

        vm.prank(setter);
        spUsdc.setVsr(FOUR_PCT_VSR);

        skip(1 days);

        // Back the spUSDC yield
        deal(address(asset), address(spUsdc), spUsdc.totalAssets());

        uint256 assets = spUsdc.assetsOf(address(vault));

        assertEq(assets, 1_000_107.459782e6);

        vm.prank(rebalancer);
        vault.withdrawFromSavings(assets);

        assertEq(asset.balanceOf(address(vault)),  assets);
        assertEq(asset.balanceOf(address(spUsdc)), 0);
        assertEq(spUsdc.balanceOf(address(vault)), 0);
    }

}

contract SparkPrimeVaultSetWithdrawFeeFailureTests is SparkPrimeVaultTestBase {

    function test_setWithdrawFee_notRiskManager() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RISK_MANAGER_ROLE
        ));
        vault.setWithdrawFee(0.005e18);
    }

    function test_setWithdrawFee_feeTooHighBoundary() public {
        vm.startPrank(riskManager);
        vm.expectRevert("SparkPrimeVault/fee-too-high");
        vault.setWithdrawFee(1);  // Can't set a fee until admin sets the max fee

        vault.setWithdrawFee(0);  // Max is 0 on deployment

        vm.stopPrank();

        vm.prank(admin);
        vault.setMaxWithdrawFee(0.005e18);

        vm.startPrank(riskManager);
        vm.expectRevert("SparkPrimeVault/fee-too-high");
        vault.setWithdrawFee(0.005e18 + 1);

        vault.setWithdrawFee(0.005e18);
    }

}

contract SparkPrimeVaultSetWithdrawFeeSuccessTests is SparkPrimeVaultTestBase {

    event WithdrawFeeSet(uint256 oldFee, uint256 newFee);

    function setUp() public override {
        super.setUp();
        vm.prank(admin);
        vault.setMaxWithdrawFee(0.01e18);
    }

    function test_setWithdrawFee() public {
        assertEq(vault.withdrawFee(), 0);

        vm.startPrank(riskManager);
        vm.expectEmit(address(vault));
        emit WithdrawFeeSet(0, 0.005e18);
        vault.setWithdrawFee(0.005e18);

        assertEq(vault.withdrawFee(), 0.005e18);

        vm.expectEmit(address(vault));
        emit WithdrawFeeSet(0.005e18, 0.01e18);
        vault.setWithdrawFee(0.01e18);

        assertEq(vault.withdrawFee(), 0.01e18);

        vm.expectEmit(address(vault));
        emit WithdrawFeeSet(0.01e18, 0);
        vault.setWithdrawFee(0);

        assertEq(vault.withdrawFee(), 0);
    }

}

contract SparkPrimeVaultSetChiFailureTests is SparkPrimeVaultTestBase {

    function setUp() public override {
        super.setUp();

        vm.prank(admin);
        vault.setVsrBounds(1e27, FOUR_PCT_VSR);

        vm.prank(setter);
        vault.setVsr(FOUR_PCT_VSR);
    }

    function test_setChi_notRiskManager() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RISK_MANAGER_ROLE
        ));
        vault.setChi(0.9e27);
    }

    function test_setChi_notPaused() public {
        vm.startPrank(riskManager);
        vm.expectRevert("SparkPrimeVault/not-paused");
        vault.setChi(0.9e27);
        vm.stopPrank();

        vm.prank(guardian);
        vault.pause();

        vm.prank(riskManager);
        vault.setChi(0.9e27);
    }

    function test_setChi_zeroChi() public {
        vm.prank(guardian);
        vault.pause();

        vm.startPrank(riskManager);
        vm.expectRevert("SparkPrimeVault/invalid-chi");
        vault.setChi(0);

        vault.setChi(1);
    }

    function test_setChi_chiNotDecreasingBoundary() public {
        skip(1 days);

        vm.prank(guardian);
        vault.pause();

        // The stored chi is stale, the comparison is against the accrued chi
        uint256 nowChi = vault.nowChi();

        assertGt(nowChi, uint256(vault.chi()));

        vm.startPrank(riskManager);
        vm.expectRevert("SparkPrimeVault/invalid-chi");
        vault.setChi(nowChi);

        vault.setChi(nowChi - 1);
    }

}

contract SparkPrimeVaultSetChiSuccessTests is SparkPrimeVaultTestBase {

    event ChiSet(uint256 oldChi, uint256 newChi);
    event Drip(uint256 chi, uint256 diff);

    address user1 = makeAddr("user1");

    function setUp() public override {
        super.setUp();

        vm.prank(admin);
        vault.setVsrBounds(1e27, FOUR_PCT_VSR);

        vm.prank(setter);
        vault.setVsr(FOUR_PCT_VSR);

        deal(address(asset), user1, 1_000_000e6);

        vm.startPrank(user1);
        asset.approve(address(vault), 1_000_000e6);
        vault.requestDeposit(1_000_000e6, user1, user1);
        vm.stopPrank();

        skip(1 days);
    }

    function test_setChi() public {
        vm.prank(guardian);
        vault.pause();

        uint256 nowChi = vault.nowChi();

        assertEq(nowChi,                 1.000107459782027902551816735e27);
        assertEq(uint256(vault.chi()),   1e27);
        assertEq(uint256(vault.rho()),   block.timestamp - 1 days);
        assertEq(vault.totalAssets(),    1_000_107.459782e6);
        assertEq(vault.assetsOf(user1),  1_000_107.459782e6);
        assertEq(vault.totalSupply(),    1_000_000e6);
        assertEq(vault.balanceOf(user1), 1_000_000e6);

        // Book a 10% loss
        vm.prank(riskManager);
        vm.expectEmit(address(vault));
        emit Drip(nowChi, 107.459782e6);
        emit ChiSet(nowChi, 0.9e27);
        vault.setChi(0.9e27);

        assertEq(vault.nowChi(),         0.9e27);
        assertEq(uint256(vault.chi()),   0.9e27);
        assertEq(uint256(vault.rho()),   block.timestamp);
        assertEq(vault.totalAssets(),    900_000e6);
        assertEq(vault.assetsOf(user1),  900_000e6);
        assertEq(vault.totalSupply(),    1_000_000e6);
        assertEq(vault.balanceOf(user1), 1_000_000e6);

        // Accrual continues from the new chi at the same VSR
        skip(1 days);

        assertEq(vault.nowChi(),        0.900096713803825112296635061e27);
        assertEq(vault.totalAssets(),   900_096.713803e6);
        assertEq(vault.assetsOf(user1), 900_096.713803e6);
    }

}

contract SparkPrimeVaultPauseFailureTests is SparkPrimeVaultTestBase {

    function test_pause_notGuardian() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            GUARDIAN_ROLE
        ));
        vault.pause();
    }

}

contract SparkPrimeVaultPauseSuccessTests is SparkPrimeVaultTestBase {

    event Paused(address account);

    address user1 = makeAddr("user1");

    function setUp() public override {
        super.setUp();

        deal(address(asset), user1, 2000e6);

        vm.startPrank(user1);
        asset.approve(address(vault), 2000e6);
        vault.requestDeposit(1000e6, user1, user1);
        vm.stopPrank();
    }

    function test_pause() public {
        assertFalse(vault.paused());

        vm.prank(guardian);
        vm.expectEmit(address(vault));
        emit Paused(guardian);
        vault.pause();

        assertTrue(vault.paused());

        // Requests and queue processing are blocked
        vm.startPrank(user1);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.requestDeposit(1000e6, user1, user1);

        vm.expectRevert("SparkPrimeVault/paused");
        vault.requestRedeem(100e6, user1, user1);
        vm.stopPrank();

        vm.prank(rebalancer);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.processDepositQueue(type(uint256).max);

        vm.expectRevert("SparkPrimeVault/paused");
        vault.processWithdrawQueue(type(uint256).max);

        // Pausing an already paused vault is a no-op
        vm.prank(guardian);
        vm.expectEmit(address(vault));
        emit Paused(guardian);
        vault.pause();

        assertTrue(vault.paused());
    }

    function test_pause_doesNotBlockTransfersOrLiquidityManagement() public {
        vm.prank(guardian);
        vault.pause();

        vm.prank(user1);
        vault.transfer(makeAddr("user2"), 100e6);

        assertEq(vault.balanceOf(user1), 900e6);

        vm.prank(taker);
        vault.take(100e6);

        vm.startPrank(rebalancer);
        vault.depositToSavings(100e6);
        vault.withdrawFromSavings(100e6);
        vm.stopPrank();
    }

}

contract SparkPrimeVaultUnpauseFailureTests is SparkPrimeVaultTestBase {

    function test_unpause_notUnpauser() public {
        vm.prank(guardian);
        vault.pause();

        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            UNPAUSER_ROLE
        ));
        vault.unpause();
    }

    function test_unpause_guardianCannotUnpause() public {
        vm.startPrank(guardian);
        vault.pause();

        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            guardian,
            UNPAUSER_ROLE
        ));
        vault.unpause();
    }

}

contract SparkPrimeVaultUnpauseSuccessTests is SparkPrimeVaultTestBase {

    event Unpaused(address account);

    address user1 = makeAddr("user1");

    function test_unpause() public {
        vm.prank(guardian);
        vault.pause();

        assertTrue(vault.paused());

        deal(address(asset), user1, 1000e6);

        vm.startPrank(user1);
        asset.approve(address(vault), 1000e6);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.requestDeposit(1000e6, user1, user1);
        vm.stopPrank();

        vm.prank(unpauser);
        vm.expectEmit(address(vault));
        emit Unpaused(unpauser);
        vault.unpause();

        assertFalse(vault.paused());

        vm.prank(user1);
        vault.requestDeposit(1000e6, user1, user1);

        assertEq(vault.balanceOf(user1), 1000e6);

        // Unpausing an already unpaused vault is a no-op
        vm.prank(unpauser);
        vm.expectEmit(address(vault));
        emit Unpaused(unpauser);
        vault.unpause();

        assertFalse(vault.paused());
    }

}

contract SparkPrimeVaultGrantRoleFailureTests is SparkPrimeVaultTestBase {

    function test_grantRole_notAdmin() public {
        bytes32[] memory roles = new bytes32[](7);
        roles[0] = DEFAULT_ADMIN_ROLE;
        roles[1] = GUARDIAN_ROLE;
        roles[2] = REBALANCER_ROLE;
        roles[3] = RISK_MANAGER_ROLE;
        roles[4] = SETTER_ROLE;
        roles[5] = TAKER_ROLE;
        roles[6] = UNPAUSER_ROLE;

        for (uint256 i = 0; i < roles.length; i++) {
            bytes32 role = roles[i];
            vm.expectRevert(abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)",
                address(this),
                DEFAULT_ADMIN_ROLE
            ));
            vault.grantRole(role, address(0x1234));
        }
    }

}

contract SparkPrimeVaultGrantRoleSuccessTests is SparkPrimeVaultTestBase {

    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    function test_grantRole() public {
        bytes32[] memory roles = new bytes32[](7);
        roles[0] = DEFAULT_ADMIN_ROLE;
        roles[1] = GUARDIAN_ROLE;
        roles[2] = REBALANCER_ROLE;
        roles[3] = RISK_MANAGER_ROLE;
        roles[4] = SETTER_ROLE;
        roles[5] = TAKER_ROLE;
        roles[6] = UNPAUSER_ROLE;

        // admin (DEFAULT_ADMIN_ROLE) should be allowed to grant DEFAULT_ADMIN_ROLE, GUARDIAN_ROLE,
        // REBALANCER_ROLE, RISK_MANAGER_ROLE, SETTER_ROLE, TAKER_ROLE, UNPAUSER_ROLE.
        vm.startPrank(admin);
        for (uint256 i = 0; i < roles.length; i++) {
            bytes32 role = roles[i];
            assertFalse(vault.hasRole(role, address(0x1234)));

            vm.expectEmit(address(vault));
            emit RoleGranted(role, address(0x1234), admin);
            vault.grantRole(role, address(0x1234));

            assertTrue(vault.hasRole(role, address(0x1234)));

            // Check role admin hasn't changed
            assertTrue(vault.getRoleAdmin(role) == DEFAULT_ADMIN_ROLE);
        }

        // Check that our admin in still DEFAULT_ADMIN_ROLE
        assertTrue(vault.hasRole(DEFAULT_ADMIN_ROLE, admin));
    }

}

contract SparkPrimeVaultRevokeRoleFailureTests is SparkPrimeVaultTestBase {

    function test_revokeRole_notAdmin() public {
        bytes32[] memory roles = new bytes32[](7);
        roles[0] = DEFAULT_ADMIN_ROLE;
        roles[1] = GUARDIAN_ROLE;
        roles[2] = REBALANCER_ROLE;
        roles[3] = RISK_MANAGER_ROLE;
        roles[4] = SETTER_ROLE;
        roles[5] = TAKER_ROLE;
        roles[6] = UNPAUSER_ROLE;

        for (uint256 i = 0; i < roles.length; i++) {
            bytes32 role = roles[i];
            vm.expectRevert(abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)",
                address(this),
                DEFAULT_ADMIN_ROLE
            ));
            vault.revokeRole(role, address(0x1234));
        }
    }

}

contract SparkPrimeVaultRevokeRoleSuccessTests is SparkPrimeVaultGrantRoleSuccessTests {

    function test_revokeRole() public {
        bytes32[] memory roles = new bytes32[](7);
        roles[0] = DEFAULT_ADMIN_ROLE;
        roles[1] = GUARDIAN_ROLE;
        roles[2] = REBALANCER_ROLE;
        roles[3] = RISK_MANAGER_ROLE;
        roles[4] = SETTER_ROLE;
        roles[5] = TAKER_ROLE;
        roles[6] = UNPAUSER_ROLE;

        // First, call test_grantRole()
        test_grantRole();

        vm.startPrank(admin);
        for (uint256 i = 0; i < roles.length; i++) {
            bytes32 role = roles[i];

            assertTrue(vault.hasRole(role, address(0x1234)));

            vm.expectEmit(address(vault));
            emit RoleRevoked(role, address(0x1234), admin);
            vault.revokeRole(role, address(0x1234));

            assertFalse(vault.hasRole(role, address(0x1234)));

            // Check role admin hasn't changed
            assertTrue(vault.getRoleAdmin(role) == DEFAULT_ADMIN_ROLE);
        }

        // Check that our admin in still DEFAULT_ADMIN_ROLE
        assertTrue(vault.hasRole(DEFAULT_ADMIN_ROLE, admin));
    }

}
