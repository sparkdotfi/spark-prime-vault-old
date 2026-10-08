// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import { stdError } from "forge-std/Test.sol";

import "./TestBase.t.sol";

contract SparkPrimeVaultSetOperatorTests is SparkPrimeVaultTestBase {

    event OperatorSet(address indexed controller, address indexed operator, bool approved);

    address user1     = makeAddr("user1");
    address operator1 = makeAddr("operator1");
    address operator2 = makeAddr("operator2");

    function test_setOperator() public {
        assertFalse(vault.isOperator(user1, operator1));
        assertFalse(vault.isOperator(user1, operator2));

        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit OperatorSet(user1, operator1, true);
        assertTrue(vault.setOperator(operator1, true));

        assertTrue(vault.isOperator(user1, operator1));
        assertFalse(vault.isOperator(user1, operator2));

        // Approving a second operator doesn't revoke the first
        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit OperatorSet(user1, operator2, true);
        assertTrue(vault.setOperator(operator2, true));

        assertTrue(vault.isOperator(user1, operator1));
        assertTrue(vault.isOperator(user1, operator2));

        // Operators are per controller
        assertFalse(vault.isOperator(operator1, user1));
        assertFalse(vault.isOperator(makeAddr("user2"), operator1));

        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit OperatorSet(user1, operator1, false);
        assertTrue(vault.setOperator(operator1, false));

        assertFalse(vault.isOperator(user1, operator1));
        assertTrue(vault.isOperator(user1, operator2));
    }

}

contract SparkPrimeVaultRequestDepositFailureTests is SparkPrimeVaultTestBase {

    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");

    function setUp() public override {
        super.setUp();

        vm.prank(admin);
        vault.setMinimums(100e6, 50e6);

        deal(address(asset), user1, 1_000_000e6);

        vm.prank(user1);
        asset.approve(address(vault), type(uint256).max);
    }

    function test_requestDeposit_paused() public {
        vm.prank(guardian);
        vault.pause();

        vm.startPrank(user1);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.requestDeposit(1000e6, user1, user1);

        vm.expectRevert("SparkPrimeVault/paused");
        vault.requestDeposit(1000e6, user1, user1, 1);
    }

    function test_requestDeposit_notOwner() public {
        vm.startPrank(user2);
        vm.expectRevert("SparkPrimeVault/not-owner");
        vault.requestDeposit(1000e6, user2, user1);

        vm.expectRevert("SparkPrimeVault/not-owner");
        vault.requestDeposit(1000e6, user1, user1);
    }

    function test_requestDeposit_invalidController() public {
        vm.startPrank(user1);
        vm.expectRevert("SparkPrimeVault/invalid-controller");
        vault.requestDeposit(1000e6, address(0), user1);
    }

    function test_requestDeposit_belowMinimumBoundary() public {
        vm.startPrank(user1);
        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestDeposit(100e6 - 1, user1, user1);

        vault.requestDeposit(100e6, user1, user1);
    }

    function test_requestDeposit_insufficientBalanceBoundary() public {
        deal(address(asset), user1, 1000e6 - 1);

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSignature(
            "ERC20InsufficientBalance(address,uint256,uint256)",
            user1,
            1000e6 - 1,
            1000e6
        ));
        vault.requestDeposit(1000e6, user1, user1);

        deal(address(asset), user1, 1000e6);

        vault.requestDeposit(1000e6, user1, user1);
    }

    function test_requestDeposit_insufficientAllowanceBoundary() public {
        vm.startPrank(user1);
        asset.approve(address(vault), 1000e6 - 1);

        vm.expectRevert(abi.encodeWithSignature(
            "ERC20InsufficientAllowance(address,uint256,uint256)",
            address(vault),
            1000e6 - 1,
            1000e6
        ));
        vault.requestDeposit(1000e6, user1, user1);

        asset.approve(address(vault), 1000e6);

        vault.requestDeposit(1000e6, user1, user1);
    }

    function test_requestDeposit_savingsDepositCapExceededBoundary() public {
        // No capacity, every request is queued into spUSDC
        vm.prank(admin);
        vault.setCapacity(0);

        vm.prank(admin);
        spUsdc.setDepositCap(500e6);

        vm.startPrank(user1);
        vm.expectRevert("SparkVault/deposit-cap-exceeded");
        vault.requestDeposit(500e6 + 1, user1, user1);

        vault.requestDeposit(500e6, user1, user1);
    }

    function test_requestDeposit_savingsDepositCapExceeded_partiallyQueued() public {
        // The instant part doesn't touch spUSDC, but the whole request reverts if the queued
        // part can't be deposited
        vm.prank(admin);
        vault.setCapacity(500e6);

        vm.prank(admin);
        spUsdc.setDepositCap(0);

        vm.startPrank(user1);
        vm.expectRevert("SparkVault/deposit-cap-exceeded");
        vault.requestDeposit(500e6 + 1, user1, user1);

        vault.requestDeposit(500e6, user1, user1);
    }

}

