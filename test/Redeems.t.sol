// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import "./TestBase.t.sol";

contract SparkPrimeVaultRequestRedeemFailureTests is SparkPrimeVaultTestBase {

    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");

    function setUp() public override {
        super.setUp();

        vm.startPrank(admin);
        vault.setMaxWithdrawFee(0.01e18);
        vault.setMinimums(100e6, 50e6);
        vm.stopPrank();

        vm.prank(riskManager);
        vault.setWithdrawFee(0.005e18);

        deal(address(asset), user1, 1000e6);

        vm.startPrank(user1);
        asset.approve(address(vault), 1000e6);
        vault.requestDeposit(1000e6, user1, user1);
        vm.stopPrank();
    }

    function test_requestRedeem_paused() public {
        vm.prank(guardian);
        vault.pause();

        vm.prank(user1);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.requestRedeem(100e6, user1, user1);
    }

    function test_requestRedeem_notOwner() public {
        vm.startPrank(user2);
        vm.expectRevert("SparkPrimeVault/not-owner");
        vault.requestRedeem(100e6, user2, user1);

        vm.expectRevert("SparkPrimeVault/not-owner");
        vault.requestRedeem(100e6, user1, user1);
    }

    function test_requestRedeem_invalidReceiver() public {
        vm.startPrank(user1);
        vm.expectRevert("SparkPrimeVault/invalid-receiver");
        vault.requestRedeem(100e6, address(0), user1);

        vm.expectRevert("SparkPrimeVault/invalid-receiver");
        vault.requestRedeem(100e6, address(vault), user1);
    }

    function test_requestRedeem_zeroShares() public {
        vm.prank(admin);
        vault.setMinimums(0, 0);

        vm.prank(user1);
        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestRedeem(0, user1, user1);
    }

    function test_requestRedeem_belowMinimumBoundary() public {
        vm.startPrank(user1);
        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestRedeem(50e6 - 1, user1, user1);

        vault.requestRedeem(50e6, user1, user1);
    }

    function test_requestRedeem_belowMinimumGrossBoundary() public {
        vm.prank(admin);
        vault.setVsrBounds(1e27, FIVE_PCT_VSR);

        vm.prank(setter);
        vault.setVsr(FIVE_PCT_VSR);

        skip(365 days);

        // The minimum applies to the gross asset value of the shares, before the fee
        uint256 shares = 47.619048e6;

        assertLt(vault.convertToAssets(shares - 1), 50e6);
        assertGe(vault.convertToAssets(shares),     50e6);

        vm.startPrank(user1);
        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestRedeem(shares - 1, user1, user1);

        vault.requestRedeem(shares, user1, user1);

        // The net amount paid can end up below the minimum
        assertLt(asset.balanceOf(user1), 50e6);
    }

    function test_requestRedeem_insufficientBalanceBoundary() public {
        vm.startPrank(user1);
        vm.expectRevert("SparkPrimeVault/insufficient-balance");
        vault.requestRedeem(1000e6 + 1, user1, user1);

        vault.requestRedeem(1000e6, user1, user1);
    }

}

