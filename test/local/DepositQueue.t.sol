// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import "forge-std/Test.sol";

import { ERC20 }        from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import { ERC1967Proxy } from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { SparkVault }      from "spark-vaults-v2/SparkVault.sol";
import { SparkPrimeVault } from "src/SparkPrimeVault.sol";

contract USDC is ERC20("USDC", "USDC") {
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 v) external { _mint(to, v); }
}

contract DepositQueueTest is Test {

    uint256 constant RAY      = 1e27;
    uint256 constant FIVE_PCT = 1.000000001547125957863212448e27;
    uint256 constant MAX      = type(uint256).max;

    USDC            usdc;
    SparkVault      sp;
    SparkPrimeVault v;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave  = makeAddr("dave");
    address eve   = makeAddr("eve");
    address op    = makeAddr("op");

    address[] users;

    function setUp() public {
        usdc = new USDC();

        sp = SparkVault(address(new ERC1967Proxy(
            address(new SparkVault()),
            abi.encodeCall(SparkVault.initialize, (address(usdc), "spUSDC", "spUSDC", admin))
        )));
        v = SparkPrimeVault(address(new ERC1967Proxy(
            address(new SparkPrimeVault()),
            abi.encodeCall(SparkPrimeVault.initialize, (address(usdc), address(sp), "spPRIME", "spPRIME", admin))
        )));

        vm.startPrank(admin);
        sp.setDepositCap(1e30);
        sp.grantRole(sp.SETTER_ROLE(), admin);
        sp.setVsrBounds(RAY, sp.MAX_VSR());
        sp.setVsr(FIVE_PCT);

        v.grantRole(v.SETTER_ROLE(), admin);
        v.grantRole(v.TAKER_ROLE(), admin);
        v.grantRole(v.REBALANCER_ROLE(), admin);
        v.grantRole(v.RISK_MANAGER_ROLE(), admin);
        v.grantRole(v.GUARDIAN_ROLE(), admin);
        v.grantRole(v.UNPAUSER_ROLE(), admin);
        v.setCapacity(1e12);
        v.setMaxWithdrawFee(0.01e18);
        v.setWithdrawFee(0.005e18);
        v.setMinimums(100e6, 50e6);
        v.setVsrBounds(RAY, v.MAX_VSR());
        v.setVsr(FIVE_PCT);
        vm.stopPrank();

        usdc.mint(address(sp), 1_000_000e6);  // back spUSDC yield
        _fund(alice); _fund(bob); _fund(carol); _fund(dave); _fund(eve); _fund(op);
    }

    /**********************************************************************************************/
    /*** Helpers                                                                                ***/
    /**********************************************************************************************/

    function _fund(address u) internal {
        users.push(u);
        usdc.mint(u, 1_000_000e6);
        vm.prank(u); usdc.approve(address(v), MAX);
    }

    function _req(address u, uint256 assets) internal {
        vm.prank(u); v.requestDeposit(assets, u, u);
    }

    function _process(uint256 maxAssets) internal {
        vm.prank(admin); v.processDepositQueue(maxAssets);
    }

    function _setCapacity(uint256 c) internal {
        vm.prank(admin); v.setCapacity(c);
    }

    function _amount(uint256 i) internal view returns (uint256 amount) {
        (,, amount,) = v.depositQueue(i);
    }

    function _length() internal view returns (uint256 n) {
        while (true) {
            try v.depositQueue(n) returns (address, address, uint256, uint256) { ++n; }
            catch { return n; }
        }
    }

    // Lays `n` cancelled entries (holes) at the tail of the queue
    function _holes(uint256 n) internal {
        uint256 start = _length();
        vm.startPrank(eve);
        for (uint256 i; i < n; ++i) {
            v.requestDeposit(100e6, eve, eve);
            v.cancelDepositRequest(start + i);
        }
        vm.stopPrank();
    }

    function invariants() internal view {
        assertGe(usdc.balanceOf(address(v)), v.totalClaimableRedeemAssets(), "ring-fence");
        assertGe(sp.balanceOf(address(v)), v.totalQueuedDepositShares(),     "queued spUSDC");

        uint256 esc = v.totalQueuedRedeemShares();
        uint256 pending;
        for (uint256 i; i < users.length; ++i) {
            esc     += v.maxMint(users[i]);
            pending += v.pendingDepositShares(users[i]);
        }
        assertEq(v.balanceOf(address(v)), esc,               "escrow");
        assertEq(pending, v.totalQueuedDepositShares(),      "pending == total");

        uint256 n = _length();
        uint256 live;
        for (uint256 i; i < n; ++i) {
            uint256 a = _amount(i);
            if (i < v.depositHead()) assertEq(a, 0, "nothing live behind the head");
            live += a;
        }
        assertEq(live, v.totalQueuedDepositShares(), "queue == total");
    }

    /**********************************************************************************************/
    /*** Instant vs queued boundary                                                             ***/
    /**********************************************************************************************/

    function test_instant_capacityExactlyHit() public {
        _setCapacity(1000e6);
        _req(alice, 1000e6);

        assertEq(v.maxDeposit(alice),  1000e6);
        assertEq(v.maxMint(alice),     1000e6);
        assertEq(v.availableCapacity(), 0);
        assertEq(_length(),             0);
        assertEq(sp.balanceOf(address(v)), 0);

        _req(bob, 100e6);  // fully queued
        assertEq(v.maxDeposit(bob), 0);
        assertEq(v.pendingDepositShares(bob), 100e6);
        (address c, address o, uint256 a, uint256 f) = v.depositQueue(0);
        assertEq(c, bob); assertEq(o, bob); assertEq(a, 100e6); assertEq(f, 0);
        invariants();
    }

    function test_instant_oneWeiOver_queuesOneShare() public {
        _setCapacity(1000e6);
        _req(alice, 1000e6 + 1);

        assertEq(v.maxDeposit(alice), 1000e6);
        assertEq(_amount(0), 1, "spUSDC chi == RAY: 1 wei is 1 share");
        assertEq(v.pendingDepositRequest(0, alice), 1);
        invariants();

        _setCapacity(1000e6 + 1);
        _process(MAX);
        assertEq(v.maxDeposit(alice), 1000e6 + 1);
        assertEq(v.maxMint(alice),    1000e6 + 1);
        assertEq(v.depositHead(), 1);
        invariants();
    }

    function test_instant_oneWeiOver_subShareRemainderAbsorbed() public {
        vm.warp(block.timestamp + 365 days);  // both chis > RAY
        _setCapacity(1000e6);

        uint256 chi        = v.nowChi();
        uint256 instantMax = 1000e6 * chi / RAY;
        uint256 spUsdcBal  = usdc.balanceOf(address(sp));

        _req(alice, instantMax + 1);

        assertEq(v.maxDeposit(alice), instantMax);
        assertEq(v.maxMint(alice),    instantMax * RAY / chi);
        assertLe(v.totalSupply(),     1000e6);
        assertEq(_length(),           0, "no zero-amount entry");
        assertEq(sp.balanceOf(address(v)), 0);
        assertEq(usdc.balanceOf(address(sp)), spUsdcBal + 1, "1 wei absorbed by spUSDC");
        assertEq(usdc.balanceOf(alice), 1_000_000e6 - instantMax - 1);
        invariants();
    }

    function test_capacityBelowSupply() public {
        _req(alice, 1000e6);
        _setCapacity(500e6);
        assertEq(v.availableCapacity(), 0);

        _req(bob, 200e6);
        assertEq(v.maxDeposit(bob), 0);
        assertEq(v.pendingDepositShares(bob), 200e6);

        _process(MAX);
        assertEq(v.depositHead(), 0);
        assertEq(v.maxDeposit(bob), 0);

        _setCapacity(1199e6);  // 199 of room
        _process(MAX);
        assertEq(v.maxDeposit(bob), 199e6);
        assertEq(v.pendingDepositShares(bob), 1e6);
        assertEq(v.totalSupply(), 1199e6);
        assertEq(v.depositHead(), 0);
        invariants();
    }

    function test_queueNonEmpty_forcesFullQueueing() public {
        _setCapacity(1000e6);
        _req(alice, 1500e6);  // 1000 instant, 500 queued
        assertEq(v.maxDeposit(alice), 1000e6);
        assertEq(v.pendingDepositShares(alice), 500e6);

        _setCapacity(1e12);
        _req(bob, 200e6);     // capacity is free but alice is ahead
        assertEq(v.maxDeposit(bob), 0);
        assertEq(v.pendingDepositShares(bob), 200e6);

        _process(600e6);      // alice full, bob 100 of 200
        assertEq(v.maxDeposit(alice), 1500e6);
        assertEq(v.maxDeposit(bob),   100e6);
        assertEq(v.pendingDepositShares(bob), 100e6);
        assertEq(v.depositHead(), 1);
        invariants();

        // Bob still queued: carol queues too, even with all capacity free
        _req(carol, 100e6);
        assertEq(v.maxDeposit(carol), 0);
        _process(MAX);
        assertEq(v.maxDeposit(bob),   200e6);
        assertEq(v.maxDeposit(carol), 100e6);
        assertEq(v.depositHead(), 3);

        // Queue drained: instant again
        _req(dave, 100e6);
        assertEq(v.maxDeposit(dave), 100e6);
        invariants();
    }

    function test_instant_chiBelowRay() public {
        _setCapacity(1000e6);
        _req(alice, 500e6);

        vm.startPrank(admin);
        v.pause();
        v.setChi(0.9e27);
        v.unpause();
        vm.stopPrank();

        _req(bob, 1000e6);  // room 500 shares = 450 USDC at 0.9
        assertEq(v.maxDeposit(bob), 450e6);
        assertEq(v.maxMint(bob),    500e6);
        assertEq(v.pendingDepositShares(bob), 550e6);
        assertEq(v.availableCapacity(), 0);

        _setCapacity(1550e6);
        _process(MAX);  // 550 shares of room = 495 USDC
        assertEq(v.maxDeposit(bob), 945e6);
        assertEq(v.maxMint(bob),    1050e6);
        assertEq(v.pendingDepositShares(bob), 55e6);
        invariants();
    }

    function test_instant_chiAboveRay() public {
        vm.warp(block.timestamp + 365 days);
        uint256 chi = v.nowChi();
        _req(alice, 1000e6);
        assertEq(v.maxDeposit(alice), 1000e6);
        assertEq(v.maxMint(alice),    1000e6 * RAY / chi);
        assertLt(v.maxMint(alice),    1000e6);
        invariants();
    }

    /**********************************************************************************************/
    /*** Partial fills                                                                          ***/
    /**********************************************************************************************/

    function test_partial_oneWeiBudget() public {
        _setCapacity(0);
        _req(alice, 100e6);
        _setCapacity(1e12);

        _process(1);
        assertEq(v.maxDeposit(alice), 1);
        assertEq(v.maxMint(alice),    1);
        assertEq(v.pendingDepositShares(alice), 100e6 - 1);
        assertEq(v.depositHead(), 0);
        invariants();
    }

    function test_partial_budgetEqualsEntry() public {
        _setCapacity(0);
        _req(alice, 100e6);
        _req(bob,   200e6);
        _setCapacity(1e12);

        _process(100e6);
        assertEq(v.maxDeposit(alice), 100e6);
        assertEq(_amount(0), 0);
        assertEq(v.maxDeposit(bob), 0);
        assertEq(_amount(1), 200e6, "bob untouched");
        assertEq(v.depositHead(), 1);
        invariants();
    }

    function test_partial_manyTinyEntries() public {
        vm.prank(admin); v.setMinimums(0, 0);
        _setCapacity(0);
        for (uint256 i; i < 50; ++i) _req(bob, 1);
        assertEq(v.pendingDepositShares(bob), 50);
        _setCapacity(1e12);

        _process(25);
        assertEq(v.maxDeposit(bob), 25);
        assertEq(v.maxMint(bob),    25);
        assertEq(v.depositHead(),   25);

        _process(MAX);
        assertEq(v.maxDeposit(bob), 50);
        assertEq(v.depositHead(),   50);
        assertEq(v.totalQueuedDepositShares(), 0);
        invariants();
    }

    function test_partial_neverOverCredits() public {
        _setCapacity(0);
        _req(alice, 1000e6);
        vm.warp(block.timestamp + 37 days + 13);  // odd spUSDC price
        _setCapacity(1e12);

        uint256 amount = _amount(0);
        uint256 value  = sp.convertToAssets(amount);
        uint256 budget = 333_333_333;

        _process(budget);
        uint256 left     = _amount(0);
        uint256 accepted = amount - left;

        assertEq(v.maxDeposit(alice), budget);
        assertEq(accepted, (amount * budget - 1) / value + 1, "divup");
        assertGe(sp.convertToAssets(accepted), budget,        "accepted spUSDC covers credit");
        assertLe(budget + sp.convertToAssets(left), value,    "fills never exceed queued value");
        assertGe(budget + sp.convertToAssets(left) + 2, value, "loss is dust");
        invariants();
    }

    function test_partialThenCancelHead_refundsRemainder() public {
        _setCapacity(0);
        _req(alice, 1000e6);
        _req(bob,   500e6);
        vm.warp(block.timestamp + 30 days);
        _setCapacity(1e12);

        _process(400e6);
        uint256 left   = _amount(0);
        uint256 refund = sp.convertToAssets(left);
        uint256 before = usdc.balanceOf(alice);

        vm.prank(alice); v.cancelDepositRequest(0);
        assertEq(usdc.balanceOf(alice) - before, refund);
        assertEq(v.pendingDepositShares(alice), 0);
        assertEq(v.maxDeposit(alice), 400e6, "accepted part stays claimable");
        assertEq(v.depositHead(), 0);
        invariants();

        _process(MAX);  // skips the hole, fills bob
        assertEq(v.maxDeposit(bob), sp.convertToAssets(500e6));  // queued at spUSDC chi == RAY
        assertEq(v.depositHead(), 2);
        invariants();
    }

    function test_cancelHeadMiddleTail() public {
        _setCapacity(0);
        _req(alice, 100e6);
        _req(bob,   200e6);
        _req(carol, 300e6);
        _req(dave,  400e6);
        _setCapacity(1e12);

        vm.prank(alice); v.cancelDepositRequest(0);  // head
        vm.prank(carol); v.cancelDepositRequest(2);  // middle
        vm.prank(dave);  v.cancelDepositRequest(3);  // tail
        assertEq(usdc.balanceOf(alice), 1_000_000e6);
        assertEq(usdc.balanceOf(carol), 1_000_000e6);
        assertEq(usdc.balanceOf(dave),  1_000_000e6);
        assertEq(v.totalQueuedDepositShares(), 200e6);

        _process(MAX);
        assertEq(v.maxDeposit(bob), 200e6);
        assertEq(v.depositHead(), 4);
        assertEq(v.totalSupply(), 200e6);
        invariants();
    }

    /**********************************************************************************************/
    /*** 500-skip bound                                                                         ***/
    /**********************************************************************************************/

    function test_holes_499_fillInOneCall() public {
        _setCapacity(0);
        _holes(499);
        _req(alice, 100e6);
        _setCapacity(1e12);

        _process(MAX);
        assertEq(v.maxDeposit(alice), 100e6);
        assertEq(v.depositHead(), 500);
        invariants();
    }

    function test_holes_500_needsTwoCalls() public {
        _setCapacity(0);
        _holes(500);
        _req(alice, 100e6);
        _setCapacity(1e12);

        _process(MAX);
        assertEq(v.maxDeposit(alice), 0);
        assertEq(v.depositHead(), 499, "stops on the 500th hole");

        _process(MAX);
        assertEq(v.maxDeposit(alice), 100e6);
        assertEq(v.depositHead(), 501);
        invariants();
    }

    function test_holes_501_needsTwoCalls() public {
        _setCapacity(0);
        _holes(501);
        _req(alice, 100e6);
        _setCapacity(1e12);

        _process(MAX);
        assertEq(v.depositHead(), 499);
        _process(MAX);
        assertEq(v.maxDeposit(alice), 100e6);
        assertEq(v.depositHead(), 502);
        invariants();
    }

    function test_holes_headPersistsWithZeroBudget() public {
        _setCapacity(0);
        _holes(1200);
        _req(alice, 100e6);

        _process(MAX);  // no budget, still walks holes
        assertEq(v.depositHead(), 499);
        _process(MAX);
        assertEq(v.depositHead(), 998);
        _process(MAX);
        assertEq(v.depositHead(), 1200, "parks on alice");
        _process(MAX);
        assertEq(v.depositHead(), 1200);
        assertEq(v.maxDeposit(alice), 0);

        _setCapacity(1e12);
        _process(MAX);
        assertEq(v.maxDeposit(alice), 100e6);
        assertEq(v.depositHead(), 1201);
        invariants();
    }

    function test_holes_onlyHolesDrainToEnd() public {
        _setCapacity(0);
        _holes(10);
        assertEq(v.totalQueuedDepositShares(), 0);
        _process(MAX);
        assertEq(v.depositHead(), 10);

        // Queue logically empty: instant again
        _setCapacity(1e12);
        _req(alice, 100e6);
        assertEq(v.maxDeposit(alice), 100e6);
        invariants();
    }

    /**********************************************************************************************/
    /*** FIFO and pricing                                                                       ***/
    /**********************************************************************************************/

    function test_fifo_samePricePerRound() public {
        _setCapacity(0);
        _req(alice, 1000e6);
        vm.warp(block.timestamp + 10 days);
        _req(bob, 1000e6);
        vm.warp(block.timestamp + 10 days);
        _req(carol, 1000e6);
        vm.warp(block.timestamp + 10 days);
        _setCapacity(1e12);

        uint256 aS = _amount(0);
        uint256 bS = _amount(1);
        uint256 cS = _amount(2);
        assertGt(aS, bS); assertGt(bS, cS);

        uint256 spChi = sp.nowChi();
        uint256 chi   = v.nowChi();
        uint256 bValue = bS * spChi / RAY;
        uint256 aValue = aS * spChi / RAY;

        _process(aValue + bValue + 2e6);  // alice, bob full; carol partial

        assertEq(v.maxDeposit(alice), aValue);
        assertEq(v.maxDeposit(bob),   bValue);
        assertEq(v.maxDeposit(carol), 2e6);
        assertGt(aValue, bValue, "earliest queued earned most spUSDC yield");
        assertEq(v.maxMint(alice), aValue * RAY / chi);
        assertEq(v.maxMint(bob),   bValue * RAY / chi);
        assertEq(v.maxMint(carol), 2e6 * RAY / chi);
        assertEq(v.depositHead(), 2);
        invariants();
    }

    function test_spUsdcYieldBetweenRequestAndProcess() public {
        _setCapacity(0);
        _req(alice, 1000e6);
        uint256 shares = _amount(0);
        assertEq(shares, 1000e6);

        vm.warp(block.timestamp + 365 days);
        uint256 value = sp.convertToAssets(shares);
        assertEq(v.pendingDepositRequest(0, alice), value);
        assertGt(value, 1049e6);

        _setCapacity(1e12);
        uint256 spBal = sp.balanceOf(address(v));
        _process(MAX);
        assertEq(v.maxDeposit(alice), value);
        assertEq(v.maxMint(alice),    value * RAY / v.nowChi());
        assertEq(sp.balanceOf(address(v)), spBal, "spUSDC kept as free sleeve");
        assertEq(v.totalQueuedDepositShares(), 0);
        invariants();
    }

    /**********************************************************************************************/
    /*** spUSDC conditions                                                                      ***/
    /**********************************************************************************************/

    function test_spUsdcIlliquid_cancelRevertsProcessWorks() public {
        _setCapacity(0);
        _req(alice, 1000e6);

        vm.startPrank(admin);
        sp.grantRole(sp.TAKER_ROLE(), admin);
        sp.take(usdc.balanceOf(address(sp)));
        vm.stopPrank();

        vm.prank(alice); vm.expectRevert("SparkVault/insufficient-liquidity"); v.cancelDepositRequest(0);
        vm.prank(admin); vm.expectRevert("SparkVault/insufficient-liquidity"); v.cancelDepositRequest(0);

        _setCapacity(1e12);
        _process(MAX);
        assertEq(v.maxDeposit(alice), 1000e6);
        assertEq(v.depositHead(), 1);
        invariants();
    }

    function test_spUsdcDepositCap() public {
        uint256 spAssets = sp.totalAssets();
        vm.prank(admin); sp.setDepositCap(spAssets);

        _req(alice, 1000e6);  // fully instant: spUSDC untouched
        assertEq(v.maxDeposit(alice), 1000e6);

        _setCapacity(1000e6);
        vm.prank(bob); vm.expectRevert("SparkVault/deposit-cap-exceeded"); v.requestDeposit(100e6, bob, bob);
        invariants();
    }

    /**********************************************************************************************/
    /*** Request inputs and authorization                                                       ***/
    /**********************************************************************************************/

    function test_zeroAndDustRequests() public {
        vm.prank(alice); vm.expectRevert("SparkPrimeVault/below-minimum"); v.requestDeposit(100e6 - 1, alice, alice);
        vm.prank(alice); vm.expectRevert("SparkPrimeVault/invalid-controller"); v.requestDeposit(100e6, address(0), alice);
        vm.prank(bob);   vm.expectRevert("SparkPrimeVault/not-owner"); v.requestDeposit(100e6, bob, alice);

        vm.prank(admin); v.setMinimums(0, 0);
        _setCapacity(0);

        _req(alice, 0);
        assertEq(_length(), 0);
        assertEq(usdc.balanceOf(alice), 1_000_000e6);

        _req(alice, 1);
        assertEq(_amount(0), 1);

        vm.warp(block.timestamp + 1 days);  // spUSDC chi > RAY: 1 wei is 0 shares
        _req(bob, 1);
        assertEq(_length(), 1, "no entry");
        assertEq(usdc.balanceOf(bob), 1_000_000e6 - 1);
        invariants();
    }

    function test_controllerNotOwner() public {
        _setCapacity(0);
        vm.prank(alice); v.requestDeposit(300e6, bob, alice);
        assertEq(v.pendingDepositRequest(0, bob),   300e6);
        assertEq(v.pendingDepositRequest(0, alice), 0);

        // Controller cancels, owner is refunded
        uint256 aBefore = usdc.balanceOf(alice);
        uint256 bBefore = usdc.balanceOf(bob);
        vm.prank(bob); v.cancelDepositRequest(0);
        assertEq(usdc.balanceOf(alice) - aBefore, 300e6);
        assertEq(usdc.balanceOf(bob), bBefore);

        // Fill credits the controller; the owner cannot claim
        vm.prank(alice); v.requestDeposit(300e6, bob, alice);
        _setCapacity(1e12);
        _process(MAX);
        assertEq(v.maxDeposit(bob),   300e6);
        assertEq(v.maxDeposit(alice), 0);
        vm.prank(alice); vm.expectRevert("SparkPrimeVault/not-authorized"); v.mint(1, alice, bob);

        vm.prank(bob); v.mint(300e6, carol, bob);  // controller picks any receiver
        assertEq(v.balanceOf(carol), 300e6);
        invariants();
    }

    function test_cancelAuthorization() public {
        _setCapacity(0);
        for (uint256 i; i < 3; ++i) { vm.prank(alice); v.requestDeposit(100e6, bob, alice); }
        vm.prank(alice); v.setOperator(op, true);
        vm.prank(bob);   v.setOperator(op, true);

        vm.prank(carol); vm.expectRevert("SparkPrimeVault/not-authorized"); v.cancelDepositRequest(0);
        vm.prank(op);    vm.expectRevert("SparkPrimeVault/not-authorized"); v.cancelDepositRequest(0);

        vm.prank(alice); v.cancelDepositRequest(0);  // owner
        vm.prank(bob);   v.cancelDepositRequest(1);  // controller
        vm.prank(admin); v.cancelDepositRequest(2);  // guardian
        assertEq(usdc.balanceOf(alice), 1_000_000e6, "all refunds to owner");
        assertEq(usdc.balanceOf(admin), 0);

        vm.prank(alice); vm.expectRevert("SparkPrimeVault/no-request"); v.cancelDepositRequest(0);
        vm.prank(alice); vm.expectRevert(stdError.indexOOBError);        v.cancelDepositRequest(3);

        // Filled entry cannot be cancelled
        _req(dave, 100e6);
        _setCapacity(1e12);
        _process(MAX);
        vm.prank(dave); vm.expectRevert("SparkPrimeVault/no-request"); v.cancelDepositRequest(3);
        assertEq(v.maxDeposit(dave), 100e6);
        invariants();
    }

    function test_pauseInteraction() public {
        _setCapacity(500e6);
        _req(alice, 1000e6);  // 500 instant, 500 queued
        _req(bob,   200e6);

        vm.prank(admin); v.pause();
        vm.prank(admin); vm.expectRevert("SparkPrimeVault/paused"); v.processDepositQueue(MAX);
        vm.prank(carol); vm.expectRevert("SparkPrimeVault/paused"); v.requestDeposit(100e6, carol, carol);

        vm.prank(bob); v.cancelDepositRequest(1);
        assertEq(usdc.balanceOf(bob), 1_000_000e6);
        vm.prank(alice); v.deposit(500e6, alice);
        assertEq(v.balanceOf(alice), 500e6);
        invariants();
    }

    /**********************************************************************************************/
    /*** Claims                                                                                 ***/
    /**********************************************************************************************/

    function test_claim_nothingClaimable() public {
        vm.prank(alice); vm.expectRevert(stdError.divisionError);   v.deposit(1, alice);
        vm.prank(alice); vm.expectRevert(stdError.arithmeticError); v.mint(1, alice);

        _req(alice, 100e6);
        vm.prank(alice); vm.expectRevert(stdError.arithmeticError); v.deposit(100e6 + 1, alice);
        vm.prank(alice); vm.expectRevert(stdError.arithmeticError); v.mint(100e6 + 1, alice);
    }

    function test_claim_proRataAcrossPricesAndSplits() public {
        // Three partial fills of alice's entry at three different chis
        _setCapacity(0);
        _req(alice, 1000e6);
        _setCapacity(1e12);

        uint256 a; uint256 s;
        for (uint256 r; r < 3; ++r) {
            vm.warp(block.timestamp + 97 days + r);
            uint256 chi = v.nowChi();
            _process(300e6 + r);
            a += 300e6 + r;
            s += (300e6 + r) * RAY / chi;
        }
        assertEq(v.maxDeposit(alice), a);
        assertEq(v.maxMint(alice),    s);
        invariants();

        // Alice: many small pieces, mixing deposit and mint
        uint256 got;
        for (uint256 i; i < 20; ++i) {
            vm.prank(alice); got += v.deposit(7_777_777, alice);
            vm.prank(alice); v.mint(3_333_333, alice); got += 3_333_333;
        }
        uint256 restShares = v.maxMint(alice);
        vm.prank(alice); v.mint(restShares, alice);
        got += restShares;

        assertEq(got, s,                      "pieces sum to the one-shot amount");
        assertEq(v.balanceOf(alice), s);
        assertEq(v.maxDeposit(alice), 0);
        assertEq(v.maxMint(alice),    0);
        invariants();
    }

    function test_claim_piecesNeverBeatFair() public {
        vm.warp(block.timestamp + 200 days);
        _req(alice, 1000e6);
        uint256 A = v.maxDeposit(alice);
        uint256 S = v.maxMint(alice);

        assertGt(A, S);

        vm.prank(alice); uint256 sh = v.deposit(1, alice);
        assertEq(sh, 0, "1 wei is worth < 1 share: floored to 0");
        assertEq(v.maxMint(alice), S, "but the share stays claimable");

        vm.prank(alice); uint256 paid = v.mint(1, alice);
        assertEq(paid, (A - 2) / S + 1, "divup((A - 1) * 1, S)");

        vm.prank(alice); v.mint(S - 1, alice);
        assertEq(v.balanceOf(alice), S);
        assertEq(v.maxDeposit(alice), 0);
        invariants();
    }

    /**********************************************************************************************/
    /*** Bugs                                                                                   ***/
    /**********************************************************************************************/

    // With chi > RAY, a budget of 1 wei accepts one spUSDC share (worth >= 1 wei) and mints
    // 0 spPRIME. A residual room of 1 share happens naturally after a capacity-limited fill,
    // so every later processDepositQueue grinds the head entry by one spUSDC share for nothing.
    // The withdraw side guards this (`net == 0 && shares < r.amount`); the deposit side does not.
    function test_BUG_zeroShareFillGrindsHead() public {
        vm.warp(block.timestamp + 365 days);
        _setCapacity(1000e6);
        _req(alice, 2000e6);  // instant up to capacity, rest queued

        assertEq(v.availableCapacity(), 1, "floored mint leaves 1 share of room");
        uint256 pending = v.pendingDepositShares(alice);
        uint256 claim   = v.maxMint(alice);

        for (uint256 i; i < 10; ++i) _process(MAX);

        assertEq(v.maxMint(alice), claim, "no spPRIME minted");
        assertEq(v.pendingDepositShares(alice), pending, "queued spUSDC must not be taken for 0 spPRIME");
    }

    /**********************************************************************************************/
    /*** Fuzz                                                                                   ***/
    /**********************************************************************************************/

    function testFuzz_fillSequenceConservation(uint256 seed) public {
        _setCapacity(0);
        uint256 n = bound(seed, 1, 6);
        address[] memory us = new address[](n);
        for (uint256 i; i < n; ++i) {
            us[i] = makeAddr(string(abi.encode(i)));
            _fund(us[i]);
            _req(us[i], bound(uint256(keccak256(abi.encode(seed, "a", i))), 100e6, 5000e6));
            vm.warp(block.timestamp + bound(uint256(keccak256(abi.encode(seed, "w", i))), 0, 60 days));
        }

        for (uint256 r; r < 8; ++r) _fuzzRound(us, uint256(keccak256(abi.encode(seed, "r", r))));
    }

    function _fuzzRound(address[] memory us, uint256 h) internal {
        vm.warp(block.timestamp + bound(h, 0, 30 days));
        _setCapacity(h % 7 == 0 ? v.totalSupply() / 2 : v.totalSupply() + bound(h >> 64, 0, 4000e6));

        uint256 chi     = v.nowChi();
        uint256 room    = v.availableCapacity();
        uint256 budget  = bound(h >> 128, 1, 3000e6);
        uint256 queued0 = v.totalQueuedDepositShares();
        uint256 supply0 = v.totalSupply();
        uint256[] memory d0 = new uint256[](us.length);
        uint256[] memory m0 = new uint256[](us.length);
        for (uint256 i; i < us.length; ++i) { d0[i] = v.maxDeposit(us[i]); m0[i] = v.maxMint(us[i]); }

        _process(budget);

        uint256 credited;
        for (uint256 i; i < us.length; ++i) {
            uint256 dA = v.maxDeposit(us[i]) - d0[i];
            assertEq(v.maxMint(us[i]) - m0[i], dA * RAY / chi, "minted == credited * RAY / chi");
            credited += dA;
        }
        uint256 acceptedValue = sp.convertToAssets(queued0 - v.totalQueuedDepositShares());
        assertLe(v.totalSupply() - supply0, room,           "capacity");
        assertLe(credited, budget,                          "budget");
        assertLe(credited, room * chi / RAY,                "budget capped by room");
        assertLe(credited, acceptedValue,                   "never over-credit");
        assertGe(credited + 4 * us.length, acceptedValue,   "rounding is dust");
        invariants();
    }

    function testFuzz_claimSplits(uint256 a1, uint256 a2, uint256 dt, uint256 seed) public {
        a1 = bound(a1, 100e6, 100_000e6);
        a2 = bound(a2, 100e6, 100_000e6);
        dt = bound(dt, 1, 3 * 365 days);

        _req(alice, a1);
        vm.warp(block.timestamp + dt);
        _req(alice, a2);
        uint256 S = v.maxMint(alice);

        uint256 got;
        for (uint256 i; i < 12 && v.maxMint(alice) != 0 && v.maxDeposit(alice) != 0; ++i) {
            uint256 h = uint256(keccak256(abi.encode(seed, i)));
            if (h % 2 == 0) {
                uint256 x = bound(h >> 8, 1, v.maxDeposit(alice));
                uint256 fair = v.maxMint(alice) * x / v.maxDeposit(alice);
                vm.prank(alice); uint256 sh = v.deposit(x, alice);
                assertEq(sh, fair);
                got += sh;
            } else {
                uint256 s = bound(h >> 8, 1, v.maxMint(alice));
                uint256 D = v.maxDeposit(alice);
                uint256 M = v.maxMint(alice);
                vm.prank(alice); uint256 as_ = v.mint(s, alice);
                assertGe(as_ * M, D * s, "mint pays at least pro-rata");
                got += s;
            }
            invariants();
        }
        uint256 restAssets = v.maxDeposit(alice);
        uint256 restShares = v.maxMint(alice);
        if (restAssets != 0)      { vm.prank(alice); got += v.deposit(restAssets, alice); }
        else if (restShares != 0) { vm.prank(alice); v.mint(restShares, alice); got += restShares; }

        assertEq(got, S, "no drift: all shares claimed exactly once");
        assertEq(v.balanceOf(alice), S);
        assertEq(v.maxDeposit(alice), 0);
        assertEq(v.maxMint(alice),    0);
        invariants();
    }

}
