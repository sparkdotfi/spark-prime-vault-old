// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import { stdError } from "forge-std/Test.sol";

import "./TestBase.t.sol";

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

    function test_requestDeposit_invalidReceiver() public {
        vm.startPrank(user1);
        vm.expectRevert("SparkPrimeVault/invalid-receiver");
        vault.requestDeposit(1000e6, address(0), user1);

        vm.expectRevert("SparkPrimeVault/invalid-receiver");
        vault.requestDeposit(1000e6, address(vault), user1);
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

    event Deposit(address indexed owner, address indexed receiver, uint256 assets, uint256 shares);
    event DepositRequest(
        address indexed owner,
        address indexed receiver,
        uint256 indexed requestId,
        uint256 assets
    );
    event Referral(uint16 indexed referral, address indexed receiver, uint256 assets);
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
        assertEq(vault.assetsOf(user1),           0);
        assertEq(vault.availableCapacity(),       1_000_000e6);

        assertEq(vault.pendingDepositShares(user1),  0);
        assertEq(vault.pendingDepositRequest(user1), 0);
        assertEq(vault.totalQueuedDepositShares(),   0);

        // The shares are minted straight to the receiver, nothing is queued
        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit Transfer(address(0), user1, 1000e6);
        emit Deposit(user1, user1, 1000e6, 1000e6);
        uint256 requestId = vault.requestDeposit(1000e6, user1, user1);

        assertEq(requestId, type(uint256).max);

        assertEq(asset.balanceOf(user1),          1_000_000e6 - 1000e6);
        assertEq(asset.balanceOf(address(vault)), 1000e6);

        assertEq(vault.totalSupply(),             1000e6);
        assertEq(vault.balanceOf(user1),          1000e6);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.assetsOf(user1),           1000e6);
        assertEq(vault.availableCapacity(),       1_000_000e6 - 1000e6);

        assertEq(vault.pendingDepositShares(user1),  0);
        assertEq(vault.pendingDepositRequest(user1), 0);
        assertEq(vault.totalQueuedDepositShares(),   0);

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

        // Shares are priced at the current chi, rounded down
        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit Transfer(address(0), user1, 952.380952e6);
        emit Deposit(user1, user1, 1000e6, 952.380952e6);
        vault.requestDeposit(1000e6, user1, user1);

        assertEq(vault.balanceOf(user1),    952.380952e6);
        assertEq(vault.assetsOf(user1),     999.999999e6);
        assertEq(vault.totalSupply(),       952.380952e6);
        assertEq(vault.availableCapacity(), 1_000_000e6 - 952.380952e6);
    }

    function test_requestDeposit_capacityExactlyHitBoundary() public {
        vm.prank(admin);
        vault.setCapacity(1000e6);

        vm.prank(user1);
        uint256 requestId = vault.requestDeposit(1000e6, user1, user1);

        assertEq(requestId, type(uint256).max);

        assertEq(vault.balanceOf(user1),           1000e6);
        assertEq(vault.availableCapacity(),        0);
        assertEq(vault.totalQueuedDepositShares(), 0);
        assertEq(spUsdc.balanceOf(address(vault)), 0);

        vm.expectRevert();  // Public array getters revert without data when out of bounds
        vault.depositQueue(0);

        // The next request is fully queued and gets the first queue index
        vm.prank(user2);
        vm.expectEmit(address(vault));
        emit DepositRequest(user2, user2, 0, 100e6);
        requestId = vault.requestDeposit(100e6, user2, user2);

        assertEq(requestId, 0);

        assertEq(vault.balanceOf(user2),             0);
        assertEq(vault.pendingDepositShares(user2),  100e6);
        assertEq(vault.pendingDepositRequest(user2), 100e6);
        assertEq(vault.totalQueuedDepositShares(),   100e6);
        assertEq(spUsdc.balanceOf(address(vault)),   100e6);

        ( address owner, address receiver, uint256 amount, uint256 fee ) = vault.depositQueue(0);

        assertEq(owner,    user2);
        assertEq(receiver, user2);
        assertEq(amount,   100e6);
        assertEq(fee,      0);
    }

    function test_requestDeposit_partialInstantRestQueued() public {
        vm.prank(admin);
        vault.setCapacity(1000e6);

        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit Transfer(address(0), user1, 1000e6);
        emit Deposit(user1, user1, 1000e6, 1000e6);
        emit DepositRequest(user1, user1, 0, 500e6);
        uint256 requestId = vault.requestDeposit(1500e6, user1, user1);

        assertEq(requestId, 0);

        // All of the USDC leaves the user, the instant part stays idle and the rest goes to spUSDC
        assertEq(asset.balanceOf(user1),           1_000_000e6 - 1500e6);
        assertEq(asset.balanceOf(address(vault)),  1000e6);
        assertEq(asset.balanceOf(address(spUsdc)), 500e6);
        assertEq(spUsdc.balanceOf(address(vault)), 500e6);

        assertEq(vault.totalSupply(),       1000e6);
        assertEq(vault.balanceOf(user1),    1000e6);
        assertEq(vault.availableCapacity(), 0);

        assertEq(vault.pendingDepositShares(user1),  500e6);
        assertEq(vault.pendingDepositRequest(user1), 500e6);
        assertEq(vault.totalQueuedDepositShares(),   500e6);
        assertEq(vault.depositHead(),                0);

        ( address owner, address receiver, uint256 amount, uint256 fee ) = vault.depositQueue(0);

        assertEq(owner,    user1);
        assertEq(receiver, user1);
        assertEq(amount,   500e6);
        assertEq(fee,      0);
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
        uint256 requestId = vault.requestDeposit(200e6, user2, user2);

        assertEq(requestId, 1);

        assertEq(vault.balanceOf(user2),            0);
        assertEq(vault.pendingDepositShares(user2), 200e6);
        assertEq(vault.totalQueuedDepositShares(),  700e6);
        assertEq(spUsdc.balanceOf(address(vault)),  700e6);

        ( address owner, address receiver, uint256 amount, ) = vault.depositQueue(1);

        assertEq(owner,    user2);
        assertEq(receiver, user2);
        assertEq(amount,   200e6);

        // Once the queue is drained, requests are instant again
        vm.prank(rebalancer);
        vault.processDepositQueue(type(uint256).max);

        assertEq(vault.totalQueuedDepositShares(), 0);

        vm.prank(user3);
        requestId = vault.requestDeposit(100e6, user3, user3);

        assertEq(requestId, type(uint256).max);

        assertEq(vault.balanceOf(user3),            100e6);
        assertEq(vault.pendingDepositShares(user3), 0);
    }

    function test_requestDeposit_instantBelowOneShareQueuesAll() public {
        vm.prank(admin);
        vault.setVsrBounds(1e27, FIVE_PCT_VSR);

        vm.prank(setter);
        vault.setVsr(FIVE_PCT_VSR);

        vm.prank(admin);
        vault.setCapacity(1000e6);

        vm.prank(user1);
        vault.requestDeposit(1000e6, user1, user1);

        skip(365 days);

        // One share of room is worth 1.05 USDC, which buys 0 shares when rounded down
        vm.prank(admin);
        vault.setCapacity(1000e6 + 1);

        assertEq(vault.availableCapacity(), 1);

        vm.prank(user2);
        uint256 requestId = vault.requestDeposit(100e6, user2, user2);

        assertEq(requestId, 0);

        assertEq(vault.balanceOf(user2),            0);
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
        uint256 requestId = vault.requestDeposit(1000e6 + 1, user1, user1);

        // The 1 wei remainder is worth 0 spUSDC shares, it is deposited and no entry is queued
        assertEq(requestId, type(uint256).max);

        assertEq(vault.balanceOf(user1),            1000e6);
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
        uint256 requestId = vault.requestDeposit(0, user1, user1);

        assertEq(requestId, type(uint256).max);

        assertEq(asset.balanceOf(user1),            1_000_000e6);
        assertEq(vault.balanceOf(user1),            0);
        assertEq(vault.pendingDepositShares(user1), 0);
        assertEq(vault.totalSupply(),               0);

        vm.expectRevert();  // Public array getters revert without data when out of bounds
        vault.depositQueue(0);
    }

    function test_requestDeposit_receiverNotOwner() public {
        vm.prank(admin);
        vault.setCapacity(1000e6);

        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit Transfer(address(0), user2, 1000e6);
        emit Deposit(user1, user2, 1000e6, 1000e6);
        emit DepositRequest(user1, user2, 0, 500e6);
        vault.requestDeposit(1500e6, user2, user1);

        // The owner pays, the receiver gets the shares and the queued position
        assertEq(asset.balanceOf(user1), 1_000_000e6 - 1500e6);
        assertEq(asset.balanceOf(user2), 1_000_000e6);

        assertEq(vault.balanceOf(user1),            0);
        assertEq(vault.pendingDepositShares(user1), 0);

        assertEq(vault.balanceOf(user2),            1000e6);
        assertEq(vault.pendingDepositShares(user2), 500e6);

        ( address owner, address receiver, uint256 amount, ) = vault.depositQueue(0);

        assertEq(owner,    user1);
        assertEq(receiver, user2);
        assertEq(amount,   500e6);
    }

    function test_requestDeposit_withReferral() public {
        uint16 referral = 1;

        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit Transfer(address(0), user1, 1000e6);
        emit Deposit(user1, user1, 1000e6, 1000e6);
        emit Referral(referral, user1, 1000e6);
        uint256 requestId = vault.requestDeposit(1000e6, user1, user1, referral);

        assertEq(requestId, type(uint256).max);

        assertEq(asset.balanceOf(user1),          1_000_000e6 - 1000e6);
        assertEq(asset.balanceOf(address(vault)), 1000e6);
        assertEq(vault.totalSupply(),             1000e6);
        assertEq(vault.balanceOf(user1),          1000e6);
    }

    function test_requestDeposit_withReferral_queued() public {
        vm.prank(admin);
        vault.setCapacity(0);

        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit DepositRequest(user1, user1, 0, 1000e6);
        emit Referral(7, user1, 1000e6);
        uint256 requestId = vault.requestDeposit(1000e6, user1, user1, 7);

        assertEq(requestId, 0);
        assertEq(vault.pendingDepositShares(user1), 1000e6);
    }

    function test_requestDeposit_requestIdsAreQueueIndexes() public {
        vm.prank(admin);
        vault.setCapacity(0);

        vm.prank(user1);
        assertEq(vault.requestDeposit(100e6, user1, user1), 0);

        vm.prank(user2);
        assertEq(vault.requestDeposit(100e6, user2, user2), 1);

        vm.prank(user3);
        assertEq(vault.requestDeposit(100e6, user3, user3), 2);

        ( address owner,,, ) = vault.depositQueue(2);

        assertEq(owner, user3);
    }

    function test_requestDeposit_queuedEarnsSavingsYield() public {
        vm.prank(admin);
        vault.setCapacity(0);

        vm.prank(user1);
        vault.requestDeposit(1000e6, user1, user1);

        assertEq(vault.pendingDepositShares(user1),  1000e6);
        assertEq(vault.pendingDepositRequest(user1), 1000e6);

        vm.prank(setter);
        spUsdc.setVsr(FIVE_PCT_VSR);

        skip(365 days);

        // The queued position is denominated in spUSDC shares, its value grows with spUSDC
        assertEq(vault.pendingDepositShares(user1),  1000e6);
        assertEq(vault.pendingDepositRequest(user1), 1049.999999e6);
        assertEq(vault.totalQueuedDepositShares(),   1000e6);
    }

}

