// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import "forge-std/Test.sol";

import { ERC20 }        from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import { ERC1967Proxy } from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { SparkVault }      from "spark-vaults-v2/SparkVault.sol";
import { SparkPrimeVault } from "src/SparkPrimeVault.sol";

contract CrunchUSDC is ERC20("USDC", "USDC") {
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 v) external { _mint(to, v); }
}

/// What happens to spPRIME when spUSDC (the real Spark Vault V2) runs out of USDC.
/// Run with -vv: every test narrates the state of both vaults step by step.
///
/// The book: 10M spPRIME supply. 1M (10%) sits in the spUSDC sleeve, 9M was taken to Arkis.
/// spUSDC has 49M from other depositors; its own taker has deployed most of spUSDC's cash,
/// so spUSDC's USDC balance (its only liquidity) is set per scenario.
contract LiquidityCrunchTest is Test {
    uint256 constant RAY = 1e27;
    uint256 constant WAD = 1e18;
    uint256 constant FIVE_PCT = 1.000000001547125957863212448e27;
    uint256 constant FEE = 0.005e18;

    CrunchUSDC usdc;
    SparkVault sp;
    SparkPrimeVault v;

    address admin   = makeAddr("admin");    // all spPRIME roles (Spark ops)
    address alice   = makeAddr("alice");
    address bob     = makeAddr("bob");
    address carol   = makeAddr("carol");
    address dave    = makeAddr("dave");
    address erin    = makeAddr("erin");     // late depositor who ends up queued
    address op      = makeAddr("op");
    address arkis   = makeAddr("arkis");    // where spPRIME's 90% is deployed
    address whale   = makeAddr("whale");    // spUSDC's other depositors
    address spTaker = makeAddr("spTaker");  // spUSDC's own taker (deploys spUSDC cash)

    function setUp() public {
        usdc = new CrunchUSDC();

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
        sp.grantRole(sp.TAKER_ROLE(), spTaker);
        sp.setVsrBounds(RAY, sp.MAX_VSR());
        sp.setVsr(FIVE_PCT);

        v.grantRole(v.SETTER_ROLE(), admin);
        v.grantRole(v.TAKER_ROLE(), admin);
        v.grantRole(v.REBALANCER_ROLE(), admin);
        v.grantRole(v.RISK_MANAGER_ROLE(), admin);
        v.grantRole(v.GUARDIAN_ROLE(), admin);
        v.grantRole(v.UNPAUSER_ROLE(), admin);
        v.setCapacity(100_000_000e6);
        v.setMaxWithdrawFee(0.01e18);
        v.setWithdrawFee(FEE);
        v.setMinimums(100e6, 50e6);
        v.setVsrBounds(RAY, v.MAX_VSR());
        v.setVsr(FIVE_PCT);
        vm.stopPrank();

        usdc.mint(address(sp), 1_000_000e6);  // back spUSDC yield
        for (uint256 i; i < 5; ++i) {
            address u = [alice, bob, carol, dave, erin][i];
            usdc.mint(u, 10_000_000e6);
            vm.prank(u); usdc.approve(address(v), type(uint256).max);
        }
        usdc.mint(whale, 49_000_000e6);
        vm.prank(whale); usdc.approve(address(sp), type(uint256).max);
    }

    /**********************************************************************************************/
    /*** Book and helpers                                                                       ***/
    /**********************************************************************************************/

    function _book() internal {
        console2.log("=== BOOK: 10M spPRIME, 1M sleeve in spUSDC, 9M taken to Arkis ===");
        uint256[4] memory amt = [uint256(4_000_000e6), 3_000_000e6, 2_000_000e6, 1_000_000e6];
        for (uint256 i; i < 4; ++i) {
            address u = [alice, bob, carol, dave][i];
            vm.prank(u); v.requestDeposit(amt[i], u, u);
            uint256 m = v.maxMint(u);
            vm.prank(u); v.mint(m, u);
        }
        vm.prank(admin); v.depositToSavings(1_000_000e6);
        vm.prank(admin); v.take(9_000_000e6);
        vm.prank(admin); usdc.transfer(arkis, 9_000_000e6);

        vm.prank(whale); sp.deposit(49_000_000e6, whale);   // spUSDC: 50M of deposits
        _setSpCash(5_000_000e6);                             // spUSDC keeps 5M, rest deployed

        assertEq(v.totalSupply(), 10_000_000e6);
        assertEq(sp.balanceOf(address(v)), 1_000_000e6);
        assertEq(sp.assetsOf(address(v)), 1_000_000e6);
        assertEq(usdc.balanceOf(address(v)), 0);
        assertEq(usdc.balanceOf(arkis), 9_000_000e6);
        assertEq(sp.totalAssets(), 50_000_000e6);
        _story("book built");
        invariants();
    }

    // spUSDC's taker moves spUSDC's cash to `target` (take out, or return what it took)
    function _setSpCash(uint256 target) internal {
        uint256 cur = usdc.balanceOf(address(sp));
        if (cur > target) {
            vm.prank(spTaker); sp.take(cur - target);
        } else if (cur < target) {
            uint256 need = target - cur;
            uint256 have = usdc.balanceOf(spTaker);
            if (have < need) usdc.mint(spTaker, need - have);
            vm.prank(spTaker); usdc.transfer(address(sp), need);
        }
        assertEq(usdc.balanceOf(address(sp)), target);
        console2.log("  [spUSDC taker] spUSDC USDC balance set to", _usd(target));
    }

    function _net(uint256 shares, uint256 chi_) internal pure returns (uint256) {
        uint256 gross = shares * chi_ / RAY;
        uint256 f = gross * FEE;
        return gross - (f == 0 ? 0 : (f - 1) / WAD + 1);
    }

    function _maxSharesFor(uint256 budget, uint256 chi_) internal pure returns (uint256) {
        return budget * WAD / (WAD - FEE) * RAY / chi_;
    }

    function _sleeve() internal view returns (uint256) {
        return sp.convertToAssets(sp.balanceOf(address(v)) - v.totalQueuedDepositShares());
    }

    function _liquid() internal view returns (uint256) {
        int256 l = v.availableLiquidAssets();
        assertGe(l, 0, "liquid never negative");
        return uint256(l);
    }

    function _idle() internal view returns (uint256) {
        return usdc.balanceOf(address(v)) - v.totalClaimableRedeemAssets();
    }

    function _wqLen() internal view returns (uint256 n) {
        while (true) {
            try v.withdrawQueue(n) returns (address, address, uint256, uint256) { ++n; }
            catch { return n; }
        }
    }

    function _dqLen() internal view returns (uint256 n) {
        while (true) {
            try v.depositQueue(n) returns (address, address, uint256, uint256) { ++n; }
            catch { return n; }
        }
    }

    function _usd(uint256 x) internal pure returns (string memory) {
        uint256 frac = x % 1e6;
        string memory f = vm.toString(frac);
        bytes memory pad = new bytes(6 - bytes(f).length);
        for (uint256 i; i < pad.length; ++i) pad[i] = "0";
        return string(abi.encodePacked(vm.toString(x / 1e6), ".", pad, f));
    }

    function _chi(uint256 c) internal pure returns (string memory) {
        uint256 frac = (c % RAY) / 1e18;  // 9 decimals
        string memory f = vm.toString(frac);
        bytes memory pad = new bytes(9 - bytes(f).length);
        for (uint256 i; i < pad.length; ++i) pad[i] = "0";
        return string(abi.encodePacked(vm.toString(c / RAY), ".", pad, f));
    }

    function _story(string memory step) internal view {
        console2.log("");
        console2.log(string.concat("--- ", step, " ---"));
        console2.log("  spUSDC USDC balance (its liquidity) :", _usd(usdc.balanceOf(address(sp))));
        console2.log("  spPRIME free sleeve value           :", _usd(_sleeve()));
        console2.log("  queued depositors' spUSDC value     :", _usd(sp.convertToAssets(v.totalQueuedDepositShares())));
        console2.log("  availableLiquidAssets               :", _usd(_liquid()));
        console2.log("  spPRIME idle USDC (not ring-fenced) :", _usd(_idle()));
        console2.log("  spPRIME USDC balance                :", _usd(usdc.balanceOf(address(v))));
        console2.log("  totalClaimableRedeemAssets          :", _usd(v.totalClaimableRedeemAssets()));
        console2.log("  totalQueuedRedeemShares             :", _usd(v.totalQueuedRedeemShares()));
        console2.log("  withdraw queue length / head        :", _wqLen(), v.withdrawHead());
        console2.log("  deposit  queue length / head        :", _dqLen(), v.depositHead());
        console2.log("  spPRIME supply / chi                :", _usd(v.totalSupply()), _chi(v.nowChi()));
    }

    function _who(string memory name, address u) internal view {
        console2.log(string.concat("  ", name, ": pending redeem / claimable shares / claimable USDC:"),
            _usd(v.pendingRedeemRequest(0, u)), _usd(v.maxRedeem(u)), _usd(v.maxWithdraw(u)));
    }

    function invariants() internal view {
        assertGe(usdc.balanceOf(address(v)), v.totalClaimableRedeemAssets(), "ring-fence");
        assertGe(sp.balanceOf(address(v)), v.totalQueuedDepositShares(), "queued spUSDC");
        uint256 esc = v.totalQueuedRedeemShares();
        for (uint256 i; i < 6; ++i) esc += v.maxMint([alice, bob, carol, dave, erin, op][i]);
        assertEq(v.balanceOf(address(v)), esc, "escrow");
    }

    /**********************************************************************************************/
    /*** 1. Healthy                                                                             ***/
    /**********************************************************************************************/

    function test_1_healthy_instantRedeemPullsFromSpUsdc() public {
        _book();
        assertEq(_liquid(), 1_000_000e6, "whole sleeve is liquid: spUSDC has 5M");

        vm.prank(alice); v.requestRedeem(500_000e6, alice, alice);
        _story("alice redeems 500k spPRIME (instant)");
        _who("alice", alice);

        // 500k gross, 0.5% fee = 2,500 kept, 497,500 pulled from spUSDC in the same tx
        assertEq(v.maxRedeem(alice), 500_000e6);
        assertEq(v.maxWithdraw(alice), 497_500e6);
        assertEq(v.pendingRedeemRequest(0, alice), 0);
        assertEq(usdc.balanceOf(address(v)), 497_500e6, "exact shortfall pulled");
        assertEq(v.totalClaimableRedeemAssets(), 497_500e6);
        assertEq(usdc.balanceOf(address(sp)), 4_502_500e6);
        assertEq(sp.balanceOf(address(v)), 502_500e6, "sleeve keeps the 2,500 fee");
        assertEq(_liquid(), 502_500e6);
        assertEq(v.totalSupply(), 9_500_000e6);
        assertEq(v.withdrawHead(), 1);
        invariants();

        vm.prank(alice); v.withdraw(497_500e6, alice, alice);
        _story("alice claims 497,500 USDC");
        assertEq(usdc.balanceOf(alice), 6_000_000e6 + 497_500e6);
        assertEq(v.totalClaimableRedeemAssets(), 0);
        invariants();
    }

    /**********************************************************************************************/
    /*** 2. Crunch: spUSDC has 50k, sleeve is worth 1M                                          ***/
    /**********************************************************************************************/

    function test_2_crunch_partialInstantRestQueues() public {
        _book();
        _setSpCash(50_000e6);
        _story("CRUNCH: spUSDC cash 50k, sleeve worth 1M");
        assertEq(_sleeve(), 1_000_000e6, "sleeve still worth 1M on paper");
        assertEq(_liquid(), 50_000e6, "but only 50k is liquid: capped by spUSDC's cash");

        vm.prank(alice); v.requestRedeem(500_000e6, alice, alice);
        _story("alice requestRedeem 500k: 50k instant (net), rest queued");
        _who("alice", alice);

        // Largest share amount whose net fits 50,000: 50,251.256281 shares -> 49,999.999999 net
        assertEq(v.maxRedeem(alice), 50_251_256_281);
        assertEq(v.maxWithdraw(alice), 49_999_999_999);
        assertEq(v.pendingRedeemRequest(0, alice), 500_000e6 - 50_251_256_281);
        assertEq(v.totalQueuedRedeemShares(), 449_748_743_719);
        assertEq(usdc.balanceOf(address(v)), 49_999_999_999, "claimable is real USDC in spPRIME");
        assertEq(usdc.balanceOf(address(sp)), 1, "spUSDC drained to 1 wei");
        assertEq(v.withdrawHead(), 0, "alice's remainder stays at the head");
        assertEq(_liquid(), 1);
        invariants();

        // The instant part is claimable right now, even though spUSDC is empty
        vm.prank(alice); v.withdraw(49_999_999_999, alice, alice);
        assertEq(usdc.balanceOf(alice), 6_000_000e6 + 49_999_999_999);
        _story("alice claims 49,999.999999 USDC immediately");
        invariants();

        // Bob joins behind alice: no instant path while someone is queued
        vm.prank(bob); v.requestRedeem(300_000e6, bob, bob);
        assertEq(v.pendingRedeemRequest(0, bob), 300_000e6);
        assertEq(v.maxRedeem(bob), 0);

        // Processing with 1 wei of liquidity: no progress, no revert
        vm.prank(admin); v.processWithdrawQueue(type(uint256).max);
        _story("bob queues 300k; rebalancer processes with 1 wei liquid -> nothing");
        _who("alice", alice);
        _who("bob", bob);
        assertEq(v.pendingRedeemRequest(0, alice), 449_748_743_719);
        assertEq(v.pendingRedeemRequest(0, bob), 300_000e6);
        assertEq(v.withdrawHead(), 0);
        invariants();
    }

    /**********************************************************************************************/
    /*** 3. Total freeze: spUSDC has 0                                                          ***/
    /**********************************************************************************************/

    function test_3_totalFreeze() public {
        _book();

        // Before the freeze: dave redeems 100k instantly but does not claim yet
        vm.prank(dave); v.requestRedeem(100_000e6, dave, dave);
        assertEq(v.maxWithdraw(dave), 99_500e6);

        // Capacity is full, erin's 300k deposit queues as spUSDC (then spUSDC deploys the cash)
        { uint256 cap = v.totalSupply(); vm.prank(admin); v.setCapacity(cap); }
        vm.prank(erin); v.requestDeposit(300_000e6, erin, erin);
        assertEq(v.totalQueuedDepositShares(), 300_000e6);
        assertEq(v.pendingDepositRequest(0, erin), 300_000e6);

        _setSpCash(0);
        _story("FREEZE: spUSDC cash 0; dave has 99.5k approved, erin 300k queued deposit");
        assertEq(_liquid(), 0);
        assertEq(_sleeve(), 900_500e6, "sleeve still worth 900.5k on paper");
        invariants();

        // Redeems queue fully
        vm.prank(alice); v.requestRedeem(500_000e6, alice, alice);
        assertEq(v.pendingRedeemRequest(0, alice), 500_000e6);
        assertEq(v.maxRedeem(alice), 0);
        assertEq(v.maxWithdraw(alice), 0);
        invariants();

        // Processing makes no progress and does not revert
        vm.prank(admin); v.processWithdrawQueue(type(uint256).max);
        _story("alice redeems 500k: all queued; processWithdrawQueue -> no progress");
        _who("alice", alice);
        assertEq(v.pendingRedeemRequest(0, alice), 500_000e6);
        assertEq(v.withdrawHead(), 1, "head is alice (dave's entry done)");

        // Queued depositor cannot get out: spUSDC cannot pay
        vm.prank(erin);  vm.expectRevert("SparkVault/insufficient-liquidity"); v.cancelDepositRequest(0);
        vm.prank(admin); vm.expectRevert("SparkVault/insufficient-liquidity"); v.cancelDepositRequest(0);
        console2.log("  erin cancelDepositRequest(0) -> revert SparkVault/insufficient-liquidity (guardian too)");

        // ... but she can still be let in: processDepositQueue does not touch spUSDC liquidity
        vm.prank(admin); v.setCapacity(100_000_000e6);
        vm.prank(admin); v.processDepositQueue(type(uint256).max);
        assertEq(v.maxDeposit(erin), 300_000e6);
        assertEq(v.maxMint(erin), 300_000e6);
        assertEq(v.totalQueuedDepositShares(), 0);
        assertEq(v.depositHead(), 1);
        assertEq(sp.balanceOf(address(v)), 1_200_500e6, "erin's spUSDC joins the sleeve");
        vm.prank(erin); v.mint(300_000e6, erin);
        assertEq(v.balanceOf(erin), 300_000e6);
        _story("processDepositQueue: erin filled and minted, her spUSDC is now sleeve");
        invariants();

        // Already-approved withdrawals still pay: dave's USDC was ring-fenced before the freeze
        vm.prank(dave); v.withdraw(99_500e6, dave, dave);
        assertEq(usdc.balanceOf(dave), 9_000_000e6 + 99_500e6);
        assertEq(v.totalClaimableRedeemAssets(), 0);
        _story("dave claims his 99,500 USDC during the freeze");
        invariants();

        // A fresh instant deposit brings idle USDC, which the rebalancer routes to the queue
        vm.prank(carol); v.requestDeposit(200_000e6, carol, carol);
        assertEq(_liquid(), 200_000e6);
        vm.prank(admin); v.processWithdrawQueue(type(uint256).max);
        uint256 s = _maxSharesFor(200_000e6, RAY);
        assertEq(v.maxRedeem(alice), s);
        assertEq(v.maxWithdraw(alice), _net(s, RAY));
        assertLe(v.maxWithdraw(alice), 200_000e6);
        assertEq(v.pendingRedeemRequest(0, alice), 500_000e6 - s);
        assertEq(usdc.balanceOf(address(sp)), 0, "spUSDC still frozen");
        _story("carol deposits 200k instant; queue processed from that new cash");
        _who("alice", alice);
        invariants();
    }

    /**********************************************************************************************/
    /*** 4. Recovery: Arkis returns USDC, spUSDC gets cash back                                 ***/
    /**********************************************************************************************/

    struct Rec {
        uint256 chi1; uint256 chi2; uint256 supplyBefore; uint256 sleeveBefore;
        uint256 aliceNet; uint256 bobS1; uint256 bobNet1; uint256 bobNet2; uint256 carolNet;
        uint256 balBefore; uint256 spSharesBefore; uint256 pulled; uint256 gross; uint256 paid;
    }

    function test_4_recovery_fifoDrain() public {
        Rec memory r;
        _book();
        _setSpCash(0);
        vm.prank(alice); v.requestRedeem(500_000e6, alice, alice);
        vm.prank(bob);   v.requestRedeem(300_000e6, bob, bob);
        vm.prank(carol); v.requestRedeem(200_000e6, carol, carol);
        assertEq(v.totalQueuedRedeemShares(), 1_000_000e6);
        _story("FREEZE: alice 500k, bob 300k, carol 200k queued");
        invariants();

        vm.warp(block.timestamp + 30 days);
        r.chi1 = v.nowChi();
        r.supplyBefore = v.totalSupply();
        r.sleeveBefore = _sleeve();

        // Round 1: Arkis returns 600k by plain transfer (Lucas's flow)
        vm.prank(arkis); usdc.transfer(address(v), 600_000e6);
        assertEq(_liquid(), 600_000e6, "spUSDC still empty: only the returned cash is liquid");
        vm.prank(admin); v.processWithdrawQueue(type(uint256).max);

        r.aliceNet = _net(500_000e6, r.chi1);
        r.bobS1    = _maxSharesFor(600_000e6 - r.aliceNet, r.chi1);
        r.bobNet1  = _net(r.bobS1, r.chi1);
        _story("day 30: Arkis returns 600k, processWithdrawQueue");
        console2.log("  round 1 chi:", _chi(r.chi1));
        _who("alice", alice); _who("bob", bob); _who("carol", carol);

        assertEq(v.maxRedeem(alice), 500_000e6);
        assertEq(v.maxWithdraw(alice), r.aliceNet);
        assertEq(v.maxRedeem(bob), r.bobS1);
        assertEq(v.maxWithdraw(bob), r.bobNet1);
        assertEq(v.pendingRedeemRequest(0, bob), 300_000e6 - r.bobS1);
        assertEq(v.pendingRedeemRequest(0, carol), 200_000e6);
        assertEq(v.withdrawHead(), 1, "bob partially filled, stays at head");
        assertLe(r.aliceNet + r.bobNet1, 600_000e6);
        assertLe(_idle(), 2, "a couple of wei of rounding left over");
        assertEq(_sleeve(), r.sleeveBefore, "spUSDC not touched (it is empty)");
        invariants();

        // Round 2, next day: spUSDC's taker returns cash, rebalancer processes again
        vm.warp(block.timestamp + 1 days);
        r.chi2 = v.nowChi();
        _setSpCash(5_000_000e6);
        r.balBefore = usdc.balanceOf(address(v));
        r.spSharesBefore = sp.balanceOf(address(v));
        vm.prank(admin); v.processWithdrawQueue(type(uint256).max);

        r.bobNet2  = _net(300_000e6 - r.bobS1, r.chi2);
        r.carolNet = _net(200_000e6, r.chi2);
        _story("day 31: spUSDC liquid again, processWithdrawQueue drains the queue");
        console2.log("  round 2 chi:", _chi(r.chi2));
        _who("alice", alice); _who("bob", bob); _who("carol", carol);

        assertEq(v.maxRedeem(bob), 300_000e6);
        assertEq(v.maxWithdraw(bob), r.bobNet1 + r.bobNet2, "bob paid at two prices");
        assertEq(v.maxWithdraw(carol), r.carolNet);
        assertEq(v.totalQueuedRedeemShares(), 0);
        assertEq(v.withdrawHead(), 3);
        assertEq(usdc.balanceOf(address(v)), v.totalClaimableRedeemAssets(), "exact shortfall pulled");
        r.pulled = usdc.balanceOf(address(v)) - r.balBefore;
        assertEq(r.pulled, r.bobNet2 + r.carolNet - (r.balBefore - r.aliceNet - r.bobNet1));
        assertEq(r.spSharesBefore - sp.balanceOf(address(v)), (r.pulled * RAY - 1) / sp.nowChi() + 1);
        console2.log("  pulled from spUSDC (exact shortfall):", _usd(r.pulled));
        invariants();

        // Fees: liabilities fell by gross, assets by net. The difference stays in the sleeve.
        r.gross = 500_000e6 * r.chi1 / RAY + r.bobS1 * r.chi1 / RAY
                + (300_000e6 - r.bobS1) * r.chi2 / RAY + 200_000e6 * r.chi2 / RAY;
        r.paid  = r.aliceNet + r.bobNet1 + r.bobNet2 + r.carolNet;
        console2.log("  gross redeemed / net paid / fee kept:", _usd(r.gross), _usd(r.paid), _usd(r.gross - r.paid));
        assertApproxEqAbs(r.gross - r.paid, r.gross * FEE / WAD, 4, "fee = 0.5% of gross (rounded up per fill)");
        assertEq(v.totalSupply(), r.supplyBefore - 1_000_000e6);

        // Everyone claims
        uint256[3] memory before = [usdc.balanceOf(alice), usdc.balanceOf(bob), usdc.balanceOf(carol)];
        vm.prank(alice); v.redeem(500_000e6, alice, alice);
        vm.prank(bob);   v.redeem(300_000e6, bob, bob);
        vm.prank(carol); v.redeem(200_000e6, carol, carol);
        assertEq(usdc.balanceOf(alice) - before[0], r.aliceNet);
        assertEq(usdc.balanceOf(bob)   - before[1], r.bobNet1 + r.bobNet2);
        assertEq(usdc.balanceOf(carol) - before[2], r.carolNet);
        assertEq(v.totalClaimableRedeemAssets(), 0);
        assertEq(usdc.balanceOf(address(v)), 0);
        _story("all three claimed");
        // Sleeve after = sleeve before (+ spUSDC yield) - what spUSDC paid. Fee stayed in.
        assertApproxEqAbs(_sleeve(), sp.convertToAssets(r.spSharesBefore) - r.pulled, 2);
        invariants();
    }

    /**********************************************************************************************/
    /*** 5. Edge: spUSDC liquidity exists, but spPRIME's spUSDC belongs to queued depositors    ***/
    /**********************************************************************************************/

    function test_5_queuedDepositorsSpUsdcIsUntouchable() public {
        _book();

        // Spark moves the whole sleeve to Arkis too: no free spUSDC left
        vm.prank(admin); v.withdrawFromSavings(1_000_000e6);
        vm.prank(admin); v.take(1_000_000e6);
        assertEq(sp.balanceOf(address(v)), 0);

        // Capacity full: erin's 2M deposit queues as spUSDC
        { uint256 cap = v.totalSupply(); vm.prank(admin); v.setCapacity(cap); }
        vm.prank(erin); v.requestDeposit(2_000_000e6, erin, erin);
        assertEq(v.totalQueuedDepositShares(), 2_000_000e6);
        assertEq(sp.balanceOf(address(v)), 2_000_000e6);
        _setSpCash(5_000_000e6);
        _story("spUSDC liquid (5M); spPRIME holds 2M spUSDC, ALL of it erin's queued deposit");
        assertEq(_sleeve(), 0);
        assertEq(_liquid(), 0, "queued depositors' spUSDC is not liquidity");

        vm.prank(alice); v.requestRedeem(500_000e6, alice, alice);
        vm.prank(admin); v.processWithdrawQueue(type(uint256).max);
        _story("alice redeems 500k: fully queued, erin's spUSDC untouched");
        assertEq(v.pendingRedeemRequest(0, alice), 500_000e6);
        assertEq(v.maxWithdraw(alice), 0);
        assertEq(sp.balanceOf(address(v)), 2_000_000e6);

        vm.prank(admin); vm.expectRevert("SparkPrimeVault/queued-shares-locked"); v.withdrawFromSavings(1);
        vm.prank(admin); vm.expectRevert("SparkPrimeVault/insufficient-liquidity"); v.take(1);
        console2.log("  withdrawFromSavings(1) -> revert queued-shares-locked; take(1) -> insufficient-liquidity");
        invariants();

        // Arkis returns 100k, rebalancer parks it in spUSDC: only that free 100k is payable
        vm.prank(arkis); usdc.transfer(address(v), 100_000e6);
        vm.prank(admin); v.depositToSavings(100_000e6);
        assertEq(_sleeve(), 100_000e6);
        assertEq(_liquid(), 100_000e6, "5M of spUSDC cash, but only 100k free sleeve");
        vm.prank(admin); v.processWithdrawQueue(type(uint256).max);
        uint256 s = _maxSharesFor(100_000e6, RAY);
        assertEq(v.maxRedeem(alice), s);
        assertEq(v.maxWithdraw(alice), _net(s, RAY));
        assertEq(sp.balanceOf(address(v)), 2_000_000e6 + 100_000e6 - _net(s, RAY));
        assertGe(sp.balanceOf(address(v)), v.totalQueuedDepositShares());
        _story("100k free sleeve paid to alice; erin's 2M spUSDC shares intact");
        _who("alice", alice);
        invariants();

        // Erin can still leave: her shares were never spent
        vm.prank(erin); v.cancelDepositRequest(0);
        assertEq(usdc.balanceOf(erin), 10_000_000e6);
        assertEq(v.totalQueuedDepositShares(), 0);
        _story("erin cancels and gets her 2M back from spUSDC");
        invariants();
    }

    // Shares are ring-fenced, spUSDC's cash is not: spUSDC's USDC is first come, first served
    // among ALL spUSDC holders. A redeemer paid from the free sleeve can use up the cash a queued
    // depositor would need to cancel. Her shares (and their value) are intact; she can still be
    // filled via processDepositQueue, and cancel later when spUSDC has cash again.
    function test_5b_spUsdcCashIsSharedFirstComeFirstServed() public {
        _book();
        { uint256 cap = v.totalSupply(); vm.prank(admin); v.setCapacity(cap); }
        vm.prank(erin); v.requestDeposit(400_000e6, erin, erin);
        _setSpCash(500_000e6);
        _story("spUSDC cash 500k; free sleeve 1M; erin 400k queued");
        assertEq(_liquid(), 500_000e6);

        vm.prank(alice); v.requestRedeem(600_000e6, alice, alice);
        _story("alice redeems 600k: takes all 500k of spUSDC's cash");
        assertEq(usdc.balanceOf(address(sp)), 500_000e6 - v.maxWithdraw(alice));
        assertEq(v.totalQueuedDepositShares(), 400_000e6, "erin's shares untouched");
        assertEq(v.pendingDepositRequest(0, erin), 400_000e6);
        assertGe(sp.balanceOf(address(v)) - v.totalQueuedDepositShares(), 500_000e6 - 1, "paid from free shares");

        vm.prank(erin); vm.expectRevert("SparkVault/insufficient-liquidity"); v.cancelDepositRequest(0);
        console2.log("  erin cancelDepositRequest -> revert SparkVault/insufficient-liquidity (cash gone)");
        invariants();

        _setSpCash(1_000_000e6);
        vm.prank(erin); v.cancelDepositRequest(0);
        assertEq(usdc.balanceOf(erin), 10_000_000e6);
        _story("spUSDC cash back: erin cancels, full 400k");
        invariants();
    }

    /**********************************************************************************************/
    /*** 6. Edge: spUSDC liquidity drops between the read and the pull; deposit cap             ***/
    /**********************************************************************************************/

    function test_6_liquidityDropsBetweenReadAndPull() public {
        _book();
        _setSpCash(600_000e6);
        uint256 seen = _liquid();
        assertEq(seen, 600_000e6);
        _story("same block: Lucas reads availableLiquidAssets = 600k");

        // Another spUSDC holder withdraws first, in the same block
        vm.prank(whale); sp.withdraw(500_000e6, whale, whale);
        _story("whale pulls 500k from spUSDC first");
        assertEq(_liquid(), 100_000e6);

        // requestRedeem re-reads liquidity inside the tx: succeeds with less
        vm.prank(alice); v.requestRedeem(500_000e6, alice, alice);
        uint256 s = _maxSharesFor(100_000e6, RAY);
        assertEq(v.maxRedeem(alice), s);
        assertEq(v.maxWithdraw(alice), _net(s, RAY));
        assertEq(v.pendingRedeemRequest(0, alice), 500_000e6 - s);
        assertEq(usdc.balanceOf(address(v)), v.totalClaimableRedeemAssets(), "claimables fully backed");
        _story("alice redeems 500k: only ~100k instant, rest queued, nothing unbacked");
        _who("alice", alice);
        invariants();

        // A rebalancer acting on a stale read: budget is clamped to live liquidity
        _setSpCash(300_000e6);
        uint256 stale = _liquid();
        vm.prank(whale); sp.withdraw(300_000e6, whale, whale);  // front-runs to zero
        assertEq(_liquid(), 0);
        uint256 claimableBefore = v.totalClaimableRedeemAssets();
        vm.prank(admin); v.processWithdrawQueue(stale);
        assertEq(v.totalClaimableRedeemAssets(), claimableBefore, "no progress, no revert");
        assertEq(v.pendingRedeemRequest(0, alice), 500_000e6 - s);
        _story("rebalancer processes with a stale 300k budget after whale drained spUSDC: no-op");
        invariants();

        // Partial front-run: succeeds with what is left
        _setSpCash(300_000e6);
        vm.prank(whale); sp.withdraw(200_000e6, whale, whale);
        vm.prank(admin); v.processWithdrawQueue(stale);
        assertLe(v.totalClaimableRedeemAssets() - claimableBefore, 100_000e6);
        assertGe(v.totalClaimableRedeemAssets() - claimableBefore, 100_000e6 - 1);
        assertEq(usdc.balanceOf(address(v)), v.totalClaimableRedeemAssets());
        _story("partial front-run: rebalancer fills ~100k, not the stale 300k");
        _who("alice", alice);
        invariants();
    }

    function test_6b_depositCapHitDuringCrunch() public {
        _book();
        _setSpCash(0);
        // spUSDC deposit cap reached
        { uint256 cap = sp.totalAssets(); vm.prank(admin); sp.setDepositCap(cap); }
        assertEq(sp.maxDeposit(address(v)), 0);
        _story("CRUNCH + spUSDC deposit cap hit");

        // Instant deposit (spPRIME has capacity) does not touch spUSDC: works
        vm.prank(erin); v.requestDeposit(100_000e6, erin, erin);
        assertEq(v.maxDeposit(erin), 100_000e6);
        assertEq(_idle(), 100_000e6);

        // Queued deposit needs spUSDC.deposit: reverts with spUSDC's reason
        { uint256 cap = v.totalSupply(); vm.prank(admin); v.setCapacity(cap); }
        vm.prank(erin); vm.expectRevert("SparkVault/deposit-cap-exceeded"); v.requestDeposit(100_000e6, erin, erin);

        // Partly instant, partly queued: the whole request reverts (instant part included)
        { uint256 cap = v.totalSupply() + 50_000e6; vm.prank(admin); v.setCapacity(cap); }
        vm.prank(erin); vm.expectRevert("SparkVault/deposit-cap-exceeded"); v.requestDeposit(100_000e6, erin, erin);
        console2.log("  queued (and part-queued) requestDeposit -> revert SparkVault/deposit-cap-exceeded");

        // Rebalancer cannot park idle in spUSDC either
        vm.prank(admin); vm.expectRevert("SparkVault/deposit-cap-exceeded"); v.depositToSavings(1e6);

        // The idle USDC from the instant deposit still serves redeemers
        vm.prank(alice); v.requestRedeem(50_000e6, alice, alice);
        assertEq(v.maxWithdraw(alice), 49_750e6);
        assertEq(usdc.balanceOf(address(sp)), 0);
        _story("alice redeems 50k, paid from erin's fresh idle USDC");
        invariants();
    }
}
