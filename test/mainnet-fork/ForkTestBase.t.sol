// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "../../lib/forge-std/src/Test.sol";

import { ERC1967Proxy } from "../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Ethereum } from "../../lib/spark-address-registry/src/Ethereum.sol";

import { Vault } from "../../src/Vault.sol";

import { IVault } from "../../src/interfaces/IVault.sol";

// TODO : Remove these interface imports and define Like interfaces later.
import { IERC20 }   from "../../lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import { IERC4626 } from "../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

interface IERC20Like {

    function allowance(address owner, address spender) external view returns (uint256);

    function approve(address spender, uint256 amount) external;

    function balanceOf(address owner) external view returns (uint256);

}

interface ISparkVaultLike {

    function balanceOf(address owner) external view returns (uint256);

    function convertToAssets(uint256 shares) external view returns (uint256);

    function previewDeposit(uint256 assets) external view returns (uint256);

}

abstract contract ForkTestBase is Test {

    struct VaultState {
        address controller;
        uint256 totalSupply;
        uint256 totalAssets;
        uint256 availableCapacity;
        int256  availableLiquidAssets;
        uint256 claimableDepositRequest;
        uint256 maxDeposit;
        uint256 maxMint;
        uint256 claimableDepositTotal;
        uint256 pendingDepositRequest;
        uint256 totalPendingDeposits;
        uint256 depositQueueLength;
        uint256 requestNonce;
        uint256 index;
        uint256 lastAccrual;
    }

    address internal constant ADMIN             = Ethereum.SPARK_PROXY;
    address internal constant VAULT_MANAGER     = address(1); // TODO : Replace with actual addresses
    address internal constant LIQUIDITY_MANAGER = address(2); // TODO : Replace with actual addresses
    address internal constant REBALANCER        = address(3); // TODO : Replace with actual addresses
    address internal constant GUARDIAN          = address(4); // TODO : Replace with actual addresses
    address internal constant RISK_MANAGER      = address(5); // TODO : Replace with actual addresses

    uint256 internal constant VAULT_CAPACITY   = 100_000_0006;
    uint256 internal constant MINIMUM_DEPOSIT  = 100e6;
    uint256 internal constant MINIMUM_WITHDRAW = 100e6;
    uint256 internal constant RATE_PER_SECOND  = 1000000003022265980097387650; // 10% APY

    uint256 internal constant RAY = 1e27;

    IERC20Like      internal constant usdc        = IERC20Like(Ethereum.USDC);
    ISparkVaultLike internal constant spUSDCVault = ISparkVaultLike(Ethereum.SPARK_VAULT_V2_SPUSDC);

    address internal user  = makeAddr("user");
    address internal user2 = makeAddr("user2");

    Vault internal spPrimeVaultUsdc;

    function setUp() public virtual {
        vm.createSelectFork(getChain("mainnet").rpcUrl, _getBlock());

        IVault.InitParams memory params = _getInitParams();

        spPrimeVaultUsdc = Vault(
            address(new ERC1967Proxy(
                address(new Vault()),
                abi.encodeWithSelector(Vault.initialize.selector, params)
            ))
        );
    }

    function _getBlock() internal pure returns (uint256) {
        return 26132838;
    }

    function _getInitParams() internal pure returns (IVault.InitParams memory) {
        return IVault.InitParams({
            name             : "Spark Prime Vault USDC",
            symbol           : "spPrimeUSDC",
            baseAsset        : IERC20(address(usdc)),
            savingsVault     : IERC4626(address(spUSDCVault)),
            minimumDeposit   : MINIMUM_DEPOSIT,
            minimumWithdraw  : MINIMUM_WITHDRAW,
            capacity         : VAULT_CAPACITY,
            ratePerSecond    : RATE_PER_SECOND,
            admin            : ADMIN,
            vaultManager     : VAULT_MANAGER,
            liquidityManager : LIQUIDITY_MANAGER,
            rebalancer       : REBALANCER,
            guardian         : GUARDIAN,
            riskManager      : RISK_MANAGER
        });
    }

    function _requestDeposit(address account, uint256 amount) internal {
        deal(address(usdc), account, amount);

        vm.startPrank(account);
        usdc.approve(address(spPrimeVaultUsdc), amount);
        spPrimeVaultUsdc.requestDeposit(amount, account, account);
        vm.stopPrank();
    }

    function _assertVaultState(VaultState memory state) internal view {
        assertEq(spPrimeVaultUsdc.totalSupply(),                                state.totalSupply);
        assertEq(spPrimeVaultUsdc.totalAssets(),                                state.totalAssets);
        assertEq(spPrimeVaultUsdc.availableCapacity(),                          state.availableCapacity);
        assertEq(spPrimeVaultUsdc.availableLiquidAssets(),                      state.availableLiquidAssets);
        assertEq(spPrimeVaultUsdc.claimableDepositRequest(0, state.controller), state.claimableDepositRequest);
        assertEq(spPrimeVaultUsdc.maxDeposit(state.controller),                 state.maxDeposit);
        assertEq(spPrimeVaultUsdc.maxMint(state.controller),                    state.maxMint);
        assertEq(spPrimeVaultUsdc.claimableDepositTotal(),                      state.claimableDepositTotal);
        assertEq(spPrimeVaultUsdc.pendingDepositRequest(0, state.controller),   state.pendingDepositRequest);
        assertEq(spPrimeVaultUsdc.totalPendingDeposits(),                       state.totalPendingDeposits);
        assertEq(spPrimeVaultUsdc.depositQueueLength(),                         state.depositQueueLength);
        assertEq(spPrimeVaultUsdc.requestNonce(state.controller),               state.requestNonce);
        assertEq(spPrimeVaultUsdc.index(),                                      state.index);
        assertEq(spPrimeVaultUsdc.lastAccrual(),                                state.lastAccrual);
    }

    function _assertQueuedDepositRequest(
        address                   controller,
        uint256                   nonce,
        IVault.Transaction memory expected
    )
        internal view
    {
        IVault.Transaction memory queued = spPrimeVaultUsdc.queuedDepositRequest(controller, nonce);

        assertEq(queued.controller, expected.controller);
        assertEq(queued.owner,      expected.owner);
        assertEq(queued.amount,     expected.amount);
        assertEq(queued.nonce,      expected.nonce);
        assertEq(queued.fee,        expected.fee);
    }

}
