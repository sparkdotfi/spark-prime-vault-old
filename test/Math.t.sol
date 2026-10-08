// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import { stdError } from "forge-std/Test.sol";

import "./TestBase.t.sol";

import { SparkPrimeVault } from "src/SparkPrimeVault.sol";

contract SparkPrimeVaultHarness is SparkPrimeVault {

    function divup(uint256 x, uint256 y) public pure returns (uint256) {
        return super._divup(x, y);
    }

    function min(uint256 x, uint256 y) public pure returns (uint256) {
        return super._min(x, y);
    }

    function net(uint256 shares, uint256 fee, uint256 chi_) public pure returns (uint256) {
        return super._net(shares, fee, chi_);
    }

    function rpow(uint256 x, uint256 n) public pure returns (uint256) {
        return super._rpow(x, n);
    }

}

contract MathTestBase is Test {

    // NOTE: Don't need to use upgradability pattern because of pure functions
    SparkPrimeVaultHarness harness;

    function setUp() public {
        harness = new SparkPrimeVaultHarness();
    }

}

contract DivupFailureTests is MathTestBase {

    function test_divup_divideByZero() public {
        vm.expectRevert(stdError.divisionError);
        harness.divup(1, 0);
    }

}

contract DivupSuccessTests is MathTestBase {

    struct TestCase {
        uint256 x;
        uint256 y;
        uint256 expected;
    }

    function fixtureDivision() public pure returns (TestCase[] memory testCases) {
        testCases = new TestCase[](11);

        testCases[0] = TestCase({ x: 1,  y: 1, expected: 1 });  // 1
        testCases[1] = TestCase({ x: 1,  y: 2, expected: 1 });  // 0.5
        testCases[2] = TestCase({ x: 2,  y: 2, expected: 1 });  // 1
        testCases[3] = TestCase({ x: 2,  y: 3, expected: 1 });  // 0.66...
        testCases[4] = TestCase({ x: 3,  y: 2, expected: 2 });  // 1.5
        testCases[5] = TestCase({ x: 5,  y: 2, expected: 3 });  // 2.5
        testCases[6] = TestCase({ x: 10, y: 3, expected: 4 });  // 3.33...

        testCases[7] = TestCase({ x: 1e6, y: 1e6 + 1, expected: 1 });  // 0.999999
        testCases[8] = TestCase({ x: 1e6, y: 1e6,     expected: 1 });  // 1
        testCases[9] = TestCase({ x: 1e6, y: 1e6 - 1, expected: 2 });  // 1.000001

        testCases[10] = TestCase({ x: 0, y: 0, expected: 0 });  // NOTE: Differs from natural division
    }

    function table_divup_roundUp(TestCase memory division) public view {
        assertEq(harness.divup(division.x, division.y), division.expected);
    }

}

contract MinSuccessTests is MathTestBase {

    function test_min() public view {
        assertEq(harness.min(0, 0), 0);
        assertEq(harness.min(0, 1), 0);
        assertEq(harness.min(1, 0), 0);
        assertEq(harness.min(1, 1), 1);
        assertEq(harness.min(1, 2), 1);
        assertEq(harness.min(2, 1), 1);

        assertEq(harness.min(type(uint256).max, 1e27),              1e27);
        assertEq(harness.min(1e27,              type(uint256).max), 1e27);
    }

}

