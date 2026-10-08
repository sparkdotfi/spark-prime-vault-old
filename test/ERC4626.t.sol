// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import { stdError } from "forge-std/Test.sol";

import "./TestBase.t.sol";

contract SparkPrimeVaultERC4626ViewFunctionTests is SparkPrimeVaultTestBase {

    // NOTE: This cannot be part of SparkPrimeVaultTestBase, because that is used in a contract where
    // DssTest is also used (and that also defines RAY).
    uint256 constant internal RAY = 1e27;

    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address user3 = makeAddr("user3");

    function setUp() public override {
        super.setUp();

        vm.startPrank(admin);
        vault.setMaxWithdrawFee(0.01e18);
        vault.setVsrBounds(1e27, FIVE_PCT_VSR);
        vm.stopPrank();

        vm.prank(riskManager);
        vault.setWithdrawFee(0.005e18);

        deal(address(asset), user1, 1000e6);
        deal(address(asset), user2, 1000e6);
        deal(address(asset), user3, 1000e6);

        // user1 holds 800e6 shares and has a claimable redeem of 200e6 shares
        vm.startPrank(user1);
        asset.approve(address(vault), 1000e6);
        vault.requestDeposit(1000e6, user1, user1);
        vault.mint(1000e6, user1);
        vault.requestRedeem(200e6, user1, user1);
        vm.stopPrank();

        // user2 has a claimable deposit of 500e6 shares in escrow
        vm.startPrank(user2);
        asset.approve(address(vault), 1000e6);
        vault.requestDeposit(500e6, user2, user2);
        vm.stopPrank();
    }

    function test_convertToAssets() public {
        assertEq(vault.convertToAssets(0),      0);
        assertEq(vault.convertToAssets(1),      1);
        assertEq(vault.convertToAssets(1000e6), 1000e6);

        vm.prank(setter);
        vault.setVsr(FIVE_PCT_VSR);

        skip(365 days);

        assertEq(vault.nowChi(), 1.049999999999999999961070145e27);

        // Rounds down
        assertEq(vault.convertToAssets(0),      0);
        assertEq(vault.convertToAssets(1),      1);
        assertEq(vault.convertToAssets(1000e6), 1049.999999e6);
    }

    function test_convertToShares() public {
        assertEq(vault.convertToShares(0),      0);
        assertEq(vault.convertToShares(1),      1);
        assertEq(vault.convertToShares(1000e6), 1000e6);

        vm.prank(setter);
        vault.setVsr(FIVE_PCT_VSR);

        skip(365 days);

        assertEq(vault.nowChi(), 1.049999999999999999961070145e27);

        // Rounds down
        assertEq(vault.convertToShares(0),      0);
        assertEq(vault.convertToShares(1),      0);
        assertEq(vault.convertToShares(1000e6), 952.380952e6);
    }

    function test_previewFunctionsRevert() public {
        vm.expectRevert("SparkPrimeVault/async");
        vault.previewDeposit(1);

        vm.expectRevert("SparkPrimeVault/async");
        vault.previewMint(1);

        vm.expectRevert("SparkPrimeVault/async");
        vault.previewRedeem(1);

        vm.expectRevert("SparkPrimeVault/async");
        vault.previewWithdraw(1);
    }

    function test_totalAssets() public {
        // Supply is user1's 800e6 plus the 500e6 escrowed for user2, the 200e6 redeem is burned
        assertEq(vault.totalSupply(),             1300e6);
        assertEq(vault.balanceOf(user1),          800e6);
        assertEq(vault.balanceOf(address(vault)), 500e6);
        assertEq(vault.totalAssets(),             1300e6);

        vm.prank(setter);
        vault.setVsr(FIVE_PCT_VSR);

        skip(365 days);

        assertEq(vault.totalAssets(), 1364.999999e6);
        assertEq(vault.totalAssets(), vault.convertToAssets(vault.totalSupply()));

        // The ring-fenced USDC owed to user1 is not part of the vault's assets
        assertEq(vault.totalClaimableRedeemAssets(), 199e6);
        assertEq(asset.balanceOf(address(vault)),    1500e6);
    }

    function test_share() public view {
        assertEq(vault.share(), address(vault));
    }

    function test_requestViewFunctions() public {
        // The requestId is ignored, every controller has a single aggregated request
        assertEq(vault.pendingDepositRequest(0, user2),     0);
        assertEq(vault.pendingDepositRequest(1, user2),     0);
        assertEq(vault.claimableDepositRequest(0, user2),   500e6);
        assertEq(vault.claimableDepositRequest(1, user2),   500e6);
        assertEq(vault.pendingRedeemRequest(0, user1),      0);
        assertEq(vault.pendingRedeemRequest(1, user1),      0);
        assertEq(vault.claimableRedeemRequest(0, user1),    200e6);
        assertEq(vault.claimableRedeemRequest(1, user1),    200e6);

        // Fill the capacity and drain the liquidity to force queueing
        vm.prank(admin);
        vault.setCapacity(1300e6);

        vm.prank(taker);
        vault.take(1500e6 - 199e6);

        vm.startPrank(user3);
        asset.approve(address(vault), 1000e6);
        vault.requestDeposit(100e6, user3, user3);
        vm.stopPrank();

        vm.prank(user1);
        vault.requestRedeem(100e6, user1, user1);

        assertEq(vault.pendingDepositRequest(0, user3),     100e6);
        assertEq(vault.pendingDepositRequest(1, user3),     100e6);
        assertEq(vault.claimableDepositRequest(0, user3),   0);
        assertEq(vault.pendingRedeemRequest(0, user1),      100e6);
        assertEq(vault.pendingRedeemRequest(1, user1),      100e6);
        assertEq(vault.claimableRedeemRequest(0, user1),    200e6);

        // A pending deposit is denominated in spUSDC shares and reported in assets
        vm.prank(setter);
        spUsdc.setVsr(FIVE_PCT_VSR);

        skip(365 days);

        assertEq(vault.pendingDepositShares(user3),     100e6);
        assertEq(vault.pendingDepositRequest(0, user3), 104.999999e6);
    }

    function test_maxFunctionsAreClaimables() public view {
        // Unlike ERC4626, the max functions report what the controller can claim right now
        assertEq(vault.maxDeposit(user1),  0);
        assertEq(vault.maxMint(user1),     0);
        assertEq(vault.maxRedeem(user1),   200e6);
        assertEq(vault.maxWithdraw(user1), 199e6);

        assertEq(vault.maxDeposit(user2),  500e6);
        assertEq(vault.maxMint(user2),     500e6);
        assertEq(vault.maxRedeem(user2),   0);
        assertEq(vault.maxWithdraw(user2), 0);

        assertEq(vault.maxDeposit(user3),  0);
        assertEq(vault.maxMint(user3),     0);
        assertEq(vault.maxRedeem(user3),   0);
        assertEq(vault.maxWithdraw(user3), 0);
    }

    function test_supportsInterface() public view {
        assertTrue(vault.supportsInterface(0xe3bc4e65));  // ERC7540 operator
        assertTrue(vault.supportsInterface(0xce3bbe50));  // ERC7540 async deposit
        assertTrue(vault.supportsInterface(0x620ee8e4));  // ERC7540 async redeem
        assertTrue(vault.supportsInterface(0x2f0a18c5));  // ERC7575
        assertTrue(vault.supportsInterface(0x01ffc9a7));  // ERC165
        assertTrue(vault.supportsInterface(0x7965db0b));  // IAccessControl
        assertTrue(vault.supportsInterface(0x5a05180f));  // IAccessControlEnumerable

        assertFalse(vault.supportsInterface(0xffffffff));
        assertFalse(vault.supportsInterface(0x87dfe5a0));  // ERC4626
    }

}

