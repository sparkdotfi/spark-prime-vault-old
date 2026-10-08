// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import { IERC20Metadata } from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "./TestBase.t.sol";

// NOTE: OpenZeppelin's ERC1967Proxy refuses to deploy without init data, this is only for testing
//       `initialize` against a blank proxy.
contract UninitializedERC1967Proxy is ERC1967Proxy {

    constructor(address implementation) ERC1967Proxy(implementation, "") {}

    function _unsafeAllowUninitialized() internal pure override returns (bool) {
        return true;
    }

}

contract SparkPrimeVaultInitializeFailureTests is SparkPrimeVaultTestBase {

    function test_initialize_alreadyInitialized() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        vault.initialize(
            address(asset),
            address(spUsdc),
            "Spark Prime USDC",
            "spPRIME",
            admin
        );
    }

    function test_initialize_assetMismatch() public {
        MockERC20 otherAsset = new MockERC20();

        // Overwrite vault deployment from setUp() to test initialization
        vault = SparkPrimeVault(
            address(new UninitializedERC1967Proxy(
                address(new SparkPrimeVault())
            ))
        );

        // spUSDC's asset is `asset`, not `otherAsset`
        vm.expectRevert("SparkPrimeVault/asset-mismatch");
        vault.initialize(
            address(otherAsset),
            address(spUsdc),
            "Spark Prime USDC",
            "spPRIME",
            admin
        );

        vault.initialize(
            address(asset),
            address(spUsdc),
            "Spark Prime USDC",
            "spPRIME",
            admin
        );
    }

}

