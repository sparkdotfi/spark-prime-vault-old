// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {VaultBase} from "../abstract/VaultBase.sol";
import {IVault} from "../interfaces/IVault.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
/** Continiously Compounding Interest Rate System */
library InterestLib {
    uint256 constant RAY = 1e27;

    function accrueInterest(VaultBase.Storage storage $) internal {
        uint256 timeDelta = block.timestamp - $.lastAccrualTimestamp;
        if (timeDelta == 0) return;

        $.lastAccrualTimestamp = block.timestamp;

        uint256 compoundingFactor = rpow($.ratePerSecond, timeDelta, RAY);
        $.indexRate = Math.mulDiv($.indexRate, compoundingFactor, RAY);

        emit IVault.AccruedInterest($.indexRate, block.timestamp);
    }

    function simulateAccrue(
        VaultBase.Storage storage $
    ) internal view returns (uint256 newIndexRate) {
        uint256 timeDelta = block.timestamp - $.lastAccrualTimestamp;
        if (timeDelta == 0) return $.indexRate;

        uint256 compoundingFactor = rpow($.ratePerSecond, timeDelta, RAY);

        newIndexRate = Math.mulDiv($.indexRate, compoundingFactor, RAY);
    }

    function rpow(
        uint256 x,
        uint256 n,
        uint256 base
    ) internal pure returns (uint256 z) {
        assembly {
            switch n
            case 0 {
                z := base
            }
            default {
                switch mod(n, 2)
                case 0 {
                    z := base
                }
                default {
                    z := x
                }
                for {
                    n := div(n, 2)
                } n {
                    n := div(n, 2)
                } {
                    let xx := mul(x, x)
                    if iszero(eq(div(xx, x), x)) {
                        revert(0, 0)
                    }
                    x := div(xx, base)
                    if mod(n, 2) {
                        let zx := mul(z, x)
                        if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) {
                            revert(0, 0)
                        }
                        z := div(zx, base)
                    }
                }
            }
        }
    }
}
