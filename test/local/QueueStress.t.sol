// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import "forge-std/Test.sol";

import { ERC20 }        from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import { ERC1967Proxy } from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { SparkVault }      from "spark-vaults-v2/SparkVault.sol";
import { SparkPrimeVault } from "src/SparkPrimeVault.sol";

contract QSUSDC is ERC20("USDC", "USDC") {
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 v) external { _mint(to, v); }
}

/// Long-running deterministic simulation of a busy spPRIME book, checked every round against an
/// independent mirror model (ghost ledger) of both queues, every controller's claimables, the
/// vault's USDC and spUSDC balances, and the solvency invariants. Ends with a full drain and exact
/// per-controller conservation. A second test logs a gas table.
contract QueueStressTest is Test {
    uint256 constant RAY      = 1e27;
    uint256 constant WAD      = 1e18;
    uint256 constant FIVE_PCT = 1.000000001547125957863212448e27;

    uint256[4] VSRS = [
        uint256(1.000000000937303470807876289e27),  // ~3%
        FIVE_PCT,
        uint256(1.000000002440418608258400030e27),  // ~8%
        uint256(1.000000003022265980097387650e27)   // ~10%
    ];

    QSUSDC usdc;
    SparkVault sp;
    SparkPrimeVault v;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave  = makeAddr("dave");
    address op    = makeAddr("op");

    // Copied from test/local/Smoke.t.sol
    function setUp() public {
        usdc = new QSUSDC();

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

    /**********************************************************************************************/
    /*** Simulation parameters and state                                                        ***/
    /**********************************************************************************************/

    uint256 constant N_USERS     = 250;
    uint256 constant ROUNDS      = 180;   // ~6 months of daily rounds
    uint256 constant SLOW_UNTIL  = 40;    // slow claimers go dormant after this round
    uint256 constant PAUSE_ROUND = 90;    // pause + setChi loss, unpause 3 rounds later
    uint256 constant ILLIQ_FROM  = 130;   // spUSDC illiquid (Spark took its cash) for 6 rounds
    uint256 constant ILLIQ_TO    = 136;

    address pau     = makeAddr("pau");      // spPRIME TAKER (Spark's PAU)
    address spTaker = makeAddr("spTaker");  // spUSDC TAKER (makes spUSDC illiquid for a while)
    address cold    = makeAddr("cold");     // third-party receiver for some USDC claims

    address[] users;
    mapping (address => uint256) kind;      // 0 normal, 1 slow, 2 piece, 3 operator
    uint256 seed;
    uint256 seed0;
    uint256 round;
    bool    slowAwake;

    struct E { address c; address o; uint256 amt; uint256 orig; uint256 fee; }

    // Mirror model
    E[]     mDq;
    E[]     mWq;
    uint256 mDh;
    uint256 mWh;
    uint256 checkedDh;
    uint256 checkedWh;
    uint256 mSupply;
    uint256 mTotQDep;
    uint256 mTotQRed;
    uint256 mTotClaimRed;
    uint256 usdcLedger;   // expected USDC.balanceOf(v)
    uint256 spLedger;     // expected spUSDC.balanceOf(v)

    mapping (address => uint256) gPendDep;
    mapping (address => uint256) gMaxDep;
    mapping (address => uint256) gMaxMint;
    mapping (address => uint256) gPendRed;
    mapping (address => uint256) gMaxRed;
    mapping (address => uint256) gMaxWd;

    // Lifetime per-controller accounting
    mapping (address => uint256) gCredShares;   // spPRIME made claimable
    mapping (address => uint256) gCredNet;      // USDC made claimable
    mapping (address => uint256) gRecvShares;   // spPRIME actually delivered
    mapping (address => uint256) gRecvUsdc;     // USDC actually delivered

    // Slow claimer snapshots
    mapping (address => bool)    snapped;
    mapping (address => uint256) snapRound;
    mapping (address => uint256[4]) snap;

    // Stats and dust
    uint256 sDepReq; uint256 sDepFullInstant; uint256 sDepSplit; uint256 sDepQueued;
    uint256 sRedReq; uint256 sRedFullInstant; uint256 sRedPartInstant; uint256 sRedQueued;
    uint256 sCancels; uint256 sCancelsGuardian;
    uint256 sDepFills; uint256 sDepPartials; uint256 sWdFills; uint256 sWdPartials; uint256 sWdZeroNet;
    uint256 sShortfallPulls;
    uint256 sClaims; uint256 sClaimsOp; uint256 sClaimsPiece; uint256 sTransfers;
    uint256 sMaxLiveDq; uint256 sMaxLiveWq; uint256 sProcCalls;
    uint256 sSlowSnapped; uint256 sSlowMaxWait;
    uint256 sSlowEscrow; uint256 sSlowEscrowShares; uint256 sSlowUsdc; uint256 sSlowUsdcAmount;
    uint256 sCapBelowSupply; uint256 sPausedRejects;

    uint256 gDepositedIn;     // USDC pulled by requestDeposit
    uint256 gCancelRefunds;   // USDC refunded on cancel (principal + spUSDC yield)
    uint256 gCredDepAssets;   // USDC value credited to deposits (claimableDepositAssets)
    uint256 gFees;            // gross - net on approvals
    uint256 dustAbsorbed;     // sub-share spUSDC remainders gifted to spUSDC on requestDeposit
    uint256 dustDepFill;      // spUSDC value accepted above credited assets (round-up on fills)
    uint256 dustWdGrossFloor; // shares*chi/RAY floor loss on redeem approvals (upper bound 1 wei/fill)
    uint256 pauYield;         // USDC minted to PAU as off-chain (Arkis) yield
    uint256 topUp;            // USDC Spark added at drain to cover all spPRIME
    uint256 pauSeed;          // USDC Spark's PAU started with
    uint256 spLastChi;
    uint256 spYield;          // spUSDC yield earned on the vault's spUSDC (queued + sleeve)
    uint256 spOps;            // spUSDC share movements (each may round by <= 1 wei of value)

    /**********************************************************************************************/
    /*** Helpers                                                                                ***/
    /**********************************************************************************************/

    function _rnd() internal returns (uint256) {
        seed = uint256(keccak256(abi.encode(seed)));
        return seed;
    }

    function _r(uint256 n) internal returns (uint256) { return _rnd() % n; }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) { return a < b ? a : b; }

    function _divup(uint256 x, uint256 y) internal pure returns (uint256) {
        return x != 0 ? ((x - 1) / y) + 1 : 0;
    }

    function _net(uint256 shares, uint256 fee, uint256 chi_) internal pure returns (uint256) {
        uint256 gross = shares * chi_ / RAY;
        return gross - _divup(gross * fee, WAD);
    }

    function _accrueSp() internal {
        uint256 c = sp.nowChi();
        spYield  += spLedger * (c - spLastChi) / RAY;
        spLastChi = c;
    }

    function _availCap() internal view returns (uint256) {
        uint256 cap = v.maxCapacity();
        return cap > mSupply ? cap - mSupply : 0;
    }

    // Independent re-derivation of availableLiquidAssets from the model's totals
    function _liquid() internal view returns (int256) {
        uint256 free   = sp.balanceOf(address(v)) - mTotQDep;
        uint256 sleeve = _min(sp.convertToAssets(free), usdc.balanceOf(address(sp)));
        return int256(usdc.balanceOf(address(v)) + sleeve) - int256(mTotClaimRed);
    }

    function _capCheck(uint256 supplyBefore) internal view {
        uint256 cap = v.maxCapacity();
        assertLe(v.totalSupply(), cap > supplyBefore ? cap : supplyBefore, "supply > max(cap, before)");
    }

    function _idle() internal view returns (uint256) {
        return usdc.balanceOf(address(v)) - mTotClaimRed;
    }

    // Redemption waves: heavy redeem demand while the PAU sends back little cash
    function _run() internal view returns (bool) {
        return (round >= 45 && round < 85) || (round >= 125 && round < 170);
    }

    function _randUser() internal returns (address) { return users[_r(N_USERS)]; }

    function _activeUser() internal returns (address u) {
        for (uint256 k; k < 8; ++k) {
            u = _randUser();
            if (kind[u] != 1 || round < SLOW_UNTIL) return u;
        }
        return users[2];  // a piece claimer
    }

    // Controller other than owner, never a slow claimer (their claimables must stay frozen)
    function _controllerFor(address o) internal returns (address) {
        if (kind[o] == 1 || _r(10) != 0) return o;
        for (uint256 k; k < 8; ++k) {
            address c = _randUser();
            if (kind[c] != 1) return c;
        }
        return o;
    }

    /**********************************************************************************************/
    /*** Modelled actions                                                                       ***/
    /**********************************************************************************************/

    function _mApproveDep(address c, uint256 assets, uint256 chi_) internal {
        uint256 shares = assets * RAY / chi_;
        mSupply        += shares;
        gMaxDep[c]     += assets;
        gMaxMint[c]    += shares;
        gCredShares[c] += shares;
        gCredDepAssets += assets;
    }

    function _reqDeposit(address o, address c, uint256 assets) internal {
        uint256 chi_         = v.nowChi();
        uint256 supplyBefore = mSupply;
        uint256 instant      = mTotQDep == 0 ? _min(assets, _availCap() * chi_ / RAY) : 0;
        if (instant * RAY / chi_ == 0) instant = 0;
        uint256 rem      = assets - instant;
        uint256 spShares = rem * RAY / sp.nowChi();
        uint256 balBefore = usdc.balanceOf(o);

        vm.prank(o);
        if (_r(4) == 0) v.requestDeposit(assets, c, o, uint16(_r(100)));
        else            v.requestDeposit(assets, c, o);

        if (instant != 0) _mApproveDep(c, instant, chi_);
        usdcLedger   += assets - rem;
        gDepositedIn += assets;
        if (spShares != 0) {
            ++spOps;
            spLedger += spShares;
            mDq.push(E(c, o, spShares, spShares, 0));
            gPendDep[c] += spShares;
            mTotQDep    += spShares;
        } else if (rem != 0) {
            dustAbsorbed += rem;
        }

        ++sDepReq;
        if (rem == 0) ++sDepFullInstant; else if (instant != 0) ++sDepSplit; else ++sDepQueued;

        assertEq(usdc.balanceOf(o), balBefore - assets, "deposit pull");
        _capCheck(supplyBefore);
    }

    function _processDeposit(uint256 maxAssets) internal {
        uint256 chi_         = v.nowChi();
        uint256 spChi        = sp.nowChi();
        uint256 supplyBefore = mSupply;
        uint256 budget       = _min(maxAssets, _availCap() * chi_ / RAY);
        uint256 i            = mDh;
        uint256 skipped;

        for (; i < mDq.length; ++i) {
            E storage r = mDq[i];
            if (r.amt == 0) { if (++skipped == 500) break; continue; }

            uint256 value = sp.convertToAssets(r.amt);
            uint256 a     = _min(value, budget);
            if (a * RAY / chi_ == 0 && a < value) break;

            uint256 sh = _divup(r.amt * a, value);
            gPendDep[r.c] -= sh;
            mTotQDep      -= sh;
            r.amt         -= sh;
            budget        -= a;
            dustDepFill   += sh * spChi / RAY - a;
            _mApproveDep(r.c, a, chi_);
            ++sDepFills;

            if (r.amt != 0) { ++sDepPartials; break; }
        }
        mDh = i;

        vm.prank(admin); v.processDepositQueue(maxAssets);
        ++sProcCalls;
        _capCheck(supplyBefore);
    }

    function _mFillWithdraw(uint256 maxAssets, uint256 chi_) internal {
        int256 liquid = _liquid();
        assertEq(v.availableLiquidAssets(), liquid, "availableLiquidAssets");
        uint256 budget = liquid > 0 ? _min(maxAssets, uint256(liquid)) : 0;
        uint256 i      = mWh;

        for (; i < mWq.length; ++i) {
            E storage r = mWq[i];
            (uint256 sh, uint256 fee) = (r.amt, r.fee);
            if (_net(sh, fee, chi_) > budget) sh = budget * WAD / (WAD - fee) * RAY / chi_;

            uint256 net = _net(sh, fee, chi_);
            if (net == 0 && sh < r.amt) break;

            mSupply        -= sh;
            gPendRed[r.c]  -= sh;
            mTotQRed       -= sh;
            gMaxRed[r.c]   += sh;
            gMaxWd[r.c]    += net;
            gCredNet[r.c]  += net;
            mTotClaimRed   += net;
            r.amt          -= sh;
            budget         -= net;
            gFees          += sh * chi_ / RAY - net;
            if (sh * chi_ % RAY != 0) ++dustWdGrossFloor;
            if (net == 0) ++sWdZeroNet;
            ++sWdFills;

            if (r.amt != 0) { ++sWdPartials; break; }
        }
        mWh = i;

        if (usdcLedger < mTotClaimRed) {
            uint256 s = mTotClaimRed - usdcLedger;
            spLedger   -= _divup(s * RAY, sp.nowChi());
            usdcLedger += s;
            ++sShortfallPulls; ++spOps;
        }
    }

    function _processWithdraw(uint256 maxAssets) internal {
        _mFillWithdraw(maxAssets, v.nowChi());
        vm.prank(admin); v.processWithdrawQueue(maxAssets);
        ++sProcCalls;
    }

    function _reqRedeem(address o, address c, uint256 shares) internal {
        uint256 chi_     = v.nowChi();
        bool    wasEmpty = mTotQRed == 0;
        uint256 idx      = mWq.length;

        mWq.push(E(c, o, shares, shares, v.withdrawFee()));
        gPendRed[c] += shares;
        mTotQRed    += shares;
        if (wasEmpty) _mFillWithdraw(type(uint256).max, chi_);

        vm.prank(o); v.requestRedeem(shares, c, o);

        ++sRedReq;
        if (mWq[idx].amt == 0) ++sRedFullInstant;
        else if (mWq[idx].amt < shares) ++sRedPartInstant;
        else ++sRedQueued;
    }

    function _cancel(uint256 idx, bool asGuardian) internal {
        E storage r = mDq[idx];
        (address c, address o, uint256 amt) = (r.c, r.o, r.amt);
        uint256 refund = amt * sp.nowChi() / RAY;
        if (usdc.balanceOf(address(sp)) < refund) return;  // spUSDC illiquid: cancel would revert

        address caller = asGuardian ? admin : (_r(2) == 0 ? o : c);
        uint256 before = usdc.balanceOf(o);

        gPendDep[c] -= amt;
        mTotQDep    -= amt;
        spLedger    -= amt;
        ++spOps;
        r.amt = 0; r.c = address(0); r.o = address(0);

        vm.prank(caller); v.cancelDepositRequest(idx);

        assertEq(usdc.balanceOf(o) - before, refund, "cancel refund");
        gCancelRefunds += refund;
        ++sCancels;
        if (asGuardian) ++sCancelsGuardian;
    }

    function _claimMint(address caller, address c, uint256 shares) internal {
        uint256 assets = _divup(gMaxDep[c] * shares, gMaxMint[c]);
        uint256 before = v.balanceOf(c);
        gMaxDep[c]  -= assets;
        gMaxMint[c] -= shares;
        uint256 got;
        vm.prank(caller);
        if (caller == c && _r(2) == 0) got = v.mint(shares, c);
        else                           got = v.mint(shares, c, c);
        assertEq(got, assets, "mint assets");
        assertEq(v.balanceOf(c) - before, shares, "mint delivered");
        gRecvShares[c] += shares;
        ++sClaims; if (caller != c) ++sClaimsOp;
    }

    function _claimDeposit(address caller, address c, uint256 assets) internal {
        uint256 shares = gMaxMint[c] * assets / gMaxDep[c];
        uint256 before = v.balanceOf(c);
        gMaxDep[c]  -= assets;
        gMaxMint[c] -= shares;
        uint256 got;
        vm.prank(caller);
        if (caller == c && _r(2) == 0) got = v.deposit(assets, c);
        else                           got = v.deposit(assets, c, c);
        assertEq(got, shares, "deposit shares");
        assertEq(v.balanceOf(c) - before, shares, "deposit delivered");
        gRecvShares[c] += shares;
        ++sClaims; if (caller != c) ++sClaimsOp;
    }

    function _claimWithdraw(address caller, address c, address recv, uint256 assets) internal {
        uint256 shares = _divup(gMaxRed[c] * assets, gMaxWd[c]);
        uint256 before = usdc.balanceOf(recv);
        gMaxRed[c]   -= shares;
        gMaxWd[c]    -= assets;
        mTotClaimRed -= assets;
        usdcLedger   -= assets;
        vm.prank(caller);
        uint256 got = v.withdraw(assets, recv, c);
        assertEq(got, shares, "withdraw shares");
        assertEq(usdc.balanceOf(recv) - before, assets, "withdraw delivered");
        gRecvUsdc[c] += assets;
        ++sClaims; if (caller != c) ++sClaimsOp;
    }

    function _claimRedeem(address caller, address c, address recv, uint256 shares) internal {
        uint256 assets = gMaxWd[c] * shares / gMaxRed[c];
        uint256 before = usdc.balanceOf(recv);
        gMaxRed[c]   -= shares;
        gMaxWd[c]    -= assets;
        mTotClaimRed -= assets;
        usdcLedger   -= assets;
        vm.prank(caller);
        uint256 got = v.redeem(shares, recv, c);
        assertEq(got, assets, "redeem assets");
        assertEq(usdc.balanceOf(recv) - before, assets, "redeem delivered");
        gRecvUsdc[c] += assets;
        ++sClaims; if (caller != c) ++sClaimsOp;
    }

    // Claims everything claimable for `c` (deposit side via mint, redeem side via withdraw)
    function _claimAll(address caller, address c, address recv) internal {
        if (gMaxMint[c] != 0)    _claimMint(caller, c, gMaxMint[c]);
        else if (gMaxDep[c] != 0) _claimDeposit(caller, c, gMaxDep[c]);  // assets-only leftover
        if (gMaxWd[c] != 0)       _claimWithdraw(caller, c, recv, gMaxWd[c]);
        else if (gMaxRed[c] != 0) _claimRedeem(caller, c, recv, gMaxRed[c]);  // zero-net leftover
    }

    // One small piece through one of the four claim functions
    function _claimPiece(address c) internal {
        uint256 k = _r(4);
        if (k < 2 && gMaxMint[c] != 0) {
            if (k == 0 || gMaxDep[c] == 0) _claimMint(c, c, 1 + _r(gMaxMint[c] / 7 + 1) % gMaxMint[c]);
            else                           _claimDeposit(c, c, 1 + _r(gMaxDep[c] / 7 + 1) % gMaxDep[c]);
            ++sClaimsPiece;
        } else if (gMaxRed[c] != 0 || gMaxWd[c] != 0) {
            if ((k == 2 || gMaxWd[c] == 0) && gMaxRed[c] != 0)
                _claimRedeem(c, c, c, 1 + _r(gMaxRed[c] / 7 + 1) % gMaxRed[c]);
            else
                _claimWithdraw(c, c, c, 1 + _r(gMaxWd[c] / 7 + 1) % gMaxWd[c]);
            ++sClaimsPiece;
        }
    }

    /**********************************************************************************************/
    /*** Checks                                                                                 ***/
    /**********************************************************************************************/

    function _checkAll() internal {
        // Queues: mirror equality, everything before head is zero, FIFO (only the head may be partial)
        assertEq(v.depositHead(),  mDh, "depositHead");
        assertEq(v.withdrawHead(), mWh, "withdrawHead");
        for (uint256 i = checkedDh; i < mDh; ++i) {
            (,, uint256 a,) = v.depositQueue(i);
            assertEq(a, 0, "deposit entry before head");
            assertEq(mDq[i].amt, 0);
        }
        for (uint256 i = checkedWh; i < mWh; ++i) {
            (,, uint256 a,) = v.withdrawQueue(i);
            assertEq(a, 0, "withdraw entry before head");
            assertEq(mWq[i].amt, 0);
        }
        (checkedDh, checkedWh) = (mDh, mWh);

        uint256 sum; uint256 live;
        for (uint256 i = mDh; i < mDq.length; ++i) {
            (address c, address o, uint256 a, uint256 f) = v.depositQueue(i);
            E storage r = mDq[i];
            assertEq(a, r.amt, "deposit entry amount");
            assertEq(c, r.c); assertEq(o, r.o); assertEq(f, 0);
            if (i > mDh) assertTrue(a == r.orig || a == 0, "deposit FIFO: filled behind head");
            sum += a; if (a != 0) ++live;
        }
        assertEq(sum, v.totalQueuedDepositShares(), "sum deposit entries");
        assertEq(sum, mTotQDep);
        if (live > sMaxLiveDq) sMaxLiveDq = live;

        sum = 0; live = 0;
        for (uint256 i = mWh; i < mWq.length; ++i) {
            (address c, address o, uint256 a, uint256 f) = v.withdrawQueue(i);
            E storage r = mWq[i];
            assertEq(a, r.amt, "withdraw entry amount");
            assertEq(c, r.c); assertEq(o, r.o); assertEq(f, r.fee);
            if (i > mWh) assertEq(a, r.orig, "withdraw FIFO: filled behind head");
            sum += a; if (a != 0) ++live;
        }
        assertEq(sum, v.totalQueuedRedeemShares(), "sum withdraw entries");
        assertEq(sum, mTotQRed);
        if (live > sMaxLiveWq) sMaxLiveWq = live;

        // Per controller
        uint256 sPD; uint256 sPR; uint256 sMM; uint256 sMW; uint256 sBal;
        for (uint256 k; k < N_USERS; ++k) {
            address u = users[k];
            assertEq(v.pendingDepositShares(u), gPendDep[u], "pendingDepositShares");
            assertEq(v.pendingRedeemShares(u),  gPendRed[u], "pendingRedeemShares");
            assertEq(v.maxDeposit(u),  gMaxDep[u],  "maxDeposit");
            assertEq(v.maxMint(u),     gMaxMint[u], "maxMint");
            assertEq(v.maxRedeem(u),   gMaxRed[u],  "maxRedeem");
            assertEq(v.maxWithdraw(u), gMaxWd[u],   "maxWithdraw");
            sPD += gPendDep[u]; sPR += gPendRed[u]; sMM += gMaxMint[u]; sMW += gMaxWd[u];
            sBal += v.balanceOf(u);

            if (kind[u] == 1) _checkSlow(u);
        }
        assertEq(sPD, v.totalQueuedDepositShares(),   "sum pendingDeposit");
        assertEq(sPR, v.totalQueuedRedeemShares(),    "sum pendingRedeem");
        assertEq(sMW, v.totalClaimableRedeemAssets(), "sum maxWithdraw");
        assertEq(mTotClaimRed, sMW);

        // Escrow, supply, ledgers, solvency
        assertEq(v.balanceOf(address(v)), sMM + v.totalQueuedRedeemShares(), "escrow");
        assertEq(v.totalSupply(), mSupply, "totalSupply");
        assertEq(sBal + v.balanceOf(address(v)), mSupply, "balances sum");
        assertEq(usdc.balanceOf(address(v)), usdcLedger, "USDC ledger");
        assertEq(sp.balanceOf(address(v)),   spLedger,   "spUSDC ledger");
        assertGe(usdc.balanceOf(address(v)), v.totalClaimableRedeemAssets(), "ring-fence");
        assertGe(sp.balanceOf(address(v)),   v.totalQueuedDepositShares(),   "queued spUSDC");
        assertEq(v.availableLiquidAssets(), _liquid(), "liquid");
    }

    function _checkSlow(address u) internal {
        if (round < SLOW_UNTIL || slowAwake) return;
        if (!snapped[u]) {
            if (gPendDep[u] != 0 || gPendRed[u] != 0) return;
            snapped[u]   = true;
            snapRound[u] = round;
            snap[u] = [gMaxDep[u], gMaxMint[u], gMaxRed[u], gMaxWd[u]];
            ++sSlowSnapped;
            if (gMaxMint[u] != 0) { ++sSlowEscrow; sSlowEscrowShares += gMaxMint[u]; }
            if (gMaxWd[u]   != 0) { ++sSlowUsdc;   sSlowUsdcAmount   += gMaxWd[u]; }
            return;
        }
        uint256[4] memory s = snap[u];
        assertEq(v.maxDeposit(u),  s[0], "slow: deposit assets moved");
        assertEq(v.maxMint(u),     s[1], "slow: escrow share count moved");
        assertEq(v.maxRedeem(u),   s[2], "slow: redeem shares moved");
        assertEq(v.maxWithdraw(u), s[3], "slow: approved USDC moved");
        if (round - snapRound[u] > sSlowMaxWait) sSlowMaxWait = round - snapRound[u];
    }

    /**********************************************************************************************/
    /*** Spark's operations                                                                     ***/
    /**********************************************************************************************/

    function _pauReturn(uint256 x) internal {
        x = _min(x, usdc.balanceOf(pau));
        if (x == 0) return;
        vm.prank(pau); usdc.transfer(address(v), x);
        usdcLedger += x;
    }

    function _take(uint256 x) internal {
        if (x == 0) return;
        vm.prank(pau); v.take(x);
        usdcLedger -= x;
    }

    function _toSavings(uint256 x) internal {
        if (x == 0) return;
        spLedger   += x * RAY / sp.nowChi();
        ++spOps;
        usdcLedger -= x;
        vm.prank(admin); v.depositToSavings(x);
    }

    function _fromSavings(uint256 x) internal {
        if (x == 0) return;
        spLedger   -= _divup(x * RAY, sp.nowChi());
        usdcLedger += x;
        ++spOps;
        vm.prank(admin); v.withdrawFromSavings(x);
    }

    // Keep a ~10% spUSDC sleeve; the rest goes to the PAU (Arkis) and trickles back
    function _rebalanceSleeve() internal {
        uint256 target   = v.totalAssets() / 10;
        uint256 free     = sp.balanceOf(address(v)) - mTotQDep;
        uint256 sleeve   = sp.convertToAssets(free);
        uint256 idle     = _idle();

        if (idle != 0) {
            uint256 toSleeve = sleeve < target ? _min(idle, target - sleeve) : 0;
            _toSavings(toSleeve);
            if (_r(3) != 0) _take(idle - toSleeve);
        }
        if (sleeve > target * 12 / 10) {
            uint256 x = _min(sleeve - target, usdc.balanceOf(address(sp)));
            if (x > 1e6) { _fromSavings(x - 1e6); _take(x - 1e6); }
        }

        sleeve = sp.convertToAssets(sp.balanceOf(address(v)) - mTotQDep);
        if (sleeve < target * 8 / 10 && !_run()) {
            uint256 before = usdc.balanceOf(address(v));
            _pauReturn(_min(target - sleeve, 20_000e6 + _r(40_000e6)));
            _toSavings(usdc.balanceOf(address(v)) - before);
        }
    }

    function _adminRound() internal {
        // Capacity: weekly raises, occasionally cut below supply
        if (round == 40 || round == 120) {
            vm.prank(admin); v.setCapacity(mSupply * 95 / 100);
            ++sCapBelowSupply;
        } else if (round == 47 || round == 127) {
            vm.prank(admin); v.setCapacity(mSupply + 200_000e6);
        } else if (round % 7 == 3 && !(round > 40 && round < 47) && !(round > 120 && round < 127)) {
            uint256 newCap = v.maxCapacity() + 80_000e6 + _r(150_000e6);
            vm.prank(admin); v.setCapacity(newCap);
        }
        if (round % 30 == 15) { vm.prank(admin); v.setVsr(VSRS[_r(4)]); }
        if (round % 45 == 20) { vm.prank(admin); sp.setVsr(VSRS[_r(3)]); }
        if (round % 20 == 7)  { vm.prank(admin); v.setWithdrawFee(_r(0.01e18 + 1)); }
        if (round % 50 == 25) { vm.prank(admin); v.setMinimums(100e6 + _r(100e6), 50e6 + _r(50e6)); }

        if (round == ILLIQ_FROM) {
            uint256 bal = usdc.balanceOf(address(sp));
            vm.prank(spTaker); sp.take(bal - 30_000e6);
        }
        if (round == ILLIQ_TO) {
            uint256 bal = usdc.balanceOf(spTaker);
            vm.prank(spTaker); usdc.transfer(address(sp), bal);
        }
    }

    /**********************************************************************************************/
    /*** One round                                                                              ***/
    /**********************************************************************************************/

    function _usersRound(bool isPaused) internal {
        if (!isPaused) {
            uint256 nDep = _run() && round < 100 ? 3 + _r(5) : 10 + _r(12);
            for (uint256 k; k < nDep; ++k) {
                address o = _activeUser();
                uint256 a = 100e6 + _r(12_000e6);
                if (_r(10) == 0) a *= 8;
                if (a < v.minDeposit()) a = v.minDeposit();
                _reqDeposit(o, _controllerFor(o), a);
            }
            uint256 nRed = _run() ? 20 + _r(15) : 5 + _r(8);
            for (uint256 k; k < nRed; ++k) {
                address o = _activeUser();
                uint256 b = v.balanceOf(o);
                if (b == 0) continue;
                uint256 sh = _r(_run() ? 2 : 6) == 0 ? b : b * (5 + _r(65)) / 100;
                if (sh == 0 || sh * v.nowChi() / RAY < v.minWithdraw()) continue;
                _reqRedeem(o, _controllerFor(o), sh);
            }
        }

        // Cancels (works while paused); guardian compliance cancels sometimes
        uint256 nCancel = _r(6);
        for (uint256 k; k < nCancel && mDq.length > mDh; ++k) {
            uint256 idx = mDh + _r(mDq.length - mDh);
            if (mDq[idx].amt == 0) continue;
            address o = mDq[idx].o;
            if (kind[o] == 1 || kind[mDq[idx].c] == 1) continue;  // slow claimers keep theirs
            _cancel(idx, _r(5) == 0);
        }

        // spPRIME transfers between active users
        for (uint256 k; k < 3; ++k) {
            address from = _randUser(); address to = _randUser();
            if (kind[from] == 1 || kind[to] == 1 || from == to) continue;
            uint256 b = v.balanceOf(from);
            if (b == 0) continue;
            uint256 x = b / (2 + _r(5));
            vm.prank(from); v.transfer(to, x);
            ++sTransfers;
        }

        // Claims by behaviour
        for (uint256 k; k < N_USERS; ++k) {
            address u = users[k];
            uint256 t = kind[u];
            if (t == 1) {
                if (round == 20) _claimAll(u, u, u);  // claim once to get a balance to redeem
                continue;
            }
            if (t == 2) { _claimPiece(u); if (_r(2) == 0) _claimPiece(u); continue; }
            if (_r(5) >= 2) continue;
            if (t == 3) _claimAll(op, u, u);
            else        _claimAll(u, u, _r(6) == 0 ? cold : u);
        }
    }

    function _plannerRound(bool isPaused) internal {
        // PAU sends some cash back for the redeem queue (plain transfer, no price impact)
        if (mTotQRed != 0) _pauReturn(_run() ? _r(40_000e6) : 50_000e6 + _r(250_000e6));

        if (!isPaused) {
            // Lucas's loop: redeem with a budget -> frees capacity -> deposits -> redeem again
            // In redemption waves Spark rate-limits approvals to what it wants to release per day
            bool w = _run();
            _processWithdraw(w ? _r(60_000e6) : _r(3) == 0 ? type(uint256).max : _r(150_000e6));
            _processDeposit(_r(4) == 0 ? _r(200_000e6) : type(uint256).max);
            _processWithdraw(w ? _r(40_000e6) : _r(2) == 0 ? type(uint256).max : _r(80_000e6));
        }

        // PAU grows its USDC off-chain at ~7% APY
        uint256 y = usdc.balanceOf(pau) * 7 / 100 / 365;
        usdc.mint(pau, y); pauYield += y;

        if (round < ILLIQ_FROM || round >= ILLIQ_TO) _rebalanceSleeve();
    }

    function _pauseEpisode() internal {
        vm.startPrank(admin);
        v.pause();
        v.setChi(v.nowChi() * 97 / 100);  // 3% loss
        vm.stopPrank();

        address u = users[3];
        vm.prank(u); vm.expectRevert("SparkPrimeVault/paused"); v.requestDeposit(1000e6, u, u);
        vm.prank(u); vm.expectRevert("SparkPrimeVault/paused"); v.requestRedeem(1, u, u);
        vm.prank(admin); vm.expectRevert("SparkPrimeVault/paused"); v.processDepositQueue(1);
        vm.prank(admin); vm.expectRevert("SparkPrimeVault/paused"); v.processWithdrawQueue(1);
        sPausedRejects += 4;
    }

    /**********************************************************************************************/
    /*** Drain and conservation                                                                 ***/
    /**********************************************************************************************/

    function _drain() internal {
        if (v.paused()) { vm.prank(admin); v.unpause(); }
        vm.startPrank(admin);
        v.setCapacity(1e30);
        v.setMinimums(0, 0);
        vm.stopPrank();
        if (usdc.balanceOf(spTaker) != 0) {
            uint256 bal = usdc.balanceOf(spTaker);
            vm.prank(spTaker); usdc.transfer(address(sp), bal);
        }

        // Slow claimers: last check before they wake up
        round = ROUNDS;
        _checkAll();

        // 1. Empty the deposit queue
        for (uint256 k; mTotQDep != 0 || mDh < mDq.length; ++k) {
            _processDeposit(type(uint256).max);
            require(k < 20, "deposit queue does not drain");
        }
        _checkAll();

        // 2. Everyone claims their deposits; then all spPRIME is redeemed
        slowAwake = true;
        for (uint256 k; k < N_USERS; ++k) {
            address u = users[k];
            if (gMaxMint[u] != 0)     _claimMint(u, u, gMaxMint[u]);
            else if (gMaxDep[u] != 0) _claimDeposit(u, u, gMaxDep[u]);
        }

        // 3. Spark brings all USDC home (PAU + top-up if needed)
        _pauReturn(usdc.balanceOf(pau));
        int256 liq  = _liquid();
        uint256 need = v.totalAssets() + 1e6;
        if (liq < int256(need)) {
            uint256 x = need - uint256(liq);
            usdc.mint(pau, x); topUp = x;
            _pauReturn(x);
        }

        for (uint256 k; k < N_USERS; ++k) {
            address u = users[k];
            uint256 b = v.balanceOf(u);
            if (b != 0) _reqRedeem(u, u, b);
        }
        for (uint256 k; mTotQRed != 0; ++k) {
            _processWithdraw(type(uint256).max);
            require(k < 20, "withdraw queue does not drain");
        }
        _checkAll();

        // 4. Everyone (slow claimers included) claims everything
        for (uint256 k; k < N_USERS; ++k) {
            address u = users[k];
            _claimAll(kind[u] == 3 ? op : u, u, u);
        }
        _checkAll();
    }

    function _finalAssertions() internal view {
        for (uint256 k; k < N_USERS; ++k) {
            address u = users[k];
            assertEq(v.maxDeposit(u) + v.maxMint(u) + v.maxRedeem(u) + v.maxWithdraw(u), 0, "leftover claimable");
            assertEq(v.pendingDepositShares(u) + v.pendingRedeemShares(u), 0, "leftover pending");
            assertEq(gRecvShares[u], gCredShares[u], "spPRIME delivered == credited");
            assertEq(gRecvUsdc[u],   gCredNet[u],    "USDC delivered == credited net");
            assertEq(v.balanceOf(u), 0, "user still holds spPRIME");
        }
        assertEq(v.totalSupply(), 0, "supply left");
        assertEq(v.balanceOf(address(v)), 0, "escrow left");
        assertEq(v.totalClaimableRedeemAssets(), 0);
        assertEq(v.totalQueuedDepositShares(), 0);
        assertEq(v.totalQueuedRedeemShares(), 0);
        assertEq(usdc.balanceOf(address(v)), usdcLedger, "USDC ledger");
        assertEq(sp.balanceOf(address(v)),   spLedger,   "spUSDC ledger");
    }

    // Spark's end equity must equal what it put in, plus what users left behind, plus spUSDC
    // yield on the vault's spUSDC: everything in the vault at the end is Spark's.
    function _moneyIdentity() internal returns (int256 diff) {
        uint256 recv;
        for (uint256 k; k < N_USERS; ++k) recv += gRecvUsdc[users[k]];
        sparkFinal = usdc.balanceOf(address(v)) + sp.convertToAssets(sp.balanceOf(address(v)))
            + usdc.balanceOf(pau);
        uint256 expected = pauSeed + pauYield + topUp + gDepositedIn + spYield
            - recv - gCancelRefunds - dustAbsorbed;
        diff = int256(sparkFinal) - int256(expected);
        moneyDiff = diff;
        sparkProfit = int256(sparkFinal) - int256(pauSeed + pauYield + topUp);
        assertLe(diff < 0 ? uint256(-diff) : uint256(diff), 2 * spOps + ROUNDS, "money identity");
    }

    int256  moneyDiff;
    int256  sparkProfit;
    uint256 sparkFinal;

    function _report() internal view {
        console2.log("=== QueueStress simulation, seed", seed0);
        console2.log("users / rounds (days)        :", N_USERS, ROUNDS);
        console2.log("deposit requests             :", sDepReq);
        console2.log("  fully instant / split / queued:", sDepFullInstant, sDepSplit, sDepQueued);
        console2.log("redeem requests              :", sRedReq);
        console2.log("  fully instant / part / queued :", sRedFullInstant, sRedPartInstant, sRedQueued);
        console2.log("cancels (of which guardian)  :", sCancels, sCancelsGuardian);
        console2.log("deposit fills / partial heads:", sDepFills, sDepPartials);
        console2.log("redeem fills / partial heads :", sWdFills, sWdPartials);
        console2.log("redeem fills with zero net   :", sWdZeroNet);
        console2.log("spUSDC shortfall pulls       :", sShortfallPulls);
        console2.log("process calls                :", sProcCalls);
        console2.log("claims (operator / piece)    :", sClaims, sClaimsOp, sClaimsPiece);
        console2.log("spPRIME transfers            :", sTransfers);
        console2.log("max live deposit entries     :", sMaxLiveDq);
        console2.log("max live withdraw entries    :", sMaxLiveWq);
        console2.log("deposit / withdraw queue len :", mDq.length, mWq.length);
        console2.log("slow claimers frozen / max wait (rounds):", sSlowSnapped, sSlowMaxWait);
        console2.log("  with frozen deposit escrow (count, shares):", sSlowEscrow, sSlowEscrowShares);
        console2.log("  with frozen approved USDC  (count, USDC)  :", sSlowUsdc, sSlowUsdcAmount);
        console2.log("--- money (USDC, 6 dp, raw units) ---");
        console2.log("USDC deposited               :", gDepositedIn);
        console2.log("USDC refunded on cancel      :", gCancelRefunds);
        console2.log("deposit assets credited      :", gCredDepAssets);
        console2.log("withdraw fees kept by Spark  :", gFees);
        console2.log("PAU off-chain yield minted   :", pauYield);
        console2.log("Spark top-up at drain        :", topUp);
        console2.log("--- dust ---");
        console2.log("sub-share remainder gifted to spUSDC:", dustAbsorbed);
        console2.log("deposit fill round-up (spUSDC value > credited):", dustDepFill);
        console2.log("redeem approvals with gross floor (<=1 wei each):", dustWdGrossFloor);
        console2.log("--- vault end state (all Spark's) ---");
        console2.log("vault USDC                   :", usdc.balanceOf(address(v)));
        console2.log("vault spUSDC shares / value  :", sp.balanceOf(address(v)), sp.convertToAssets(sp.balanceOf(address(v))));
        console2.log("PAU USDC                     :", usdc.balanceOf(pau));
        console2.log("spUSDC yield on vault's spUSDC:", spYield);
        console2.log("Spark final equity (vault USDC + spUSDC value + PAU):", sparkFinal);
        console2.log("Spark profit over seed + PAU yield + top-up (signed):", sparkProfit);
        console2.log("money identity residual (signed wei):", moneyDiff);
        console2.log("spUSDC share movements       :", spOps);
    }

    /**********************************************************************************************/
    /*** Tests                                                                                  ***/
    /**********************************************************************************************/

    function test_stress_busyBookSixMonths() public {
        _runSim(0x5bA4C);
    }

    function test_stress_busyBookSixMonths_otherSeed() public {
        _runSim(0xC0FFEE);
    }

    function _runSim(uint256 seed_) internal {
        vm.pauseGasMetering();
        seed = seed_; seed0 = seed_;

        vm.startPrank(admin);
        sp.grantRole(sp.TAKER_ROLE(), spTaker);
        v.grantRole(v.TAKER_ROLE(), pau);
        v.setCapacity(2_000_000e6);
        vm.stopPrank();

        for (uint256 i; i < N_USERS; ++i) {
            address u = makeAddr(string.concat("user", vm.toString(i)));
            users.push(u);
            uint256 t = i % 10;
            kind[u] = t == 0 ? 1 : t == 1 ? 2 : t == 2 ? 3 : 0;
            usdc.mint(u, 5_000_000e6);
            vm.prank(u); usdc.approve(address(v), type(uint256).max);
            if (kind[u] == 3) { vm.prank(u); v.setOperator(op, true); }
        }
        usdc.mint(pau, 500_000e6);
        pauSeed   = 500_000e6;
        spLastChi = sp.nowChi();

        for (round = 0; round < ROUNDS; ++round) {
            vm.warp(block.timestamp + 20 hours + _r(8 hours));
            _accrueSp();

            _adminRound();
            if (round == PAUSE_ROUND) _pauseEpisode();
            if (round == PAUSE_ROUND + 3) { vm.prank(admin); v.unpause(); }
            bool isPaused = v.paused();

            _usersRound(isPaused);
            _plannerRound(isPaused);
            _checkAll();
        }

        _drain();
        _finalAssertions();
        _moneyIdentity();
        _report();
    }

    /**********************************************************************************************/
    /*** Gas                                                                                    ***/
    /**********************************************************************************************/

    function _gasUser(uint256 i) internal returns (address u) {
        u = address(uint160(0xA11CE0000 + i));
        usdc.mint(u, 1_000_000e6);
        vm.prank(u); usdc.approve(address(v), type(uint256).max);
    }

    function _coolAll() internal {
        vm.cool(address(v)); vm.cool(address(sp)); vm.cool(address(usdc));
    }

    function _gasDepositQueue(uint256 n) internal returns (uint256 total) {
        uint256 snapId = vm.snapshotState();
        vm.prank(admin); v.setCapacity(0);
        for (uint256 i; i < n; ++i) {
            address u = _gasUser(i);
            vm.prank(u); v.requestDeposit(1000e6, u, u);
        }
        vm.warp(block.timestamp + 1 days);
        vm.prank(admin); v.setCapacity(1e30);
        _coolAll();
        vm.prank(admin);
        uint256 g = gasleft();
        v.processDepositQueue(type(uint256).max);
        total = g - gasleft();
        assertEq(v.depositHead(), n);
        vm.revertToState(snapId);
    }

    function _gasWithdrawQueue(uint256 n) internal returns (uint256 total) {
        uint256 snapId = vm.snapshotState();
        address[] memory us = new address[](n);
        for (uint256 i; i < n; ++i) {
            address u = _gasUser(i);
            us[i] = u;
            vm.startPrank(u);
            v.requestDeposit(1000e6, u, u);
            v.mint(v.maxMint(u), u);
            vm.stopPrank();
        }
        uint256 cash = usdc.balanceOf(address(v));
        vm.prank(admin); v.take(cash);
        for (uint256 i; i < n; ++i) {
            uint256 b = v.balanceOf(us[i]);
            vm.prank(us[i]); v.requestRedeem(b, us[i], us[i]);
        }
        vm.warp(block.timestamp + 1 days);
        vm.prank(admin); usdc.transfer(address(v), cash);
        _coolAll();
        vm.prank(admin);
        uint256 g = gasleft();
        v.processWithdrawQueue(type(uint256).max);
        total = g - gasleft();
        assertEq(v.withdrawHead(), n);
        vm.revertToState(snapId);
    }

    function _gasInstantRedeem(bool fromSleeve) internal returns (uint256 used) {
        uint256 snapId = vm.snapshotState();
        address u = _gasUser(9999);
        vm.startPrank(u);
        v.requestDeposit(10_000e6, u, u);
        v.mint(v.maxMint(u), u);
        vm.stopPrank();
        if (fromSleeve) { vm.prank(admin); v.depositToSavings(10_000e6); }
        vm.warp(block.timestamp + 1 days);
        uint256 sh = v.balanceOf(u) / 2;
        _coolAll();
        vm.prank(u);
        uint256 g = gasleft();
        v.requestRedeem(sh, u, u);
        used = g - gasleft();
        assertEq(v.totalQueuedRedeemShares(), 0, "not fully instant");
        vm.revertToState(snapId);
    }

    function _gasInstantDeposit() internal returns (uint256 used) {
        address u = _gasUser(8888);
        _coolAll();
        vm.prank(u);
        uint256 g = gasleft();
        v.requestDeposit(1000e6, u, u);
        used = g - gasleft();
    }

    function test_gas_queueProcessing() public {
        uint256[3] memory sizes = [uint256(50), 200, 500];
        console2.log("=== gas (cold storage per call; per-entry = total / entries) ===");
        console2.log("entries | processDepositQueue total, per entry | processWithdrawQueue total, per entry");
        for (uint256 k; k < 3; ++k) {
            uint256 n  = sizes[k];
            uint256 gd = _gasDepositQueue(n);
            uint256 gw = _gasWithdrawQueue(n);
            console2.log(string.concat(
                vm.toString(n), " | ", vm.toString(gd), ", ", vm.toString(gd / n),
                " | ", vm.toString(gw), ", ", vm.toString(gw / n)
            ));
        }
        console2.log("requestRedeem fully instant, idle USDC     :", _gasInstantRedeem(false));
        console2.log("requestRedeem fully instant, spUSDC sleeve :", _gasInstantRedeem(true));
        console2.log("requestDeposit fully instant (reference)   :", _gasInstantDeposit());
    }
}
