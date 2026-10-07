// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import { ERC20 }        from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import { ERC1967Proxy } from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { SparkVault }      from "spark-vaults-v2/SparkVault.sol";
import { SparkPrimeVault } from "src/SparkPrimeVault.sol";

contract USDC2 is ERC20("USDC", "USDC") {
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 v) external { _mint(to, v); }
}

contract Handler is Test {
    USDC2 usdc; SparkVault sp; SparkPrimeVault v; address admin;
    address[3] public users;
    uint256 public paid; uint256 public owedLost;
    constructor(USDC2 u, SparkVault s, SparkPrimeVault vv, address a) {
        usdc = u; sp = s; v = vv; admin = a;
        users = [makeAddr("u0"), makeAddr("u1"), makeAddr("u2")];
        for (uint256 i; i < 3; ++i) {
            usdc.mint(users[i], 1e15);
            vm.prank(users[i]); usdc.approve(address(v), type(uint256).max);
        }
    }
    function _u(uint256 s) internal view returns (address) { return users[s % 3]; }
    function reqDep(uint256 s, uint256 a, uint256 c) external {
        a = bound(a, 100e6, 1e9 * 1e6);
        address u = _u(s);
        vm.prank(u); try v.requestDeposit(a, _u(c), u) {} catch {}
    }
    function claimDep(uint256 s, uint256 frac) external {
        address u = _u(s); uint256 m = v.maxMint(u); if (m == 0) return;
        m = bound(frac, 1, m);
        vm.prank(u); v.mint(m, u);
    }
    function claimDepAssets(uint256 s, uint256 frac) external {
        address u = _u(s); uint256 m = v.maxDeposit(u); if (m == 0) return;
        m = bound(frac, 1, m);
        vm.prank(u); try v.deposit(m, u) {} catch {}
    }
    function reqRed(uint256 s, uint256 sh, uint256 c) external {
        address u = _u(s); uint256 b = v.balanceOf(u); if (b == 0) return;
        sh = bound(sh, 1, b);
        if (sh * v.nowChi() / 1e27 < 50e6) return;
        vm.prank(u); v.requestRedeem(sh, _u(c), u);
    }
    function claimRed(uint256 s, uint256 frac, bool useW) external {
        address u = _u(s);
        if (useW) { uint256 m = v.maxWithdraw(u); if (m == 0) return; m = bound(frac, 1, m);
            vm.prank(u); v.withdraw(m, u, u); }
        else { uint256 m = v.maxRedeem(u); if (m == 0) return; m = bound(frac, 1, m);
            vm.prank(u); v.redeem(m, u, u); }
    }
    function cancel(uint256 idx, bool guardian) external {
        uint256 n = v.depositHead();
        (,,uint256 l) = (0,0,0);
        try v.depositQueue(idx % 50) returns (address c, address o, uint256 amt, uint256) {
            if (amt == 0) return;
            vm.prank(guardian ? admin : o); v.cancelDepositRequest(idx % 50);
        } catch {}
        n; l;
    }
    function procDep(uint256 m) external { vm.prank(admin); v.processDepositQueue(bound(m, 0, 1e16)); }
    function procWd(uint256 m) external { vm.prank(admin); v.processWithdrawQueue(bound(m, 0, 1e16)); }
    function take(uint256 m) external {
        uint256 idle = usdc.balanceOf(address(v)) - v.totalClaimableRedeemAssets();
        if (idle == 0) return; vm.prank(admin); v.take(bound(m, 1, idle));
    }
    function toSav(uint256 m) external {
        uint256 idle = usdc.balanceOf(address(v)) - v.totalClaimableRedeemAssets();
        if (idle == 0) return; vm.prank(admin); v.depositToSavings(bound(m, 1, idle));
    }
    function fromSav(uint256 m) external { vm.prank(admin); try v.withdrawFromSavings(bound(m, 1, 1e15)) {} catch {} }
    function giveBack(uint256 m) external { usdc.mint(address(v), bound(m, 0, 1e13)); }
    function warp(uint256 t) external { vm.warp(block.timestamp + bound(t, 0, 30 days)); }
    function cap(uint256 c) external { vm.prank(admin); v.setCapacity(bound(c, 0, 1e16)); }
    function chiCut(uint256 c) external {
        vm.startPrank(admin); v.pause();
        uint256 ch = v.nowChi(); c = bound(c, ch / 2, ch - 1);
        v.setChi(c); v.unpause(); vm.stopPrank();
    }
    function fee(uint256 f) external { vm.prank(admin); v.setWithdrawFee(bound(f, 0, 0.01e18)); }
}

contract Inv is Test {
    USDC2 usdc; SparkVault sp; SparkPrimeVault v; Handler h;
    address admin = makeAddr("admin");
    function setUp() public {
        usdc = new USDC2();
        sp = SparkVault(address(new ERC1967Proxy(address(new SparkVault()),
            abi.encodeCall(SparkVault.initialize, (address(usdc), "spUSDC", "spUSDC", admin)))));
        v = SparkPrimeVault(address(new ERC1967Proxy(address(new SparkPrimeVault()),
            abi.encodeCall(SparkPrimeVault.initialize, (address(usdc), address(sp), "spPRIME", "spPRIME", admin)))));
        vm.startPrank(admin);
        sp.setDepositCap(1e30); sp.grantRole(sp.SETTER_ROLE(), admin);
        sp.setVsrBounds(1e27, sp.MAX_VSR()); sp.setVsr(1.000000001547125957863212448e27);
        v.grantRole(v.SETTER_ROLE(), admin); v.grantRole(v.TAKER_ROLE(), admin);
        v.grantRole(v.REBALANCER_ROLE(), admin); v.grantRole(v.RISK_MANAGER_ROLE(), admin);
        v.grantRole(v.GUARDIAN_ROLE(), admin); v.grantRole(v.UNPAUSER_ROLE(), admin);
        v.setCapacity(5e12); v.setMaxWithdrawFee(0.01e18); v.setWithdrawFee(0.005e18);
        v.setMinimums(100e6, 50e6); v.setVsrBounds(1e27, v.MAX_VSR()); v.setVsr(1.000000003e27);
        vm.stopPrank();
        usdc.mint(address(sp), 1e14);
        h = new Handler(usdc, sp, v, admin);
        targetContract(address(h));
    }
    function invariant_solvency() public view {
        assertGe(usdc.balanceOf(address(v)), v.totalClaimableRedeemAssets(), "ring-fence");
        assertGe(sp.balanceOf(address(v)), v.totalQueuedDepositShares(), "queued spUSDC");
        assertEq(v.balanceOf(address(v)), v.maxMint(h.users(0)) + v.maxMint(h.users(1)) + v.maxMint(h.users(2)) + v.totalQueuedRedeemShares(), "escrow");
        assertGe(v.availableLiquidAssets(), 0);
    }
}