contract SparkPrimeVaultDepositFailureTests is SparkPrimeVaultTestBase {

    address user1    = makeAddr("user1");
    address user2    = makeAddr("user2");
    address operator = makeAddr("operator");

    function setUp() public override {
        super.setUp();

        deal(address(asset), user1, 1000e6);

        vm.startPrank(user1);
        asset.approve(address(vault), 1000e6);
        vault.requestDeposit(1000e6, user1, user1);
        vm.stopPrank();
    }

    function test_deposit_revertsReceiverZeroAddress() public {
        vm.prank(user1);
        vm.expectRevert("SparkPrimeVault/invalid-address");
        vault.deposit(1000e6, address(0));
    }

    function test_deposit_revertsReceiverVault() public {
        vm.prank(user1);
        vm.expectRevert("SparkPrimeVault/invalid-address");
        vault.deposit(1000e6, address(vault));
    }

    function test_deposit_notAuthorized() public {
        vm.prank(user2);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.deposit(1000e6, user2, user1);

        vm.prank(user2);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.deposit(1000e6, user1, user1);
    }

    function test_deposit_operatorReceiverNotController() public {
        vm.prank(operator);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.deposit(1000e6, user1, user1);

        vm.prank(user1);
        vault.setOperator(operator, true);

        // An operator can only claim to the controller
        vm.startPrank(operator);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.deposit(1000e6, operator, user1);

        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.deposit(1000e6, user2, user1);

        vault.deposit(1000e6, user1, user1);
    }

    function test_deposit_nothingClaimable() public {
        vm.prank(user2);
        vm.expectRevert(stdError.divisionError);
        vault.deposit(1, user2);
    }

    function test_deposit_exceedsClaimableBoundary() public {
        vm.startPrank(user1);
        vm.expectRevert(stdError.arithmeticError);
        vault.deposit(1000e6 + 1, user1);

        vault.deposit(1000e6, user1);
    }

}