contract SparkPrimeVaultCancelDepositRequestFailureTests is SparkPrimeVaultTestBase {

    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address user3 = makeAddr("user3");

    function setUp() public override {
        super.setUp();

        // No capacity, every request is queued
        vm.prank(admin);
        vault.setCapacity(0);

        deal(address(asset), user1, 1_000_000e6);

        vm.startPrank(user1);
        asset.approve(address(vault), type(uint256).max);
        vault.requestDeposit(1000e6, user1, user1);  // Index 0
        vault.requestDeposit(500e6,  user2, user1);  // Index 1, user2 is the receiver
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

        assertEq(vault.balanceOf(user1), 1000e6);

        vm.prank(user1);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.cancelDepositRequest(0);
    }

    function test_cancelDepositRequest_notAuthorized() public {
        // Third parties can't cancel
        vm.prank(user3);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.cancelDepositRequest(0);

        // The receiver of one request can't cancel another
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
        uint256 indexed requestId,
        address indexed owner,
        address indexed receiver,
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
        vault.requestDeposit(500e6,  user2, user1);  // Index 1, user2 is the receiver
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

        ( address owner, address receiver, uint256 amount, ) = vault.depositQueue(0);

        assertEq(owner,    user1);
        assertEq(receiver, user1);
        assertEq(amount,   1000e6);

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

        ( owner, receiver, amount, ) = vault.depositQueue(0);

        assertEq(owner,    address(0));
        assertEq(receiver, address(0));
        assertEq(amount,   0);
    }

    function test_cancelDepositRequest_receiver() public {
        assertEq(asset.balanceOf(user1), 1_000_000e6 - 1500e6);
        assertEq(asset.balanceOf(user2), 0);

        assertEq(vault.pendingDepositShares(user2), 500e6);

        // The receiver cancels, the owner is refunded
        vm.prank(user2);
        vm.expectEmit(address(vault));
        emit CancelDepositRequest(1, user1, user2, 500e6);
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

        assertEq(vault.pendingDepositRequest(user1), 1049.999999e6);

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

        assertEq(vault.balanceOf(user1),            400e6);
        assertEq(vault.pendingDepositShares(user1), 600e6);
        assertEq(vault.depositHead(),               0);

        ( ,, uint256 amount, ) = vault.depositQueue(0);

        assertEq(amount, 600e6);

        // Only the unfilled remainder is refunded, the filled part was already minted
        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit CancelDepositRequest(0, user1, user1, 600e6);
        vault.cancelDepositRequest(0);

        assertEq(asset.balanceOf(user1),            1_000_000e6 - 1500e6 + 600e6);
        assertEq(vault.balanceOf(user1),            400e6);
        assertEq(vault.pendingDepositShares(user1), 0);
        assertEq(vault.totalQueuedDepositShares(),  800e6);
        assertEq(vault.depositHead(),               0);

        // The next fill skips the cancelled head
        vm.prank(rebalancer);
        vault.processDepositQueue(type(uint256).max);

        assertEq(vault.balanceOf(user2), 500e6);
        assertEq(vault.balanceOf(user3), 300e6);
        assertEq(vault.depositHead(),    3);
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

    event Deposit(address indexed owner, address indexed receiver, uint256 assets, uint256 shares);
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

        assertEq(vault.balanceOf(user1),           0);
        assertEq(vault.totalSupply(),              0);
        assertEq(vault.totalQueuedDepositShares(), 1800e6);
        assertEq(vault.depositHead(),              0);
    }

    function test_processDepositQueue_zeroBudget() public {
        vm.prank(admin);
        vault.setCapacity(1_000_000e6);

        vm.prank(rebalancer);
        vault.processDepositQueue(0);

        assertEq(vault.balanceOf(user1),           0);
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

        assertEq(vault.balanceOf(user1), 0);
        assertEq(vault.balanceOf(user2), 0);
        assertEq(vault.balanceOf(user3), 0);

        assertEq(vault.pendingDepositShares(user1), 1000e6);
        assertEq(vault.pendingDepositShares(user2), 500e6);
        assertEq(vault.pendingDepositShares(user3), 300e6);
        assertEq(vault.totalQueuedDepositShares(),  1800e6);
        assertEq(vault.depositHead(),               0);

        vm.prank(rebalancer);
        vm.expectEmit(address(vault));
        emit Transfer(address(0), user1, 1000e6);
        emit Deposit(user1, user1, 1000e6, 1000e6);
        emit Transfer(address(0), user2, 500e6);
        emit Deposit(user2, user2, 500e6, 500e6);
        emit Transfer(address(0), user3, 300e6);
        emit Deposit(user3, user3, 300e6, 300e6);
        vault.processDepositQueue(type(uint256).max);

        // The spUSDC is not redeemed, it becomes the vault's free sleeve
        assertEq(asset.balanceOf(address(spUsdc)), 1800e6);
        assertEq(spUsdc.balanceOf(address(vault)), 1800e6);
        assertEq(vault.availableLiquidAssets(),    1800e6);

        assertEq(vault.totalSupply(),             1800e6);
        assertEq(vault.balanceOf(address(vault)), 0);

        assertEq(vault.balanceOf(user1), 1000e6);
        assertEq(vault.balanceOf(user2), 500e6);
        assertEq(vault.balanceOf(user3), 300e6);

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
        assertEq(vault.balanceOf(user1), 1000e6);
        assertEq(vault.balanceOf(user2), 200e6);
        assertEq(vault.balanceOf(user3), 0);

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

        assertEq(vault.balanceOf(user2),           500e6);
        assertEq(vault.balanceOf(user3),           300e6);
        assertEq(vault.totalQueuedDepositShares(), 0);
        assertEq(vault.totalSupply(),              1800e6);
        assertEq(vault.depositHead(),              3);
    }

    function test_processDepositQueue_budgetExactlyHeadBoundary() public {
        vm.prank(admin);
        vault.setCapacity(1_000_000e6);

        vm.prank(rebalancer);
        vault.processDepositQueue(1000e6 - 1);

        assertEq(vault.balanceOf(user1),            1000e6 - 1);
        assertEq(vault.pendingDepositShares(user1), 1);
        assertEq(vault.depositHead(),               0);

        vm.prank(rebalancer);
        vault.processDepositQueue(1);

        assertEq(vault.balanceOf(user1),            1000e6);
        assertEq(vault.pendingDepositShares(user1), 0);
        assertEq(vault.balanceOf(user2),            0);
        assertEq(vault.depositHead(),               1);
    }

    function test_processDepositQueue_oneWeiBudget() public {
        vm.prank(admin);
        vault.setCapacity(1_000_000e6);

        vm.prank(rebalancer);
        vault.processDepositQueue(1);

        assertEq(vault.balanceOf(user1),            1);
        assertEq(vault.pendingDepositShares(user1), 1000e6 - 1);
        assertEq(vault.totalSupply(),               1);
        assertEq(vault.depositHead(),               0);
    }

    function test_processDepositQueue_capacityPartialFill() public {
        vm.prank(admin);
        vault.setCapacity(1199e6);

        vm.prank(rebalancer);
        vault.processDepositQueue(type(uint256).max);

        assertEq(vault.balanceOf(user1),            1000e6);
        assertEq(vault.balanceOf(user2),            199e6);
        assertEq(vault.pendingDepositShares(user2), 301e6);
        assertEq(vault.totalSupply(),               1199e6);
        assertEq(vault.availableCapacity(),         0);
        assertEq(vault.depositHead(),               1);

        // Nothing more happens without more room
        vm.prank(rebalancer);
        vault.processDepositQueue(type(uint256).max);

        assertEq(vault.balanceOf(user2), 199e6);
        assertEq(vault.depositHead(),    1);
    }

    function test_processDepositQueue_skipsCancelled() public {
        vm.prank(user2);
        vault.cancelDepositRequest(1);

        vm.prank(admin);
        vault.setCapacity(1_000_000e6);

        vm.prank(rebalancer);
        vault.processDepositQueue(type(uint256).max);

        assertEq(vault.balanceOf(user1),           1000e6);
        assertEq(vault.balanceOf(user2),           0);
        assertEq(vault.balanceOf(user3),           300e6);
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

        assertEq(vault.balanceOf(user4), 100e6);
        assertEq(vault.depositHead(),    503);
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

        assertEq(vault.balanceOf(user1), 1000e6);
        assertEq(vault.balanceOf(user4), 0);
        assertEq(vault.depositHead(),    3 + 499);

        vm.prank(rebalancer);
        vault.processDepositQueue(type(uint256).max);

        assertEq(vault.balanceOf(user4), 100e6);
        assertEq(vault.depositHead(),    504);
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

        assertEq(vault.balanceOf(user1),            0);
        assertEq(vault.pendingDepositShares(user1), 1000e6);
        assertEq(vault.totalSupply(),               0);
        assertEq(vault.depositHead(),               0);

        // Two shares of room are worth 2 wei, which mints 1 share
        vm.prank(admin);
        vault.setCapacity(2);

        vm.prank(rebalancer);
        vault.processDepositQueue(type(uint256).max);

        assertEq(vault.balanceOf(user1),            1);
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

        // Everyone in the round is credited the spUSDC value of their shares at the same chi
        vm.prank(rebalancer);
        vm.expectEmit(address(vault));
        emit Transfer(address(0), user1, 999.999999e6);
        emit Deposit(user1, user1, 1049.999999e6, 999.999999e6);
        emit Transfer(address(0), user2, 499.999999e6);
        emit Deposit(user2, user2, 524.999999e6, 499.999999e6);
        emit Transfer(address(0), user3, 299.999999e6);
        emit Deposit(user3, user3, 314.999999e6, 299.999999e6);
        vault.processDepositQueue(type(uint256).max);

        assertEq(vault.balanceOf(user1), 999.999999e6);
        assertEq(vault.balanceOf(user2), 499.999999e6);
        assertEq(vault.balanceOf(user3), 299.999999e6);

        assertEq(vault.totalSupply(),              1799.999997e6);
        assertEq(vault.totalQueuedDepositShares(), 0);
        assertEq(spUsdc.balanceOf(address(vault)), 1800e6);  // Kept as the free sleeve
        assertEq(vault.depositHead(),              3);
    }

    function test_processDepositQueue_partialFillRoundsSharesUp() public {
        vm.prank(setter);
        spUsdc.setVsr(FIVE_PCT_VSR);

        skip(37 days + 13);  // An odd spUSDC price

        assertEq(spUsdc.nowChi(),                    1.004958123386656194224284927e27);
        assertEq(vault.pendingDepositRequest(user1), 1004.958123e6);

        vm.prank(admin);
        vault.setCapacity(1_000_000e6);

        vm.prank(rebalancer);
        vault.processDepositQueue(333.333333e6);

        // The accepted spUSDC rounds up, so it is always worth at least the credited assets
        assertEq(vault.balanceOf(user1),             333.333333e6);
        assertEq(vault.pendingDepositShares(user1),  668.311220e6);
        assertEq(vault.pendingDepositRequest(user1), 671.624789e6);
        assertEq(vault.depositHead(),                0);

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
        assertEq(vault.balanceOf(user1), 999.866337e6);  // 1000e6 * RAY / chi
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
