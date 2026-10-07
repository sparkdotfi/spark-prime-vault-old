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

contract Smoke is Test {
    uint256 constant RAY = 1e27;
    uint256 constant FIVE_PCT = 1.000000001547125957863212448e27;

    USDC usdc;
    SparkVault sp;
    SparkPrimeVault v;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave  = makeAddr("dave");
    address op    = makeAddr("op");

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
        for (uint256 i; i < 4; ++i) {
            address u = [alice, bob, carol, dave][i];
            usdc.mint(u, 10_000e6);
            vm.prank(u); usdc.approve(address(v), type(uint256).max);
        }
    }

    function invariants() internal view {
        assertGe(usdc.balanceOf(address(v)), v.totalClaimableRedeemAssets(), "ring-fence");
        assertGe(sp.balanceOf(address(v)), v.totalQueuedDepositShares(), "queued spUSDC");
        uint256 esc = v.totalQueuedRedeemShares();
        for (uint256 i; i < 5; ++i) esc += v.maxMint([alice, bob, carol, dave, op][i]);
        assertEq(v.balanceOf(address(v)), esc, "escrow");
        assertLe(v.totalSupply(), 1e12, "capacity");
    }

    function test_instantDepositAndClaim() public {
        vm.prank(alice); v.requestDeposit(1000e6, alice, alice);
        assertEq(v.maxDeposit(alice), 1000e6);
        assertEq(v.maxMint(alice), 1000e6);
        assertEq(v.pendingDepositRequest(0, alice), 0);
        assertEq(v.totalSupply(), 1000e6);
        invariants();

        uint256 m = v.maxMint(alice);
        vm.prank(alice); v.mint(m, alice);
        assertEq(v.balanceOf(alice), 1000e6);
        assertEq(v.maxDeposit(alice), 0);
        assertEq(v.maxMint(alice), 0);
        invariants();
    }

    function test_queuedDepositsProcessAndCancel() public {
        vm.prank(admin); v.setCapacity(1500e6);

        vm.prank(alice); v.requestDeposit(1000e6, alice, alice);       // instant
        vm.prank(bob);   v.requestDeposit(1000e6, bob, bob);           // 500 instant, 500 queued
        vm.prank(carol); v.requestDeposit(200e6, carol, carol);        // all queued
        vm.prank(dave);  v.requestDeposit(300e6, dave, dave);          // all queued

        assertEq(v.maxDeposit(bob), 500e6);
        assertEq(v.pendingDepositRequest(0, bob), 500e6);
        assertEq(v.pendingDepositRequest(0, carol), 200e6);
        assertEq(v.totalQueuedDepositShares(), 1000e6);
        assertEq(usdc.balanceOf(address(v)), 1500e6);
        invariants();

        vm.warp(block.timestamp + 30 days);
        assertGt(v.pendingDepositRequest(0, bob), 500e6, "queued earn spUSDC yield");

        // Dave cancels, gets principal + yield
        vm.prank(alice); vm.expectRevert("SparkPrimeVault/not-authorized"); v.cancelDepositRequest(2);
        uint256 before = usdc.balanceOf(dave);
        vm.prank(dave); v.cancelDepositRequest(2);
        assertGt(usdc.balanceOf(dave) - before, 300e6);
        assertEq(v.pendingDepositRequest(0, dave), 0);
        vm.prank(dave); vm.expectRevert("SparkPrimeVault/no-request"); v.cancelDepositRequest(2);
        invariants();

        // Capacity still full: nothing fills
        vm.prank(admin); v.processDepositQueue(type(uint256).max);
        assertEq(v.depositHead(), 0);
        assertEq(v.maxDeposit(bob), 500e6);

        // Raise capacity, fill Bob fully and Carol partially at the same chi and spUSDC price
        vm.prank(admin); v.setCapacity(1e12);
        uint256 bobValue   = v.pendingDepositRequest(0, bob);
        uint256 carolValue = v.pendingDepositRequest(0, carol);
        uint256 spBefore   = sp.balanceOf(address(v));
        vm.prank(admin); v.processDepositQueue(bobValue + 50e6);

        assertEq(v.maxDeposit(bob), 500e6 + bobValue);
        assertEq(v.pendingDepositRequest(0, bob), 0);
        assertEq(v.maxDeposit(carol), 50e6);
        assertEq(v.depositHead(), 1, "carol stays at head");
        assertApproxEqAbs(v.pendingDepositRequest(0, carol), carolValue - 50e6, 1);
        assertEq(sp.balanceOf(address(v)), spBefore, "spUSDC is not redeemed on fill");
        uint256 chi = v.nowChi();
        assertEq(v.maxMint(carol), 50e6 * RAY / chi);
        invariants();

        // Guardian cancels Carol's remainder (compliance), Carol gets the USDC
        before = usdc.balanceOf(carol);
        vm.prank(admin); v.cancelDepositRequest(1);
        assertApproxEqAbs(usdc.balanceOf(carol) - before, carolValue - 50e6, 1);
        assertEq(v.totalQueuedDepositShares(), 0);
        invariants();

        // Carol claims via deposit(assets)
        vm.prank(carol); v.deposit(50e6, carol);
        assertEq(v.balanceOf(carol), 50e6 * RAY / chi);
        assertEq(v.maxDeposit(carol), 0);
        assertEq(v.maxMint(carol), 0);
        invariants();
    }

    function test_redeemInstantQueuedAndClaims() public {
        vm.prank(alice); v.requestDeposit(2000e6, alice, alice);
        vm.prank(alice); v.mint(2000e6, alice);
        vm.prank(admin); v.depositToSavings(1500e6);   // 500 idle, 1500 in spUSDC sleeve
        vm.prank(admin); v.take(400e6);                // 100 idle
        vm.warp(block.timestamp + 365 days);

        uint256 chi = v.nowChi();
        assertApproxEqRel(chi, 1.05e27, 0.001e18);

        // Instant redeem fully covered: 100 idle + sleeve (~1575)
        vm.prank(alice); v.requestRedeem(500e6, alice, alice);
        uint256 gross = 500e6 * chi / RAY;
        uint256 net   = gross - (gross * 0.005e18 + 1e18 - 1) / 1e18;
        assertEq(v.maxWithdraw(alice), net);
        assertEq(v.maxRedeem(alice), 500e6);
        assertEq(v.pendingRedeemRequest(0, alice), 0);
        assertEq(v.balanceOf(alice), 1500e6);
        assertEq(v.totalSupply(), 1500e6);
        assertEq(usdc.balanceOf(address(v)), net, "shortfall pulled from spUSDC, exactly");
        invariants();

        // Claim via withdraw(maxWithdraw) like the PAU does
        vm.prank(alice); uint256 burned = v.withdraw(net, alice, alice);
        assertEq(burned, 500e6);
        assertEq(v.maxWithdraw(alice), 0);
        assertEq(v.maxRedeem(alice), 0);
        assertEq(v.totalClaimableRedeemAssets(), 0);
        invariants();

        // Instant redeem partially covered: sleeve has ~1575-net left, ask for 1500 shares (~1575 gross)
        int256 liquid = v.availableLiquidAssets();
        assertGt(liquid, 0);
        vm.prank(alice); v.requestRedeem(1500e6, alice, alice);
        uint256 approved = v.maxRedeem(alice);
        uint256 queued   = v.pendingRedeemRequest(0, alice);
        assertGt(approved, 0);
        assertGt(queued, 0);
        assertEq(approved + queued, 1500e6);
        assertLe(v.maxWithdraw(alice), uint256(liquid), "net never exceeds liquidity");
        assertGe(v.maxWithdraw(alice) + 2, uint256(liquid), "and uses almost all of it");
        assertEq(usdc.balanceOf(address(v)), v.totalClaimableRedeemAssets());
        assertEq(v.withdrawHead(), 1, "partial entry stays at head");
        invariants();

        // Only sleeve dust is liquid: processing can at most nibble a share-wei or two
        vm.prank(admin); v.processWithdrawQueue(type(uint256).max);
        assertApproxEqAbs(v.pendingRedeemRequest(0, alice), queued, 2);
        assertEq(usdc.balanceOf(address(v)), v.totalClaimableRedeemAssets());
        invariants();

        // Arkis returns USDC by plain transfer, rebalancer processes the queue
        usdc.mint(address(v), 2000e6);
        vm.prank(admin); v.processWithdrawQueue(type(uint256).max);
        assertEq(v.pendingRedeemRequest(0, alice), 0);
        assertEq(v.maxRedeem(alice), 1500e6);
        assertEq(v.withdrawHead(), 2);
        assertEq(v.totalSupply(), 0);
        invariants();

        // Partial claims round in the vault's favour and the remainder is fully claimable
        uint256 owed = v.maxWithdraw(alice);
        vm.prank(alice); uint256 got = v.redeem(700e6, alice, alice);
        assertLe(got, owed * 700 / 1500 + 1);
        uint256 rest = v.maxWithdraw(alice);
        vm.prank(alice); v.withdraw(rest, alice, alice);
        assertEq(got + rest, owed);
        assertEq(v.maxRedeem(alice), 0);
        assertEq(v.maxWithdraw(alice), 0);
        assertEq(usdc.balanceOf(alice), 10_000e6 - 2000e6 + net + owed);
        invariants();
    }

    function test_fifoAndBudgetOnWithdrawQueue() public {
        vm.prank(alice); v.requestDeposit(1000e6, alice, alice);
        vm.prank(alice); v.mint(1000e6, alice);
        vm.prank(bob);   v.requestDeposit(1000e6, bob, bob);
        vm.prank(bob);   v.mint(1000e6, bob);
        vm.prank(admin); v.take(2000e6);

        vm.prank(alice); v.requestRedeem(1000e6, alice, alice);  // queued, no liquidity
        vm.prank(bob);   v.requestRedeem(1000e6, bob, bob);      // queued behind alice
        assertEq(v.pendingRedeemRequest(0, alice), 1000e6);
        assertEq(v.pendingRedeemRequest(0, bob), 1000e6);

        usdc.mint(address(v), 5000e6);
        vm.prank(admin); v.processWithdrawQueue(1200e6);  // net budget: alice full, bob partial
        assertEq(v.maxRedeem(alice), 1000e6);
        assertGt(v.maxRedeem(bob), 0);
        assertLt(v.maxRedeem(bob), 1000e6);
        assertLe(v.maxWithdraw(alice) + v.maxWithdraw(bob), 1200e6);
        assertEq(v.withdrawHead(), 1);
        invariants();

        vm.prank(admin); v.processWithdrawQueue(type(uint256).max);
        assertEq(v.maxRedeem(bob), 1000e6);
        assertEq(v.pendingRedeemRequest(0, bob), 0);
        assertEq(v.withdrawHead(), 2);
        invariants();
    }

    function test_pauseAndSetChi() public {
        vm.prank(alice); v.requestDeposit(1000e6, alice, alice);
        vm.prank(alice); v.mint(500e6, alice);
        vm.prank(alice); v.requestRedeem(200e6, alice, alice);

        vm.prank(admin); vm.expectRevert("SparkPrimeVault/not-paused"); v.setChi(0.9e27);

        vm.prank(admin); v.pause();
        vm.prank(alice); vm.expectRevert("SparkPrimeVault/paused"); v.requestDeposit(100e6, alice, alice);
        vm.prank(alice); vm.expectRevert("SparkPrimeVault/paused"); v.requestRedeem(100e6, alice, alice);
        vm.prank(admin); vm.expectRevert("SparkPrimeVault/paused"); v.processWithdrawQueue(1);
        vm.prank(admin); vm.expectRevert("SparkPrimeVault/paused"); v.processDepositQueue(1);

        // Claims, transfers, take and savings moves still work
        vm.prank(alice); v.mint(100e6, alice);
        vm.prank(alice); v.redeem(100e6, alice, alice);
        vm.prank(alice); v.transfer(bob, 1e6);
        vm.prank(admin); v.take(1e6);
        vm.prank(admin); v.depositToSavings(1e6);
        vm.prank(admin); v.withdrawFromSavings(1e6);

        vm.prank(admin); vm.expectRevert("SparkPrimeVault/invalid-chi"); v.setChi(0);
        vm.prank(admin); vm.expectRevert("SparkPrimeVault/invalid-chi"); v.setChi(1e27);
        vm.prank(admin); v.setChi(0.9e27);
        assertEq(v.nowChi(), 0.9e27);
        assertEq(v.maxDeposit(alice), 400e6, "claimable assets fixed");
        assertEq(v.maxMint(alice), 400e6, "claimable shares fixed, worth less");
        assertEq(v.maxWithdraw(alice), 99.5e6, "approved redeem is fixed USDC, unaffected");
        assertEq(v.maxRedeem(alice), 100e6);
        vm.prank(alice); v.withdraw(99.5e6, alice, alice);
        assertEq(v.maxRedeem(alice), 0, "claim while paused");

        vm.prank(alice); vm.expectRevert(); v.unpause();
        vm.prank(admin); v.unpause();
        vm.prank(alice); v.requestDeposit(100e6, alice, alice);
        invariants();
    }

    function test_roleBoundaries() public {
        vm.prank(alice); v.requestDeposit(1000e6, alice, alice);
        vm.prank(alice); v.mint(1000e6, alice);
        vm.prank(admin); v.take(500e6);
        vm.prank(admin); v.depositToSavings(300e6);
        vm.prank(alice); v.requestRedeem(100e6, alice, alice);  // ring-fences ~99.5 of the 200 idle
        uint256 idle = usdc.balanceOf(address(v)) - v.totalClaimableRedeemAssets();

        vm.startPrank(admin);
        vm.expectRevert("SparkPrimeVault/insufficient-liquidity"); v.take(idle + 1);
        vm.expectRevert("SparkPrimeVault/insufficient-liquidity"); v.depositToSavings(idle + 1);
        v.take(idle);
        vm.stopPrank();

        // Queued spUSDC is locked for the rebalancer
        vm.prank(admin); v.setCapacity(1000e6);
        vm.prank(bob);   v.requestDeposit(1000e6, bob, bob);   // queued: 1000 spUSDC shares
        vm.prank(admin); vm.expectRevert("SparkPrimeVault/queued-shares-locked"); v.withdrawFromSavings(301e6);
        vm.prank(admin); v.withdrawFromSavings(300e6);
        invariants();

        // Fees
        vm.prank(admin); vm.expectRevert("SparkPrimeVault/fee-too-high"); v.setMaxWithdrawFee(0.011e18);
        vm.prank(admin); vm.expectRevert("SparkPrimeVault/fee-too-high"); v.setWithdrawFee(0.011e18);
        vm.prank(alice); vm.expectRevert(); v.setWithdrawFee(0);

        // Minimums
        vm.prank(alice); vm.expectRevert("SparkPrimeVault/below-minimum"); v.requestDeposit(99e6, alice, alice);
        vm.prank(alice); vm.expectRevert("SparkPrimeVault/below-minimum"); v.requestRedeem(49e6, alice, alice);
        vm.prank(bob);   vm.expectRevert("SparkPrimeVault/not-owner");     v.requestRedeem(100e6, bob, alice);
    }

    function test_operators() public {
        vm.prank(alice); v.requestDeposit(1000e6, alice, alice);
        vm.prank(op); vm.expectRevert("SparkPrimeVault/not-authorized"); v.mint(1e6, alice, alice);
        vm.prank(alice); v.setOperator(op, true);
        vm.prank(op); vm.expectRevert("SparkPrimeVault/not-authorized"); v.mint(1e6, op, alice);
        vm.prank(op); v.mint(1e6, alice, alice);
        assertEq(v.balanceOf(alice), 1e6);
        vm.prank(op); vm.expectRevert("SparkPrimeVault/not-owner"); v.requestRedeem(1e6, alice, alice);
        vm.prank(alice); vm.expectRevert("SparkPrimeVault/invalid-address"); v.mint(1e6, address(v), alice);
    }

    function test_interfaceAndPreviews() public {
        assertTrue(v.supportsInterface(0xe3bc4e65));
        assertTrue(v.supportsInterface(0xce3bbe50));
        assertTrue(v.supportsInterface(0x620ee8e4));
        assertTrue(v.supportsInterface(0x2f0a18c5));
        assertTrue(v.supportsInterface(0x01ffc9a7));
        assertEq(v.share(), address(v));
        assertEq(v.decimals(), 6);
        vm.expectRevert("SparkPrimeVault/async"); v.previewDeposit(1);
        vm.expectRevert("SparkPrimeVault/async"); v.previewRedeem(1);
        assertEq(v.getImplementation() != address(0), true);
    }

    // A 1 share-wei entry nets 0 USDC, so it fits any budget: it is burned for 0 and passed over
    // (never jams the head), while a budget-limited partial fill that nets 0 does not grind.
    function test_dustHeadDoesNotJam() public {
        vm.prank(admin); v.setMinimums(100e6, 0);
        vm.prank(alice); v.requestDeposit(1000e6, alice, alice);
        vm.prank(alice); v.mint(1000e6, alice);
        vm.prank(bob);   v.requestDeposit(1000e6, bob, bob);
        vm.prank(bob);   v.mint(1000e6, bob);
        vm.prank(admin); v.take(2000e6);                       // no liquidity, chi == RAY

        vm.prank(bob);   v.requestRedeem(100e6, bob, bob);     // queued
        vm.prank(alice); v.requestRedeem(1, alice, alice);     // 1 share-wei behind bob, nets 0
        vm.prank(alice); v.requestRedeem(500e6, alice, alice); // behind the dust
        assertEq(v.pendingRedeemRequest(0, alice), 500e6 + 1);

        // Exactly bob's net: bob filled, the dust passed over for 0, alice's 500e6 not ground
        usdc.mint(address(v), 99.5e6);
        vm.prank(admin); v.processWithdrawQueue(type(uint256).max);
        assertEq(v.maxRedeem(bob), 100e6);
        assertEq(v.maxRedeem(alice), 1);
        assertEq(v.maxWithdraw(alice), 0);
        assertEq(v.pendingRedeemRequest(0, alice), 500e6, "not ground");
        assertEq(v.withdrawHead(), 2);
        invariants();

        usdc.mint(address(v), 1000e6);
        vm.prank(admin); v.processWithdrawQueue(type(uint256).max);
        assertEq(v.maxRedeem(alice), 500e6 + 1);
        assertEq(v.withdrawHead(), 3);
        invariants();
    }
}