contract SparkPrimeVaultInitializeSuccessTests is SparkPrimeVaultTestBase {

    // NOTE: This cannot be part of SparkPrimeVaultTestBase, because that is used in a contract where
    // DssTest is also used (and that also defines RAY).
    uint256 constant internal RAY = 1e27;

    function test_initialize_eighteenDecimals() public {
        MockERC20 eighteenDecimalsAsset = new MockERC20();

        SparkVault spUsds = SparkVault(
            address(new ERC1967Proxy(
                address(new SparkVault()),
                abi.encodeCall(
                    SparkVault.initialize,
                    (address(eighteenDecimalsAsset), "Spark Savings USDS V2", "spUSDS", admin)
                )
            ))
        );

        // This is from OpenZeppelin's Initializable.sol, which is used in SparkPrimeVault.
        // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Initializable")) - 1)) & ~bytes32(uint256(0xff))
        bytes32 INITIALIZABLE_STORAGE = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

        // Overwrite vault deployment from setUp() to test initialization
        vault = SparkPrimeVault(
            address(new UninitializedERC1967Proxy(
                address(new SparkPrimeVault())
            ))
        );

        // Assert that the vault is not initialized
        assertEq(
            vm.load(
                address(vault),
                INITIALIZABLE_STORAGE
            ),
            bytes32(0)
        );
        assertEq(vault.asset(),           address(0));
        assertEq(address(vault.spUsdc()), address(0));
        assertEq(vault.name(),            "");
        assertEq(vault.decimals(),        0);
        assertEq(vault.symbol(),          "");
        assertEq(vault.chi(),             0);
        assertEq(vault.rho(),             0);
        assertEq(vault.vsr(),             0);
        assertEq(vault.minVsr(),          0);
        assertEq(vault.maxVsr(),          0);

        assertFalse(vault.hasRole(DEFAULT_ADMIN_ROLE, admin));

        assertEq(eighteenDecimalsAsset.allowance(address(vault), address(spUsds)), 0);

        vault.initialize(
            address(eighteenDecimalsAsset),
            address(spUsds),
            "Spark Prime USDS",
            "spPRIME-USDS",
            admin
        );

        // Assert that the vault has been initialized
        assertEq(
            vm.load(
                address(vault),
                INITIALIZABLE_STORAGE
            ),
            bytes32(uint256(1))
        );

        assertEq(vault.asset(),           address(eighteenDecimalsAsset));
        assertEq(address(vault.spUsdc()), address(spUsds));
        assertEq(vault.name(),            "Spark Prime USDS");
        assertEq(vault.decimals(),        IERC20Metadata(address(eighteenDecimalsAsset)).decimals());
        assertEq(vault.decimals(),        18);
        assertEq(vault.symbol(),          "spPRIME-USDS");
        assertEq(vault.chi(),             RAY);
        assertEq(vault.rho(),             uint64(block.timestamp));
        assertEq(vault.vsr(),             RAY);
        assertEq(vault.minVsr(),          RAY);
        assertEq(vault.maxVsr(),          RAY);

        assertEq(vault.maxCapacity(),    0);
        assertEq(vault.minDeposit(),     0);
        assertEq(vault.minWithdraw(),    0);
        assertEq(vault.withdrawFee(),    0);
        assertEq(vault.maxWithdrawFee(), 0);
        assertEq(vault.totalSupply(),    0);

        assertFalse(vault.paused());

        assertTrue(vault.hasRole(DEFAULT_ADMIN_ROLE, admin));

        // The vault can deposit into the savings vault without further approvals
        assertEq(eighteenDecimalsAsset.allowance(address(vault), address(spUsds)), type(uint256).max);
    }

    function test_initialize_sixDecimals() public {
        // This is from OpenZeppelin's Initializable.sol, which is used in SparkPrimeVault.
        // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Initializable")) - 1)) & ~bytes32(uint256(0xff))
        bytes32 INITIALIZABLE_STORAGE = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

        // Overwrite vault deployment from setUp() to test initialization
        vault = SparkPrimeVault(
            address(new UninitializedERC1967Proxy(
                address(new SparkPrimeVault())
            ))
        );

        // Assert that the vault is not initialized
        assertEq(
            vm.load(
                address(vault),
                INITIALIZABLE_STORAGE
            ),
            bytes32(0)
        );

        assertEq(vault.asset(),           address(0));
        assertEq(address(vault.spUsdc()), address(0));
        assertEq(vault.name(),            "");
        assertEq(vault.decimals(),        0);
        assertEq(vault.symbol(),          "");
        assertEq(vault.chi(),             0);
        assertEq(vault.rho(),             0);
        assertEq(vault.vsr(),             0);
        assertEq(vault.minVsr(),          0);
        assertEq(vault.maxVsr(),          0);

        assertFalse(vault.hasRole(DEFAULT_ADMIN_ROLE, admin));

        assertEq(asset.allowance(address(vault), address(spUsdc)), 0);

        vault.initialize(
            address(asset),
            address(spUsdc),
            "Spark Prime USDC",
            "spPRIME",
            admin
        );

        assertEq(
            vm.load(
                address(vault),
                INITIALIZABLE_STORAGE
            ),
            bytes32(uint256(1))
        );

        assertEq(vault.asset(),           address(asset));
        assertEq(address(vault.spUsdc()), address(spUsdc));
        assertEq(vault.name(),            "Spark Prime USDC");
        assertEq(vault.decimals(),        IERC20Metadata(address(asset)).decimals());
        assertEq(vault.decimals(),        6);
        assertEq(vault.symbol(),          "spPRIME");
        assertEq(vault.chi(),             RAY);
        assertEq(vault.rho(),             uint64(block.timestamp));
        assertEq(vault.vsr(),             RAY);
        assertEq(vault.minVsr(),          RAY);
        assertEq(vault.maxVsr(),          RAY);

        assertEq(vault.maxCapacity(),    0);
        assertEq(vault.minDeposit(),     0);
        assertEq(vault.minWithdraw(),    0);
        assertEq(vault.withdrawFee(),    0);
        assertEq(vault.maxWithdrawFee(), 0);
        assertEq(vault.totalSupply(),    0);

        assertFalse(vault.paused());

        assertTrue(vault.hasRole(DEFAULT_ADMIN_ROLE, admin));

        assertEq(asset.allowance(address(vault), address(spUsdc)), type(uint256).max);
    }

}

