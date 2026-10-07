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

contract Security is Test {
    uint256 constant RAY = 1e27;
    uint256 constant FIVE_PCT = 1.000000001547125957863212448e27;

    USDC usdc;
    SparkVault sp;
    SparkPrimeVault v;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");
    address eve   = makeAddr("eve");

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

        usdc.mint(address(sp), 1_000_000e6);
        address[3] memory us = [alice, bob, eve];
        for (uint256 i; i < 3; ++i) {
            usdc.mint(us[i], 10_000_000e6);
            vm.prank(us[i]); usdc.approve(address(v), type(uint256).max);
            vm.prank(us[i]); usdc.approve(address(sp), type(uint256).max);
        }
    }

    // F1 (fixed): a long run of cancelled entries is walked at most ~500 per call and the head is
    // saved, so a gas-capped call still makes progress and honest entries behind it get accepted.
    function test_F1_cancelledRunCannotJamQueue() public {
        vm.prank(admin); v.setCapacity(1000e6);
        vm.prank(alice); v.requestDeposit(1000e6, alice, alice);    // fills capacity, queue empty

        uint256 N = 1100;
        for (uint256 i; i < N; ++i) {
            vm.startPrank(eve);
            v.requestDeposit(100e6, eve, eve);                      // queued (capacity full)
            v.cancelDepositRequest(i);                               // zeroed in place
            vm.stopPrank();
        }
        vm.prank(bob); v.requestDeposit(500e6, bob, bob);            // honest depositor behind the run
        vm.prank(admin); v.setCapacity(1e12);

        vm.cool(address(v)); vm.cool(address(sp));
        vm.prank(admin);
        (bool ok,) = address(v).call{gas: 5_000_000}(abi.encodeCall(v.processDepositQueue, (type(uint256).max)));
        assertTrue(ok, "bounded walk fits the gas cap");
        assertEq(v.depositHead(), 499, "progress saved");

        vm.prank(admin); v.processDepositQueue(type(uint256).max);
        vm.prank(admin); v.processDepositQueue(type(uint256).max);
        assertEq(v.depositHead(), N + 1);
        assertEq(v.maxDeposit(bob), 500e6, "bob accepted");
    }

    // F2: anyone can fill spUSDC's depositCap (costless: they keep earning spUSDC yield),
    // which makes every queued requestDeposit and depositToSavings revert.
    function test_F2_spUsdcCapGrief() public {
        uint256 cap = sp.totalAssets() + 5_000_000e6;
        vm.prank(admin); sp.setDepositCap(cap);
        vm.prank(admin); v.setCapacity(1000e6);
        vm.prank(alice); v.requestDeposit(1000e6, alice, alice);      // instant, capacity now full

        uint256 room = sp.maxDeposit(eve);
        vm.prank(eve); sp.deposit(room, eve);                          // eve fills spUSDC to cap

        vm.prank(bob); vm.expectRevert("SparkVault/deposit-cap-exceeded");
        v.requestDeposit(100e6, bob, bob);                             // cannot even queue
        vm.prank(admin); vm.expectRevert("SparkVault/deposit-cap-exceeded");
        v.depositToSavings(100e6);
    }

    // F3 (fixed): redeem/withdraw reject receiver == address(this) and address(0), like deposit
    // claims and transfers do, so a claim can never turn into Spark's idle cash.
    function test_F3_claimToSelfRejected() public {
        vm.prank(alice); v.requestDeposit(1000e6, alice, alice);
        vm.prank(alice); v.mint(1000e6, alice);
        vm.prank(alice); v.requestRedeem(1000e6, alice, alice);
        uint256 owed = v.maxWithdraw(alice);

        vm.prank(alice); vm.expectRevert("SparkPrimeVault/invalid-address"); v.withdraw(owed, address(v), alice);
        vm.prank(alice); vm.expectRevert("SparkPrimeVault/invalid-address"); v.redeem(1000e6, address(0), alice);
        assertEq(v.maxWithdraw(alice), owed);

        vm.prank(alice); v.withdraw(owed, alice, alice);
        assertEq(usdc.balanceOf(alice), 10_000_000e6 - 1000e6 + owed);
    }

    // F4 (fixed): a budget too small to pay any net USDC does not burn shares from the head.
    function test_F4_tinyBudgetDoesNotGrind() public {
        vm.prank(alice); v.requestDeposit(1000e6, alice, alice);
        vm.prank(alice); v.mint(1000e6, alice);
        vm.prank(admin); v.take(1000e6);
        vm.warp(block.timestamp + 365 days);                           // chi ~1.05
        vm.prank(alice); v.requestRedeem(1000e6, alice, alice);        // all queued, no liquidity
        usdc.mint(address(v), 1000e6);

        uint256 supply0 = v.totalSupply();
        for (uint256 i; i < 10; ++i) { vm.prank(admin); v.processWithdrawQueue(2); }
        assertEq(v.maxRedeem(alice), 0, "nothing burned");
        assertEq(v.pendingRedeemRequest(0, alice), 1000e6);
        assertEq(v.totalSupply(), supply0);
    }

    // F5 (fixed): a deposit remainder below one spUSDC share is absorbed without a queue entry.
    function test_F5_dustRemainderNotQueued() public {
        vm.warp(block.timestamp + 365 days);                           // spUSDC chi ~1.05
        uint256 c = 1000e6 * RAY / v.nowChi();
        vm.prank(admin); v.setCapacity(c);     // capacity*chi/RAY just under 1000e6
        uint256 instantCap = v.availableCapacity() * v.nowChi() / RAY;
        uint256 rem = 1000e6 - instantCap;
        assertGt(rem, 0);
        assertLt(rem * RAY / sp.nowChi(), 1);
        vm.prank(alice); v.requestDeposit(1000e6, alice, alice);
        assertEq(v.maxDeposit(alice), instantCap);
        assertEq(v.totalQueuedDepositShares(), 0);
        vm.expectRevert(); v.depositQueue(0);                          // no entry pushed
    }

    // F6: front-running the guardian's pause before setChi. Instant redeems are open to anyone,
    // so whoever sees the loss first exits at the pre-loss chi with the vault's liquidity.
    function test_F6_pauseFrontRun() public {
        vm.prank(alice); v.requestDeposit(1000e6, alice, alice);
        vm.prank(alice); v.mint(1000e6, alice);
        vm.prank(bob);   v.requestDeposit(1000e6, bob, bob);
        vm.prank(bob);   v.mint(1000e6, bob);
        vm.prank(admin); v.take(1000e6);                               // 1000 idle left

        // loss event known; alice front-runs pause+setChi
        vm.prank(alice); v.requestRedeem(1000e6, alice, alice);
        assertEq(v.maxRedeem(alice), 1000e6, "fully approved at old chi");
        vm.prank(admin); v.pause();
        vm.prank(admin); v.setChi(0.5e27);
        assertEq(v.convertToAssets(v.balanceOf(bob)), 500e6, "bob eats the whole loss");
        assertGt(v.maxWithdraw(alice), 990e6);
    }
}