contract SparkPrimeVaultRequestRedeemSuccessTests is SparkPrimeVaultTestBase {

    // NOTE: This cannot be part of SparkPrimeVaultTestBase, because that is used in a contract where
    // DssTest is also used (and that also defines RAY).
    uint256 constant internal RAY = 1e27;

    event RedeemRequest(
        address indexed owner,
        address indexed receiver,
        uint256 indexed requestId,
        uint256 shares
    );
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Withdraw(address indexed owner, address indexed receiver, uint256 assets, uint256 shares);

    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");

    function setUp() public override {
        super.setUp();

        vm.prank(admin);
        vault.setMaxWithdrawFee(0.01e18);

        vm.prank(riskManager);
        vault.setWithdrawFee(0.005e18);

        deal(address(asset), user1, 1000e6);
        deal(address(asset), user2, 1000e6);

        vm.startPrank(user1);
        asset.approve(address(vault), 1000e6);
        vault.requestDeposit(1000e6, user1, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        asset.approve(address(vault), 1000e6);
        vault.requestDeposit(1000e6, user2, user2);
        vm.stopPrank();
    }

    function test_requestRedeem_instant() public {
        assertEq(asset.balanceOf(user1),          0);
        assertEq(asset.balanceOf(address(vault)), 2000e6);

        assertEq(vault.totalSupply(),             2000e6);
        assertEq(vault.balanceOf(user1),          1000e6);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.availableLiquidAssets(),   2000e6);

        assertEq(vault.pendingRedeemShares(user1),  0);
        assertEq(vault.pendingRedeemRequest(user1), 0);
        assertEq(vault.totalQueuedRedeemShares(),   0);
        assertEq(vault.withdrawHead(),              0);

        // The shares are escrowed, burned and the net USDC is paid in the same call
        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit Transfer(user1, address(vault), 200e6);
        emit RedeemRequest(user1, user1, 0, 200e6);
        emit Transfer(address(vault), address(0), 200e6);
        emit Withdraw(user1, user1, 199e6, 200e6);
        uint256 requestId = vault.requestRedeem(200e6, user1, user1);

        assertEq(requestId, 0);

        assertEq(asset.balanceOf(user1),          199e6);  // 0.5% fee
        assertEq(asset.balanceOf(address(vault)), 1801e6);

        assertEq(vault.totalSupply(),             1800e6);
        assertEq(vault.balanceOf(user1),          800e6);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.availableLiquidAssets(),   1801e6);

        assertEq(vault.pendingRedeemShares(user1),  0);
        assertEq(vault.pendingRedeemRequest(user1), 0);
        assertEq(vault.totalQueuedRedeemShares(),   0);
        assertEq(vault.withdrawHead(),              1);

        // The entry is kept with the fee locked in, fully filled
        ( address owner, address receiver, uint256 amount, uint256 fee ) = vault.withdrawQueue(0);

        assertEq(owner,    user1);
        assertEq(receiver, user1);
        assertEq(amount,   0);
        assertEq(fee,      0.005e18);
    }

    function test_requestRedeem_instant_chiAboveRay() public {
        vm.prank(admin);
        vault.setVsrBounds(1e27, FIVE_PCT_VSR);

        vm.prank(setter);
        vault.setVsr(FIVE_PCT_VSR);

        skip(365 days);

        // Back the accrued value
        deal(address(asset), address(vault), vault.totalAssets());

        assertEq(vault.nowChi(),                  1.049999999999999999961070145e27);
        assertEq(vault.convertToAssets(200e6),    209.999999e6);
        assertEq(asset.balanceOf(address(vault)), 2099.999999e6);

        // Gross is 209.999999e6, the 0.5% fee rounds up to 1.05e6
        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit Transfer(user1, address(vault), 200e6);
        emit RedeemRequest(user1, user1, 0, 200e6);
        emit Transfer(address(vault), address(0), 200e6);
        emit Withdraw(user1, user1, 208.949999e6, 200e6);
        vault.requestRedeem(200e6, user1, user1);

        assertEq(asset.balanceOf(user1),          208.949999e6);
        assertEq(asset.balanceOf(address(vault)), 2099.999999e6 - 208.949999e6);
        assertEq(vault.totalSupply(),             1800e6);
    }

    function test_requestRedeem_instant_withdrawFeeZero() public {
        vm.prank(riskManager);
        vault.setWithdrawFee(0);

        vm.prank(user1);
        vault.requestRedeem(200e6, user1, user1);

        assertEq(asset.balanceOf(user1),          200e6);
        assertEq(asset.balanceOf(address(vault)), 1800e6);

        ( ,,, uint256 fee ) = vault.withdrawQueue(0);

        assertEq(fee, 0);
    }

    function test_requestRedeem_instant_fromSavingsSleeve() public {
        vm.prank(rebalancer);
        vault.depositToSavings(2000e6);

        assertEq(asset.balanceOf(address(vault)),  0);
        assertEq(spUsdc.balanceOf(address(vault)), 2000e6);
        assertEq(vault.availableLiquidAssets(),    2000e6);

        vm.prank(user1);
        vault.requestRedeem(200e6, user1, user1);

        // Exactly the net amount is pulled from spUSDC and paid out
        assertEq(asset.balanceOf(user1),           199e6);
        assertEq(asset.balanceOf(address(vault)),  0);
        assertEq(spUsdc.balanceOf(address(vault)), 2000e6 - 199e6);
        assertEq(vault.availableLiquidAssets(),    2000e6 - 199e6);
    }

    function test_requestRedeem_instant_idleAndSleeveSplit() public {
        vm.prank(rebalancer);
        vault.depositToSavings(300e6);

        vm.prank(taker);
        vault.take(1600e6);

        assertEq(asset.balanceOf(address(vault)),  100e6);
        assertEq(spUsdc.balanceOf(address(vault)), 300e6);
        assertEq(vault.availableLiquidAssets(),    400e6);

        vm.prank(user1);
        vault.requestRedeem(300e6, user1, user1);

        // Net 298.5e6: the 100e6 idle plus 198.5e6 pulled from spUSDC
        assertEq(asset.balanceOf(user1),           298.5e6);
        assertEq(asset.balanceOf(address(vault)),  0);
        assertEq(spUsdc.balanceOf(address(vault)), 101.5e6);
        assertEq(vault.availableLiquidAssets(),    101.5e6);
    }

    function test_requestRedeem_liquidityExactlyNetBoundary() public {
        vm.prank(taker);
        vault.take(2000e6 - 199e6);

        assertEq(vault.availableLiquidAssets(), 199e6);

        vm.prank(user1);
        vault.requestRedeem(200e6, user1, user1);

        assertEq(asset.balanceOf(user1),            199e6);
        assertEq(asset.balanceOf(address(vault)),   0);
        assertEq(vault.pendingRedeemRequest(user1), 0);
        assertEq(vault.withdrawHead(),              1);
        assertEq(vault.availableLiquidAssets(),     0);
        assertEq(vault.totalSupply(),               1800e6);
    }

    function test_requestRedeem_liquidityOneWeiShort() public {
        vm.prank(taker);
        vault.take(2000e6 - (199e6 - 1));

        assertEq(vault.availableLiquidAssets(), 199e6 - 1);

        vm.prank(user1);
        vault.requestRedeem(200e6, user1, user1);

        // The largest share amount whose net fits: floor(198.999999e6 / 0.995) = 199.999998e6
        // shares, gross 199.999998e6, fee rounds up to 1e6, net 198.999998e6
        assertEq(asset.balanceOf(user1),            198.999998e6);
        assertEq(asset.balanceOf(address(vault)),   1);
        assertEq(vault.pendingRedeemShares(user1),  2);
        assertEq(vault.pendingRedeemRequest(user1), 2);
        assertEq(vault.totalQueuedRedeemShares(),   2);
        assertEq(vault.balanceOf(address(vault)),   2);
        assertEq(vault.totalSupply(),               2000e6 - 199.999998e6);
        assertEq(vault.withdrawHead(),              0);
        assertEq(vault.availableLiquidAssets(),     1);
    }

    function test_requestRedeem_partialInstantRestQueued() public {
        vm.prank(taker);
        vault.take(1900e6);

        assertEq(vault.availableLiquidAssets(), 100e6);

        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit Transfer(user1, address(vault), 200e6);
        emit RedeemRequest(user1, user1, 0, 200e6);
        emit Transfer(address(vault), address(0), 100.502512e6);
        emit Withdraw(user1, user1, 99.999999e6, 100.502512e6);
        uint256 requestId = vault.requestRedeem(200e6, user1, user1);

        assertEq(requestId, 0);

        // 100.502512e6 shares net 99.999999e6, the remaining 99.497488e6 shares wait in escrow
        assertEq(asset.balanceOf(user1),          99.999999e6);
        assertEq(asset.balanceOf(address(vault)), 1);

        assertEq(vault.pendingRedeemShares(user1),  99.497488e6);
        assertEq(vault.pendingRedeemRequest(user1), 99.497488e6);

        assertEq(vault.balanceOf(user1),          800e6);
        assertEq(vault.balanceOf(address(vault)), 99.497488e6);
        assertEq(vault.totalSupply(),             2000e6 - 100.502512e6);
        assertEq(vault.totalQueuedRedeemShares(), 99.497488e6);
        assertEq(vault.withdrawHead(),            0);
        assertEq(vault.availableLiquidAssets(),   1);

        ( address owner, address receiver, uint256 amount, uint256 fee ) = vault.withdrawQueue(0);

        assertEq(owner,    user1);
        assertEq(receiver, user1);
        assertEq(amount,   99.497488e6);
        assertEq(fee,      0.005e18);
    }

    function test_requestRedeem_fullyQueued() public {
        vm.prank(taker);
        vault.take(2000e6);

        assertEq(vault.availableLiquidAssets(), 0);

        // No burn, the shares wait in escrow
        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit Transfer(user1, address(vault), 200e6);
        emit RedeemRequest(user1, user1, 0, 200e6);
        uint256 requestId = vault.requestRedeem(200e6, user1, user1);

        assertEq(requestId, 0);

        assertEq(asset.balanceOf(user1), 0);

        assertEq(vault.pendingRedeemShares(user1),  200e6);
        assertEq(vault.pendingRedeemRequest(user1), 200e6);

        assertEq(vault.balanceOf(user1),          800e6);
        assertEq(vault.balanceOf(address(vault)), 200e6);
        assertEq(vault.totalSupply(),             2000e6);
        assertEq(vault.totalQueuedRedeemShares(), 200e6);
        assertEq(vault.withdrawHead(),            0);

        ( address owner, address receiver, uint256 amount, uint256 fee ) = vault.withdrawQueue(0);

        assertEq(owner,    user1);
        assertEq(receiver, user1);
        assertEq(amount,   200e6);
        assertEq(fee,      0.005e18);
    }

    function test_requestRedeem_queueNotEmptyForcesQueueing() public {
        vm.prank(taker);
        vault.take(2000e6);

        vm.prank(user1);
        vault.requestRedeem(200e6, user1, user1);

        // Liquidity returns, but user2 waits behind user1
        deal(address(asset), address(vault), 10_000e6);

        assertEq(vault.availableLiquidAssets(), 10_000e6);

        vm.prank(user2);
        uint256 requestId = vault.requestRedeem(200e6, user2, user2);

        assertEq(requestId, 1);

        assertEq(asset.balanceOf(user2),           0);
        assertEq(vault.pendingRedeemShares(user2), 200e6);
        assertEq(vault.totalQueuedRedeemShares(),  400e6);
        assertEq(vault.withdrawHead(),             0);

        ( address owner, address receiver, uint256 amount, ) = vault.withdrawQueue(1);

        assertEq(owner,    user2);
        assertEq(receiver, user2);
        assertEq(amount,   200e6);
    }

    function test_requestRedeem_queuedEarnsVaultYield() public {
        vm.prank(admin);
        vault.setVsrBounds(1e27, FIVE_PCT_VSR);

        vm.prank(setter);
        vault.setVsr(FIVE_PCT_VSR);

        vm.prank(taker);
        vault.take(2000e6);

        vm.prank(user1);
        vault.requestRedeem(500e6, user1, user1);

        skip(365 days);

        deal(address(asset), address(vault), 10_000e6);

        // Anyone can process the queue once there is liquidity
        vault.processWithdrawQueue(type(uint256).max);

        // Priced at the chi at processing time, not at request time
        assertEq(asset.balanceOf(user1), 522.374999e6);  // Gross 524.999999e6 less 0.5%
        assertEq(vault.pendingRedeemShares(user1), 0);
    }

    function test_requestRedeem_dustNetsZeroBurnedForZero() public {
        vm.prank(taker);
        vault.take(2000e6);

        // 1 share grosses 1 wei, the fee rounds up to 1 wei, so the net is 0 and fits any budget
        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit Transfer(user1, address(vault), 1);
        emit RedeemRequest(user1, user1, 0, 1);
        emit Transfer(address(vault), address(0), 1);
        emit Withdraw(user1, user1, 0, 1);
        vault.requestRedeem(1, user1, user1);

        assertEq(asset.balanceOf(user1),           0);
        assertEq(vault.pendingRedeemShares(user1), 0);
        assertEq(vault.totalQueuedRedeemShares(),  0);
        assertEq(vault.totalSupply(),              2000e6 - 1);
        assertEq(vault.withdrawHead(),             1);
    }

    function test_requestRedeem_feeLockedAtRequest() public {
        vm.prank(taker);
        vault.take(2000e6);

        vm.prank(user1);
        vault.requestRedeem(200e6, user1, user1);  // 0.5%

        vm.prank(riskManager);
        vault.setWithdrawFee(0.01e18);

        vm.prank(user2);
        vault.requestRedeem(200e6, user2, user2);  // 1%

        // Lowering the max fee doesn't touch the queued fee
        vm.prank(admin);
        vault.setMaxWithdrawFee(0.002e18);

        assertEq(vault.withdrawFee(), 0.002e18);

        ( ,,, uint256 fee1 ) = vault.withdrawQueue(0);
        ( ,,, uint256 fee2 ) = vault.withdrawQueue(1);

        assertEq(fee1, 0.005e18);
        assertEq(fee2, 0.01e18);

        deal(address(asset), address(vault), 1000e6);

        vault.processWithdrawQueue(type(uint256).max);

        assertEq(asset.balanceOf(user1), 199e6);
        assertEq(asset.balanceOf(user2), 198e6);
    }

    function test_requestRedeem_receiverNotOwner() public {
        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit Transfer(user1, address(vault), 200e6);
        emit RedeemRequest(user1, user2, 0, 200e6);
        emit Transfer(address(vault), address(0), 200e6);
        emit Withdraw(user1, user2, 199e6, 200e6);
        vault.requestRedeem(200e6, user2, user1);

        // The owner's shares are used, the receiver gets the USDC
        assertEq(vault.balanceOf(user1), 800e6);
        assertEq(vault.balanceOf(user2), 1000e6);

        assertEq(asset.balanceOf(user1), 0);
        assertEq(asset.balanceOf(user2), 199e6);

        ( address owner, address receiver,, ) = vault.withdrawQueue(0);

        assertEq(owner,    user1);
        assertEq(receiver, user2);
    }

    function test_requestRedeem_requestIdsAreQueueIndexes() public {
        vm.prank(user1);
        assertEq(vault.requestRedeem(100e6, user1, user1), 0);

        vm.prank(user2);
        assertEq(vault.requestRedeem(100e6, user2, user2), 1);

        vm.prank(user1);
        assertEq(vault.requestRedeem(100e6, user1, user1), 2);

        ( address owner,,, ) = vault.withdrawQueue(2);

        assertEq(owner, user1);
        assertEq(vault.withdrawHead(), 3);
    }

}