contract SparkPrimeVaultRequestDepositSuccessTests is SparkPrimeVaultTestBase {

    // NOTE: This cannot be part of SparkPrimeVaultTestBase, because that is used in a contract where
    // DssTest is also used (and that also defines RAY).
    uint256 constant internal RAY = 1e27;

    event DepositRequest(
        address indexed controller,
        address indexed owner,
        uint256 indexed requestId,
        address sender,
        uint256 assets
    );
    event Referral(uint16 indexed referral, address indexed controller, uint256 assets);
    event Transfer(address indexed from, address indexed to, uint256 value);

    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address user3 = makeAddr("user3");

    function setUp() public override {
        super.setUp();

        deal(address(asset), user1, 1_000_000e6);
        deal(address(asset), user2, 1_000_000e6);
        deal(address(asset), user3, 1_000_000e6);

        vm.prank(user1);
        asset.approve(address(vault), type(uint256).max);

        vm.prank(user2);
        asset.approve(address(vault), type(uint256).max);

        vm.prank(user3);
        asset.approve(address(vault), type(uint256).max);
    }

    function test_requestDeposit_instant() public {
        assertEq(asset.balanceOf(user1),          1_000_000e6);
        assertEq(asset.balanceOf(address(vault)), 0);

        assertEq(vault.totalSupply(),             0);
        assertEq(vault.balanceOf(user1),          0);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.availableCapacity(),       1_000_000e6);

        assertEq(vault.maxDeposit(user1),                   0);
        assertEq(vault.maxMint(user1),                      0);
        assertEq(vault.pendingDepositShares(user1),         0);
        assertEq(vault.pendingDepositRequest(0, user1),     0);
        assertEq(vault.claimableDepositRequest(0, user1),   0);
        assertEq(vault.totalQueuedDepositShares(),          0);

        // The shares are minted into escrow and made claimable in the same call
        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit Transfer(address(0), address(vault), 1000e6);
        emit DepositRequest(user1, user1, 0, user1, 1000e6);
        uint256 requestId = vault.requestDeposit(1000e6, user1, user1);

        assertEq(requestId, 0);

        assertEq(asset.balanceOf(user1),          1_000_000e6 - 1000e6);
        assertEq(asset.balanceOf(address(vault)), 1000e6);

        assertEq(vault.totalSupply(),             1000e6);
        assertEq(vault.balanceOf(user1),          0);
        assertEq(vault.balanceOf(address(vault)), 1000e6);
        assertEq(vault.availableCapacity(),       1_000_000e6 - 1000e6);

        assertEq(vault.maxDeposit(user1),                   1000e6);
        assertEq(vault.maxMint(user1),                      1000e6);
        assertEq(vault.pendingDepositShares(user1),         0);
        assertEq(vault.pendingDepositRequest(0, user1),     0);
        assertEq(vault.claimableDepositRequest(0, user1),   1000e6);
        assertEq(vault.totalQueuedDepositShares(),          0);

        // Nothing was queued
        vm.expectRevert();  // Public array getters revert without data when out of bounds
        vault.depositQueue(0);
    }

    function test_requestDeposit_instant_chiAboveRay() public {
        vm.prank(admin);
        vault.setVsrBounds(1e27, FIVE_PCT_VSR);

        vm.prank(setter);
        vault.setVsr(FIVE_PCT_VSR);

        skip(365 days);

        assertEq(vault.nowChi(), 1.049999999999999999961070145e27);

        vm.prank(user1);
        vault.requestDeposit(1000e6, user1, user1);

        // Shares are priced at the current chi, rounded down
        assertEq(vault.maxDeposit(user1),         1000e6);
        assertEq(vault.maxMint(user1),            952.380952e6);
        assertEq(vault.totalSupply(),             952.380952e6);
        assertEq(vault.balanceOf(address(vault)), 952.380952e6);
        assertEq(vault.availableCapacity(),       1_000_000e6 - 952.380952e6);

        assertEq(vault.convertToShares(1000e6), 952.380952e6);
    }

    function test_requestDeposit_capacityExactlyHitBoundary() public {
        vm.prank(admin);
        vault.setCapacity(1000e6);

        vm.prank(user1);
        vault.requestDeposit(1000e6, user1, user1);

        assertEq(vault.maxDeposit(user1),          1000e6);
        assertEq(vault.maxMint(user1),             1000e6);
        assertEq(vault.availableCapacity(),        0);
        assertEq(vault.totalQueuedDepositShares(), 0);
        assertEq(spUsdc.balanceOf(address(vault)), 0);

        vm.expectRevert();  // Public array getters revert without data when out of bounds
        vault.depositQueue(0);

        // The next request is fully queued
        vm.prank(user2);
        vault.requestDeposit(100e6, user2, user2);

        assertEq(vault.maxDeposit(user2),               0);
        assertEq(vault.maxMint(user2),                  0);
        assertEq(vault.pendingDepositShares(user2),     100e6);
        assertEq(vault.pendingDepositRequest(0, user2), 100e6);
        assertEq(vault.totalQueuedDepositShares(),      100e6);
        assertEq(spUsdc.balanceOf(address(vault)),      100e6);

        ( address controller, address owner, uint256 amount, uint256 fee ) = vault.depositQueue(0);

        assertEq(controller, user2);
        assertEq(owner,      user2);
        assertEq(amount,     100e6);
        assertEq(fee,        0);
    }

    function test_requestDeposit_partialInstantRestQueued() public {
        vm.prank(admin);
        vault.setCapacity(1000e6);

        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit Transfer(address(0), address(vault), 1000e6);
        emit DepositRequest(user1, user1, 0, user1, 1500e6);
        vault.requestDeposit(1500e6, user1, user1);

        // All of the USDC leaves the user, the instant part stays idle and the rest goes to spUSDC
        assertEq(asset.balanceOf(user1),           1_000_000e6 - 1500e6);
        assertEq(asset.balanceOf(address(vault)),  1000e6);
        assertEq(asset.balanceOf(address(spUsdc)), 500e6);
        assertEq(spUsdc.balanceOf(address(vault)), 500e6);

        assertEq(vault.totalSupply(),             1000e6);
        assertEq(vault.balanceOf(address(vault)), 1000e6);
        assertEq(vault.availableCapacity(),       0);

        assertEq(vault.maxDeposit(user1),                 1000e6);
        assertEq(vault.maxMint(user1),                    1000e6);
        assertEq(vault.pendingDepositShares(user1),       500e6);
        assertEq(vault.pendingDepositRequest(0, user1),   500e6);
        assertEq(vault.claimableDepositRequest(0, user1), 1000e6);
        assertEq(vault.totalQueuedDepositShares(),        500e6);
        assertEq(vault.depositHead(),                     0);

        ( address controller, address owner, uint256 amount, uint256 fee ) = vault.depositQueue(0);

        assertEq(controller, user1);
        assertEq(owner,      user1);
        assertEq(amount,     500e6);
        assertEq(fee,        0);
    }

    function test_requestDeposit_queueNotEmptyForcesQueueing() public {
        vm.prank(admin);
        vault.setCapacity(1000e6);

        vm.prank(user1);
        vault.requestDeposit(1500e6, user1, user1);  // 1000e6 instant, 500e6 queued

        // Even with capacity available again, user2 waits behind user1
        vm.prank(admin);
        vault.setCapacity(1_000_000e6);

        assertEq(vault.availableCapacity(), 1_000_000e6 - 1000e6);

        vm.prank(user2);
        vault.requestDeposit(200e6, user2, user2);

        assertEq(vault.maxDeposit(user2),           0);
        assertEq(vault.maxMint(user2),              0);
        assertEq(vault.pendingDepositShares(user2), 200e6);
        assertEq(vault.totalQueuedDepositShares(),  700e6);
        assertEq(spUsdc.balanceOf(address(vault)),  700e6);

        ( address controller, address owner, uint256 amount, ) = vault.depositQueue(1);

        assertEq(controller, user2);
        assertEq(owner,      user2);
        assertEq(amount,     200e6);

        // Once the queue is drained, requests are instant again
        vm.prank(rebalancer);
        vault.processDepositQueue(type(uint256).max);

        assertEq(vault.totalQueuedDepositShares(), 0);

        vm.prank(user3);
        vault.requestDeposit(100e6, user3, user3);

        assertEq(vault.maxDeposit(user3),           100e6);
        assertEq(vault.pendingDepositShares(user3), 0);
    }

    function test_requestDeposit_instantBelowOneShareQueuesAll() public {
        vm.prank(admin);
        vault.setVsrBounds(1e27, FIVE_PCT_VSR);

        vm.prank(setter);
        vault.setVsr(FIVE_PCT_VSR);

        vm.prank(admin);
        vault.setCapacity(1000e6);

        vm.startPrank(user1);
        vault.requestDeposit(1000e6, user1, user1);
        vault.mint(1000e6, user1);
        vm.stopPrank();

        skip(365 days);

        // One share of room is worth 1.05 USDC, which buys 0 shares when rounded down
        vm.prank(admin);
        vault.setCapacity(1000e6 + 1);

        assertEq(vault.availableCapacity(), 1);

        vm.prank(user2);
        vault.requestDeposit(100e6, user2, user2);

        assertEq(vault.maxDeposit(user2),           0);
        assertEq(vault.maxMint(user2),              0);
        assertEq(vault.pendingDepositShares(user2), 100e6);
        assertEq(vault.totalSupply(),               1000e6);
        assertEq(vault.availableCapacity(),         1);
    }

    function test_requestDeposit_subShareRemainderAbsorbed() public {
        // spUSDC's share price is above one, the vault's is not
        vm.prank(setter);
        spUsdc.setVsr(FIVE_PCT_VSR);

        skip(365 days);

        assertEq(spUsdc.nowChi(), 1.049999999999999999961070145e27);
        assertEq(vault.nowChi(),  1e27);

        vm.prank(admin);
        vault.setCapacity(1000e6);

        vm.prank(user1);
        vault.requestDeposit(1000e6 + 1, user1, user1);

        // The 1 wei remainder is worth 0 spUSDC shares, it is deposited and no entry is queued
        assertEq(vault.maxDeposit(user1),           1000e6);
        assertEq(vault.maxMint(user1),              1000e6);
        assertEq(vault.pendingDepositShares(user1), 0);
        assertEq(vault.totalQueuedDepositShares(),  0);
        assertEq(asset.balanceOf(user1),            1_000_000e6 - 1000e6 - 1);
        assertEq(asset.balanceOf(address(vault)),   1000e6);
        assertEq(asset.balanceOf(address(spUsdc)),  1);
        assertEq(spUsdc.balanceOf(address(vault)),  0);

        vm.expectRevert();  // Public array getters revert without data when out of bounds
        vault.depositQueue(0);
    }

    function test_requestDeposit_zeroAssets() public {
        vm.prank(admin);
        vault.setCapacity(0);

        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit DepositRequest(user1, user1, 0, user1, 0);
        vault.requestDeposit(0, user1, user1);

        assertEq(asset.balanceOf(user1),            1_000_000e6);
        assertEq(vault.maxDeposit(user1),           0);
        assertEq(vault.pendingDepositShares(user1), 0);
        assertEq(vault.totalSupply(),               0);

        vm.expectRevert();  // Public array getters revert without data when out of bounds
        vault.depositQueue(0);
    }

    function test_requestDeposit_controllerNotOwner() public {
        vm.prank(admin);
        vault.setCapacity(1000e6);

        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit Transfer(address(0), address(vault), 1000e6);
        emit DepositRequest(user2, user1, 0, user1, 1500e6);
        vault.requestDeposit(1500e6, user2, user1);

        // The owner pays, the controller holds the claim and the queued position
        assertEq(asset.balanceOf(user1), 1_000_000e6 - 1500e6);
        assertEq(asset.balanceOf(user2), 1_000_000e6);

        assertEq(vault.maxDeposit(user1),           0);
        assertEq(vault.maxMint(user1),              0);
        assertEq(vault.pendingDepositShares(user1), 0);

        assertEq(vault.maxDeposit(user2),           1000e6);
        assertEq(vault.maxMint(user2),              1000e6);
        assertEq(vault.pendingDepositShares(user2), 500e6);

        ( address controller, address owner, uint256 amount, ) = vault.depositQueue(0);

        assertEq(controller, user2);
        assertEq(owner,      user1);
        assertEq(amount,     500e6);
    }

    function test_requestDeposit_withReferral() public {
        uint16 referral = 1;

        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit Transfer(address(0), address(vault), 1000e6);
        emit DepositRequest(user1, user1, 0, user1, 1000e6);
        emit Referral(referral, user1, 1000e6);
        uint256 requestId = vault.requestDeposit(1000e6, user1, user1, referral);

        assertEq(requestId, 0);

        assertEq(asset.balanceOf(user1),          1_000_000e6 - 1000e6);
        assertEq(asset.balanceOf(address(vault)), 1000e6);
        assertEq(vault.totalSupply(),             1000e6);
        assertEq(vault.maxDeposit(user1),         1000e6);
        assertEq(vault.maxMint(user1),            1000e6);
    }

    function test_requestDeposit_queuedEarnsSavingsYield() public {
        vm.prank(admin);
        vault.setCapacity(0);

        vm.prank(user1);
        vault.requestDeposit(1000e6, user1, user1);

        assertEq(vault.pendingDepositShares(user1),     1000e6);
        assertEq(vault.pendingDepositRequest(0, user1), 1000e6);

        vm.prank(setter);
        spUsdc.setVsr(FIVE_PCT_VSR);

        skip(365 days);

        // The queued position is denominated in spUSDC shares, its value grows with spUSDC
        assertEq(vault.pendingDepositShares(user1),     1000e6);
        assertEq(vault.pendingDepositRequest(0, user1), 1049.999999e6);
        assertEq(vault.totalQueuedDepositShares(),      1000e6);
    }

}