contract SparkPrimeVaultDepositSuccessTests is SparkPrimeVaultTestBase {

    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Transfer(address indexed from, address indexed to, uint256 value);

    address user1    = makeAddr("user1");
    address user2    = makeAddr("user2");
    address operator = makeAddr("operator");

    function setUp() public override {
        super.setUp();

        vm.prank(admin);
        vault.setVsrBounds(1e27, FIVE_PCT_VSR);

        deal(address(asset), user1, 1000e6);
        deal(address(asset), user2, 1000e6);

        vm.startPrank(user1);
        asset.approve(address(vault), 1000e6);
        vault.requestDeposit(1000e6, user1, user1);
        vm.stopPrank();

        vm.prank(user2);
        asset.approve(address(vault), 1000e6);
    }

    function test_deposit() public {
        assertEq(vault.totalSupply(),             1000e6);
        assertEq(vault.balanceOf(user1),          0);
        assertEq(vault.balanceOf(address(vault)), 1000e6);
        assertEq(vault.assetsOf(user1),           0);

        assertEq(vault.maxDeposit(user1),                 1000e6);
        assertEq(vault.maxMint(user1),                    1000e6);
        assertEq(vault.claimableDepositRequest(0, user1), 1000e6);

        // The claim only moves the shares out of escrow, the supply is unchanged
        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit Transfer(address(vault), user1, 1000e6);
        emit Deposit(user1, user1, 1000e6, 1000e6);
        uint256 shares = vault.deposit(1000e6, user1);

        assertEq(shares, 1000e6);

        assertEq(vault.totalSupply(),             1000e6);
        assertEq(vault.balanceOf(user1),          1000e6);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.assetsOf(user1),           1000e6);

        assertEq(vault.maxDeposit(user1),                 0);
        assertEq(vault.maxMint(user1),                    0);
        assertEq(vault.claimableDepositRequest(0, user1), 0);
    }

    function test_deposit_partial() public {
        vm.prank(user1);
        uint256 shares = vault.deposit(400e6, user1);

        assertEq(shares, 400e6);

        assertEq(vault.balanceOf(user1),          400e6);
        assertEq(vault.balanceOf(address(vault)), 600e6);
        assertEq(vault.maxDeposit(user1),         600e6);
        assertEq(vault.maxMint(user1),            600e6);

        vm.prank(user1);
        shares = vault.deposit(600e6, user1);

        assertEq(shares, 600e6);

        assertEq(vault.balanceOf(user1),          1000e6);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.maxDeposit(user1),         0);
        assertEq(vault.maxMint(user1),            0);
    }

    function test_deposit_partial_chiAboveRay() public {
        vm.prank(setter);
        vault.setVsr(FIVE_PCT_VSR);

        skip(365 days);

        vm.prank(user2);
        vault.requestDeposit(1000e6, user2, user2);

        assertEq(vault.maxDeposit(user2), 1000e6);
        assertEq(vault.maxMint(user2),    952.380952e6);

        // Shares are paid out pro-rata to the claim, rounded down
        vm.prank(user2);
        uint256 shares = vault.deposit(400e6, user2);

        assertEq(shares, 380.952380e6);

        assertEq(vault.balanceOf(user2),  380.952380e6);
        assertEq(vault.maxDeposit(user2), 600e6);
        assertEq(vault.maxMint(user2),    571.428572e6);

        // 1 wei is worth less than a share, so it buys nothing but the shares stay claimable
        vm.prank(user2);
        shares = vault.deposit(1, user2);

        assertEq(shares, 0);

        assertEq(vault.balanceOf(user2),  380.952380e6);
        assertEq(vault.maxDeposit(user2), 600e6 - 1);
        assertEq(vault.maxMint(user2),    571.428572e6);

        vm.prank(user2);
        shares = vault.deposit(600e6 - 1, user2);

        assertEq(shares, 571.428572e6);

        assertEq(vault.balanceOf(user2),  952.380952e6);
        assertEq(vault.maxDeposit(user2), 0);
        assertEq(vault.maxMint(user2),    0);
    }

    function test_deposit_differentReceiver() public {
        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit Transfer(address(vault), user2, 1000e6);
        emit Deposit(user1, user2, 1000e6, 1000e6);
        vault.deposit(1000e6, user2);

        assertEq(vault.balanceOf(user1),  0);
        assertEq(vault.balanceOf(user2),  1000e6);
        assertEq(vault.maxDeposit(user1), 0);
        assertEq(vault.maxMint(user1),    0);
    }

    function test_deposit_operator() public {
        vm.prank(user1);
        vault.setOperator(operator, true);

        vm.prank(operator);
        vm.expectEmit(address(vault));
        emit Transfer(address(vault), user1, 1000e6);
        emit Deposit(user1, user1, 1000e6, 1000e6);
        vault.deposit(1000e6, user1, user1);

        assertEq(vault.balanceOf(user1),    1000e6);
        assertEq(vault.balanceOf(operator), 0);
        assertEq(vault.maxDeposit(user1),   0);
        assertEq(vault.maxMint(user1),      0);
    }

    function test_deposit_whilePaused() public {
        vm.prank(guardian);
        vault.pause();

        vm.prank(user1);
        vault.deposit(1000e6, user1);

        assertEq(vault.balanceOf(user1),  1000e6);
        assertEq(vault.maxDeposit(user1), 0);
    }

}

