// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {QueueHelper} from "./QueueHelper.sol";
import {VaultHandler} from "../VaultHandler.t.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract CapacityHandler is QueueHelper {
    struct QueuedDeposit {
        address controller;
        uint256 nonce;
    }

    address[] internal actors;
    QueuedDeposit[] internal queuedDeposits;

    uint256 public withdrawMatches;
    uint256 public depositMatches;

    constructor() {
        _deployVault();
        actors = defaultUsers();
    }

    function getVault() external view returns (VaultHandler) {
        return vault;
    }

    function getSavingsVault() external view returns (IERC4626) {
        return savingsVault;
    }

    function getBaseAsset() external view returns (IERC20) {
        return baseAsset;
    }

    function getActors() external view returns (address[] memory) {
        return actors;
    }

    function requestDeposit(uint256 seed, uint256 amount) external {
        address actor = _actor(seed);
        amount = bound(amount, MINIMUM_DEPOSIT, 50 ether);
        _nextBlock();

        uint256 instant = vault.depositQueueLength() == 0
            ? _capacityValue()
            : 0;
        uint256 queued = amount > instant ? amount - instant : 0;
        if (queued > 0 && savingsVault.previewDeposit(queued) == 0) return;

        _fund(actor, amount);
        vm.prank(actor);
        vault.requestDeposit(amount, actor, actor);

        if (queued > 0)
            queuedDeposits.push(
                QueuedDeposit(actor, vault.requestNonce(actor))
            );
    }

    function claimDeposit(uint256 seed, uint256 amount, bool viaMint) external {
        address actor = _actor(seed);
        _nextBlock();
        uint256 locked = vault.maxMint(actor);
        uint256 claimable = vault.maxDeposit(actor);
        if (locked == 0 || claimable == 0) return;

        if (viaMint) {
            uint256 shares = bound(amount, 1, locked);
            vm.prank(actor);
            vault.mint(shares, actor);
        } else {
            uint256 assets = bound(amount, 1, claimable);
            if (Math.mulDiv(locked, assets, claimable) == 0) assets = claimable;
            vm.prank(actor);
            vault.deposit(assets, actor);
        }
    }

    function requestRedeem(uint256 seed, uint256 shares) external {
        address actor = _actor(seed);
        uint256 balance = vault.balanceOf(actor);
        if (balance == 0) return;
        shares = bound(shares, 1, balance);
        _nextBlock();
        if (vault.convertToAssets(shares) < MINIMUM_WITHDRAW) return;

        vm.prank(actor);
        vault.requestRedeem(shares, actor, actor);
    }

    function claimRedeem(
        uint256 seed,
        uint256 amount,
        bool viaWithdraw
    ) external {
        address actor = _actor(seed);
        _nextBlock();

        if (viaWithdraw) {
            uint256 owed = vault.maxWithdraw(actor);
            if (owed == 0) return;
            uint256 assets = bound(amount, 1, owed);
            vm.prank(actor);
            vault.withdraw(assets, actor, actor);
        } else {
            uint256 claimable = vault.maxRedeem(actor);
            if (claimable == 0) return;
            uint256 shares = bound(amount, 1, claimable);
            vm.prank(actor);
            vault.redeem(shares, actor, actor);
        }
    }

    function cancelDeposit(uint256 index) external {
        if (queuedDeposits.length == 0) return;
        QueuedDeposit memory entry = queuedDeposits[
            bound(index, 0, queuedDeposits.length - 1)
        ];
        if (
            vault
                .queuedDepositRequest(entry.controller, entry.nonce)
                .controller == address(0)
        ) return;

        _nextBlock();
        vm.prank(entry.controller);
        vault.cancelDepositRequest(entry.controller, entry.nonce);
    }

    function processQueue(uint256 volume) external {
        _nextBlock();
        volume = bound(volume, 0, vault.maxTradeVolume());
        uint256 withdraws = vault.totalPendingWithdraws();
        uint256 deposits = vault.totalPendingDeposits();

        vm.prank(rebalancer);
        vault.processQueue(volume);

        if (vault.totalPendingWithdraws() < withdraws) ++withdrawMatches;
        if (vault.totalPendingDeposits() < deposits) ++depositMatches;
    }

    function sanitizeDepositQueue(uint256 maxIterations) external {
        vault.sanitizeDepositQueue(bound(maxIterations, 0, 20));
    }

    function setCapacity(uint256 room) external {
        _setCapacity(vault.totalSupply() + bound(room, 0, 200 ether));
    }

    function injectLiquidity(uint256 amount) external {
        _injectLiquidity(bound(amount, 0, 50 ether));
    }

    function takeFreeLiquidity(uint256 amount) external {
        int256 free = vault.availableLiquidAssets();
        if (free <= 0) return;
        amount = bound(amount, 0, uint256(free));
        vm.prank(liquidityManager);
        vault.take(amount);
    }

    function warp(uint256 elapsed) external {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + bound(elapsed, 0, 30 days));
    }

    function accrueSavings(uint256 bps) external {
        _accrueSavings(bound(bps, 0, 500));
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }
}