contract SparkPrimeVaultCancelDepositRequestFailureTests is SparkPrimeVaultTestBase {

    address user1    = makeAddr("user1");
    address user2    = makeAddr("user2");
    address user3    = makeAddr("user3");
    address operator = makeAddr("operator");

    function setUp() public override {
        super.setUp();

        // No capacity, every request is queued
        vm.prank(admin);
        vault.setCapacity(0);

        deal(address(asset), user1, 1_000_000e6);

        vm.startPrank(user1);
        asset.approve(address(vault), type(uint256).max);
        vault.requestDeposit(1000e6, user1, user1);  // Index 0
        vault.requestDeposit(500e6,  user2, user1);  // Index 1, user2 is the controller
        vm.stopPrank();
    }

    function test_cancelDepositRequest_indexOutOfBounds() public {
        vm.prank(user1);
        vm.expectRevert(stdError.indexOOBError);
        vault.cancelDepositRequest(2);
    }

    function test_cancelDepositRequest_noRequest_alreadyCancelled() public {
        vm.startPrank(user1);
        vault.cancelDepositRequest(0);

        vm.expectRevert("SparkPrimeVault/no-request");
        vault.cancelDepositRequest(0);
    }

    function test_cancelDepositRequest_noRequest_alreadyFilled() public {
        vm.prank(admin);
        vault.setCapacity(1_000_000e6);

        vm.prank(rebalancer);
        vault.processDepositQueue(type(uint256).max);

        assertEq(vault.maxDeposit(user1), 1000e6);

        vm.prank(user1);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.cancelDepositRequest(0);
    }

    function test_cancelDepositRequest_notAuthorized() public {
        // Third parties can't cancel
        vm.prank(user3);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.cancelDepositRequest(0);

        // Operators can't cancel, they can only claim
        vm.prank(user1);
        vault.setOperator(operator, true);

        vm.prank(user2);
        vault.setOperator(operator, true);

        vm.startPrank(operator);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.cancelDepositRequest(0);

        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.cancelDepositRequest(1);
        vm.stopPrank();

        // The controller of one request can't cancel another
        vm.prank(user2);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.cancelDepositRequest(0);

        // Other roles can't cancel
        vm.prank(rebalancer);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.cancelDepositRequest(0);

        vm.prank(admin);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.cancelDepositRequest(0);
    }

    function test_cancelDepositRequest_savingsInsufficientLiquidity() public {
        vm.prank(admin);
        spUsdc.grantRole(TAKER_ROLE, taker);

        // spUSDC has lent out all of its USDC, the refund can't be paid
        vm.prank(taker);
        spUsdc.take(1500e6);

        vm.prank(user1);
        vm.expectRevert("SparkVault/insufficient-liquidity");
        vault.cancelDepositRequest(0);

        vm.prank(guardian);
        vm.expectRevert("SparkVault/insufficient-liquidity");
        vault.cancelDepositRequest(0);

        deal(address(asset), address(spUsdc), 1000e6);

        vm.prank(user1);
        vault.cancelDepositRequest(0);
    }

}

contract SparkPrimeVaultCancelDepositRequestSuccessTests is SparkPrimeVaultTestBase {

    event CancelDepositRequest(
        uint256 indexed index,
        address indexed controller,
        address indexed owner,
        uint256 assets
    );

    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address user3 = makeAddr("user3");

    function setUp() public override {
        super.setUp();

        // No capacity, every request is queued
        vm.prank(admin);
        vault.setCapacity(0);

        deal(address(asset), user1, 1_000_000e6);
        deal(address(asset), user3, 1_000_000e6);

        vm.startPrank(user1);
        asset.approve(address(vault), type(uint256).max);
        vault.requestDeposit(1000e6, user1, user1);  // Index 0
        vault.requestDeposit(500e6,  user2, user1);  // Index 1, user2 is the controller
        vm.stopPrank();

        vm.startPrank(user3);
        asset.approve(address(vault), type(uint256).max);
        vault.requestDeposit(300e6, user3, user3);   // Index 2
        vm.stopPrank();
    }

    function test_cancelDepositRequest_owner() public {
        assertEq(asset.balanceOf(user1),           1_000_000e6 - 1500e6);
        assertEq(asset.balanceOf(address(spUsdc)), 1800e6);
        assertEq(spUsdc.balanceOf(address(vault)), 1800e6);

        assertEq(vault.pendingDepositShares(user1), 1000e6);
        assertEq(vault.totalQueuedDepositShares(),  1800e6);
        assertEq(vault.depositHead(),               0);

        ( address controller, address owner, uint256 amount, ) = vault.depositQueue(0);

        assertEq(controller, user1);
        assertEq(owner,      user1);
        assertEq(amount,     1000e6);

        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit CancelDepositRequest(0, user1, user1, 1000e6);
        vault.cancelDepositRequest(0);

        // The spUSDC is redeemed straight to the owner, the entry is left empty in place
        assertEq(asset.balanceOf(user1),           1_000_000e6 - 500e6);
        assertEq(asset.balanceOf(address(spUsdc)), 800e6);
        assertEq(spUsdc.balanceOf(address(vault)), 800e6);

        assertEq(vault.pendingDepositShares(user1), 0);
        assertEq(vault.totalQueuedDepositShares(),  800e6);
        assertEq(vault.depositHead(),               0);

        ( controller, owner, amount, ) = vault.depositQueue(0);

        assertEq(controller, address(0));
        assertEq(owner,      address(0));
        assertEq(amount,     0);
    }

    function test_cancelDepositRequest_controller() public {
        assertEq(asset.balanceOf(user1), 1_000_000e6 - 1500e6);
        assertEq(asset.balanceOf(user2), 0);

        assertEq(vault.pendingDepositShares(user2), 500e6);

        // The controller cancels, the owner is refunded
        vm.prank(user2);
        vm.expectEmit(address(vault));
        emit CancelDepositRequest(1, user2, user1, 500e6);
        vault.cancelDepositRequest(1);

        assertEq(asset.balanceOf(user1), 1_000_000e6 - 1000e6);
        assertEq(asset.balanceOf(user2), 0);

        assertEq(vault.pendingDepositShares(user2), 0);
        assertEq(vault.totalQueuedDepositShares(),  1300e6);
    }

    function test_cancelDepositRequest_guardian() public {
        assertEq(asset.balanceOf(user3),    1_000_000e6 - 300e6);
        assertEq(asset.balanceOf(guardian), 0);

        // The guardian cancels for compliance, the owner is refunded
        vm.prank(guardian);
        vm.expectEmit(address(vault));
        emit CancelDepositRequest(2, user3, user3, 300e6);
        vault.cancelDepositRequest(2);

        assertEq(asset.balanceOf(user3),    1_000_000e6);
        assertEq(asset.balanceOf(guardian), 0);

        assertEq(vault.pendingDepositShares(user3), 0);
        assertEq(vault.totalQueuedDepositShares(),  1500e6);
    }

    function test_cancelDepositRequest_whilePaused() public {
        vm.prank(guardian);
        vault.pause();

        vm.prank(user1);
        vault.cancelDepositRequest(0);

        assertEq(asset.balanceOf(user1),            1_000_000e6 - 500e6);
        assertEq(vault.pendingDepositShares(user1), 0);
    }

    function test_cancelDepositRequest_refundIncludesSavingsYield() public {
        vm.prank(setter);
        spUsdc.setVsr(FIVE_PCT_VSR);

        skip(365 days);

        // Back the spUSDC yield
        deal(address(asset), address(spUsdc), spUsdc.totalAssets());

        assertEq(vault.pendingDepositRequest(0, user1), 1049.999999e6);

        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit CancelDepositRequest(0, user1, user1, 1049.999999e6);
        vault.cancelDepositRequest(0);

        assertEq(asset.balanceOf(user1),            1_000_000e6 - 1500e6 + 1049.999999e6);
        assertEq(vault.pendingDepositShares(user1), 0);
        assertEq(spUsdc.balanceOf(address(vault)),  800e6);
    }

    function test_cancelDepositRequest_partiallyFilledHead() public {
        vm.prank(admin);
        vault.setCapacity(1_000_000e6);

        vm.prank(rebalancer);
        vault.processDepositQueue(400e6);

        assertEq(vault.maxDeposit(user1),           400e6);
        assertEq(vault.maxMint(user1),              400e6);
        assertEq(vault.pendingDepositShares(user1), 600e6);
        assertEq(vault.depositHead(),               0);

        ( ,, uint256 amount, ) = vault.depositQueue(0);

        assertEq(amount, 600e6);

        // Only the unfilled remainder is refunded, the filled part stays claimable
        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit CancelDepositRequest(0, user1, user1, 600e6);
        vault.cancelDepositRequest(0);

        assertEq(asset.balanceOf(user1),            1_000_000e6 - 1500e6 + 600e6);
        assertEq(vault.maxDeposit(user1),           400e6);
        assertEq(vault.maxMint(user1),              400e6);
        assertEq(vault.pendingDepositShares(user1), 0);
        assertEq(vault.totalQueuedDepositShares(),  800e6);
        assertEq(vault.depositHead(),               0);

        // The next fill skips the cancelled head
        vm.prank(rebalancer);
        vault.processDepositQueue(type(uint256).max);

        assertEq(vault.maxDeposit(user2), 500e6);
        assertEq(vault.maxDeposit(user3), 300e6);
        assertEq(vault.depositHead(),     3);
    }

}