contract SparkPrimeVaultMintFailureTests is SparkPrimeVaultTestBase {

    address user1    = makeAddr("user1");
    address user2    = makeAddr("user2");
    address operator = makeAddr("operator");

    function setUp() public override {
        super.setUp();

        deal(address(asset), user1, 1000e6);

        vm.startPrank(user1);
        asset.approve(address(vault), 1000e6);
        vault.requestDeposit(1000e6, user1, user1);
        vm.stopPrank();
    }

    function test_mint_revertsReceiverZeroAddress() public {
        vm.prank(user1);
        vm.expectRevert("SparkPrimeVault/invalid-address");
        vault.mint(1000e6, address(0));
    }

    function test_mint_revertsReceiverVault() public {
        vm.prank(user1);
        vm.expectRevert("SparkPrimeVault/invalid-address");
        vault.mint(1000e6, address(vault));
    }

    function test_mint_notAuthorized() public {
        vm.prank(user2);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.mint(1000e6, user2, user1);

        vm.prank(user2);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.mint(1000e6, user1, user1);
    }

    function test_mint_operatorReceiverNotController() public {
        vm.prank(operator);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.mint(1000e6, user1, user1);

        vm.prank(user1);
        vault.setOperator(operator, true);

        // An operator can only claim to the controller
        vm.startPrank(operator);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.mint(1000e6, operator, user1);

        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.mint(1000e6, user2, user1);

        vault.mint(1000e6, user1, user1);
    }

    function test_mint_nothingClaimable() public {
        vm.prank(user2);
        vm.expectRevert(stdError.arithmeticError);
        vault.mint(1, user2);
    }

    function test_mint_exceedsClaimableBoundary() public {
        vm.startPrank(user1);
        vm.expectRevert(stdError.arithmeticError);
        vault.mint(1000e6 + 1, user1);

        vault.mint(1000e6, user1);
    }

}