contract SparkPrimeVaultDripTests is SparkPrimeVaultTestBase {

    // NOTE: This cannot be part of SparkPrimeVaultTestBase, because that is used in a contract where
    // DssTest is also used (and that also defines RAY).
    uint256 constant internal RAY = 1e27;

    event Drip(uint256 chi, uint256 diff);

    address user1 = makeAddr("user1");

    function setUp() public override {
        super.setUp();

        vm.prank(admin);
        vault.setVsrBounds(1e27, FOUR_PCT_VSR);

        vm.prank(setter);
        vault.setVsr(FOUR_PCT_VSR);

        deal(address(asset), user1, 1_000_000e6);

        vm.startPrank(user1);
        asset.approve(address(vault), 1_000_000e6);
        vault.requestDeposit(1_000_000e6, user1, user1);
        vault.mint(1_000_000e6, user1);
        vm.stopPrank();
    }

    function test_drip_sameBlock() public {
        uint256 timestamp = block.timestamp;

        assertEq(uint256(vault.chi()), RAY);
        assertEq(uint256(vault.rho()), timestamp);

        // No time has passed, chi is returned as is and nothing is written
        vm.expectEmit(address(vault));
        emit Drip(RAY, 0);
        uint256 nChi = vault.drip();

        assertEq(nChi,                 RAY);
        assertEq(uint256(vault.chi()), RAY);
        assertEq(uint256(vault.rho()), timestamp);
    }

    function test_drip() public {
        uint256 timestamp = block.timestamp;

        skip(1 days);

        assertEq(uint256(vault.chi()), RAY);
        assertEq(uint256(vault.rho()), timestamp);
        assertEq(vault.nowChi(),       1.000107459782027902551816735e27);
        assertEq(vault.totalAssets(),  1_000_107.459782e6);

        // Anyone can drip, the diff is the growth of the liabilities
        vm.prank(makeAddr("randomUser"));
        vm.expectEmit(address(vault));
        emit Drip(1.000107459782027902551816735e27, 107.459782e6);
        uint256 nChi = vault.drip();

        assertEq(nChi,                 1.000107459782027902551816735e27);
        assertEq(uint256(vault.chi()), 1.000107459782027902551816735e27);
        assertEq(uint256(vault.rho()), timestamp + 1 days);
        assertEq(vault.nowChi(),       1.000107459782027902551816735e27);
        assertEq(vault.totalAssets(),  1_000_107.459782e6);

        // Dripping again in the same block is a no-op
        vm.expectEmit(address(vault));
        emit Drip(1.000107459782027902551816735e27, 0);
        vault.drip();

        skip(1 days);

        // The second day compounds on the first
        vm.expectEmit(address(vault));
        emit Drip(1.000214931111660558587961741e27, 107.471329e6);
        vault.drip();

        assertEq(uint256(vault.chi()), 1.000214931111660558587961741e27);
        assertEq(uint256(vault.rho()), timestamp + 2 days);
        assertEq(vault.totalAssets(),  1_000_214.931111e6);
    }

}

