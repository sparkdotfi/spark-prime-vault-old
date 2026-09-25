// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {VaultHandler} from "../VaultHandler.t.sol";
import {VaultDeployer} from "./VaultDeployer.sol";
import {USDC} from "../mocks/USDC.sol";
import {SavingsVault} from "../mocks/SavingsVault.sol";
import {IVault} from "src/interfaces/IVault.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

abstract contract QueueHelper is Test {
    VaultHandler internal vault;
    IERC4626 internal savingsVault;
    IERC20 internal baseAsset;

    address internal admin = makeAddr("admin");
    address internal rebalancer = makeAddr("rebalancer");
    address internal vaultManager = makeAddr("vault_manager");
    address internal liquidityManager = makeAddr("liquidity_manager");
    address internal operator = makeAddr("operator");

    address internal user = makeAddr("User");
    address internal userTwo = makeAddr("UserTwo");
    address internal userThree = makeAddr("userThree");
    address internal userFour = makeAddr("userFour");
    address internal victim = makeAddr("victim");
    address internal savingsWhale = makeAddr("savings_whale");

    uint256 internal constant ROUNDING_DUST = 1e12;
    uint256 internal constant ACCRUAL_DRIFT = 1e14;
    uint256 constant TEN_PERCENT_APY = 1000000003022265980097387650;
    uint256 constant RAY = 1e27;
    uint256 constant MAXIMUM_VAULT_CAPACITY = 100 ether;
    uint256 constant MINIMUM_DEPOSIT = 0.01 ether;
    uint256 constant MINIMUM_WITHDRAW = 0.01 ether;

    uint256 constant FIXTURE_INDEX = 1_173_458_912_345_678_901_234_567_891;
    uint256 constant FIXTURE_SAVINGS_PRICE_BPS = 537;
    uint256 constant FIXTURE_BLOCK_TIME = 12;
    uint256 constant SAVINGS_WHALE_DEPOSIT = 1_000_000 ether;
    uint256 constant SAVINGS_GROWTH_DIVISOR_PER_BLOCK = 1e8;

    uint256 internal blockTime;
    bool internal savingsGrows;

    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 constant LIQUIDITY_MANAGER_ROLE =
        0x77e60b99a50d27fb027f6912a507d956105b4148adab27a86d235c8bcca8fa2f;
    bytes32 constant REBALANCER_ROLER =
        0xccc64574297998b6c3edf6078cc5e01268465ff116954e3af02ff3a70a730f46;
    bytes32 constant VAULT_MANAGER_ROLE =
        0xd1473398bb66596de5d1ea1fc8e303ff2ac23265adc9144b1b52065dc4f0934b;

    function _deployVault() internal {
        _deployVaultWithMinimums(MINIMUM_DEPOSIT, MINIMUM_WITHDRAW);
    }

    function _deployVaultWithMinimums(
        uint256 minimumDeposit,
        uint256 minimumWithdraw
    ) internal {
        _deployCleanVault(minimumDeposit, minimumWithdraw);

        vault.setIndexRate(vm.envOr("FIXTURE_INDEX", FIXTURE_INDEX));
        blockTime = vm.envOr("FIXTURE_BLOCK_TIME", FIXTURE_BLOCK_TIME);

        uint256 bps = vm.envOr(
            "FIXTURE_SAVINGS_PRICE_BPS",
            FIXTURE_SAVINGS_PRICE_BPS
        );
        if (bps == 0) return;

        deal(address(baseAsset), savingsWhale, SAVINGS_WHALE_DEPOSIT);
        vm.startPrank(savingsWhale);
        baseAsset.approve(address(savingsVault), SAVINGS_WHALE_DEPOSIT);
        savingsVault.deposit(SAVINGS_WHALE_DEPOSIT, savingsWhale);
        vm.stopPrank();
        _accrueSavings(bps);
        savingsGrows = true;
    }

    function _deployCleanVault(
        uint256 minimumDeposit,
        uint256 minimumWithdraw
    ) internal {
        baseAsset = new USDC();
        savingsVault = new SavingsVault(baseAsset);

        vault = VaultDeployer.deploy(
            baseAsset,
            savingsVault,
            admin,
            vaultManager,
            liquidityManager,
            rebalancer,
            minimumDeposit,
            minimumWithdraw,
            MAXIMUM_VAULT_CAPACITY,
            TEN_PERCENT_APY
        );
        blockTime = 0;
        savingsGrows = false;
    }

    function _nextBlock() internal {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + blockTime);
        if (!savingsGrows) return;
        uint256 held = baseAsset.balanceOf(address(savingsVault));
        deal(
            address(baseAsset),
            address(savingsVault),
            held + held / SAVINGS_GROWTH_DIVISOR_PER_BLOCK
        );
    }

    function defaultUsers() internal view returns (address[] memory users) {
        users = new address[](4);
        users[0] = user;
        users[1] = userTwo;
        users[2] = userThree;
        users[3] = userFour;
    }

    function _fund(address _user, uint256 amount) internal {
        deal(address(baseAsset), _user, amount);
        vm.prank(_user);
        baseAsset.approve(address(vault), type(uint256).max);
    }

    function _requestDeposit(address _user, uint256 amount) internal {
        _nextBlock();
        _fund(_user, amount);
        vm.prank(_user);
        vault.requestDeposit(amount, _user, _user);
    }

    function _claim(address _user, uint256 amount) internal {
        _nextBlock();
        vm.prank(_user);
        vault.deposit(amount, _user);
    }

    function _depositAndClaim(address _user, uint256 amount) internal {
        _nextBlock();
        _ensureInstantCapacity(amount);
        _fund(_user, amount);
        vm.prank(_user);
        vault.requestDeposit(amount, _user, _user);
        _claim(_user, amount);
    }

    function _ensureInstantCapacity(uint256 amount) internal {
        uint256 needed = _committedShares() + _sharesFor(amount);
        if (vault.maxCapacity() < needed) _setCapacity(needed);
    }

    function _committedShares() internal view returns (uint256) {
        return vault.totalSupply() + vault.claimableDepositTotal();
    }

    function _sharesFor(uint256 assets) internal view returns (uint256) {
        return
            Math.mulDiv(
                assets,
                RAY,
                vault.previewIndex(),
                Math.Rounding.Ceil
            );
    }

    function _capacityValue() internal view returns (uint256) {
        return
            Math.mulDiv(
                vault.availableCapacity(),
                vault.previewIndex(),
                RAY,
                Math.Rounding.Ceil
            );
    }

    function _fillCapacity(address _user) internal returns (uint256 amount) {
        _nextBlock();
        amount = _capacityValue();
        _fund(_user, amount);
        vm.prank(_user);
        vault.requestDeposit(amount, _user, _user);
    }

    function _requestRedeem(address _user, uint256 shares) internal {
        _nextBlock();
        vm.prank(_user);
        vault.requestRedeem(shares, _user, _user);
    }

    function _setCapacity(uint256 newCapacity) internal {
        vm.prank(vaultManager);
        vault.setCapacity(newCapacity);
    }

    function _ensureCapacity(uint256 needed) internal {
        uint256 shares = _sharesFor(needed);
        if (vault.maxCapacity() < shares) _setCapacity(shares);
    }

    function _openCapacity(uint256 assets) internal {
        _setCapacity(_committedShares() + _sharesFor(assets));
    }

    /// @dev force the capacity to current assets to force deposit queues
    function _closeCapacity() internal {
        _setCapacity(_committedShares());
    }

    function _drift(uint256 amount) internal view returns (uint256) {
        return
            (amount * (ACCRUAL_DRIFT + blockTime * 1e13)) /
            1e18 +
            ROUNDING_DUST;
    }

    function _coverRedemption(uint256 shares) internal {
        uint256 owed = vault.convertToAssets(shares);
        owed += _drift(owed);
        int256 liquid = vault.availableLiquidAssets();
        uint256 held = liquid > 0 ? uint256(liquid) : 0;
        if (owed > held) _injectLiquidity(owed - held);
    }

    function _matchVolume() internal view returns (uint256) {
        return
            Math.min(
                vault.convertToAssets(vault.totalPendingWithdraws()),
                savingsVault.previewRedeem(vault.totalPendingDeposits())
            );
    }

    /// @dev Curator pulls out all liquidity to force withdraw queues
    function _drainLiquidity() internal returns (uint256 taken) {
        taken = baseAsset.balanceOf(address(vault));
        if (taken == 0) return 0;
        vm.prank(liquidityManager);
        vault.take(taken);
    }

    function _injectLiquidity(uint256 amount) internal {
        deal(
            address(baseAsset),
            address(vault),
            baseAsset.balanceOf(address(vault)) + amount
        );
    }

    /// @dev Only works under capacity
    function _mintSharesTo(address _user, uint256 assetValue) internal {
        _depositAndClaim(_user, assetValue);
    }

    /// @dev Only works under capacity
    function _mintShares(
        uint256 length,
        uint256 totalValue,
        address[] memory users
    ) internal returns (uint256 minted) {
        require(length > 0 && users.length > 0, "bad spec");
        uint256 perEntry = totalValue / length;
        for (uint256 i; i < length; ++i) {
            _depositAndClaim(users[i % users.length], perEntry);
            minted += perEntry;
        }
    }

    function createDepositQueue(
        uint256 length,
        uint256 totalValue,
        address[] memory users
    ) internal returns (uint256 requested) {
        require(
            length > 0 && users.length > 0,
            "deposit queue data cant be zero"
        );

        uint256 perEntry = totalValue / length;
        for (uint256 i; i < length; ++i) {
            _requestDeposit(users[i % users.length], perEntry);
            requested += perEntry;
        }
    }

    function createWithdrawQueue(
        uint256 length,
        uint256 totalShares,
        address[] memory users
    ) internal returns (uint256 requested) {
        require(
            length > 0 && users.length > 0,
            "withdraw queue data cant be zero"
        );

        uint256 perEntry = totalShares / length;
        for (uint256 i; i < length; ++i) {
            _requestRedeem(users[i % users.length], perEntry);
            requested += perEntry;
        }
    }

    function _accrueSavings(uint256 bps) internal {
        uint256 held = baseAsset.balanceOf(address(savingsVault));
        deal(
            address(baseAsset),
            address(savingsVault),
            (held * (10_000 + bps)) / 10_000
        );
    }

    function assetsHeld() internal view returns (uint256) {
        return baseAsset.balanceOf(address(vault));
    }

    function assetsOwed() internal view returns (uint256) {
        return vault.claimableWithdrawTotal();
    }

    function sharesOwed() internal view returns (uint256) {
        return vault.claimableDepositTotal();
    }

    function sharesDeliverable() internal view returns (uint256) {
        uint256 supply = vault.totalSupply();
        uint256 cap = vault.maxCapacity();
        return cap > supply ? cap - supply : 0;
    }

    /// @notice The invariant: everything marked Claimable must be claimable.
    function assertSolvent() internal view {
        assertLe(
            assetsOwed(),
            assetsHeld(),
            "INSOLVENT: claimable withdraws larger than assets held"
        );
        assertLe(
            sharesOwed(),
            sharesDeliverable(),
            "INSOLVENT: claimable deposits larger than "
        );
        assertEq(
            vault.balanceOf(address(vault)),
            vault.totalPendingWithdraws(),
            "ESCROW: vault holds shares beyond pending redeem escrow"
        );
        assertGe(
            savingsVault.balanceOf(address(vault)),
            vault.totalPendingDeposits(),
            "UNBACKED: deposit queue exceeds the savings position"
        );
    }

    function assertInsolvent() internal view {
        assertTrue(
            assetsOwed() > assetsHeld() ||
                sharesOwed() > sharesDeliverable() ||
                savingsVault.balanceOf(address(vault)) <
                vault.totalPendingDeposits(),
            "expected insolvency, vault is solvent"
        );
    }

    function _fundAndDeposit(
        VaultHandler,
        address _user,
        IERC20 asset,
        uint256 amount
    ) internal {
        _nextBlock();
        vm.startPrank(_user);
        deal(address(asset), _user, amount);
        asset.approve(address(vault), amount);
        vault.requestDeposit(amount, _user, _user);
        vm.stopPrank();
    }

    function _claimDeposit(
        VaultHandler,
        address _user,
        uint256 amount
    ) internal {
        _nextBlock();
        vm.startPrank(_user);
        vault.deposit(amount, _user);
        vm.stopPrank();
    }
}
