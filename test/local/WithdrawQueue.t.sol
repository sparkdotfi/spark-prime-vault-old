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

contract WithdrawQueueTest is Test {

    uint256 constant RAY      = 1e27;
    uint256 constant WAD      = 1e18;
    uint256 constant FEE      = 0.005e18;
    uint256 constant FIVE_PCT = 1.000000001547125957863212448e27;

    USDC            usdc;
    SparkVault      sp;
    SparkPrimeVault v;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave  = makeAddr("dave");
    address op    = makeAddr("op");

    address[4] users;

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
        sp.grantRole(sp.TAKER_ROLE(), admin);
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
        v.setWithdrawFee(FEE);
        v.setMinimums(100e6, 50e6);
        v.setVsrBounds(RAY, v.MAX_VSR());
        v.setVsr(FIVE_PCT);
        vm.stopPrank();

        usdc.mint(address(sp), 1_000_000e6);  // back spUSDC yield
        users = [alice, bob, carol, dave];
        for (uint256 i; i < 4; ++i) {
            usdc.mint(users[i], 10_000e6);
            vm.prank(users[i]); usdc.approve(address(v), type(uint256).max);
        }
    }

    function invariants() internal view {
        assertGe(usdc.balanceOf(address(v)), v.totalClaimableRedeemAssets(), "ring-fence");
        assertGe(sp.balanceOf(address(v)), v.totalQueuedDepositShares(), "queued spUSDC");
        uint256 esc = v.totalQueuedRedeemShares();
        for (uint256 i; i < 5; ++i) esc += v.maxMint([alice, bob, carol, dave, op][i]);
        assertEq(v.balanceOf(address(v)), esc, "escrow");
        assertLe(v.totalSupply(), 1e12, "capacity");
        assertGe(v.availableLiquidAssets(), 0, "liquidity");
    }

    /**********************************************************************************************/
    /*** Helpers                                                                                ***/
    /**********************************************************************************************/

    function _buy(address u, uint256 assets) internal {
        vm.prank(u); v.requestDeposit(assets, u, u);
        uint256 m = v.maxMint(u);
        vm.prank(u); v.mint(m, u);
    }

    function _redeem(address u, uint256 shares) internal {
        vm.prank(u); v.requestRedeem(shares, u, u);
    }

    function _process(uint256 budget) internal {
        vm.prank(admin); v.processWithdrawQueue(budget);
    }

    function _idle() internal view returns (uint256) {
        return usdc.balanceOf(address(v)) - v.totalClaimableRedeemAssets();
    }

    function _setIdle(uint256 x) internal {
        uint256 i = _idle();
        if (i > x) { vm.prank(admin); v.take(i - x); }
        else usdc.mint(address(v), x - i);
    }

    function _net(uint256 shares, uint256 fee) internal view returns (uint256) {
        uint256 gross = shares * v.nowChi() / RAY;
        return gross - _divup(gross * fee, WAD);
    }

    // Mirror of the contract's partial-fill sizing
    function _fill(uint256 budget, uint256 fee) internal view returns (uint256) {
        return budget * WAD / (WAD - fee) * RAY / v.nowChi();
    }

    function _divup(uint256 x, uint256 y) internal pure returns (uint256) {
        return x == 0 ? 0 : (x - 1) / y + 1;
    }

    function _liquid() internal view returns (uint256) {
        return uint256(v.availableLiquidAssets());
    }

    /**********************************************************************************************/
    /*** Instant path sizing                                                                    ***/
    /**********************************************************************************************/

    function test_instant_liquidityExactlyNet_roundChi() public {
        _buy(alice, 1000e6);
        _setIdle(199e6);

        _redeem(alice, 200e6);  // gross 200, fee 1, net 199

        assertEq(v.maxRedeem(alice),           200e6);
        assertEq(v.maxWithdraw(alice),         199e6);
        assertEq(v.pendingRedeemRequest(0, alice), 0);
        assertEq(v.withdrawHead(),             1);
        assertEq(v.availableLiquidAssets(),    0);
        assertEq(v.totalSupply(),              800e6);
        invariants();
    }

    function test_instant_oneWeiShort() public {
        _buy(alice, 1000e6);
        _setIdle(199e6 - 1);

        _redeem(alice, 200e6);

        // floor(198999999 / 0.995) = 199999998 shares, fee ceil(999999.99) = 1e6
        assertEq(v.maxRedeem(alice),               199_999_998);
        assertEq(v.maxWithdraw(alice),             198_999_998);
        assertEq(v.pendingRedeemRequest(0, alice), 2);
        assertEq(v.withdrawHead(),                 0);
        assertEq(v.availableLiquidAssets(),        1);

        // 1 wei left would pay 0 for a partial fill: no grind
        for (uint256 i; i < 5; ++i) _process(type(uint256).max);
        assertEq(v.pendingRedeemRequest(0, alice), 2);
        assertEq(v.maxRedeem(alice),               199_999_998);

        // 2 wei: the 2 share-wei settle for 1 wei net, the split cost alice 1 wei of fee rounding
        usdc.mint(address(v), 1);
        _process(type(uint256).max);
        assertEq(v.pendingRedeemRequest(0, alice), 0);
        assertEq(v.maxRedeem(alice),               200e6);
        assertEq(v.maxWithdraw(alice),             199e6 - 1);
        assertEq(v.withdrawHead(),                 1);
        invariants();
    }

    // Spec: "instant part = largest share amount whose NET assets fit within availableLiquidAssets()".
    // With a non-round chi, liquidity equal to (or 1 wei above) the full net leaves a share-wei
    // queued at the head, so the request is not complete and the instant path is off for everyone.
    function test_BUG_instantUndershootsWhenLiquidityCoversNet() public {
        _buy(alice, 1000e6);
        _buy(bob,   1000e6);
        vm.warp(block.timestamp + 1 days);

        uint256 shares  = 300e6;
        uint256 fullNet = _net(shares, FEE);
        _setIdle(fullNet);

        _redeem(alice, shares);
        invariants();

        // Arkis returns USDC, Bob redeems with ample liquidity
        usdc.mint(address(v), 1000e6);
        _redeem(bob, 100e6);

        assertEq(v.pendingRedeemRequest(0, alice), 0,      "alice fully filled");
        assertEq(v.maxRedeem(alice),               shares, "alice fully filled");
        assertEq(v.maxRedeem(bob),                 100e6,  "bob instant");
    }

    // Same root cause on the rebalancer path: a budget equal to the head's full net leaves it queued
    function test_processBudgetExactlyHeadNet_nonRoundChi_headStays() public {
        _buy(alice, 1000e6);
        _buy(bob,   1000e6);
        _setIdle(0);
        _redeem(alice, 300e6);
        _redeem(bob,   100e6);
        vm.warp(block.timestamp + 1 days);
        usdc.mint(address(v), 1000e6);

        uint256 fullNet = _net(300e6, FEE);
        _process(fullNet);

        // Current behaviour: alice 1 share-wei short, bob untouched
        assertEq(v.pendingRedeemRequest(0, alice), 300e6 - _fill(fullNet, FEE));
        assertGt(v.pendingRedeemRequest(0, alice), 0);
        assertEq(v.withdrawHead(),                 0);
        assertEq(v.maxRedeem(bob),                 0);

        _process(type(uint256).max);
        assertEq(v.pendingRedeemRequest(0, alice), 0);
        assertEq(v.maxRedeem(bob),                 100e6);
        assertEq(v.withdrawHead(),                 2);
        invariants();
    }

    function test_instant_sleeveOnly_pullsExactShortfall() public {
        _buy(alice, 1000e6);
        vm.prank(admin); v.depositToSavings(1000e6);
        assertEq(usdc.balanceOf(address(v)), 0);
        vm.warp(block.timestamp + 30 days);

        uint256 net = _net(400e6, FEE);
        _redeem(alice, 400e6);

        assertEq(v.maxRedeem(alice),         400e6);
        assertEq(v.maxWithdraw(alice),       net);
        assertEq(usdc.balanceOf(address(v)), net, "pulled exactly the shortfall");
        assertEq(sp.balanceOf(address(v)),   1000e6 - _divup(net * RAY, sp.nowChi()));
        invariants();
    }

    function test_instant_sleeveCappedBySpUsdcCash() public {
        _buy(alice, 1000e6);
        vm.prank(admin); v.depositToSavings(1000e6);
        uint256 cash = usdc.balanceOf(address(sp));
        vm.prank(admin); sp.take(cash - 300e6);

        assertEq(v.availableLiquidAssets(), 300e6, "capped by spUSDC's own USDC");

        _redeem(alice, 1000e6);

        uint256 filled = _fill(300e6, FEE);
        uint256 net    = _net(filled, FEE);
        assertEq(v.maxRedeem(alice),               filled);
        assertEq(v.maxWithdraw(alice),             net);
        assertEq(v.pendingRedeemRequest(0, alice), 1000e6 - filled);
        assertEq(usdc.balanceOf(address(sp)),      300e6 - net);
        assertEq(usdc.balanceOf(address(v)),       net);
        assertLe(v.availableLiquidAssets(),        4);
        invariants();
    }

    function test_instant_idleAndSleeveSplit() public {
        _buy(alice, 1000e6);
        vm.prank(admin); v.depositToSavings(300e6);
        vm.prank(admin); v.take(600e6);  // 100 idle + 300 sleeve

        _redeem(alice, 300e6);  // net 298.5: 100 idle + 198.5 pulled

        assertEq(v.maxWithdraw(alice),       298.5e6);
        assertEq(usdc.balanceOf(address(v)), 298.5e6);
        assertEq(sp.balanceOf(address(v)),   101.5e6);
        assertEq(v.availableLiquidAssets(),  101.5e6);
        invariants();
    }

    function test_shortfallNeverTouchesQueuedDeposits() public {
        _buy(alice, 1000e6);
        vm.prank(admin); v.setCapacity(1000e6);
        vm.prank(admin); v.depositToSavings(200e6);
        vm.prank(admin); v.take(800e6);
        vm.warp(block.timestamp + 10 days);

        vm.prank(bob); v.requestDeposit(1000e6, bob, bob);  // capacity full: all queued in spUSDC
        uint256 queued = v.totalQueuedDepositShares();
        uint256 value  = sp.convertToAssets(queued);
        assertEq(v.availableLiquidAssets(), int256(sp.convertToAssets(200e6)));

        _redeem(alice, 1000e6);

        assertEq(v.totalQueuedDepositShares(), queued);
        assertLe(sp.balanceOf(address(v)) - queued, 2, "only sleeve dust left");
        assertEq(v.maxWithdraw(alice) + uint256(v.availableLiquidAssets()), sp.convertToAssets(200e6));

        vm.prank(admin); vm.expectRevert("SparkPrimeVault/queued-shares-locked"); v.withdrawFromSavings(3);
        _process(type(uint256).max);
        assertEq(v.totalQueuedDepositShares(), queued);
        invariants();

        // Bob's queued spUSDC is intact
        uint256 before = usdc.balanceOf(bob);
        vm.prank(bob); v.cancelDepositRequest(0);
        assertEq(usdc.balanceOf(bob) - before, value);
        invariants();
    }

    /**********************************************************************************************/
    /*** Queue ordering and partial fills                                                       ***/
    /**********************************************************************************************/

    function test_nonEmptyQueueForcesFullQueueing_FIFO_sameChi() public {
        _buy(alice, 1000e6);
        _buy(bob,   1000e6);
        _buy(carol, 1000e6);
        _setIdle(0);

        _redeem(alice, 500e6);
        usdc.mint(address(v), 10_000e6);
        _redeem(bob, 500e6);  // ample liquidity, but alice is ahead

        assertEq(v.pendingRedeemRequest(0, bob), 500e6);
        assertEq(v.maxRedeem(bob),               0);
        assertEq(v.totalClaimableRedeemAssets(), 0);

        vm.warp(block.timestamp + 7 days);
        _redeem(carol, 500e6);

        uint256 net = _net(500e6, FEE);
        _process(net + 2);  // alice's net (+2 wei, see the BUG test), too little for bob
        assertEq(v.maxWithdraw(alice), net);
        assertEq(v.maxRedeem(bob),     0);
        assertEq(v.withdrawHead(),     1);

        _process(type(uint256).max);
        assertEq(v.maxWithdraw(bob),   net, "same chi for the round");
        assertEq(v.maxWithdraw(carol), net, "same chi for the round");
        assertEq(v.withdrawHead(),     3);
        assertEq(v.totalQueuedRedeemShares(), 0);
        invariants();
    }

    function test_partialFills_manyEntries() public {
        address[12] memory us;
        for (uint256 i; i < 12; ++i) {
            us[i] = address(uint160(0x1000 + i));
            usdc.mint(us[i], 100e6);
            vm.prank(us[i]); usdc.approve(address(v), type(uint256).max);
            _buy(us[i], 100e6);
        }
        _setIdle(0);
        for (uint256 i; i < 12; ++i) _redeem(us[i], 100e6);
        usdc.mint(address(v), 2000e6);

        _process(3 * 99.5e6 + 50e6);
        for (uint256 i; i < 3; ++i) assertEq(v.maxWithdraw(us[i]), 99.5e6);
        assertEq(v.maxRedeem(us[3]),   50_251_256);
        assertEq(v.maxWithdraw(us[3]), 49_999_999);
        assertEq(v.maxRedeem(us[4]),   0);
        assertEq(v.withdrawHead(),     3);

        _process(1);  // nets 0: no grind
        assertEq(v.maxRedeem(us[3]), 50_251_256);

        _process(type(uint256).max);
        assertEq(v.maxRedeem(us[3]),   100e6);
        assertEq(v.maxWithdraw(us[3]), 99.5e6 - 1, "1 wei fee rounding for the split");
        for (uint256 i = 4; i < 12; ++i) assertEq(v.maxWithdraw(us[i]), 99.5e6);
        assertEq(v.withdrawHead(), 12);
        assertEq(_idle(), 2000e6 - 11 * 99.5e6 - (99.5e6 - 1));
        invariants();
    }

    function test_dustEntriesBurnedForZero_bigHeadNeverGround() public {
        vm.prank(admin); v.setMinimums(100e6, 0);
        _buy(alice, 1000e6);
        _buy(bob,   1000e6);
        _setIdle(0);

        _redeem(alice, 1);
        _redeem(bob,   1);
        _redeem(alice, 1);
        _redeem(bob,   500e6);
        assertEq(v.totalQueuedRedeemShares(), 500e6 + 3);

        _process(type(uint256).max);  // no liquidity
        assertEq(v.withdrawHead(), 0);

        usdc.mint(address(v), 1);
        _process(0);                   // zero budget: dust stays
        assertEq(v.withdrawHead(), 0);

        for (uint256 i; i < 10; ++i) _process(type(uint256).max);
        assertEq(v.withdrawHead(), 3, "dust passed over");
        assertEq(v.maxRedeem(alice),   2);
        assertEq(v.maxWithdraw(alice), 0);
        assertEq(v.maxRedeem(bob),     1);
        assertEq(v.pendingRedeemRequest(0, bob), 500e6, "head not ground");
        assertEq(v.availableLiquidAssets(), 1);

        // Zero-asset claims of the dust
        vm.prank(alice); assertEq(v.redeem(2, alice, alice), 0);
        vm.prank(bob);   assertEq(v.withdraw(0, bob, bob), 0);
        assertEq(v.maxRedeem(bob), 1, "withdraw(0) burns no claimable shares");
        vm.prank(bob);   assertEq(v.redeem(1, bob, bob), 0);
        invariants();
    }

    /**********************************************************************************************/
    /*** Fees and price changes                                                                 ***/
    /**********************************************************************************************/

    function test_feeLockedPerRequest() public {
        for (uint256 i; i < 4; ++i) _buy(users[i], 1000e6);
        _setIdle(0);

        _redeem(alice, 100e6);                                       // 0.5%
        vm.prank(admin); v.setWithdrawFee(0.01e18);
        _redeem(bob, 100e6);                                         // 1%
        vm.prank(admin); v.setMaxWithdrawFee(0.002e18);
        assertEq(v.withdrawFee(), 0.002e18, "live fee clamped");
        _redeem(carol, 100e6);                                       // 0.2%
        vm.prank(admin); v.setWithdrawFee(0);
        _redeem(dave, 100e6);                                        // 0

        (,,, uint256 bobFee) = v.withdrawQueue(1);
        assertEq(bobFee, 0.01e18, "queued fee survives a lower max");

        usdc.mint(address(v), 1000e6);
        _process(type(uint256).max);

        assertEq(v.maxWithdraw(alice), 99.5e6);
        assertEq(v.maxWithdraw(bob),   99e6);
        assertEq(v.maxWithdraw(carol), 99.8e6);
        assertEq(v.maxWithdraw(dave),  100e6);
        assertEq(_idle(), 1000e6 - 398.3e6, "fees stay as Spark's cash");
        invariants();
    }

    function test_setChiLoss_queuedAbsorb_approvedFixed() public {
        _buy(alice, 1000e6);
        _buy(bob,   1000e6);
        _redeem(alice, 500e6);  // instant
        assertEq(v.maxWithdraw(alice), 497.5e6);
        _setIdle(0);
        _redeem(bob, 500e6);    // queued

        vm.startPrank(admin);
        v.pause();
        v.setChi(0.8e27);
        v.unpause();
        vm.stopPrank();

        assertEq(v.maxWithdraw(alice), 497.5e6, "approved is fixed USDC");
        assertEq(v.totalAssets(), 1200e6, "1500 shares incl. bob's escrow at 0.8");

        usdc.mint(address(v), 1000e6);
        _process(type(uint256).max);
        assertEq(v.maxWithdraw(bob), 398e6, "queued absorbs the loss");

        vm.prank(alice); v.withdraw(497.5e6, alice, alice);
        assertEq(usdc.balanceOf(alice), 10_000e6 - 1000e6 + 497.5e6);
        invariants();
    }

    function test_chiRisesBetweenRequestAndProcess() public {
        _buy(alice, 1000e6);
        _setIdle(0);
        _redeem(alice, 500e6);
        uint256 atRequest = _net(500e6, FEE);

        vm.warp(block.timestamp + 365 days);
        usdc.mint(address(v), 1000e6);
        uint256 atProcess = _net(500e6, FEE);
        _process(type(uint256).max);

        assertEq(v.maxWithdraw(alice), atProcess);
        assertGt(atProcess, atRequest + 24e6);
        invariants();
    }

    function test_minWithdrawOnGross() public {
        _buy(alice, 1000e6);
        vm.warp(block.timestamp + 365 days);
        uint256 s = _divup(50e6 * RAY, v.nowChi());

        vm.prank(alice); vm.expectRevert("SparkPrimeVault/below-minimum"); v.requestRedeem(s - 1, alice, alice);
        _redeem(alice, s);
        assertLt(v.maxWithdraw(alice), 50e6, "net may be below the minimum");

        vm.prank(admin); v.setMinimums(0, 0);
        vm.prank(alice); vm.expectRevert("SparkPrimeVault/below-minimum"); v.requestRedeem(0, alice, alice);
    }

    /**********************************************************************************************/
    /*** Liquidity accounting and roles                                                         ***/
    /**********************************************************************************************/

    // Unreachable through the interface; forced here to show the failure mode (e.g. USDC seized)
    function test_negativeLiquidity_revertsFills() public {
        _buy(alice, 1000e6);
        _redeem(alice, 200e6);
        deal(address(usdc), address(v), v.totalClaimableRedeemAssets() - 1);
        assertEq(v.availableLiquidAssets(), -1);

        vm.prank(admin); vm.expectRevert("SparkVault/insufficient-balance"); v.processWithdrawQueue(1e6);
        vm.prank(alice); vm.expectRevert("SparkVault/insufficient-balance"); v.requestRedeem(100e6, alice, alice);
        vm.prank(admin); vm.expectRevert(stdError.arithmeticError); v.take(0);
    }

    function test_rolesRacingQueuedWithdrawals() public {
        _buy(alice, 1000e6);
        _buy(bob,   1000e6);
        vm.prank(admin); v.depositToSavings(1500e6);
        _redeem(alice, 400e6);  // 398 ring-fenced from the 500 idle
        assertEq(_idle(), 102e6);

        vm.startPrank(admin);
        vm.expectRevert("SparkPrimeVault/insufficient-liquidity"); v.take(102e6 + 1);
        vm.expectRevert("SparkPrimeVault/insufficient-liquidity"); v.depositToSavings(102e6 + 1);

        int256 liquid = v.availableLiquidAssets();
        v.withdrawFromSavings(1500e6);
        assertEq(v.availableLiquidAssets(), liquid, "moving the sleeve does not change liquidity");
        vm.expectRevert(); v.withdrawFromSavings(1);
        v.take(_idle());
        vm.stopPrank();

        // Taker starves new redeems (trusted), never the approved ones
        _redeem(bob, 500e6);
        assertEq(v.pendingRedeemRequest(0, bob), 500e6);
        vm.prank(admin); vm.expectRevert("SparkPrimeVault/insufficient-liquidity"); v.depositToSavings(1);

        vm.prank(alice); v.withdraw(398e6, alice, alice);
        assertEq(usdc.balanceOf(address(v)), 0);
        invariants();
    }

    // Capacity full and no cash: neither queue can move. Seed liquidity then alternate the two
    // processors: burned redeems free capacity, accepted deposits free their spUSDC as liquidity.
    function test_loop_withdrawFreesCapacityForDeposits() public {
        _buy(alice, 2000e6);
        vm.startPrank(admin);
        v.setCapacity(2000e6);
        v.take(2000e6);
        vm.stopPrank();

        vm.prank(bob); v.requestDeposit(1000e6, bob, bob);
        _redeem(alice, 1000e6);
        assertEq(v.pendingRedeemRequest(0, alice), 1000e6);

        vm.startPrank(admin);
        v.processWithdrawQueue(type(uint256).max);
        v.processDepositQueue(type(uint256).max);
        vm.stopPrank();
        assertEq(v.pendingRedeemRequest(0, alice), 1000e6, "deadlock without cash");
        assertEq(v.maxDeposit(bob),                0,      "deadlock without capacity");

        usdc.mint(address(v), 100e6);  // Arkis returns 100
        uint256 rounds;
        while (v.totalQueuedRedeemShares() + v.totalQueuedDepositShares() != 0) {
            vm.startPrank(admin);
            v.processWithdrawQueue(type(uint256).max);
            v.processDepositQueue(type(uint256).max);
            vm.stopPrank();
            invariants();
            require(++rounds < 20, "no progress");
        }
        assertEq(rounds, 10);

        assertEq(v.maxRedeem(alice), 1000e6);
        assertApproxEqAbs(v.maxWithdraw(alice), 995e6, 10);
        assertLe(v.maxWithdraw(alice), 995e6);
        assertApproxEqAbs(v.maxDeposit(bob), 1000e6, 10);
        assertLe(v.maxDeposit(bob), 1000e6);
        assertApproxEqAbs(v.availableLiquidAssets(), 105e6, 20, "seed + fee");
        assertEq(v.totalSupply(), 1000e6 + v.maxMint(bob));

        // More withdrawals: Bob claims, then redeems instantly from the freed sleeve
        uint256 m = v.maxMint(bob);
        vm.prank(bob); v.mint(m, bob);
        _redeem(bob, 50e6);
        assertEq(v.maxRedeem(bob),   50e6);
        assertEq(v.maxWithdraw(bob), 49.75e6);
        invariants();
    }

    /**********************************************************************************************/
    /*** Claims                                                                                 ***/
    /**********************************************************************************************/

    function test_claims_proRataAcrossApprovals() public {
        _buy(alice, 2000e6);
        _setIdle(0);
        _redeem(alice, 500e6);                              // fee 0.5%
        vm.prank(admin); v.setWithdrawFee(0.01e18);
        _redeem(alice, 500e6);                              // fee 1%

        vm.warp(block.timestamp + 180 days);
        usdc.mint(address(v), 5000e6);
        uint256 s1 = _fill(200e6, FEE);
        uint256 w  = _net(s1, FEE);
        _process(200e6);
        assertEq(v.maxRedeem(alice),   s1);
        assertEq(v.maxWithdraw(alice), w);

        vm.warp(block.timestamp + 90 days);
        w += _net(500e6 - s1, FEE) + _net(500e6, 0.01e18);
        _process(type(uint256).max);
        assertEq(v.maxRedeem(alice),   1000e6);
        assertEq(v.maxWithdraw(alice), w);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice); uint256 a1 = v.redeem(400e6, alice, alice);
        assertEq(a1, w * 400e6 / 1000e6);
        vm.prank(alice); uint256 s2 = v.withdraw(100e6, alice, alice);
        assertEq(s2, _divup(600e6 * 100e6, w - a1));
        vm.prank(alice); uint256 a3 = v.redeem(600e6 - s2, alice, alice);
        assertEq(v.maxRedeem(alice),   0);
        assertEq(v.maxWithdraw(alice), 0);
        assertEq(a1 + 100e6 + a3, w);
        assertEq(usdc.balanceOf(alice) - before, w);
        invariants();
    }

    function test_claims_manySmallEqualsOne() public {
        _buy(alice, 1000e6);
        _buy(bob,   1000e6);
        vm.warp(block.timestamp + 77 days);
        _redeem(alice, 777_777_777);
        _redeem(bob,   777_777_777);
        uint256 w = v.maxWithdraw(alice);
        assertEq(v.maxWithdraw(bob), w);

        vm.prank(alice); v.withdraw(w, alice, alice);

        uint256 paid;
        uint256 r0 = v.maxRedeem(bob);
        for (uint256 i = 1; i <= 40; ++i) {
            vm.startPrank(bob);
            if (i % 2 == 0 && v.maxRedeem(bob) != 0) paid += v.redeem(_min(i * 1_234_567 + 1, v.maxRedeem(bob)), bob, bob);
            else { uint256 a = _min(i * 999_999 + 3, v.maxWithdraw(bob)); v.withdraw(a, bob, bob); paid += a; }
            vm.stopPrank();
            // Remaining claim is never below pro-rata: early chunks never overpay
            assertGe(v.maxWithdraw(bob) * r0, w * v.maxRedeem(bob));
        }
        uint256 rest = v.maxWithdraw(bob);
        vm.prank(bob); v.withdraw(rest, bob, bob);
        paid += rest;
        uint256 left = v.maxRedeem(bob);
        if (left != 0) { vm.prank(bob); paid += v.redeem(left, bob, bob); }

        assertEq(paid, w);
        assertEq(usdc.balanceOf(alice), usdc.balanceOf(bob));
        assertEq(v.totalClaimableRedeemAssets(), 0);
        invariants();
    }

    function test_claims_authAndEdges() public {
        _buy(alice, 1000e6);
        _redeem(alice, 200e6);  // 199 claimable

        vm.prank(op); vm.expectRevert("SparkPrimeVault/not-authorized"); v.withdraw(1e6, alice, alice);
        vm.prank(alice); v.setOperator(op, true);
        vm.prank(op); vm.expectRevert("SparkPrimeVault/not-authorized"); v.withdraw(1e6, op, alice);
        vm.prank(op); vm.expectRevert("SparkPrimeVault/not-authorized"); v.redeem(1e6, op, alice);
        vm.prank(op); v.withdraw(1e6, alice, alice);

        vm.startPrank(alice);
        vm.expectRevert("SparkPrimeVault/invalid-address"); v.withdraw(1e6, address(v), alice);
        vm.expectRevert("SparkPrimeVault/invalid-address"); v.redeem(1e6, address(0), alice);
        v.withdraw(1e6, carol, alice);  // the controller may pick any receiver
        vm.stopPrank();
        assertEq(usdc.balanceOf(carol), 10_001e6);

        // Nothing claimable
        vm.startPrank(bob);
        vm.expectRevert(stdError.divisionError);   v.redeem(1, bob, bob);
        vm.expectRevert(stdError.arithmeticError); v.withdraw(1, bob, bob);
        assertEq(v.withdraw(0, bob, bob), 0);
        vm.stopPrank();

        // Claims while paused, over-claims revert
        vm.prank(admin); v.pause();
        vm.prank(alice); vm.expectRevert(stdError.arithmeticError); v.withdraw(197e6 + 1, alice, alice);
        vm.prank(alice); v.withdraw(197e6, alice, alice);
        assertEq(v.maxRedeem(alice), 0);
        invariants();
    }

    function test_escrowTransfersBlocked() public {
        _buy(alice, 1000e6);
        _setIdle(0);
        _redeem(alice, 500e6);

        vm.startPrank(alice);
        vm.expectRevert("SparkPrimeVault/invalid-address"); v.transfer(address(v), 1);
        vm.expectRevert("SparkPrimeVault/invalid-address"); v.transfer(address(0), 1);
        v.approve(bob, type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert("SparkPrimeVault/invalid-address");       v.transferFrom(alice, address(v), 1);
        vm.expectRevert("SparkPrimeVault/insufficient-allowance"); v.transferFrom(address(v), bob, 1);
        vm.stopPrank();
        assertEq(v.balanceOf(address(v)), 500e6);
        invariants();
    }

    function test_requestRedeem_controllerNotOwner() public {
        _buy(alice, 1000e6);

        vm.prank(bob);   vm.expectRevert("SparkPrimeVault/not-owner");          v.requestRedeem(100e6, bob, alice);
        vm.prank(alice); vm.expectRevert("SparkPrimeVault/invalid-controller"); v.requestRedeem(100e6, address(0), alice);

        _setIdle(50e6);
        vm.prank(alice); v.requestRedeem(100e6, bob, alice);
        assertEq(v.balanceOf(alice), 900e6);
        assertEq(v.maxRedeem(alice), 0);
        assertGt(v.maxRedeem(bob), 0);
        assertEq(v.pendingRedeemRequest(0, alice), 0);
        assertEq(v.pendingRedeemRequest(0, bob) + v.maxRedeem(bob), 100e6);
        (address c, address o,,) = v.withdrawQueue(0);
        assertEq(c, bob);
        assertEq(o, alice);

        uint256 w = v.maxWithdraw(bob);
        vm.prank(alice); vm.expectRevert("SparkPrimeVault/not-authorized"); v.withdraw(w, alice, bob);
        vm.prank(bob); v.withdraw(w, bob, bob);
        assertEq(usdc.balanceOf(bob), 10_000e6 + w);
        invariants();
    }

    /**********************************************************************************************/
    /*** Fuzz                                                                                   ***/
    /**********************************************************************************************/

    function testFuzz_instantSizing(uint256 shares, uint256 liq, uint256 fee, uint256 dt) public {
        shares = bound(shares, 50e6, 5000e6);
        liq    = bound(liq,    0,    6000e6);
        fee    = bound(fee,    0,    0.01e18);
        dt     = bound(dt,     0,    730 days);

        usdc.mint(alice, 10_000e6);
        _buy(alice, 5000e6);
        vm.warp(block.timestamp + dt);
        vm.prank(admin); v.setWithdrawFee(fee);
        _setIdle(liq);

        uint256 fullNet = _net(shares, fee);
        _redeem(alice, shares);

        assertEq(v.maxRedeem(alice) + v.pendingRedeemRequest(0, alice), shares);
        assertLe(v.maxWithdraw(alice), liq);
        assertEq(v.maxWithdraw(alice) + _liquid(), liq);
        if (liq >= fullNet + 2) assertEq(v.maxRedeem(alice), shares);
        if (v.pendingRedeemRequest(0, alice) != 0) assertLe(_liquid(), 4, "partial fill uses the liquidity");
        invariants();
    }

    function testFuzz_claimSplits(uint256 shares, uint256 dt, uint256 fee, uint256[8] memory parts) public {
        shares = bound(shares, 50e6, 1000e6);
        dt     = bound(dt,     0,    730 days);
        fee    = bound(fee,    0,    0.01e18);

        _buy(alice, 1000e6);
        vm.warp(block.timestamp + dt);
        vm.prank(admin); v.setWithdrawFee(fee);
        _redeem(alice, shares);

        uint256 r0 = v.maxRedeem(alice);
        uint256 w0 = v.maxWithdraw(alice);
        uint256 paid;
        for (uint256 i; i < 8; ++i) {
            uint256 x = parts[i];
            vm.startPrank(alice);
            if (x % 2 == 0 && v.maxRedeem(alice) != 0) {
                paid += v.redeem(bound(x, 0, v.maxRedeem(alice)), alice, alice);
            } else {
                uint256 a = bound(x, 0, v.maxWithdraw(alice));
                v.withdraw(a, alice, alice);
                paid += a;
            }
            vm.stopPrank();
            assertGe(v.maxWithdraw(alice) * r0, w0 * v.maxRedeem(alice), "never ahead of pro-rata");
        }
        uint256 rest = v.maxWithdraw(alice);
        vm.prank(alice); v.withdraw(rest, alice, alice);
        paid += rest;
        uint256 left = v.maxRedeem(alice);
        if (left != 0) { vm.prank(alice); paid += v.redeem(left, alice, alice); }

        assertEq(paid, w0);
        assertEq(v.maxRedeem(alice), 0);
        assertEq(v.maxWithdraw(alice), 0);
        assertEq(v.totalClaimableRedeemAssets(), 0);
        invariants();
    }

    uint256[4] gRequested;
    uint256[4] gApproved;
    uint256[4] gClaimedShares;
    uint256[4] gCredited;
    uint256[4] gPaid;

    function testFuzz_redeemSequence(uint256 seed) public {
        for (uint256 i; i < 4; ++i) _buy(users[i], 2000e6);
        uint256 supply0 = v.totalSupply();
        vm.prank(admin); v.depositToSavings(2000e6);

        for (uint256 step; step < 40; ++step) {
            uint256 rnd = uint256(keccak256(abi.encode(seed, step)));
            uint256 u   = rnd % 4;
            uint256 act = (rnd >> 8) % 8;
            uint256 x   = rnd >> 16;

            uint256[4] memory r0;
            uint256[4] memory w0;
            uint256[4] memory b0;
            for (uint256 i; i < 4; ++i) {
                (r0[i], w0[i], b0[i]) = (v.maxRedeem(users[i]), v.maxWithdraw(users[i]), usdc.balanceOf(users[i]));
            }
            uint256 head0 = v.withdrawHead();

            if (act <= 1) {
                uint256 s = bound(x, 0, v.balanceOf(users[u]));
                if (s * v.nowChi() / RAY >= 50e6) { _redeem(users[u], s); gRequested[u] += s; }
            } else if (act == 2) {
                _process(bound(x, 0, 3000e6));
            } else if (act == 3) {
                usdc.mint(address(v), bound(x, 0, 2000e6));
            } else if (act == 4) {
                vm.startPrank(users[u]);
                if (x % 2 == 0 && r0[u] != 0) v.redeem(bound(x, 0, r0[u]), users[u], users[u]);
                else v.withdraw(bound(x, 0, w0[u]), users[u], users[u]);
                vm.stopPrank();
            } else if (act == 5) {
                vm.warp(block.timestamp + bound(x, 0, 60 days));
                uint256 fee = bound(x >> 64, 0, 0.01e18);
                vm.prank(admin); v.setWithdrawFee(fee);
            } else if (act == 6) {
                uint256 amt = bound(x, 0, _idle());
                vm.prank(admin); v.take(amt);
            } else {
                uint256 free = sp.balanceOf(address(v)) - v.totalQueuedDepositShares();
                uint256 amt  = x % 2 == 0 ? bound(x, 0, _idle()) : bound(x, 0, sp.convertToAssets(free));
                vm.prank(admin);
                if (x % 2 == 0) v.depositToSavings(amt);
                else            v.withdrawFromSavings(amt);
            }

            for (uint256 i; i < 4; ++i) {
                address a = users[i];
                if (act == 4) {
                    gClaimedShares[i] += r0[i] - v.maxRedeem(a);
                    gPaid[i]          += usdc.balanceOf(a) - b0[i];
                } else {
                    gApproved[i] += v.maxRedeem(a) - r0[i];
                    gCredited[i] += v.maxWithdraw(a) - w0[i];
                }
                assertEq(gRequested[i], v.pendingRedeemRequest(0, a) + gApproved[i]);
                assertEq(gApproved[i],  gClaimedShares[i] + v.maxRedeem(a));
                assertEq(gCredited[i],  gPaid[i] + v.maxWithdraw(a));
            }
            assertGe(v.withdrawHead(), head0);
            assertEq(supply0 - v.totalSupply(), gApproved[0] + gApproved[1] + gApproved[2] + gApproved[3]);
            invariants();
        }

        // Drain: everything queued gets gApproved and claimed in full
        usdc.mint(address(v), 20_000e6);
        _process(type(uint256).max);
        assertEq(v.totalQueuedRedeemShares(), 0);
        for (uint256 i; i < 4; ++i) {
            address a = users[i];
            gApproved[i] += v.maxRedeem(a) - (gApproved[i] - gClaimedShares[i]);
            gCredited[i] += v.maxWithdraw(a) - (gCredited[i] - gPaid[i]);
            uint256 w = v.maxWithdraw(a);
            vm.prank(a); v.withdraw(w, a, a);
            uint256 left = v.maxRedeem(a);
            if (left != 0) { vm.prank(a); v.redeem(left, a, a); }
            assertEq(gApproved[i], gRequested[i]);
            assertEq(gPaid[i] + w, gCredited[i]);
        }
        assertEq(v.totalClaimableRedeemAssets(), 0);
        invariants();
    }

    function _min(uint256 x, uint256 y) internal pure returns (uint256) {
        return x < y ? x : y;
    }

}