contract SparkPrimeVaultRequestRedeemFailureTests is SparkPrimeVaultTestBase {

    // NOTE: This cannot be part of SparkPrimeVaultTestBase, because that is used in a contract where
    // DssTest is also used (and that also defines RAY).
    uint256 constant internal RAY = 1e27;

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
        vault.mint(1000e6, user1);
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

    function test_requestRedeem_invalidController() public {
        vm.prank(user1);
        vm.expectRevert("SparkPrimeVault/invalid-controller");
        vault.requestRedeem(100e6, address(0), user1);
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

        // The net amount can end up below the minimum
        assertLt(vault.maxWithdraw(user1), 50e6);
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
        address indexed controller,
        address indexed owner,
        uint256 indexed requestId,
        address sender,
        uint256 shares
    );
    event Transfer(address indexed from, address indexed to, uint256 value);

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
        vault.mint(1000e6, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        asset.approve(address(vault), 1000e6);
        vault.requestDeposit(1000e6, user2, user2);
        vault.mint(1000e6, user2);
        vm.stopPrank();
    }

    function test_requestRedeem_instant() public {
        assertEq(asset.balanceOf(address(vault)), 2000e6);

        assertEq(vault.totalSupply(),             2000e6);
        assertEq(vault.balanceOf(user1),          1000e6);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.availableLiquidAssets(),   2000e6);

        assertEq(vault.maxRedeem(user1),                 0);
        assertEq(vault.maxWithdraw(user1),               0);
        assertEq(vault.pendingRedeemShares(user1),       0);
        assertEq(vault.pendingRedeemRequest(0, user1),   0);
        assertEq(vault.claimableRedeemRequest(0, user1), 0);
        assertEq(vault.totalQueuedRedeemShares(),        0);
        assertEq(vault.totalClaimableRedeemAssets(),     0);
        assertEq(vault.withdrawHead(),                   0);

        // The shares are escrowed, burned and the net USDC is ring-fenced in the same call
        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit Transfer(user1, address(vault), 200e6);
        emit Transfer(address(vault), address(0), 200e6);
        emit RedeemRequest(user1, user1, 0, user1, 200e6);
        uint256 requestId = vault.requestRedeem(200e6, user1, user1);

        assertEq(requestId, 0);

        assertEq(asset.balanceOf(address(vault)), 2000e6);

        assertEq(vault.totalSupply(),             1800e6);
        assertEq(vault.balanceOf(user1),          800e6);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.availableLiquidAssets(),   2000e6 - 199e6);

        assertEq(vault.maxRedeem(user1),                 200e6);
        assertEq(vault.maxWithdraw(user1),               199e6);  // 0.5% fee
        assertEq(vault.pendingRedeemShares(user1),       0);
        assertEq(vault.pendingRedeemRequest(0, user1),   0);
        assertEq(vault.claimableRedeemRequest(0, user1), 200e6);
        assertEq(vault.totalQueuedRedeemShares(),        0);
        assertEq(vault.totalClaimableRedeemAssets(),     199e6);
        assertEq(vault.withdrawHead(),                   1);

        // The entry is kept with the fee locked in, fully filled
        ( address controller, address owner, uint256 amount, uint256 fee ) = vault.withdrawQueue(0);

        assertEq(controller, user1);
        assertEq(owner,      user1);
        assertEq(amount,     0);
        assertEq(fee,        0.005e18);
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

        vm.prank(user1);
        vault.requestRedeem(200e6, user1, user1);

        // Gross is 209.999999e6, the 0.5% fee rounds up to 1.05e6
        assertEq(vault.maxRedeem(user1),             200e6);
        assertEq(vault.maxWithdraw(user1),           208.949999e6);
        assertEq(vault.totalClaimableRedeemAssets(), 208.949999e6);
        assertEq(vault.totalSupply(),                1800e6);
    }

    function test_requestRedeem_instant_withdrawFeeZero() public {
        vm.prank(riskManager);
        vault.setWithdrawFee(0);

        vm.prank(user1);
        vault.requestRedeem(200e6, user1, user1);

        assertEq(vault.maxRedeem(user1),             200e6);
        assertEq(vault.maxWithdraw(user1),           200e6);
        assertEq(vault.totalClaimableRedeemAssets(), 200e6);

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

        // Exactly the ring-fenced amount is pulled from spUSDC
        assertEq(vault.maxRedeem(user1),             200e6);
        assertEq(vault.maxWithdraw(user1),           199e6);
        assertEq(vault.totalClaimableRedeemAssets(), 199e6);
        assertEq(asset.balanceOf(address(vault)),    199e6);
        assertEq(spUsdc.balanceOf(address(vault)),   2000e6 - 199e6);
        assertEq(vault.availableLiquidAssets(),      2000e6 - 199e6);
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
        assertEq(vault.maxRedeem(user1),             300e6);
        assertEq(vault.maxWithdraw(user1),           298.5e6);
        assertEq(vault.totalClaimableRedeemAssets(), 298.5e6);
        assertEq(asset.balanceOf(address(vault)),    298.5e6);
        assertEq(spUsdc.balanceOf(address(vault)),   101.5e6);
        assertEq(vault.availableLiquidAssets(),      101.5e6);
    }

    function test_requestRedeem_liquidityExactlyNetBoundary() public {
        vm.prank(taker);
        vault.take(2000e6 - 199e6);

        assertEq(vault.availableLiquidAssets(), 199e6);

        vm.prank(user1);
        vault.requestRedeem(200e6, user1, user1);

        assertEq(vault.maxRedeem(user1),               200e6);
        assertEq(vault.maxWithdraw(user1),             199e6);
        assertEq(vault.pendingRedeemRequest(0, user1), 0);
        assertEq(vault.withdrawHead(),                 1);
        assertEq(vault.availableLiquidAssets(),        0);
        assertEq(vault.totalSupply(),                  1800e6);
    }

    function test_requestRedeem_liquidityOneWeiShort() public {
        vm.prank(taker);
        vault.take(2000e6 - (199e6 - 1));

        assertEq(vault.availableLiquidAssets(), 199e6 - 1);

        vm.prank(user1);
        vault.requestRedeem(200e6, user1, user1);

        // The largest share amount whose net fits: floor(198.999999e6 / 0.995) = 199.999998e6
        // shares, gross 199.999998e6, fee rounds up to 1e6, net 198.999998e6
        assertEq(vault.maxRedeem(user1),               199.999998e6);
        assertEq(vault.maxWithdraw(user1),             198.999998e6);
        assertEq(vault.pendingRedeemShares(user1),     2);
        assertEq(vault.pendingRedeemRequest(0, user1), 2);
        assertEq(vault.totalQueuedRedeemShares(),      2);
        assertEq(vault.balanceOf(address(vault)),      2);
        assertEq(vault.totalSupply(),                  2000e6 - 199.999998e6);
        assertEq(vault.withdrawHead(),                 0);
        assertEq(vault.availableLiquidAssets(),        1);
    }

    function test_requestRedeem_partialInstantRestQueued() public {
        vm.prank(taker);
        vault.take(1900e6);

        assertEq(vault.availableLiquidAssets(), 100e6);

        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit Transfer(user1, address(vault), 200e6);
        emit Transfer(address(vault), address(0), 100.502512e6);
        emit RedeemRequest(user1, user1, 0, user1, 200e6);
        vault.requestRedeem(200e6, user1, user1);

        // 100.502512e6 shares net 99.999999e6, the remaining 99.497488e6 shares wait in escrow
        assertEq(vault.maxRedeem(user1),                 100.502512e6);
        assertEq(vault.maxWithdraw(user1),               99.999999e6);
        assertEq(vault.pendingRedeemShares(user1),       99.497488e6);
        assertEq(vault.pendingRedeemRequest(0, user1),   99.497488e6);
        assertEq(vault.claimableRedeemRequest(0, user1), 100.502512e6);

        assertEq(vault.balanceOf(user1),             800e6);
        assertEq(vault.balanceOf(address(vault)),    99.497488e6);
        assertEq(vault.totalSupply(),                2000e6 - 100.502512e6);
        assertEq(vault.totalQueuedRedeemShares(),    99.497488e6);
        assertEq(vault.totalClaimableRedeemAssets(), 99.999999e6);
        assertEq(vault.withdrawHead(),               0);
        assertEq(vault.availableLiquidAssets(),      1);

        ( address controller, address owner, uint256 amount, uint256 fee ) = vault.withdrawQueue(0);

        assertEq(controller, user1);
        assertEq(owner,      user1);
        assertEq(amount,     99.497488e6);
        assertEq(fee,        0.005e18);
    }

    function test_requestRedeem_fullyQueued() public {
        vm.prank(taker);
        vault.take(2000e6);

        assertEq(vault.availableLiquidAssets(), 0);

        // No burn, the shares wait in escrow
        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit Transfer(user1, address(vault), 200e6);
        emit RedeemRequest(user1, user1, 0, user1, 200e6);
        vault.requestRedeem(200e6, user1, user1);

        assertEq(vault.maxRedeem(user1),                 0);
        assertEq(vault.maxWithdraw(user1),               0);
        assertEq(vault.pendingRedeemShares(user1),       200e6);
        assertEq(vault.pendingRedeemRequest(0, user1),   200e6);
        assertEq(vault.claimableRedeemRequest(0, user1), 0);

        assertEq(vault.balanceOf(user1),             800e6);
        assertEq(vault.balanceOf(address(vault)),    200e6);
        assertEq(vault.totalSupply(),                2000e6);
        assertEq(vault.totalQueuedRedeemShares(),    200e6);
        assertEq(vault.totalClaimableRedeemAssets(), 0);
        assertEq(vault.withdrawHead(),               0);

        ( address controller, address owner, uint256 amount, uint256 fee ) = vault.withdrawQueue(0);

        assertEq(controller, user1);
        assertEq(owner,      user1);
        assertEq(amount,     200e6);
        assertEq(fee,        0.005e18);
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
        vault.requestRedeem(200e6, user2, user2);

        assertEq(vault.maxRedeem(user2),             0);
        assertEq(vault.pendingRedeemShares(user2),   200e6);
        assertEq(vault.totalQueuedRedeemShares(),    400e6);
        assertEq(vault.totalClaimableRedeemAssets(), 0);
        assertEq(vault.withdrawHead(),               0);

        ( address controller, address owner, uint256 amount, ) = vault.withdrawQueue(1);

        assertEq(controller, user2);
        assertEq(owner,      user2);
        assertEq(amount,     200e6);
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

        vm.prank(rebalancer);
        vault.processWithdrawQueue(type(uint256).max);

        // Priced at the chi at processing time, not at request time
        assertEq(vault.maxRedeem(user1),   500e6);
        assertEq(vault.maxWithdraw(user1), 522.374999e6);  // Gross 524.999999e6 less 0.5%
    }

    function test_requestRedeem_dustNetsZeroBurnedForZero() public {
        vm.prank(taker);
        vault.take(2000e6);

        // 1 share grosses 1 wei, the fee rounds up to 1 wei, so the net is 0 and fits any budget
        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit Transfer(user1, address(vault), 1);
        emit Transfer(address(vault), address(0), 1);
        emit RedeemRequest(user1, user1, 0, user1, 1);
        vault.requestRedeem(1, user1, user1);

        assertEq(vault.maxRedeem(user1),             1);
        assertEq(vault.maxWithdraw(user1),           0);
        assertEq(vault.pendingRedeemShares(user1),   0);
        assertEq(vault.totalQueuedRedeemShares(),    0);
        assertEq(vault.totalClaimableRedeemAssets(), 0);
        assertEq(vault.totalSupply(),                2000e6 - 1);
        assertEq(vault.withdrawHead(),               1);
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

        vm.prank(rebalancer);
        vault.processWithdrawQueue(type(uint256).max);

        assertEq(vault.maxWithdraw(user1), 199e6);
        assertEq(vault.maxWithdraw(user2), 198e6);
    }

    function test_requestRedeem_controllerNotOwner() public {
        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit Transfer(user1, address(vault), 200e6);
        emit Transfer(address(vault), address(0), 200e6);
        emit RedeemRequest(user2, user1, 0, user1, 200e6);
        vault.requestRedeem(200e6, user2, user1);

        // The owner's shares are used, the controller holds the claim
        assertEq(vault.balanceOf(user1), 800e6);
        assertEq(vault.balanceOf(user2), 1000e6);

        assertEq(vault.maxRedeem(user1),   0);
        assertEq(vault.maxWithdraw(user1), 0);
        assertEq(vault.maxRedeem(user2),   200e6);
        assertEq(vault.maxWithdraw(user2), 199e6);

        ( address controller, address owner,, ) = vault.withdrawQueue(0);

        assertEq(controller, user2);
        assertEq(owner,      user1);
    }

}