contract SparkPrimeVaultProcessWithdrawQueueFailureTests is SparkPrimeVaultTestBase {

    function test_processWithdrawQueue_paused() public {
        vm.prank(guardian);
        vault.pause();

        vm.expectRevert("SparkPrimeVault/paused");
        vault.processWithdrawQueue(type(uint256).max);

        vm.prank(unpauser);
        vault.unpause();

        vault.processWithdrawQueue(type(uint256).max);
    }

}

contract SparkPrimeVaultProcessWithdrawQueueSuccessTests is SparkPrimeVaultTestBase {

    // NOTE: This cannot be part of SparkPrimeVaultTestBase, because that is used in a contract where
    // DssTest is also used (and that also defines RAY).
    uint256 constant internal RAY = 1e27;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Withdraw(address indexed owner, address indexed receiver, uint256 assets, uint256 shares);

    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address user3 = makeAddr("user3");

    function setUp() public override {
        super.setUp();

        vm.prank(admin);
        vault.setMaxWithdrawFee(0.01e18);

        vm.prank(riskManager);
        vault.setWithdrawFee(0.005e18);

        address[3] memory users = [user1, user2, user3];

        for (uint256 i = 0; i < users.length; i++) {
            deal(address(asset), users[i], 1000e6);

            vm.startPrank(users[i]);
            asset.approve(address(vault), 1000e6);
            vault.requestDeposit(1000e6, users[i], users[i]);
            vm.stopPrank();
        }

        // All liquidity is deployed, every request is queued
        vm.prank(taker);
        vault.take(3000e6);

        vm.prank(user1);
        vault.requestRedeem(500e6, user1, user1);  // Index 0

        vm.prank(user2);
        vault.requestRedeem(300e6, user2, user2);  // Index 1

        vm.prank(user3);
        vault.requestRedeem(200e6, user3, user3);  // Index 2
    }

    function test_processWithdrawQueue_noLiquidity() public {
        vault.processWithdrawQueue(type(uint256).max);

        assertEq(asset.balanceOf(user1),          0);
        assertEq(vault.totalQueuedRedeemShares(), 1000e6);
        assertEq(vault.totalSupply(),             3000e6);
        assertEq(vault.withdrawHead(),            0);
    }

    function test_processWithdrawQueue_zeroBudget() public {
        deal(address(asset), address(vault), 1000e6);

        vault.processWithdrawQueue(0);

        assertEq(asset.balanceOf(user1),          0);
        assertEq(vault.totalQueuedRedeemShares(), 1000e6);
        assertEq(vault.totalSupply(),             3000e6);
        assertEq(vault.withdrawHead(),            0);
    }

    function test_processWithdrawQueue_fullFill() public {
        // Liquidity comes back (e.g. the PAU transfers USDC to the vault)
        deal(address(asset), address(vault), 1000e6);

        assertEq(vault.availableLiquidAssets(), 1000e6);

        assertEq(vault.totalSupply(),             3000e6);
        assertEq(vault.balanceOf(address(vault)), 1000e6);

        assertEq(asset.balanceOf(user1), 0);
        assertEq(asset.balanceOf(user2), 0);
        assertEq(asset.balanceOf(user3), 0);

        assertEq(vault.pendingRedeemShares(user1), 500e6);
        assertEq(vault.pendingRedeemShares(user2), 300e6);
        assertEq(vault.pendingRedeemShares(user3), 200e6);
        assertEq(vault.totalQueuedRedeemShares(),  1000e6);
        assertEq(vault.withdrawHead(),             0);

        // Anyone can process the queue
        vm.prank(makeAddr("randomUser"));
        vm.expectEmit(address(vault));
        emit Transfer(address(vault), address(0), 500e6);
        emit Withdraw(user1, user1, 497.5e6, 500e6);
        emit Transfer(address(vault), address(0), 300e6);
        emit Withdraw(user2, user2, 298.5e6, 300e6);
        emit Transfer(address(vault), address(0), 200e6);
        emit Withdraw(user3, user3, 199e6, 200e6);
        vault.processWithdrawQueue(type(uint256).max);

        // The fees stay in the vault as free liquidity
        assertEq(asset.balanceOf(address(vault)), 5e6);
        assertEq(vault.availableLiquidAssets(),   5e6);

        assertEq(vault.totalSupply(),             2000e6);
        assertEq(vault.balanceOf(address(vault)), 0);

        assertEq(asset.balanceOf(user1), 497.5e6);
        assertEq(asset.balanceOf(user2), 298.5e6);
        assertEq(asset.balanceOf(user3), 199e6);

        assertEq(vault.pendingRedeemShares(user1), 0);
        assertEq(vault.pendingRedeemShares(user2), 0);
        assertEq(vault.pendingRedeemShares(user3), 0);
        assertEq(vault.totalQueuedRedeemShares(),  0);
        assertEq(vault.withdrawHead(),             3);

        for (uint256 i = 0; i < 3; i++) {
            ( ,, uint256 amount, ) = vault.withdrawQueue(i);
            assertEq(amount, 0);
        }
    }

    function test_processWithdrawQueue_budgetPartialFill() public {
        deal(address(asset), address(vault), 1000e6);

        vault.processWithdrawQueue(600e6);

        // user1 is filled, user2 gets the largest share amount whose net fits the remaining
        // 102.5e6: 103.015075e6 shares, fee rounds up to 0.515076e6, net 102.499999e6
        assertEq(asset.balanceOf(user1), 497.5e6);
        assertEq(asset.balanceOf(user2), 102.499999e6);
        assertEq(asset.balanceOf(user3), 0);

        assertEq(asset.balanceOf(address(vault)), 1000e6 - 497.5e6 - 102.499999e6);

        assertEq(vault.pendingRedeemShares(user2), 300e6 - 103.015075e6);
        assertEq(vault.totalQueuedRedeemShares(),  1000e6 - 500e6 - 103.015075e6);
        assertEq(vault.totalSupply(),              3000e6 - 500e6 - 103.015075e6);
        assertEq(vault.withdrawHead(),             1);

        ( ,, uint256 amount, ) = vault.withdrawQueue(1);

        assertEq(amount, 300e6 - 103.015075e6);

        vault.processWithdrawQueue(type(uint256).max);

        // The split cost user2 1 wei of fee rounding
        assertEq(asset.balanceOf(user2), 298.5e6 - 1);
        assertEq(asset.balanceOf(user3), 199e6);

        assertEq(asset.balanceOf(address(vault)), 5e6 + 1);

        assertEq(vault.totalQueuedRedeemShares(), 0);
        assertEq(vault.totalSupply(),             2000e6);
        assertEq(vault.withdrawHead(),            3);
    }

    function test_processWithdrawQueue_liquidityCapped() public {
        // The budget is capped by the available liquidity, not just by `maxAssets`
        deal(address(asset), address(vault), 600e6);

        vault.processWithdrawQueue(type(uint256).max);

        assertEq(asset.balanceOf(user1), 497.5e6);
        assertEq(asset.balanceOf(user2), 102.499999e6);
        assertEq(vault.withdrawHead(),   1);

        assertEq(asset.balanceOf(address(vault)), 1);
        assertEq(vault.availableLiquidAssets(),   1);
    }

    function test_processWithdrawQueue_budgetExactlyHeadNetBoundary() public {
        deal(address(asset), address(vault), 1000e6);

        vault.processWithdrawQueue(497.5e6 - 1);

        assertEq(asset.balanceOf(user1),           497.499998e6);
        assertEq(vault.pendingRedeemShares(user1), 2);
        assertEq(vault.withdrawHead(),             0);

        // The 2 share-wei net 1 wei as a whole, so 1 wei of budget settles them
        vault.processWithdrawQueue(1);

        assertEq(asset.balanceOf(user1),           497.5e6 - 1);
        assertEq(vault.pendingRedeemShares(user1), 0);
        assertEq(asset.balanceOf(user2),           0);
        assertEq(vault.withdrawHead(),             1);
    }

    function test_processWithdrawQueue_tinyBudgetDoesNotGrind() public {
        deal(address(asset), address(vault), 1000e6);

        // A budget that nets nothing after the fee doesn't burn any shares from the head
        for (uint256 i = 0; i < 10; i++) {
            vault.processWithdrawQueue(1);
        }

        assertEq(asset.balanceOf(user1),           0);
        assertEq(vault.pendingRedeemShares(user1), 500e6);
        assertEq(vault.totalSupply(),              3000e6);
        assertEq(vault.withdrawHead(),             0);
    }

    function test_processWithdrawQueue_dustEntryPassedOver() public {
        deal(address(asset), address(vault), 1000e6);

        vault.processWithdrawQueue(type(uint256).max);

        assertEq(vault.withdrawHead(), 3);

        vm.prank(taker);
        vault.take(5e6);

        assertEq(vault.availableLiquidAssets(), 0);

        vm.prank(user1);
        vault.requestRedeem(100e6, user1, user1);  // Index 3

        vm.prank(user2);
        vault.requestRedeem(1, user2, user2);      // Index 4, nets 0

        vm.prank(user3);
        vault.requestRedeem(200e6, user3, user3);  // Index 5

        deal(address(asset), address(vault), 99.5e6);

        // user1 is paid exactly, the dust is burned for 0 and user3 is not ground down
        vm.expectEmit(address(vault));
        emit Transfer(address(vault), address(0), 100e6);
        emit Withdraw(user1, user1, 99.5e6, 100e6);
        emit Transfer(address(vault), address(0), 1);
        emit Withdraw(user2, user2, 0, 1);
        vault.processWithdrawQueue(type(uint256).max);

        assertEq(asset.balanceOf(user1), 497.5e6 + 99.5e6);
        assertEq(asset.balanceOf(user2), 298.5e6);
        assertEq(asset.balanceOf(user3), 199e6);

        assertEq(vault.pendingRedeemShares(user2), 0);
        assertEq(vault.pendingRedeemShares(user3), 200e6);
        assertEq(vault.totalQueuedRedeemShares(),  200e6);
        assertEq(asset.balanceOf(address(vault)),  0);
        assertEq(vault.withdrawHead(),             5);
    }

    function test_processWithdrawQueue_pullsShortfallFromSavings() public {
        deal(address(asset), address(vault), 1000e6);

        vm.prank(rebalancer);
        vault.depositToSavings(1000e6);

        assertEq(asset.balanceOf(address(vault)),  0);
        assertEq(spUsdc.balanceOf(address(vault)), 1000e6);
        assertEq(vault.availableLiquidAssets(),    1000e6);

        vault.processWithdrawQueue(type(uint256).max);

        // Exactly the paid amount is pulled from spUSDC, the fees stay in the sleeve
        assertEq(asset.balanceOf(user1), 497.5e6);
        assertEq(asset.balanceOf(user2), 298.5e6);
        assertEq(asset.balanceOf(user3), 199e6);

        assertEq(asset.balanceOf(address(vault)),  0);
        assertEq(spUsdc.balanceOf(address(vault)), 5e6);
        assertEq(vault.availableLiquidAssets(),    5e6);
        assertEq(vault.withdrawHead(),             3);
    }

    function test_processWithdrawQueue_savingsLiquidityCapped() public {
        deal(address(asset), address(vault), 1000e6);

        vm.prank(rebalancer);
        vault.depositToSavings(1000e6);

        vm.prank(admin);
        spUsdc.grantRole(TAKER_ROLE, taker);

        // The sleeve is worth 1000e6 but spUSDC can only pay 600e6 of it
        vm.prank(taker);
        spUsdc.take(400e6);

        assertEq(vault.availableLiquidAssets(), 600e6);

        vault.processWithdrawQueue(type(uint256).max);

        assertEq(asset.balanceOf(user1), 497.5e6);
        assertEq(asset.balanceOf(user2), 102.499999e6);
        assertEq(vault.withdrawHead(),   1);

        assertEq(asset.balanceOf(address(vault)),  0);
        assertEq(asset.balanceOf(address(spUsdc)), 1);
        assertEq(vault.availableLiquidAssets(),    1);
    }

    function test_processWithdrawQueue_queuedDepositSharesNotUsed() public {
        address user4 = makeAddr("user4");
        deal(address(asset), user4, 1000e6);

        // Capacity is full, user4's deposit is queued in spUSDC
        vm.prank(admin);
        vault.setCapacity(3000e6);

        vm.startPrank(user4);
        asset.approve(address(vault), 1000e6);
        vault.requestDeposit(1000e6, user4, user4);
        vm.stopPrank();

        assertEq(spUsdc.balanceOf(address(vault)), 1000e6);
        assertEq(vault.totalQueuedDepositShares(), 1000e6);
        assertEq(vault.availableLiquidAssets(),    0);

        vault.processWithdrawQueue(type(uint256).max);

        // The queued depositor's spUSDC is never used to pay redeemers
        assertEq(asset.balanceOf(user1),           0);
        assertEq(vault.totalQueuedRedeemShares(),  1000e6);
        assertEq(spUsdc.balanceOf(address(vault)), 1000e6);
        assertEq(vault.withdrawHead(),             0);
    }

    function test_processWithdrawQueue_chiAtProcessingTime() public {
        vm.prank(admin);
        vault.setVsrBounds(1e27, FIVE_PCT_VSR);

        vm.prank(setter);
        vault.setVsr(FIVE_PCT_VSR);

        skip(365 days);

        deal(address(asset), address(vault), 10_000e6);

        assertEq(vault.nowChi(), 1.049999999999999999961070145e27);

        vault.processWithdrawQueue(type(uint256).max);

        // Queued redeemers earn the vault's yield until they are processed
        assertEq(asset.balanceOf(user1), 522.374999e6);  // Gross 524.999999e6 less 0.5%
        assertEq(asset.balanceOf(user2), 313.424999e6);  // Gross 314.999999e6 less 0.5%
        assertEq(asset.balanceOf(user3), 208.949999e6);  // Gross 209.999999e6 less 0.5%
    }

    function test_processWithdrawQueue_lossBookedBeforeProcessing() public {
        vm.prank(guardian);
        vault.pause();

        vm.prank(riskManager);
        vault.setChi(0.8e27);

        vm.prank(unpauser);
        vault.unpause();

        deal(address(asset), address(vault), 1000e6);

        vault.processWithdrawQueue(type(uint256).max);

        // Queued redeemers absorb the loss, the fee applies to the reduced gross
        assertEq(asset.balanceOf(user1), 398e6);
        assertEq(asset.balanceOf(user2), 238.8e6);
        assertEq(asset.balanceOf(user3), 159.2e6);

        assertEq(asset.balanceOf(address(vault)), 204e6);
        assertEq(vault.availableLiquidAssets(),   204e6);
    }

    function test_processWithdrawQueue_dripsFirst() public {
        vm.prank(admin);
        vault.setVsrBounds(1e27, FIVE_PCT_VSR);

        vm.prank(setter);
        vault.setVsr(FIVE_PCT_VSR);

        uint256 timestamp = block.timestamp;

        skip(1 days);

        assertEq(uint256(vault.chi()), 1e27);
        assertEq(uint256(vault.rho()), timestamp);

        vault.processWithdrawQueue(type(uint256).max);

        assertEq(uint256(vault.chi()), 1.000133680617113440350406888e27);
        assertEq(uint256(vault.rho()), timestamp + 1 days);
    }

}
