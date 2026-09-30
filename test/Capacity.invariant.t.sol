// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {QueueHelper} from "./utils/QueueHelper.sol";
import {CapacityHandler} from "./utils/CapacityHandler.sol";

contract CapacityInvariantTests is QueueHelper {
    CapacityHandler internal handler;

    function setUp() public {
        handler = new CapacityHandler();
        vault = handler.getVault();
        savingsVault = handler.getSavingsVault();
        baseAsset = handler.getBaseAsset();

        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = CapacityHandler.requestDeposit.selector;
        selectors[1] = CapacityHandler.claimDeposit.selector;
        selectors[2] = CapacityHandler.requestRedeem.selector;
        selectors[3] = CapacityHandler.claimRedeem.selector;
        selectors[4] = CapacityHandler.cancelDeposit.selector;
        selectors[5] = CapacityHandler.processQueue.selector;
        selectors[6] = CapacityHandler.setCapacity.selector;
        selectors[7] = CapacityHandler.injectLiquidity.selector;
        selectors[8] = CapacityHandler.takeFreeLiquidity.selector;
        selectors[9] = CapacityHandler.warp.selector;
        selectors[10] = CapacityHandler.accrueSavings.selector;
        selectors[11] = CapacityHandler.sanitizeDepositQueue.selector;

        targetContract(address(handler));
        targetSelector(
            FuzzSelector({addr: address(handler), selectors: selectors})
        );
    }

    function invariant_totalSupplyNeverExceedsMaxCapacity() public view {
        assertLe(vault.totalSupply(), vault.maxCapacity());
    }

    function invariant_solvent() public view {
        assertSolvent();
    }

    function invariant_noUnclaimableCredit() public view {
        address[] memory actors = handler.getActors();
        for (uint256 i; i < actors.length; ++i) {
            assertTrue(
                vault.maxDeposit(actors[i]) == 0 || vault.maxMint(actors[i]) > 0
            );
        }
    }

    function invariant_depositQueueLengthTracksPendingDeposits() public view {
        assertEq(
            vault.depositQueueLength() == 0,
            vault.totalPendingDeposits() == 0
        );
    }

    function invariant_processQueueAcceptsMaxTradeVolume() public {
        uint256 snapshot = vm.snapshotState();
        uint256 volume = vault.maxTradeVolume();

        vm.prank(rebalancer);
        vault.processQueue(volume);

        vm.revertToState(snapshot);
    }
}