contract SparkPrimeVaultProcessDepositQueueFailureTests is SparkPrimeVaultTestBase {

    function test_processDepositQueue_notRebalancer() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            REBALANCER_ROLE
        ));
        vault.processDepositQueue(type(uint256).max);
    }

    function test_processDepositQueue_paused() public {
        vm.prank(guardian);
        vault.pause();

        vm.startPrank(rebalancer);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.processDepositQueue(type(uint256).max);
        vm.stopPrank();

        vm.prank(unpauser);
        vault.unpause();

        vm.prank(rebalancer);
        vault.processDepositQueue(type(uint256).max);
    }

}

contract SparkPrimeVaultProcessDepositQueueSuccessTests is SparkPrimeVaultTestBase {

    // NOTE: This cannot be part of SparkPrimeVaultTestBase, because that is used in a contract where
    // DssTest is also used (and that also defines RAY).
    uint256 constant internal RAY = 1e27;

    event Transfer(address indexed from, address indexed to, uint256 value);

    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address user3 = makeAddr("user3");
    address user4 = makeAddr("user4");

    function setUp() public override {
        super.setUp();

        // No capacity, every request is queued
        vm.prank(admin);
        vault.setCapacity(0);

        deal(address(asset), user1, 1_000_000e6);
        deal(address(asset), user2, 1_000_000e6);
        deal(address(asset), user3, 1_000_000e6);
        deal(address(asset), user4, 1_000_000e6);

        vm.startPrank(user1);
        asset.approve(address(vault), type(uint256).max);
        vault.requestDeposit(1000e6, user1, user1);  // Index 0
        vm.stopPrank();

        vm.startPrank(user2);
        asset.approve(address(vault), type(uint256).max);
        vault.requestDeposit(500e6, user2, user2);   // Index 1
        vm.stopPrank();

        vm.startPrank(user3);
        asset.approve(address(vault), type(uint256).max);
        vault.requestDeposit(300e6, user3, user3);   // Index 2
        vm.stopPrank();

        vm.prank(user4);
        asset.approve(address(vault), type(uint256).max);
    }

    function test_processDepositQueue_noCapacity() public {
        vm.prank(rebalancer);
        vault.processDepositQueue(type(uint256).max);

        assertEq(vault.maxDeposit(user1),          0);
        assertEq(vault.totalSupply(),              0);
        assertEq(vault.totalQueuedDepositShares(), 1800e6);
        assertEq(vault.depositHead(),              0);
    }

    function test_processDepositQueue_zeroBudget() public {
        vm.prank(admin);
        vault.setCapacity(1_000_000e6);

        vm.prank(rebalancer);
        vault.processDepositQueue(0);

        assertEq(vault.maxDeposit(user1),          0);
        assertEq(vault.totalSupply(),              0);
        assertEq(vault.totalQueuedDepositShares(), 1800e6);
        assertEq(vault.depositHead(),              0);
    }

    function test_processDepositQueue_fullFill() public {
        vm.prank(admin);
        vault.setCapacity(1_000_000e6);

        assertEq(asset.balanceOf(address(spUsdc)), 1800e6);
        assertEq(spUsdc.balanceOf(address(vault)), 1800e6);

        assertEq(vault.totalSupply(),             0);
        assertEq(vault.balanceOf(address(vault)), 0);

        assertEq(vault.maxDeposit(user1), 0);
        assertEq(vault.maxDeposit(user2), 0);
        assertEq(vault.maxDeposit(user3), 0);
        assertEq(vault.maxMint(user1),    0);
        assertEq(vault.maxMint(user2),    0);
        assertEq(vault.maxMint(user3),    0);

        assertEq(vault.pendingDepositShares(user1), 1000e6);
        assertEq(vault.pendingDepositShares(user2), 500e6);
        assertEq(vault.pendingDepositShares(user3), 300e6);
        assertEq(vault.totalQueuedDepositShares(),  1800e6);
        assertEq(vault.depositHead(),               0);

        vm.prank(rebalancer);
        vm.expectEmit(address(vault));
        emit Transfer(address(0), address(vault), 1000e6);
        emit Transfer(address(0), address(vault), 500e6);
        emit Transfer(address(0), address(vault), 300e6);
        vault.processDepositQueue(type(uint256).max);

        // The spUSDC is not redeemed, it becomes the vault's free sleeve
        assertEq(asset.balanceOf(address(spUsdc)), 1800e6);
        assertEq(spUsdc.balanceOf(address(vault)), 1800e6);
        assertEq(vault.availableLiquidAssets(),    1800e6);

        assertEq(vault.totalSupply(),             1800e6);
        assertEq(vault.balanceOf(address(vault)), 1800e6);

        assertEq(vault.maxDeposit(user1), 1000e6);
        assertEq(vault.maxDeposit(user2), 500e6);
        assertEq(vault.maxDeposit(user3), 300e6);
        assertEq(vault.maxMint(user1),    1000e6);
        assertEq(vault.maxMint(user2),    500e6);
        assertEq(vault.maxMint(user3),    300e6);

        assertEq(vault.pendingDepositShares(user1), 0);
        assertEq(vault.pendingDepositShares(user2), 0);
        assertEq(vault.pendingDepositShares(user3), 0);
        assertEq(vault.totalQueuedDepositShares(),  0);
        assertEq(vault.depositHead(),               3);

        for (uint256 i = 0; i < 3; i++) {
            ( ,, uint256 amount, ) = vault.depositQueue(i);
            assertEq(amount, 0);
        }
    }

    function test_processDepositQueue_budgetPartialFill() public {
        vm.prank(admin);
        vault.setCapacity(1_000_000e6);

        vm.prank(rebalancer);
        vault.processDepositQueue(1200e6);

        // user1 is filled, user2 is partially filled and stays at the head
        assertEq(vault.maxDeposit(user1), 1000e6);
        assertEq(vault.maxDeposit(user2), 200e6);
        assertEq(vault.maxDeposit(user3), 0);

        assertEq(vault.pendingDepositShares(user1), 0);
        assertEq(vault.pendingDepositShares(user2), 300e6);
        assertEq(vault.pendingDepositShares(user3), 300e6);
        assertEq(vault.totalQueuedDepositShares(),  600e6);
        assertEq(vault.totalSupply(),               1200e6);
        assertEq(vault.depositHead(),               1);

        ( ,, uint256 amount, ) = vault.depositQueue(1);

        assertEq(amount, 300e6);

        vm.prank(rebalancer);
        vault.processDepositQueue(type(uint256).max);

        assertEq(vault.maxDeposit(user2),          500e6);
        assertEq(vault.maxDeposit(user3),          300e6);
        assertEq(vault.totalQueuedDepositShares(), 0);
        assertEq(vault.totalSupply(),              1800e6);
        assertEq(vault.depositHead(),              3);
    }

    function test_processDepositQueue_budgetExactlyHeadBoundary() public {
        vm.prank(admin);
        vault.setCapacity(1_000_000e6);

        vm.prank(rebalancer);
        vault.processDepositQueue(1000e6 - 1);

        assertEq(vault.maxDeposit(user1),           1000e6 - 1);
        assertEq(vault.pendingDepositShares(user1), 1);
        assertEq(vault.depositHead(),               0);

        vm.prank(rebalancer);
        vault.processDepositQueue(1);

        assertEq(vault.maxDeposit(user1),           1000e6);
        assertEq(vault.pendingDepositShares(user1), 0);
        assertEq(vault.maxDeposit(user2),           0);
        assertEq(vault.depositHead(),               1);
    }

    function test_processDepositQueue_oneWeiBudget() public {
        vm.prank(admin);
        vault.setCapacity(1_000_000e6);

        vm.prank(rebalancer);
        vault.processDepositQueue(1);

        assertEq(vault.maxDeposit(user1),           1);
        assertEq(vault.maxMint(user1),              1);
        assertEq(vault.pendingDepositShares(user1), 1000e6 - 1);
        assertEq(vault.totalSupply(),               1);
        assertEq(vault.depositHead(),               0);
    }

    function test_processDepositQueue_capacityPartialFill() public {
        vm.prank(admin);
        vault.setCapacity(1199e6);

        vm.prank(rebalancer);
        vault.processDepositQueue(type(uint256).max);

        assertEq(vault.maxDeposit(user1),           1000e6);
        assertEq(vault.maxDeposit(user2),           199e6);
        assertEq(vault.pendingDepositShares(user2), 301e6);
        assertEq(vault.totalSupply(),               1199e6);
        assertEq(vault.availableCapacity(),         0);
        assertEq(vault.depositHead(),               1);

        // Nothing more happens without more room
        vm.prank(rebalancer);
        vault.processDepositQueue(type(uint256).max);

        assertEq(vault.maxDeposit(user2), 199e6);
        assertEq(vault.depositHead(),     1);
    }

    function test_processDepositQueue_skipsCancelled() public {
        vm.prank(user2);
        vault.cancelDepositRequest(1);

        vm.prank(admin);
        vault.setCapacity(1_000_000e6);

        vm.prank(rebalancer);
        vault.processDepositQueue(type(uint256).max);

        assertEq(vault.maxDeposit(user1),          1000e6);
        assertEq(vault.maxDeposit(user2),          0);
        assertEq(vault.maxDeposit(user3),          300e6);
        assertEq(vault.totalSupply(),              1300e6);
        assertEq(vault.totalQueuedDepositShares(), 0);
        assertEq(vault.depositHead(),              3);
    }

    function test_processDepositQueue_cancelledWalkBoundary() public {
        // 499 cancelled entries ahead of user4 are walked in one call
        _cancelledEntries(499);

        vm.prank(user4);
        vault.requestDeposit(100e6, user4, user4);  // Index 502

        vm.prank(admin);
        vault.setCapacity(1_000_000e6);

        vm.prank(rebalancer);
        vault.processDepositQueue(type(uint256).max);

        assertEq(vault.maxDeposit(user4), 100e6);
        assertEq(vault.depositHead(),     503);
    }

    function test_processDepositQueue_cancelledWalkBoundary_needsTwoCalls() public {
        // The walk stops on the 500th cancelled entry and saves its progress
        _cancelledEntries(500);

        vm.prank(user4);
        vault.requestDeposit(100e6, user4, user4);  // Index 503

        vm.prank(admin);
        vault.setCapacity(1_000_000e6);

        vm.prank(rebalancer);
        vault.processDepositQueue(type(uint256).max);

        assertEq(vault.maxDeposit(user1), 1000e6);
        assertEq(vault.maxDeposit(user4), 0);
        assertEq(vault.depositHead(),     3 + 499);

        vm.prank(rebalancer);
        vault.processDepositQueue(type(uint256).max);

        assertEq(vault.maxDeposit(user4), 100e6);
        assertEq(vault.depositHead(),     504);
    }

    function test_processDepositQueue_cancelledWalkedWithoutBudget() public {
        _cancelledEntries(10);

        // No capacity, the cancelled entries are still walked past
        vm.prank(rebalancer);
        vault.processDepositQueue(type(uint256).max);

        assertEq(vault.totalSupply(), 0);
        assertEq(vault.depositHead(), 0);  // user1 is live at the head

        vm.prank(user1);
        vault.cancelDepositRequest(0);

        vm.prank(rebalancer);
        vault.processDepositQueue(type(uint256).max);

        assertEq(vault.totalSupply(), 0);
        assertEq(vault.depositHead(), 1);  // user2 is live at the head
    }

    function test_processDepositQueue_zeroShareFillDoesNotGrindHead() public {
        vm.prank(admin);
        vault.setVsrBounds(1e27, FIVE_PCT_VSR);

        vm.prank(setter);
        vault.setVsr(FIVE_PCT_VSR);

        skip(365 days);

        // One share of room is worth 1 wei after rounding, which mints 0 shares
        vm.prank(admin);
        vault.setCapacity(1);

        vm.prank(rebalancer);
        vault.processDepositQueue(type(uint256).max);

        assertEq(vault.maxDeposit(user1),           0);
        assertEq(vault.maxMint(user1),              0);
        assertEq(vault.pendingDepositShares(user1), 1000e6);
        assertEq(vault.totalSupply(),               0);
        assertEq(vault.depositHead(),               0);

        // Two shares of room are worth 2 wei, which mints 1 share
        vm.prank(admin);
        vault.setCapacity(2);

        vm.prank(rebalancer);
        vault.processDepositQueue(type(uint256).max);

        assertEq(vault.maxDeposit(user1),           2);
        assertEq(vault.maxMint(user1),              1);
        assertEq(vault.pendingDepositShares(user1), 1000e6 - 2);
        assertEq(vault.totalSupply(),               1);
        assertEq(vault.depositHead(),               0);
    }

    function test_processDepositQueue_savingsYieldCreditedAtSamePrice() public {
        vm.prank(admin);
        vault.setVsrBounds(1e27, FIVE_PCT_VSR);

        vm.startPrank(setter);
        vault.setVsr(FIVE_PCT_VSR);
        spUsdc.setVsr(FIVE_PCT_VSR);
        vm.stopPrank();

        skip(365 days);

        assertEq(spUsdc.nowChi(), 1.049999999999999999961070145e27);
        assertEq(vault.nowChi(),  1.049999999999999999961070145e27);

        vm.prank(admin);
        vault.setCapacity(1_000_000e6);

        vm.prank(rebalancer);
        vault.processDepositQueue(type(uint256).max);

        // Everyone in the round is credited the spUSDC value of their shares at the same chi
        assertEq(vault.maxDeposit(user1), 1049.999999e6);
        assertEq(vault.maxDeposit(user2), 524.999999e6);
        assertEq(vault.maxDeposit(user3), 314.999999e6);
        assertEq(vault.maxMint(user1),    999.999999e6);
        assertEq(vault.maxMint(user2),    499.999999e6);
        assertEq(vault.maxMint(user3),    299.999999e6);

        assertEq(vault.totalSupply(),              1799.999997e6);
        assertEq(vault.totalQueuedDepositShares(), 0);
        assertEq(spUsdc.balanceOf(address(vault)), 1800e6);  // Kept as the free sleeve
        assertEq(vault.depositHead(),              3);
    }

    function test_processDepositQueue_partialFillRoundsSharesUp() public {
        vm.prank(setter);
        spUsdc.setVsr(FIVE_PCT_VSR);

        skip(37 days + 13);  // An odd spUSDC price

        assertEq(spUsdc.nowChi(),                       1.004958123386656194224284927e27);
        assertEq(vault.pendingDepositRequest(0, user1), 1004.958123e6);

        vm.prank(admin);
        vault.setCapacity(1_000_000e6);

        vm.prank(rebalancer);
        vault.processDepositQueue(333.333333e6);

        // The accepted spUSDC rounds up, so it is always worth at least the credited assets
        assertEq(vault.maxDeposit(user1),               333.333333e6);
        assertEq(vault.maxMint(user1),                  333.333333e6);
        assertEq(vault.pendingDepositShares(user1),     668.311220e6);
        assertEq(vault.pendingDepositRequest(0, user1), 671.624789e6);
        assertEq(vault.depositHead(),                   0);

        assertGe(spUsdc.convertToAssets(1000e6 - 668.311220e6), 333.333333e6);
    }

    function test_processDepositQueue_dripsFirst() public {
        vm.prank(admin);
        vault.setVsrBounds(1e27, FIVE_PCT_VSR);

        vm.prank(setter);
        vault.setVsr(FIVE_PCT_VSR);

        uint256 timestamp = block.timestamp;

        skip(1 days);

        assertEq(uint256(vault.chi()), 1e27);
        assertEq(uint256(vault.rho()), timestamp);

        vm.prank(admin);
        vault.setCapacity(1_000_000e6);

        vm.prank(rebalancer);
        vault.processDepositQueue(type(uint256).max);

        assertEq(uint256(vault.chi()), 1.000133680617113440350406888e27);
        assertEq(uint256(vault.rho()), timestamp + 1 days);

        // Shares are priced at the dripped chi
        assertEq(vault.maxDeposit(user1), 1000e6);
        assertEq(vault.maxMint(user1),    999.866337e6);  // 1000e6 * RAY / chi
    }

    // Lays `n` cancelled entries at the tail of the queue
    function _cancelledEntries(uint256 n) internal {
        uint256 start = 3;
        vm.startPrank(user4);
        for (uint256 i = 0; i < n; i++) {
            vault.requestDeposit(100e6, user4, user4);
            vault.cancelDepositRequest(start + i);
        }
        vm.stopPrank();
    }

}

