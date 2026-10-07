// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";

import { ERC1967Proxy } from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 }       from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { Ethereum } from "spark-address-registry/Ethereum.sol";

import { SparkPrimeVault } from "src/SparkPrimeVault.sol";

interface ISparkVaultLike {
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function balanceOf(address owner) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function depositCap() external view returns (uint256);
    function getRoleMember(bytes32 role, uint256 index) external view returns (address);
    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);
    function setDepositCap(uint256 newCap) external;
    function totalAssets() external view returns (uint256);
}

contract SparkPrimeVaultForkTest is Test {

    struct VaultState {
        uint256 totalSupply;
        uint256 usdc;                    // USDC held by the vault
        uint256 spUsdc;                  // spUSDC shares held by the vault
        uint256 claimableDepositShares;  // spPRIME escrowed for approved deposits
        uint256 claimableRedeemAssets;   // USDC ring-fenced for approved redeems
        uint256 queuedDepositShares;     // spUSDC held for queued deposits
        uint256 queuedRedeemShares;      // spPRIME escrowed for queued redeems
    }

    struct UserState {
        uint256 usdc;
        uint256 shares;                  // spPRIME held
        uint256 claimableDepositAssets;
        uint256 claimableDepositShares;
        uint256 pendingDepositShares;    // spUSDC shares
        uint256 pendingRedeemShares;
        uint256 claimableRedeemShares;
        uint256 claimableRedeemAssets;
    }

    uint256 constant RAY = 1e27;
    uint256 constant WAD = 1e18;

    uint256 constant FIVE_PCT    = 1.000000001547125957863212448e27;
    uint256 constant CAPACITY    = 10_000e6;
    uint256 constant MIN_DEPOSIT = 100e6;
    uint256 constant MIN_REDEEM  = 50e6;
    uint256 constant FEE         = 0.005e18;
    uint256 constant MAX_FEE     = 0.01e18;

    address constant ADMIN = Ethereum.SPARK_PROXY;

    IERC20          constant usdc   = IERC20(Ethereum.USDC);
    ISparkVaultLike constant spUsdc = ISparkVaultLike(Ethereum.SPARK_VAULT_V2_SPUSDC);

    address guardian    = makeAddr("guardian");
    address rebalancer  = makeAddr("rebalancer");
    address riskManager = makeAddr("riskManager");
    address setter      = makeAddr("setter");
    address taker       = makeAddr("taker");  // The PAU
    address unpauser    = makeAddr("unpauser");

    address alice    = makeAddr("alice");
    address bob      = makeAddr("bob");
    address carol    = makeAddr("carol");
    address dave     = makeAddr("dave");
    address operator = makeAddr("operator");

    SparkPrimeVault vault;

    VaultState                    v;  // Expected vault state
    mapping(address => UserState) u;  // Expected user state

    function setUp() public {
        vm.createSelectFork(getChain("mainnet").rpcUrl, 26132838);

        vault = SparkPrimeVault(address(new ERC1967Proxy(
            address(new SparkPrimeVault()),
            abi.encodeCall(
                SparkPrimeVault.initialize,
                (address(usdc), address(spUsdc), "Spark Prime USDC", "spPRIME", ADMIN)
            )
        )));
        vm.label(address(vault), "spPRIME");
        vm.label(address(spUsdc), "spUSDC");

        vm.startPrank(ADMIN);
        vault.grantRole(vault.GUARDIAN_ROLE(),     guardian);
        vault.grantRole(vault.REBALANCER_ROLE(),   rebalancer);
        vault.grantRole(vault.RISK_MANAGER_ROLE(), riskManager);
        vault.grantRole(vault.SETTER_ROLE(),       setter);
        vault.grantRole(vault.TAKER_ROLE(),        taker);
        vault.grantRole(vault.UNPAUSER_ROLE(),     unpauser);

        vault.setVsrBounds(RAY, vault.MAX_VSR());
        vault.setCapacity(CAPACITY);
        vault.setMinimums(MIN_DEPOSIT, MIN_REDEEM);
        vault.setMaxWithdrawFee(MAX_FEE);
        vm.stopPrank();

        vm.prank(setter);
        vault.setVsr(FIVE_PCT);

        vm.prank(riskManager);
        vault.setWithdrawFee(FEE);

        // Make room under spUSDC's deposit cap for the whole test (incl. 30 days of its accrual)
        uint256 cap = spUsdc.totalAssets() * 11 / 10 + 1_000_000e6;
        if (spUsdc.depositCap() < cap) {
            vm.prank(spUsdc.getRoleMember(spUsdc.DEFAULT_ADMIN_ROLE(), 0));
            spUsdc.setDepositCap(cap);
        }

        // The vault's spUSDC moves must not depend on how much liquidity the ALM left in spUSDC
        if (usdc.balanceOf(address(spUsdc)) < 100_000e6) {
            deal(address(usdc), address(spUsdc), 100_000e6);
        }
    }

    function test_e2e() external {
        _check();

        /*** 1. Instant deposit within capacity, price locked at chi = RAY ***/

        _requestDeposit(alice, 4_000e6);

        v.totalSupply            = 4_000e6;
        v.usdc                   = 4_000e6;
        v.claimableDepositShares = 4_000e6;

        u[alice].claimableDepositAssets = 4_000e6;
        u[alice].claimableDepositShares = 4_000e6;
        _check();

        /*** 2. Claim via mint (the PAU's maxMint + mint path) ***/

        vm.prank(alice);
        assertEq(vault.mint(4_000e6, alice), 4_000e6);

        v.claimableDepositShares = 0;

        u[alice].shares                 = 4_000e6;
        u[alice].claimableDepositAssets = 0;
        u[alice].claimableDepositShares = 0;
        _check();

        /*** 3. Deposit overflowing capacity: 6,000 instant, 1,000 queued in spUSDC ***/

        uint256 bobQueued = spUsdc.convertToShares(1_000e6);

        _requestDeposit(bob, 7_000e6);

        v.totalSupply            = 10_000e6;
        v.usdc                   = 10_000e6;
        v.spUsdc                 = bobQueued;
        v.claimableDepositShares = 6_000e6;
        v.queuedDepositShares    = bobQueued;

        u[bob].claimableDepositAssets = 6_000e6;
        u[bob].claimableDepositShares = 6_000e6;
        u[bob].pendingDepositShares   = bobQueued;
        _check();

        assertEq(vault.availableCapacity(), 0);
        assertEq(vault.pendingDepositRequest(0, bob), spUsdc.convertToAssets(bobQueued));
        assertApproxEqAbs(vault.pendingDepositRequest(0, bob), 1_000e6, 2);

        /*** 4. Fully queued deposits (queue non-empty): carol keeps hers, dave's is cancelled ***/

        uint256 carolQueued = spUsdc.convertToShares(2_000e6);
        uint256 daveQueued  = spUsdc.convertToShares(500e6);

        _requestDeposit(carol, 2_000e6);
        _requestDeposit(dave,  500e6);

        v.spUsdc              += carolQueued + daveQueued;
        v.queuedDepositShares += carolQueued + daveQueued;

        u[carol].pendingDepositShares = carolQueued;
        u[dave].pendingDepositShares  = daveQueued;
        _check();

        /*** 5. 30 days pass: spPRIME accrues 5% APY, queued spUSDC accrues spUSDC's rate ***/

        skip(30 days);

        uint256 chi = vault.nowChi();
        assertApproxEqRel(chi, 1.004018201891974921e27, 1e9);  // 1.05 ** (30 / 365)
        assertEq(vault.totalAssets(),    10_000e6 * chi / RAY);
        assertEq(vault.assetsOf(alice),  4_000e6  * chi / RAY);

        /*** 6. Compliance cancel of dave's queued deposit: refund incl. spUSDC yield to owner ***/

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.cancelDepositRequest(2);

        uint256 refund = spUsdc.convertToAssets(daveQueued);
        assertGt(refund, 500e6);

        vm.prank(guardian);
        vault.cancelDepositRequest(2);

        v.spUsdc              -= daveQueued;
        v.queuedDepositShares -= daveQueued;

        u[dave].usdc                 = refund;
        u[dave].pendingDepositShares = 0;
        _check();

        /*** 7. Raise capacity and process the deposit queue: partial, then full ***/

        vm.prank(ADMIN);
        vault.setCapacity(20_000e6);

        {
            uint256 accepted = _divup(bobQueued * 500e6, spUsdc.convertToAssets(bobQueued));
            uint256 minted   = 500e6 * RAY / chi;

            vm.prank(rebalancer);
            vault.processDepositQueue(500e6);

            v.totalSupply            += minted;
            v.claimableDepositShares += minted;
            v.queuedDepositShares    -= accepted;  // Reclassified as free sleeve, not redeemed

            u[bob].claimableDepositAssets += 500e6;
            u[bob].claimableDepositShares += minted;
            u[bob].pendingDepositShares   -= accepted;
            _check();

            assertEq(vault.depositHead(), 0);  // Partially filled head stays in place
        }
        {
            uint256 bobRest     = spUsdc.convertToAssets(u[bob].pendingDepositShares);
            uint256 carolValue  = spUsdc.convertToAssets(carolQueued);
            uint256 bobMinted   = bobRest    * RAY / chi;
            uint256 carolMinted = carolValue * RAY / chi;

            vm.prank(rebalancer);
            vault.processDepositQueue(type(uint256).max);

            v.totalSupply            += bobMinted + carolMinted;
            v.claimableDepositShares += bobMinted + carolMinted;
            v.queuedDepositShares     = 0;

            u[bob].claimableDepositAssets   += bobRest;
            u[bob].claimableDepositShares   += bobMinted;
            u[bob].pendingDepositShares      = 0;
            u[carol].claimableDepositAssets  = carolValue;
            u[carol].claimableDepositShares  = carolMinted;
            u[carol].pendingDepositShares    = 0;
            _check();

            assertEq(vault.depositHead(), 3);  // Skipped dave's cancelled entry
            assertEq(spUsdc.balanceOf(address(vault)), bobQueued + carolQueued);  // Nothing redeemed
        }

        /*** 8. PAU flow: withdrawFromSavings -> take; plain USDC transfer back -> depositToSavings ***/

        {
            uint256 burned = spUsdc.previewWithdraw(1_000e6);

            vm.prank(rebalancer);
            vault.withdrawFromSavings(1_000e6);

            vm.prank(taker);
            vault.take(10_500e6);

            v.usdc   = 500e6;
            v.spUsdc -= burned;
            _check();

            vm.prank(taker);
            assertTrue(usdc.transfer(address(vault), 300e6));

            assertEq(vault.nowChi(), chi);  // Plain transfers never move the price

            uint256 minted = spUsdc.previewDeposit(300e6);

            vm.prank(rebalancer);
            vault.depositToSavings(300e6);

            v.spUsdc += minted;
            _check();
        }

        /*** 9. Instant requestRedeem, shortfall over idle USDC pulled from spUSDC ***/

        uint256 aliceNet;
        {
            uint256 gross = 1_500e6 * chi / RAY;
            aliceNet = gross - _divup(gross * FEE, WAD);

            assertGe(vault.availableLiquidAssets(), int256(aliceNet));

            uint256 burned = spUsdc.previewWithdraw(aliceNet - 500e6);

            vm.prank(alice);
            vault.requestRedeem(1_500e6, alice, alice);

            v.totalSupply           -= 1_500e6;
            v.usdc                   = aliceNet;  // Exactly ring-fenced
            v.spUsdc                -= burned;
            v.claimableRedeemAssets  = aliceNet;

            u[alice].shares                = 2_500e6;
            u[alice].claimableRedeemShares = 1_500e6;
            u[alice].claimableRedeemAssets = aliceNet;
            _check();

            assertEq(vault.withdrawHead(), 1);
        }

        /*** 10. Queued redeem with locked fee, processed after the fee is raised ***/

        // bob claims all his spPRIME via deposit (instant + both queue fills, mixed prices)
        {
            uint256 claimAssets = u[bob].claimableDepositAssets;
            uint256 claimShares = u[bob].claimableDepositShares;

            vm.prank(bob);
            assertEq(vault.deposit(claimAssets, bob), claimShares);

            v.claimableDepositShares -= claimShares;

            u[bob].shares                 = claimShares;
            u[bob].claimableDepositAssets = 0;
            u[bob].claimableDepositShares = 0;
            _check();
        }

        // Drain liquidity: sleeve to USDC, idle USDC taken. alice's ring-fence is untouchable.
        uint256 taken = 10_500e6 - 300e6;
        {
            uint256 sleeve = spUsdc.convertToAssets(v.spUsdc);
            uint256 burned = spUsdc.previewWithdraw(sleeve);

            vm.prank(rebalancer);
            vault.withdrawFromSavings(sleeve);

            vm.prank(taker);
            vm.expectRevert("SparkPrimeVault/insufficient-liquidity");
            vault.take(sleeve + 1);

            vm.prank(taker);
            vault.take(sleeve);

            taken    += sleeve;
            v.spUsdc -= burned;
            _check();

            assertLe(vault.availableLiquidAssets(), 1);  // At most 1 wei of spUSDC dust
        }

        vm.prank(bob);
        vault.requestRedeem(2_000e6, bob, bob);

        v.queuedRedeemShares = 2_000e6;

        u[bob].shares             -= 2_000e6;
        u[bob].pendingRedeemShares = 2_000e6;
        _check();

        {
            ( address controller,, uint256 amount, uint256 fee ) = vault.withdrawQueue(1);
            assertEq(controller, bob);
            assertEq(amount,     2_000e6);
            assertEq(fee,        FEE);
        }

        vm.prank(riskManager);
        vault.setWithdrawFee(MAX_FEE);

        vm.prank(taker);
        assertTrue(usdc.transfer(address(vault), 2_100e6));

        taken  -= 2_100e6;
        v.usdc += 2_100e6;

        uint256 bobNet;
        {
            uint256 gross = 2_000e6 * chi / RAY;
            bobNet = gross - _divup(gross * FEE, WAD);  // Locked 0.5%, not the new 1%

            vm.prank(rebalancer);
            vault.processWithdrawQueue(type(uint256).max);

            v.totalSupply           -= 2_000e6;
            v.queuedRedeemShares     = 0;
            v.claimableRedeemAssets += bobNet;

            u[bob].pendingRedeemShares   = 0;
            u[bob].claimableRedeemShares = 2_000e6;
            u[bob].claimableRedeemAssets = bobNet;
            _check();

            assertEq(vault.withdrawHead(), 2);
            // The fee stays in the vault as idle USDC
            assertEq(usdc.balanceOf(address(vault)) - vault.totalClaimableRedeemAssets(), 2_100e6 - bobNet);
        }

        /*** 11. Operator claims via withdraw for the controller (receiver must be the controller) ***/

        vm.prank(alice);
        vault.setOperator(operator, true);

        vm.prank(operator);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.withdraw(aliceNet, operator, alice);

        vm.prank(operator);
        assertEq(vault.withdraw(aliceNet, alice, alice), 1_500e6);

        v.usdc                  -= aliceNet;
        v.claimableRedeemAssets -= aliceNet;

        u[alice].usdc                  = aliceNet;
        u[alice].claimableRedeemShares = 0;
        u[alice].claimableRedeemAssets = 0;
        _check();

        /*** 12. Pause, setChi loss, claims still work, requests and processing revert ***/

        vm.prank(riskManager);
        vm.expectRevert("SparkPrimeVault/not-paused");
        vault.setChi(chi * 9 / 10);

        vm.prank(guardian);
        vault.pause();

        uint256 lossChi = chi * 9 / 10;

        vm.prank(riskManager);
        vault.setChi(lossChi);

        assertEq(vault.chi(),         lossChi);
        assertEq(vault.totalAssets(), v.totalSupply * lossChi / RAY);

        // Approved redeems are fixed in USDC: the loss does not touch them
        vm.prank(bob);
        assertEq(vault.redeem(2_000e6, bob, bob), bobNet);

        v.usdc                  -= bobNet;
        v.claimableRedeemAssets  = 0;

        u[bob].usdc                  = bobNet;
        u[bob].claimableRedeemShares = 0;
        u[bob].claimableRedeemAssets = 0;
        _check();

        // Escrowed deposit shares absorb the loss
        {
            uint256 carolShares = u[carol].claimableDepositShares;

            vm.prank(carol);
            assertEq(vault.mint(carolShares, carol), u[carol].claimableDepositAssets);

            v.claimableDepositShares -= carolShares;

            u[carol].shares                 = carolShares;
            u[carol].claimableDepositAssets = 0;
            u[carol].claimableDepositShares = 0;
            _check();

            assertEq(vault.assetsOf(carol), carolShares * lossChi / RAY);
        }

        vm.startPrank(alice);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.requestDeposit(100e6, alice, alice);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.requestRedeem(100e6, alice, alice);
        vm.stopPrank();

        vm.startPrank(rebalancer);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.processDepositQueue(type(uint256).max);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.processWithdrawQueue(type(uint256).max);
        vm.stopPrank();

        /*** 13. Unpause: deposits reopen at the post-loss price ***/

        vm.prank(unpauser);
        vault.unpause();

        _requestDeposit(dave, 100e6);

        uint256 daveShares = 100e6 * RAY / lossChi;

        v.totalSupply            += daveShares;
        v.usdc                   += 100e6;
        v.claimableDepositShares += daveShares;

        u[dave].claimableDepositAssets = 100e6;
        u[dave].claimableDepositShares = daveShares;
        _check();

        assertEq(usdc.balanceOf(taker), taken);
    }

    /**********************************************************************************************/
    /*** Helpers                                                                                ***/
    /**********************************************************************************************/

    function _requestDeposit(address user, uint256 assets) internal {
        deal(address(usdc), user, usdc.balanceOf(user) + assets);

        vm.startPrank(user);
        usdc.approve(address(vault), assets);
        vault.requestDeposit(assets, user, user);
        vm.stopPrank();
    }

    function _check() internal view {
        // Expected state
        assertEq(vault.totalSupply(),                    v.totalSupply,            "totalSupply");
        assertEq(usdc.balanceOf(address(vault)),         v.usdc,                   "vault usdc");
        assertEq(spUsdc.balanceOf(address(vault)),       v.spUsdc,                 "vault spUsdc");
        assertEq(vault.totalClaimableDepositShares(),    v.claimableDepositShares, "claimableDepositShares");
        assertEq(vault.totalClaimableRedeemAssets(),     v.claimableRedeemAssets,  "claimableRedeemAssets");
        assertEq(vault.totalQueuedDepositShares(),       v.queuedDepositShares,    "queuedDepositShares");
        assertEq(vault.totalQueuedRedeemShares(),        v.queuedRedeemShares,     "queuedRedeemShares");

        // Bucket invariants
        assertGe(usdc.balanceOf(address(vault)),   vault.totalClaimableRedeemAssets(), "ring-fence");
        assertGe(spUsdc.balanceOf(address(vault)), vault.totalQueuedDepositShares(),   "queued spUSDC");
        assertEq(
            vault.balanceOf(address(vault)),
            vault.totalClaimableDepositShares() + vault.totalQueuedRedeemShares(),
            "escrow"
        );

        _checkUser(alice);
        _checkUser(bob);
        _checkUser(carol);
        _checkUser(dave);
    }

    function _checkUser(address user) internal view {
        UserState memory s = u[user];

        assertEq(usdc.balanceOf(user),                s.usdc,                   "usdc");
        assertEq(vault.balanceOf(user),               s.shares,                 "shares");
        assertEq(vault.claimableDepositAssets(user),  s.claimableDepositAssets, "claimableDepositAssets");
        assertEq(vault.claimableDepositShares(user),  s.claimableDepositShares, "claimableDepositShares");
        assertEq(vault.pendingDepositShares(user),    s.pendingDepositShares,   "pendingDepositShares");
        assertEq(vault.pendingRedeemShares(user),     s.pendingRedeemShares,    "pendingRedeemShares");
        assertEq(vault.claimableRedeemShares(user),   s.claimableRedeemShares,  "claimableRedeemShares");
        assertEq(vault.claimableRedeemAssets(user),   s.claimableRedeemAssets,  "claimableRedeemAssets");
    }

    function _divup(uint256 x, uint256 y) internal pure returns (uint256) {
        return x == 0 ? 0 : (x - 1) / y + 1;
    }

}