contract SparkPrimeVaultConvenienceViewFunctionTests is SparkPrimeVaultTestBase {

    // NOTE: This cannot be part of SparkPrimeVaultTestBase, because that is used in a contract where
    // DssTest is also used (and that also defines RAY).
    uint256 constant internal RAY = 1e27;

    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");

    function test_convenienceViewFunctions() public {
        // Test `assetsOf(address)`, `availableCapacity()`, `availableLiquidAssets()`, `nowChi()`
        deal(address(asset), user1, 1_000_000e6);

        vm.startPrank(user1);
        asset.approve(address(vault), 1_000_000e6);
        vault.requestDeposit(1_000_000e6, user1, user1);
        vault.mint(1_000_000e6, user1);
        vm.stopPrank();

        assertEq(vault.assetsOf(user1),         1_000_000e6);
        assertEq(vault.availableCapacity(),     0);
        assertEq(vault.availableLiquidAssets(), 1_000_000e6);
        assertEq(vault.nowChi(),                RAY);

        vm.startPrank(admin);
        vault.setVsrBounds(1e27, vault.MAX_VSR());
        vm.startPrank(setter);

        // 5% APY:
        // ❯ bc -l <<< 'scale=27; e( l(1.05)/(60 * 60 * 24 * 365) )'
        // 1.000000001547125957863212448
        vault.setVsr(1.000000001547125957863212448e27);
        vm.stopPrank();

        vm.prank(taker);
        vault.take(500_000e6);

        assertEq(vault.totalAssets(),           1_000_000e6);
        assertEq(vault.assetsOf(user1),         1_000_000e6);
        assertEq(vault.availableCapacity(),     0);
        assertEq(vault.availableLiquidAssets(), 500_000e6);
        assertEq(vault.nowChi(),                RAY);

        vm.warp(block.timestamp + 1 hours);

        // Even without calling drip(), these functions return new values (they all use `nowChi()`
        // internally):
        assertEq(vault.totalAssets(),           1_000_005.569668e6);
        assertEq(vault.assetsOf(user1),         1_000_005.569668e6);
        assertEq(vault.availableCapacity(),     0);  // Capacity is counted in shares, the index doesn't consume it
        assertEq(vault.availableLiquidAssets(), 500_000e6);
        assertEq(vault.nowChi(),                1.000005569668954547626342464e27);

        vault.drip();

        // After calling drip(), the values should be the same:
        assertEq(vault.totalAssets(),           1_000_005.569668e6);
        assertEq(vault.assetsOf(user1),         1_000_005.569668e6);
        assertEq(vault.availableCapacity(),     0);
        assertEq(vault.availableLiquidAssets(), 500_000e6);
        assertEq(vault.nowChi(),                1.000005569668954547626342464e27);
    }

    function test_availableCapacity_capacityLeTotalSupplyBoundary() public {
        deal(address(asset), user1, 1000e6);

        vm.startPrank(user1);
        asset.approve(address(vault), 1000e6);
        vault.requestDeposit(1000e6, user1, user1);
        vm.stopPrank();

        // Escrowed (unclaimed) shares count towards the supply
        assertEq(vault.totalSupply(),       1000e6);
        assertEq(vault.balanceOf(user1),    0);
        assertEq(vault.availableCapacity(), 1_000_000e6 - 1000e6);

        vm.prank(admin);
        vault.setCapacity(1000e6 - 1);

        assertEq(vault.availableCapacity(), 0);

        vm.prank(admin);
        vault.setCapacity(1000e6);

        assertEq(vault.availableCapacity(), 0);

        vm.prank(admin);
        vault.setCapacity(1000e6 + 1);

        assertEq(vault.availableCapacity(), 1);

        // Claiming doesn't change the supply, so the capacity is unchanged
        vm.prank(user1);
        vault.mint(1000e6, user1);

        assertEq(vault.totalSupply(),       1000e6);
        assertEq(vault.balanceOf(user1),    1000e6);
        assertEq(vault.availableCapacity(), 1);
    }

    function test_availableLiquidAssets_idleAndSleeve() public {
        deal(address(asset), user1, 1000e6);

        vm.startPrank(user1);
        asset.approve(address(vault), 1000e6);
        vault.requestDeposit(1000e6, user1, user1);
        vault.mint(1000e6, user1);
        vm.stopPrank();

        assertEq(vault.availableLiquidAssets(), 1000e6);

        // The sleeve counts as liquidity
        vm.prank(rebalancer);
        vault.depositToSavings(600e6);

        assertEq(asset.balanceOf(address(vault)),  400e6);
        assertEq(spUsdc.balanceOf(address(vault)), 600e6);
        assertEq(vault.availableLiquidAssets(),    1000e6);

        // Taken cash does not
        vm.prank(taker);
        vault.take(100e6);

        assertEq(vault.availableLiquidAssets(), 900e6);

        // Ring-fenced cash does not
        vm.prank(user1);
        vault.requestRedeem(200e6, user1, user1);

        assertEq(asset.balanceOf(address(vault)),    300e6);
        assertEq(vault.totalClaimableRedeemAssets(), 200e6);
        assertEq(vault.availableLiquidAssets(),      700e6);

        // Savings yield grows the sleeve
        vm.prank(setter);
        spUsdc.setVsr(FOUR_PCT_VSR);

        skip(1 days);

        deal(address(asset), address(spUsdc), spUsdc.totalAssets());

        assertEq(spUsdc.assetsOf(address(vault)), 600.064475e6);
        assertEq(vault.availableLiquidAssets(),   700.064475e6);
    }

    function test_availableLiquidAssets_sleeveCappedBySavingsLiquidity() public {
        deal(address(asset), user1, 1000e6);

        vm.startPrank(user1);
        asset.approve(address(vault), 1000e6);
        vault.requestDeposit(1000e6, user1, user1);
        vault.mint(1000e6, user1);
        vm.stopPrank();

        vm.prank(rebalancer);
        vault.depositToSavings(1000e6);

        assertEq(vault.availableLiquidAssets(), 1000e6);

        vm.prank(admin);
        spUsdc.grantRole(TAKER_ROLE, taker);

        // The sleeve is worth 1000e6 but spUSDC can only pay 300e6 of it right now
        vm.prank(taker);
        spUsdc.take(700e6);

        assertEq(spUsdc.assetsOf(address(vault)), 1000e6);
        assertEq(vault.availableLiquidAssets(),   300e6);

        vm.prank(taker);
        spUsdc.take(300e6);

        assertEq(vault.availableLiquidAssets(), 0);
    }

    function test_availableLiquidAssets_queuedDepositSharesExcluded() public {
        deal(address(asset), user1, 1000e6);
        deal(address(asset), user2, 400e6);

        vm.startPrank(user1);
        asset.approve(address(vault), 1000e6);
        vault.requestDeposit(1000e6, user1, user1);
        vault.mint(1000e6, user1);
        vm.stopPrank();

        vm.prank(taker);
        vault.take(1000e6);

        assertEq(vault.availableLiquidAssets(), 0);

        // Capacity is full, user2's deposit is queued in spUSDC
        vm.prank(admin);
        vault.setCapacity(1000e6);

        vm.startPrank(user2);
        asset.approve(address(vault), 400e6);
        vault.requestDeposit(400e6, user2, user2);
        vm.stopPrank();

        // The queued depositors' spUSDC belongs to them, it is not the vault's liquidity
        assertEq(spUsdc.balanceOf(address(vault)),  400e6);
        assertEq(vault.totalQueuedDepositShares(),  400e6);
        assertEq(vault.availableLiquidAssets(),     0);
    }

    function test_availableLiquidAssets_negative() public {
        deal(address(asset), user1, 1000e6);

        vm.startPrank(user1);
        asset.approve(address(vault), 1000e6);
        vault.requestDeposit(1000e6, user1, user1);
        vault.mint(1000e6, user1);
        vault.requestRedeem(200e6, user1, user1);
        vm.stopPrank();

        assertEq(vault.totalClaimableRedeemAssets(), 200e6);
        assertEq(vault.availableLiquidAssets(),      800e6);

        // Unreachable through the interface, forced here to show the sign (e.g. USDC seized)
        deal(address(asset), address(vault), 200e6 - 1);

        assertEq(vault.availableLiquidAssets(), -1);
    }

    function test_getImplementation() public {
        SparkPrimeVault implementation = new SparkPrimeVault();

        vault = SparkPrimeVault(
            address(new ERC1967Proxy(
                address(implementation),
                abi.encodeCall(
                    SparkPrimeVault.initialize,
                    (address(asset), address(spUsdc), "Spark Prime USDC", "spPRIME", admin)
                )
            ))
        );

        assertEq(vault.getImplementation(), address(implementation));
    }

}