contract SparkPrimeVaultMintSuccessTests is SparkPrimeVaultTestBase {

    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Transfer(address indexed from, address indexed to, uint256 value);

    address user1    = makeAddr("user1");
    address user2    = makeAddr("user2");
    address operator = makeAddr("operator");

    function setUp() public override {
        super.setUp();

        vm.prank(admin);
        vault.setVsrBounds(1e27, FIVE_PCT_VSR);

        deal(address(asset), user1, 1000e6);
        deal(address(asset), user2, 1000e6);

        vm.startPrank(user1);
        asset.approve(address(vault), 1000e6);
        vault.requestDeposit(1000e6, user1, user1);
        vm.stopPrank();

        vm.prank(user2);
        asset.approve(address(vault), 1000e6);
    }

    function test_mint() public {
        assertEq(vault.totalSupply(),             1000e6);
        assertEq(vault.balanceOf(user1),          0);
        assertEq(vault.balanceOf(address(vault)), 1000e6);
        assertEq(vault.assetsOf(user1),           0);

        assertEq(vault.maxDeposit(user1),                 1000e6);
        assertEq(vault.maxMint(user1),                    1000e6);
        assertEq(vault.claimableDepositRequest(0, user1), 1000e6);

        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit Transfer(address(vault), user1, 1000e6);
        emit Deposit(user1, user1, 1000e6, 1000e6);
        uint256 assets = vault.mint(1000e6, user1);

        assertEq(assets, 1000e6);

        assertEq(vault.totalSupply(),             1000e6);
        assertEq(vault.balanceOf(user1),          1000e6);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.assetsOf(user1),           1000e6);

        assertEq(vault.maxDeposit(user1),                 0);
        assertEq(vault.maxMint(user1),                    0);
        assertEq(vault.claimableDepositRequest(0, user1), 0);
    }

    function test_mint_partial() public {
        vm.prank(user1);
        uint256 assets = vault.mint(400e6, user1);

        assertEq(assets, 400e6);

        assertEq(vault.balanceOf(user1),          400e6);
        assertEq(vault.balanceOf(address(vault)), 600e6);
        assertEq(vault.maxDeposit(user1),         600e6);
        assertEq(vault.maxMint(user1),            600e6);

        vm.prank(user1);
        assets = vault.mint(600e6, user1);

        assertEq(assets, 600e6);

        assertEq(vault.balanceOf(user1),          1000e6);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.maxDeposit(user1),         0);
        assertEq(vault.maxMint(user1),            0);
    }

    function test_mint_partial_chiAboveRay() public {
        vm.prank(setter);
        vault.setVsr(FIVE_PCT_VSR);

        skip(365 days);

        vm.prank(user2);
        vault.requestDeposit(1000e6, user2, user2);

        assertEq(vault.maxDeposit(user2), 1000e6);
        assertEq(vault.maxMint(user2),    952.380952e6);

        // Assets are charged pro-rata to the claim, rounded up
        vm.prank(user2);
        uint256 assets = vault.mint(1, user2);

        assertEq(assets, 2);

        assertEq(vault.balanceOf(user2),  1);
        assertEq(vault.maxDeposit(user2), 1000e6 - 2);
        assertEq(vault.maxMint(user2),    952.380951e6);

        vm.prank(user2);
        assets = vault.mint(952.380951e6, user2);

        assertEq(assets, 1000e6 - 2);

        assertEq(vault.balanceOf(user2),  952.380952e6);
        assertEq(vault.maxDeposit(user2), 0);
        assertEq(vault.maxMint(user2),    0);
    }

    function test_mint_differentReceiver() public {
        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit Transfer(address(vault), user2, 1000e6);
        emit Deposit(user1, user2, 1000e6, 1000e6);
        vault.mint(1000e6, user2);

        assertEq(vault.balanceOf(user1),  0);
        assertEq(vault.balanceOf(user2),  1000e6);
        assertEq(vault.maxDeposit(user1), 0);
        assertEq(vault.maxMint(user1),    0);
    }

    function test_mint_operator() public {
        vm.prank(user1);
        vault.setOperator(operator, true);

        vm.prank(operator);
        vm.expectEmit(address(vault));
        emit Transfer(address(vault), user1, 1000e6);
        emit Deposit(user1, user1, 1000e6, 1000e6);
        vault.mint(1000e6, user1, user1);

        assertEq(vault.balanceOf(user1),    1000e6);
        assertEq(vault.balanceOf(operator), 0);
        assertEq(vault.maxDeposit(user1),   0);
        assertEq(vault.maxMint(user1),      0);
    }

    function test_mint_whilePaused() public {
        vm.prank(guardian);
        vault.pause();

        vm.prank(user1);
        vault.mint(1000e6, user1);

        assertEq(vault.balanceOf(user1), 1000e6);
        assertEq(vault.maxMint(user1),   0);
    }

}

contract SparkPrimeVaultRedeemFailureTests is SparkPrimeVaultTestBase {

    address user1    = makeAddr("user1");
    address user2    = makeAddr("user2");
    address operator = makeAddr("operator");

    function setUp() public override {
        super.setUp();

        vm.prank(admin);
        vault.setMaxWithdrawFee(0.01e18);

        vm.prank(riskManager);
        vault.setWithdrawFee(0.005e18);

        deal(address(asset), user1, 1000e6);

        vm.startPrank(user1);
        asset.approve(address(vault), 1000e6);
        vault.requestDeposit(1000e6, user1, user1);
        vault.mint(1000e6, user1);
        vault.requestRedeem(200e6, user1, user1);  // 200e6 shares, 199e6 assets claimable
        vm.stopPrank();
    }

    function test_redeem_revertsReceiverZeroAddress() public {
        vm.prank(user1);
        vm.expectRevert("SparkPrimeVault/invalid-address");
        vault.redeem(200e6, address(0), user1);
    }

    function test_redeem_revertsReceiverVault() public {
        vm.prank(user1);
        vm.expectRevert("SparkPrimeVault/invalid-address");
        vault.redeem(200e6, address(vault), user1);
    }

    function test_redeem_notAuthorized() public {
        vm.prank(user2);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.redeem(200e6, user2, user1);

        vm.prank(user2);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.redeem(200e6, user1, user1);
    }

    function test_redeem_operatorReceiverNotController() public {
        vm.prank(operator);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.redeem(200e6, user1, user1);

        vm.prank(user1);
        vault.setOperator(operator, true);

        // An operator can only claim to the controller
        vm.startPrank(operator);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.redeem(200e6, operator, user1);

        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.redeem(200e6, user2, user1);

        vault.redeem(200e6, user1, user1);
    }

    function test_redeem_nothingClaimable() public {
        vm.prank(user2);
        vm.expectRevert(stdError.divisionError);
        vault.redeem(1, user2, user2);
    }

    function test_redeem_exceedsClaimableBoundary() public {
        vm.startPrank(user1);
        vm.expectRevert(stdError.arithmeticError);
        vault.redeem(200e6 + 1, user1, user1);

        vault.redeem(200e6, user1, user1);
    }

}

