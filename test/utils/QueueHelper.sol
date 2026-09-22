// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {VaultHandler} from "../VaultHandler.t.sol";
import {USDC} from "../mocks/USDC.sol";
import {IVault} from "src/interfaces/IVault.sol";

abstract contract QueueHelper is Test {
    VaultHandler internal vault;
    IERC20 internal baseAsset;

    address internal rebalancer = makeAddr("rebalancer");
    address internal vaultManager = makeAddr("vault_manager");
    address internal liquidityManager = makeAddr("liquidity_manager");
    address internal operator = makeAddr("operator");

    address internal user = makeAddr("User");
    address internal userTwo = makeAddr("UserTwo");
    address internal userThree = makeAddr("userThree");
    address internal userFour = makeAddr("userFour");
    address internal victim = makeAddr("victim");

    uint256 internal constant ROUNDING_DUST = 1e12;

    function _deployVault() internal {
        baseAsset = new USDC();
        vault = new VaultHandler(
            baseAsset,
            rebalancer,
            vaultManager,
            liquidityManager
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
        _fund(_user, amount);
        vm.prank(_user);
        vault.requestDeposit(amount, _user, _user);
    }

    function _claim(address _user, uint256 amount) internal {
        vm.prank(_user);
        vault.deposit(amount, _user);
    }

    function _depositAndClaim(address _user, uint256 amount) internal {
        _requestDeposit(_user, amount);
        _claim(_user, amount);
    }

    function _requestRedeem(address _user, uint256 shares) internal {
        vm.prank(_user);
        vault.requestRedeem(shares, _user, _user);
    }

    function _setCapacity(uint256 newCapacity) internal {
        vm.prank(vaultManager);
        vault.setCapacity(newCapacity);
    }

    function _ensureCapacity(uint256 needed) internal {
        if (vault.maxCapacity() < needed) _setCapacity(needed);
    }

    /// @dev force the capacity to current assets to force deposit queues
    function _closeCapacity() internal {
        _setCapacity(vault.totalAssets());
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

    function assetsHeld() internal view returns (uint256) {
        return baseAsset.balanceOf(address(vault));
    }

    function assetsOwed() internal view returns (uint256) {
        return vault.convertToAssets(vault.claimableWithdrawTotal());
    }

    function sharesOwed() internal view returns (uint256) {
        return vault.convertToShares(vault.claimableDepositTotal());
    }

    function sharesDeliverable() internal view returns (uint256) {
        uint256 inventory = vault.balanceOf(address(vault));
        uint256 total = vault.totalAssets();
        uint256 cap = vault.maxCapacity();
        uint256 mintable = cap > total ? vault.convertToShares(cap - total) : 0;
        return inventory + mintable + vault.claimableWithdrawTotal();
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
    }

    function assertInsolvent() internal view {
        assertTrue(
            assetsOwed() > assetsHeld() || sharesOwed() > sharesDeliverable(),
            "expected insolvency, vault is solvent"
        );
    }

    function _fundAndDeposit(
        VaultHandler,
        address _user,
        IERC20 asset,
        uint256 amount
    ) internal {
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
        vm.startPrank(_user);
        vault.deposit(amount, _user);
        vm.stopPrank();
    }
}