contract NetSuccessTests is MathTestBase {

    struct TestCase {
        uint256 shares;
        uint256 fee;
        uint256 chi;
        uint256 expected;
    }

    function fixtureNetCase() public pure returns (TestCase[] memory testCases) {
        testCases = new TestCase[](10);

        // No fee: net is gross, which rounds down
        testCases[0] = TestCase({ shares: 1000e6, fee: 0, chi: 1e27,   expected: 1000e6 });
        testCases[1] = TestCase({ shares: 1000e6, fee: 0, chi: 1.05e27, expected: 1050e6 });
        testCases[2] = TestCase({ shares: 1,      fee: 0, chi: 1.05e27, expected: 1      });
        testCases[3] = TestCase({ shares: 1,      fee: 0, chi: 0.9e27,  expected: 0      });

        // 0.5% fee on round numbers
        testCases[4] = TestCase({ shares: 200e6,  fee: 0.005e18, chi: 1e27,   expected: 199e6    });
        testCases[5] = TestCase({ shares: 1000e6, fee: 0.005e18, chi: 1.05e27, expected: 1044.75e6 });

        // 1% fee (MAX_WITHDRAW_FEE)
        testCases[6] = TestCase({ shares: 1000e6, fee: 0.01e18, chi: 1e27, expected: 990e6 });

        // The fee rounds up, so a dust gross nets to zero
        testCases[7] = TestCase({ shares: 1,   fee: 0.005e18, chi: 1e27, expected: 0   });
        testCases[8] = TestCase({ shares: 199, fee: 0.005e18, chi: 1e27, expected: 198 });  // Fee 0.995 -> 1
        testCases[9] = TestCase({ shares: 200, fee: 0.005e18, chi: 1e27, expected: 199 });  // Fee 1 exactly
    }

    function table_net_feeRoundsUp(TestCase memory netCase) public view {
        assertEq(harness.net(netCase.shares, netCase.fee, netCase.chi), netCase.expected);
    }

    function testFuzz_net_neverExceedsGross(uint256 shares, uint256 fee, uint256 chi) public view {
        shares = bound(shares, 0, 1e30);
        fee    = bound(fee,    0, 0.01e18);
        chi    = bound(chi,    1, 10e27);

        uint256 gross = shares * chi / 1e27;
        uint256 net   = harness.net(shares, fee, chi);

        assertLe(net, gross);
        assertGe(net + gross * fee / 1e18 + 1, gross);  // Fee rounds up by at most 1
    }

}

contract RpowSuccessTests is MathTestBase {

    struct ApyVsrTestCase {
        uint256 apy;
        uint256 vsr;
    }

    // NOTE: The CSV data was sourced from Sky Ecosystem's VSR conversion table:
    //       https://ipfs.io/ipfs/QmVp4mhhbwWGTfbh2BzwQB9eiBrQBKiqcPRZCaAxNUaar6
    function fixtureApyVsr() public view returns (ApyVsrTestCase[] memory testCases) {
        string memory csv = vm.readFile("test/tables/rpow-apy.csv");
        string[] memory rows = vm.split(csv, "\n");
        testCases = new ApyVsrTestCase[](rows.length);
        for (uint256 i = 0; i < rows.length; i++) {
            testCases[i] = ApyVsrTestCase({
                apy: vm.parseUint(vm.split(rows[i], ",")[0]),
                vsr: vm.parseUint(vm.split(rows[i], ",")[1])
            });
        }
    }

    function table_rpow_apyVsr18Decimals(ApyVsrTestCase memory apyVsr) public view {
        uint256 deposit = 1_000_000e18;

        uint256 depositWithYieldApy = deposit * (10000 + apyVsr.apy) / 10000;
        uint256 depositWithYieldVsr = deposit * harness.rpow(apyVsr.vsr, 365 days) / 1e27;

        assertApproxEqAbs(depositWithYieldApy, depositWithYieldVsr, 150_000);  // 1.5e-13 difference maximum on 1m
    }

    function table_rpow_apyVsr6Decimals(ApyVsrTestCase memory apyVsr) public view {
        uint256 deposit = 1_000_000e6;

        uint256 depositWithYieldApy = deposit * (10000 + apyVsr.apy) / 10000;
        uint256 depositWithYieldVsr = deposit * harness.rpow(apyVsr.vsr, 365 days) / 1e27;

        assertApproxEqAbs(depositWithYieldApy, depositWithYieldVsr, 1);  // 1 unit of rounding error for 6 decimals
    }

    // Adding this test to demonstrate the upper bound values of rpow instead of failure mode testing.
    // MAX_VSR is 100% APY.
    function test_rpow_upperBoundValues() public {
        uint256 maxVsr = harness.MAX_VSR();

        // Reverts between 75 and 80 years
        vm.expectRevert();
        harness.rpow(maxVsr, 80 * 365 days);

        uint256 maxVsrChi = harness.rpow(maxVsr, 75 * 365 days);

        // 37,778,931,862,957,161,634,615,052,296,000,273,248,252,349,772,281% accrued over 75 years at 100% APY
        // without drip getting called.
        assertEq(maxVsrChi, 3.7778931862957161634615052296000273248252349772281e49);
    }

    function test_rpow_lowerBoundValues() public view {
        uint256 minVsr = 1e27;

        uint256 minVsrChi = harness.rpow(minVsr, 1000 * 365 days);

        assertEq(minVsrChi, 1e27);
    }

}