contract SparkPrimeVaultProcessWithdrawQueueFailureTests is SparkPrimeVaultTestBase {

    function test_processWithdrawQueue_notRebalancer() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            REBALANCER_ROLE
        ));
        vault.processWithdrawQueue(type(uint256).max);
    }

    function test_processWithdrawQueue_paused() public {
        vm.prank(guardian);
        vault.pause();

        vm.startPrank(rebalancer);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.processWithdrawQueue(type(uint256).max);
        vm.stopPrank();

        vm.prank(unpauser);
        vault.unpause();

        vm.prank(rebalancer);
        vault.processWithdrawQueue(type(uint256).max);
    }

}

contract SparkPrimeVaultProcessWithdrawQueueSuccessTests is SparkPrimeVaultTestBase {

    // NOTE: This cannot be part of SparkPrimeVaultTestBase, because that is used in a contract where
    // DssTest is also used (and that also defines RAY).
    uint256 constant internal RAY = 1e27;

    event Transfer(address indexed from, address indexed to, uint256 value);

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
            vault.mint(1000e6, users[i]);
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
        vm.prank(rebalancer);
        vault.processWithdrawQueue(type(uint256).max);

        assertEq(vault.maxRedeem(user1),          0);
        assertEq(vault.totalQueuedRedeemShares(), 1000e6);
        assertEq(vault.totalSupply(),             3000e6);
        assertEq(vault.withdrawHead(),            0);
    }

    function test_processWithdrawQueue_zeroBudget() public {
        deal(address(asset), address(vault), 1000e6);

        vm.prank(rebalancer);
        vault.processWithdrawQueue(0);

        assertEq(vault.maxRedeem(user1),          0);
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

        assertEq(vault.maxRedeem(user1),   0);
        assertEq(vault.maxRedeem(user2),   0);
        assertEq(vault.maxRedeem(user3),   0);
        assertEq(vault.maxWithdraw(user1), 0);
        assertEq(vault.maxWithdraw(user2), 0);
        assertEq(vault.maxWithdraw(user3), 0);

        assertEq(vault.pendingRedeemShares(user1),   500e6);
        assertEq(vault.pendingRedeemShares(user2),   300e6);
        assertEq(vault.pendingRedeemShares(user3),   200e6);
        assertEq(vault.totalQueuedRedeemShares(),    1000e6);
        assertEq(vault.totalClaimableRedeemAssets(), 0);
        assertEq(vault.withdrawHead(),               0);

        vm.prank(rebalancer);
        vm.expectEmit(address(vault));
        emit Transfer(address(vault), address(0), 500e6);
        emit Transfer(address(vault), address(0), 300e6);
        emit Transfer(address(vault), address(0), 200e6);
        vault.processWithdrawQueue(type(uint256).max);

        // The fees stay in the vault as free liquidity
        assertEq(vault.availableLiquidAssets(), 5e6);

        assertEq(vault.totalSupply(),             2000e6);
        assertEq(vault.balanceOf(address(vault)), 0);

        assertEq(vault.maxRedeem(user1),   500e6);
        assertEq(vault.maxRedeem(user2),   300e6);
        assertEq(vault.maxRedeem(user3),   200e6);
        assertEq(vault.maxWithdraw(user1), 497.5e6);
        assertEq(vault.maxWithdraw(user2), 298.5e6);
        assertEq(vault.maxWithdraw(user3), 199e6);

        assertEq(vault.pendingRedeemShares(user1),   0);
        assertEq(vault.pendingRedeemShares(user2),   0);
        assertEq(vault.pendingRedeemShares(user3),   0);
        assertEq(vault.totalQueuedRedeemShares(),    0);
        assertEq(vault.totalClaimableRedeemAssets(), 995e6);
        assertEq(vault.withdrawHead(),               3);

        for (uint256 i = 0; i < 3; i++) {
            ( ,, uint256 amount, ) = vault.withdrawQueue(i);
            assertEq(amount, 0);
        }
    }

    function test_processWithdrawQueue_budgetPartialFill() public {
        deal(address(asset), address(vault), 1000e6);

        vm.prank(rebalancer);
        vault.processWithdrawQueue(600e6);

        // user1 is filled, user2 gets the largest share amount whose net fits the remaining
        // 102.5e6: 103.015075e6 shares, fee rounds up to 0.515076e6, net 102.499999e6
        assertEq(vault.maxRedeem(user1),   500e6);
        assertEq(vault.maxRedeem(user2),   103.015075e6);
        assertEq(vault.maxRedeem(user3),   0);
        assertEq(vault.maxWithdraw(user1), 497.5e6);
        assertEq(vault.maxWithdraw(user2), 102.499999e6);
        assertEq(vault.maxWithdraw(user3), 0);

        assertEq(vault.pendingRedeemShares(user2),   300e6 - 103.015075e6);
        assertEq(vault.totalQueuedRedeemShares(),    1000e6 - 500e6 - 103.015075e6);
        assertEq(vault.totalClaimableRedeemAssets(), 497.5e6 + 102.499999e6);
        assertEq(vault.totalSupply(),                3000e6 - 500e6 - 103.015075e6);
        assertEq(vault.withdrawHead(),               1);

        ( ,, uint256 amount, ) = vault.withdrawQueue(1);

        assertEq(amount, 300e6 - 103.015075e6);

        vm.prank(rebalancer);
        vault.processWithdrawQueue(type(uint256).max);

        // The split cost user2 1 wei of fee rounding
        assertEq(vault.maxRedeem(user2),   300e6);
        assertEq(vault.maxRedeem(user3),   200e6);
        assertEq(vault.maxWithdraw(user2), 298.5e6 - 1);
        assertEq(vault.maxWithdraw(user3), 199e6);

        assertEq(vault.totalQueuedRedeemShares(),    0);
        assertEq(vault.totalClaimableRedeemAssets(), 995e6 - 1);
        assertEq(vault.totalSupply(),                2000e6);
        assertEq(vault.withdrawHead(),               3);
    }

    function test_processWithdrawQueue_liquidityCapped() public {
        // The budget is capped by the available liquidity, not just by `maxAssets`
        deal(address(asset), address(vault), 600e6);

        vm.prank(rebalancer);
        vault.processWithdrawQueue(type(uint256).max);

        assertEq(vault.maxRedeem(user1),   500e6);
        assertEq(vault.maxRedeem(user2),   103.015075e6);
        assertEq(vault.maxWithdraw(user1), 497.5e6);
        assertEq(vault.maxWithdraw(user2), 102.499999e6);
        assertEq(vault.withdrawHead(),     1);

        assertEq(vault.availableLiquidAssets(), 1);
    }

    function test_processWithdrawQueue_budgetExactlyHeadNetBoundary() public {
        deal(address(asset), address(vault), 1000e6);

        vm.prank(rebalancer);
        vault.processWithdrawQueue(497.5e6 - 1);

        assertEq(vault.maxRedeem(user1),           499.999998e6);
        assertEq(vault.maxWithdraw(user1),         497.499998e6);
        assertEq(vault.pendingRedeemShares(user1), 2);
        assertEq(vault.withdrawHead(),             0);

        vm.prank(rebalancer);
        vault.processWithdrawQueue(1);

        assertEq(vault.maxRedeem(user1),           500e6);
        assertEq(vault.maxWithdraw(user1),         497.5e6 - 1);
        assertEq(vault.pendingRedeemShares(user1), 0);
        assertEq(vault.maxRedeem(user2),           0);
        assertEq(vault.withdrawHead(),             1);
    }

    function test_processWithdrawQueue_tinyBudgetDoesNotGrind() public {
        deal(address(asset), address(vault), 1000e6);

        // A budget that nets nothing after the fee doesn't burn any shares from the head
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(rebalancer);
            vault.processWithdrawQueue(1);
        }

        assertEq(vault.maxRedeem(user1),           0);
        assertEq(vault.pendingRedeemShares(user1), 500e6);
        assertEq(vault.totalSupply(),              3000e6);
        assertEq(vault.withdrawHead(),             0);
    }

    function test_processWithdrawQueue_dustEntryPassedOver() public {
        deal(address(asset), address(vault), 1000e6);

        vm.prank(rebalancer);
        vault.processWithdrawQueue(type(uint256).max);

        vm.prank(user1);
        vault.redeem(500e6, user1, user1);

        vm.prank(user2);
        vault.redeem(300e6, user2, user2);

        vm.prank(user3);
        vault.redeem(200e6, user3, user3);

        assertEq(vault.totalClaimableRedeemAssets(), 0);
        assertEq(vault.withdrawHead(),               3);

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

        vm.prank(rebalancer);
        vault.processWithdrawQueue(type(uint256).max);

        // user1 is filled exactly, the dust is burned for 0 and user3 is not ground down
        assertEq(vault.maxRedeem(user1),   100e6);
        assertEq(vault.maxWithdraw(user1), 99.5e6);
        assertEq(vault.maxRedeem(user2),   1);
        assertEq(vault.maxWithdraw(user2), 0);
        assertEq(vault.maxRedeem(user3),   0);

        assertEq(vault.pendingRedeemShares(user3), 200e6);
        assertEq(vault.totalQueuedRedeemShares(),  200e6);
        assertEq(vault.availableLiquidAssets(),    0);
        assertEq(vault.withdrawHead(),             5);
    }

    function test_processWithdrawQueue_pullsShortfallFromSavings() public {
        deal(address(asset), address(vault), 1000e6);

        vm.prank(rebalancer);
        vault.depositToSavings(1000e6);

        assertEq(asset.balanceOf(address(vault)),  0);
        assertEq(spUsdc.balanceOf(address(vault)), 1000e6);
        assertEq(vault.availableLiquidAssets(),    1000e6);

        vm.prank(rebalancer);
        vault.processWithdrawQueue(type(uint256).max);

        // Exactly the ring-fenced amount is pulled from spUSDC, the fees stay in the sleeve
        assertEq(vault.maxWithdraw(user1), 497.5e6);
        assertEq(vault.maxWithdraw(user2), 298.5e6);
        assertEq(vault.maxWithdraw(user3), 199e6);

        assertEq(vault.totalClaimableRedeemAssets(), 995e6);
        assertEq(asset.balanceOf(address(vault)),    995e6);
        assertEq(spUsdc.balanceOf(address(vault)),   5e6);
        assertEq(vault.availableLiquidAssets(),      5e6);
        assertEq(vault.withdrawHead(),               3);
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

        vm.prank(rebalancer);
        vault.processWithdrawQueue(type(uint256).max);

        assertEq(vault.maxRedeem(user1),   500e6);
        assertEq(vault.maxRedeem(user2),   103.015075e6);
        assertEq(vault.maxWithdraw(user1), 497.5e6);
        assertEq(vault.maxWithdraw(user2), 102.499999e6);
        assertEq(vault.withdrawHead(),     1);

        assertEq(asset.balanceOf(address(vault)),    599.999999e6);
        assertEq(asset.balanceOf(address(spUsdc)),   1);
        assertEq(vault.totalClaimableRedeemAssets(), 599.999999e6);
        assertEq(vault.availableLiquidAssets(),      1);
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

        assertEq(spUsdc.balanceOf(address(vault)),  1000e6);
        assertEq(vault.totalQueuedDepositShares(),  1000e6);
        assertEq(vault.availableLiquidAssets(),     0);

        vm.prank(rebalancer);
        vault.processWithdrawQueue(type(uint256).max);

        // The queued depositor's spUSDC is never used to pay redeemers
        assertEq(vault.maxRedeem(user1),           0);
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

        vm.prank(rebalancer);
        vault.processWithdrawQueue(type(uint256).max);

        // Queued redeemers earn the vault's yield until they are processed
        assertEq(vault.maxRedeem(user1),   500e6);
        assertEq(vault.maxWithdraw(user1), 522.374999e6);  // Gross 524.999999e6 less 0.5%
        assertEq(vault.maxRedeem(user2),   300e6);
        assertEq(vault.maxWithdraw(user2), 313.424999e6);  // Gross 314.999999e6 less 0.5%
        assertEq(vault.maxRedeem(user3),   200e6);
        assertEq(vault.maxWithdraw(user3), 208.949999e6);  // Gross 209.999999e6 less 0.5%
    }

    function test_processWithdrawQueue_lossBookedBeforeProcessing() public {
        vm.prank(guardian);
        vault.pause();

        vm.prank(riskManager);
        vault.setChi(0.8e27);

        vm.prank(unpauser);
        vault.unpause();

        deal(address(asset), address(vault), 1000e6);

        vm.prank(rebalancer);
        vault.processWithdrawQueue(type(uint256).max);

        // Queued redeemers absorb the loss, the fee applies to the reduced gross
        assertEq(vault.maxWithdraw(user1), 398e6);
        assertEq(vault.maxWithdraw(user2), 238.8e6);
        assertEq(vault.maxWithdraw(user3), 159.2e6);

        assertEq(vault.totalClaimableRedeemAssets(), 796e6);
        assertEq(vault.availableLiquidAssets(),      204e6);
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

        vm.prank(rebalancer);
        vault.processWithdrawQueue(type(uint256).max);

        assertEq(uint256(vault.chi()), 1.000133680617113440350406888e27);
        assertEq(uint256(vault.rho()), timestamp + 1 days);
    }

}