contract SparkPrimeVaultRedeemSuccessTests is SparkPrimeVaultTestBase {

    event Withdraw(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    address user1    = makeAddr("user1");
    address user2    = makeAddr("user2");
    address operator = makeAddr("operator");

    function setUp() public override {
        super.setUp();

        vm.prank(admin);
        vault.setMaxWithdrawFee(0.01e18);

        vm.prank(riskManager);
        vault.setWithdrawFee(0.005e18);

        deal(address(asset), user1, 1000e6);

        vm.startPrank(user1);
        asset.approve(address(vault), 1000e6);
        vault.requestDeposit(1000e6, user1, user1);
        vault.mint(1000e6, user1);
        vault.requestRedeem(200e6, user1, user1);  // 200e6 shares, 199e6 assets claimable
        vm.stopPrank();
    }

    function test_redeem() public {
        assertEq(asset.balanceOf(user1),          0);
        assertEq(asset.balanceOf(address(vault)), 1000e6);

        assertEq(vault.totalSupply(),                800e6);
        assertEq(vault.balanceOf(user1),             800e6);
        assertEq(vault.totalClaimableRedeemAssets(), 199e6);
        assertEq(vault.availableLiquidAssets(),      801e6);

        assertEq(vault.maxRedeem(user1),                 200e6);
        assertEq(vault.maxWithdraw(user1),               199e6);
        assertEq(vault.claimableRedeemRequest(0, user1), 200e6);

        // The shares were burned when the request was approved, the claim only pays the USDC
        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit Withdraw(user1, user1, user1, 199e6, 200e6);
        uint256 assets = vault.redeem(200e6, user1, user1);

        assertEq(assets, 199e6);

        assertEq(asset.balanceOf(user1),          199e6);
        assertEq(asset.balanceOf(address(vault)), 801e6);

        assertEq(vault.totalSupply(),                800e6);
        assertEq(vault.balanceOf(user1),             800e6);
        assertEq(vault.totalClaimableRedeemAssets(), 0);
        assertEq(vault.availableLiquidAssets(),      801e6);

        assertEq(vault.maxRedeem(user1),                 0);
        assertEq(vault.maxWithdraw(user1),               0);
        assertEq(vault.claimableRedeemRequest(0, user1), 0);
    }

    function test_redeem_partial() public {
        // Assets are paid out pro-rata to the claim, rounded down
        vm.prank(user1);
        uint256 assets = vault.redeem(50e6, user1, user1);

        assertEq(assets, 49.75e6);

        assertEq(asset.balanceOf(user1),             49.75e6);
        assertEq(vault.maxRedeem(user1),             150e6);
        assertEq(vault.maxWithdraw(user1),           149.25e6);
        assertEq(vault.totalClaimableRedeemAssets(), 149.25e6);

        // 1 share is worth 0.995 wei, which pays nothing
        vm.prank(user1);
        assets = vault.redeem(1, user1, user1);

        assertEq(assets, 0);

        assertEq(asset.balanceOf(user1),             49.75e6);
        assertEq(vault.maxRedeem(user1),             150e6 - 1);
        assertEq(vault.maxWithdraw(user1),           149.25e6);
        assertEq(vault.totalClaimableRedeemAssets(), 149.25e6);

        vm.prank(user1);
        assets = vault.redeem(150e6 - 1, user1, user1);

        assertEq(assets, 149.25e6);

        assertEq(asset.balanceOf(user1),             199e6);
        assertEq(vault.maxRedeem(user1),             0);
        assertEq(vault.maxWithdraw(user1),           0);
        assertEq(vault.totalClaimableRedeemAssets(), 0);
    }

    function test_redeem_zeroShares() public {
        vm.prank(user1);
        uint256 assets = vault.redeem(0, user1, user1);

        assertEq(assets, 0);

        assertEq(vault.maxRedeem(user1),   200e6);
        assertEq(vault.maxWithdraw(user1), 199e6);
    }

    function test_redeem_differentReceiver() public {
        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit Withdraw(user1, user2, user1, 199e6, 200e6);
        vault.redeem(200e6, user2, user1);

        assertEq(asset.balanceOf(user1), 0);
        assertEq(asset.balanceOf(user2), 199e6);
        assertEq(vault.maxRedeem(user1), 0);
    }

    function test_redeem_operator() public {
        vm.prank(user1);
        vault.setOperator(operator, true);

        vm.prank(operator);
        vm.expectEmit(address(vault));
        emit Withdraw(operator, user1, user1, 199e6, 200e6);
        vault.redeem(200e6, user1, user1);

        assertEq(asset.balanceOf(user1),    199e6);
        assertEq(asset.balanceOf(operator), 0);
        assertEq(vault.maxRedeem(user1),    0);
    }

    function test_redeem_whilePaused() public {
        vm.prank(guardian);
        vault.pause();

        vm.prank(user1);
        vault.redeem(200e6, user1, user1);

        assertEq(asset.balanceOf(user1), 199e6);
        assertEq(vault.maxRedeem(user1), 0);
    }

    function test_redeem_afterLossIsFixed() public {
        // Approved redeems are fixed in USDC, a loss booked afterwards doesn't touch them
        vm.prank(guardian);
        vault.pause();

        vm.prank(riskManager);
        vault.setChi(0.5e27);

        assertEq(vault.maxRedeem(user1),   200e6);
        assertEq(vault.maxWithdraw(user1), 199e6);
        assertEq(vault.assetsOf(user1),    400e6);

        vm.prank(user1);
        uint256 assets = vault.redeem(200e6, user1, user1);

        assertEq(assets, 199e6);
    }

}

contract SparkPrimeVaultWithdrawFailureTests is SparkPrimeVaultTestBase {

    address user1    = makeAddr("user1");
    address user2    = makeAddr("user2");
    address operator = makeAddr("operator");

    function setUp() public override {
        super.setUp();

        vm.prank(admin);
        vault.setMaxWithdrawFee(0.01e18);

        vm.prank(riskManager);
        vault.setWithdrawFee(0.005e18);

        deal(address(asset), user1, 1000e6);

        vm.startPrank(user1);
        asset.approve(address(vault), 1000e6);
        vault.requestDeposit(1000e6, user1, user1);
        vault.mint(1000e6, user1);
        vault.requestRedeem(200e6, user1, user1);  // 200e6 shares, 199e6 assets claimable
        vm.stopPrank();
    }

    function test_withdraw_revertsReceiverZeroAddress() public {
        vm.prank(user1);
        vm.expectRevert("SparkPrimeVault/invalid-address");
        vault.withdraw(199e6, address(0), user1);
    }

    function test_withdraw_revertsReceiverVault() public {
        vm.prank(user1);
        vm.expectRevert("SparkPrimeVault/invalid-address");
        vault.withdraw(199e6, address(vault), user1);
    }

    function test_withdraw_notAuthorized() public {
        vm.prank(user2);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.withdraw(199e6, user2, user1);

        vm.prank(user2);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.withdraw(199e6, user1, user1);
    }

    function test_withdraw_operatorReceiverNotController() public {
        vm.prank(operator);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.withdraw(199e6, user1, user1);

        vm.prank(user1);
        vault.setOperator(operator, true);

        // An operator can only claim to the controller
        vm.startPrank(operator);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.withdraw(199e6, operator, user1);

        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.withdraw(199e6, user2, user1);

        vault.withdraw(199e6, user1, user1);
    }

    function test_withdraw_nothingClaimable() public {
        vm.prank(user2);
        vm.expectRevert(stdError.arithmeticError);
        vault.withdraw(1, user2, user2);
    }

    function test_withdraw_exceedsClaimableBoundary() public {
        vm.startPrank(user1);
        vm.expectRevert(stdError.arithmeticError);
        vault.withdraw(199e6 + 1, user1, user1);

        vault.withdraw(199e6, user1, user1);
    }

}

contract SparkPrimeVaultWithdrawSuccessTests is SparkPrimeVaultTestBase {

    event Withdraw(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    address user1    = makeAddr("user1");
    address user2    = makeAddr("user2");
    address operator = makeAddr("operator");

    function setUp() public override {
        super.setUp();

        vm.prank(admin);
        vault.setMaxWithdrawFee(0.01e18);

        vm.prank(riskManager);
        vault.setWithdrawFee(0.005e18);

        deal(address(asset), user1, 1000e6);

        vm.startPrank(user1);
        asset.approve(address(vault), 1000e6);
        vault.requestDeposit(1000e6, user1, user1);
        vault.mint(1000e6, user1);
        vault.requestRedeem(200e6, user1, user1);  // 200e6 shares, 199e6 assets claimable
        vm.stopPrank();
    }

    function test_withdraw() public {
        assertEq(asset.balanceOf(user1),          0);
        assertEq(asset.balanceOf(address(vault)), 1000e6);

        assertEq(vault.totalSupply(),                800e6);
        assertEq(vault.balanceOf(user1),             800e6);
        assertEq(vault.totalClaimableRedeemAssets(), 199e6);
        assertEq(vault.availableLiquidAssets(),      801e6);

        assertEq(vault.maxRedeem(user1),                 200e6);
        assertEq(vault.maxWithdraw(user1),               199e6);
        assertEq(vault.claimableRedeemRequest(0, user1), 200e6);

        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit Withdraw(user1, user1, user1, 199e6, 200e6);
        uint256 shares = vault.withdraw(199e6, user1, user1);

        assertEq(shares, 200e6);

        assertEq(asset.balanceOf(user1),          199e6);
        assertEq(asset.balanceOf(address(vault)), 801e6);

        assertEq(vault.totalSupply(),                800e6);
        assertEq(vault.balanceOf(user1),             800e6);
        assertEq(vault.totalClaimableRedeemAssets(), 0);
        assertEq(vault.availableLiquidAssets(),      801e6);

        assertEq(vault.maxRedeem(user1),                 0);
        assertEq(vault.maxWithdraw(user1),               0);
        assertEq(vault.claimableRedeemRequest(0, user1), 0);
    }

    function test_withdraw_partial() public {
        // Shares are charged pro-rata to the claim, rounded up
        vm.prank(user1);
        uint256 shares = vault.withdraw(49.75e6, user1, user1);

        assertEq(shares, 50e6);

        assertEq(asset.balanceOf(user1),             49.75e6);
        assertEq(vault.maxRedeem(user1),             150e6);
        assertEq(vault.maxWithdraw(user1),           149.25e6);
        assertEq(vault.totalClaimableRedeemAssets(), 149.25e6);

        // 1 wei costs 1.005 shares, rounded up to 2
        vm.prank(user1);
        shares = vault.withdraw(1, user1, user1);

        assertEq(shares, 2);

        assertEq(asset.balanceOf(user1),             49.75e6 + 1);
        assertEq(vault.maxRedeem(user1),             150e6 - 2);
        assertEq(vault.maxWithdraw(user1),           149.25e6 - 1);
        assertEq(vault.totalClaimableRedeemAssets(), 149.25e6 - 1);

        vm.prank(user1);
        shares = vault.withdraw(149.25e6 - 1, user1, user1);

        assertEq(shares, 150e6 - 2);

        assertEq(asset.balanceOf(user1),             199e6);
        assertEq(vault.maxRedeem(user1),             0);
        assertEq(vault.maxWithdraw(user1),           0);
        assertEq(vault.totalClaimableRedeemAssets(), 0);
    }

    function test_withdraw_zeroAssets() public {
        vm.prank(user1);
        uint256 shares = vault.withdraw(0, user1, user1);

        assertEq(shares, 0);

        assertEq(vault.maxRedeem(user1),   200e6);
        assertEq(vault.maxWithdraw(user1), 199e6);
    }

    function test_withdraw_differentReceiver() public {
        vm.prank(user1);
        vm.expectEmit(address(vault));
        emit Withdraw(user1, user2, user1, 199e6, 200e6);
        vault.withdraw(199e6, user2, user1);

        assertEq(asset.balanceOf(user1),   0);
        assertEq(asset.balanceOf(user2),   199e6);
        assertEq(vault.maxWithdraw(user1), 0);
    }

    function test_withdraw_operator() public {
        vm.prank(user1);
        vault.setOperator(operator, true);

        vm.prank(operator);
        vm.expectEmit(address(vault));
        emit Withdraw(operator, user1, user1, 199e6, 200e6);
        vault.withdraw(199e6, user1, user1);

        assertEq(asset.balanceOf(user1),    199e6);
        assertEq(asset.balanceOf(operator), 0);
        assertEq(vault.maxWithdraw(user1),  0);
    }

    function test_withdraw_whilePaused() public {
        vm.prank(guardian);
        vault.pause();

        vm.prank(user1);
        vault.withdraw(199e6, user1, user1);

        assertEq(asset.balanceOf(user1),   199e6);
        assertEq(vault.maxWithdraw(user1), 0);
    }

    function test_withdraw_afterLossIsFixed() public {
        // Approved redeems are fixed in USDC, a loss booked afterwards doesn't touch them
        vm.prank(guardian);
        vault.pause();

        vm.prank(riskManager);
        vault.setChi(0.5e27);

        assertEq(vault.maxRedeem(user1),   200e6);
        assertEq(vault.maxWithdraw(user1), 199e6);
        assertEq(vault.assetsOf(user1),    400e6);

        vm.prank(user1);
        uint256 shares = vault.withdraw(199e6, user1, user1);

        assertEq(shares, 200e6);
    }

}
