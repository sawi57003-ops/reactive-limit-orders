// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { DemoToken } from "../src/DemoToken.sol";
import { DemoAMM } from "../src/DemoAMM.sol";
import { LimitOrderRegistry } from "../src/LimitOrderRegistry.sol";
import { LimitOrderExecutor } from "../src/LimitOrderExecutor.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";

/// @notice Handler driving randomized registry + AMM activity. Ghost state tracks the
///         accounting the invariants check.
contract LimitOrderHandler is Test {
    DemoToken public tokenA;
    DemoToken public tokenB;
    DemoAMM public amm;
    LimitOrderRegistry public registry;
    LimitOrderExecutor public executor;
    address public proxy;
    address public reactive;

    address[] public users;
    uint256 public ghostActiveEscrow; // sum of amountIn over Active orders (tokenA)
    uint256 public ghostFilledTotal;
    uint256 public ghostCancelledTotal;
    uint256 public ghostCreatedTotal;
    mapping(uint256 => uint256) public orderAmount;
    mapping(uint256 => bool) public orderCounted;

    constructor(
        DemoToken tokenA_,
        DemoToken tokenB_,
        DemoAMM amm_,
        LimitOrderRegistry registry_,
        LimitOrderExecutor executor_,
        address proxy_,
        address reactive_
    ) {
        tokenA = tokenA_;
        tokenB = tokenB_;
        amm = amm_;
        registry = registry_;
        executor = executor_;
        proxy = proxy_;
        reactive = reactive_;
        for (uint256 i = 0; i < 3; i++) {
            address u = makeAddr(string(abi.encodePacked("inv-user-", i)));
            users.push(u);
            vm.prank(u);
            tokenA.approve(address(registry), type(uint256).max);
            vm.prank(u);
            tokenA.approve(address(amm), type(uint256).max);
            vm.prank(u);
            tokenB.approve(address(amm), type(uint256).max);
        }
    }

    function createOrder(uint256 userSeed, uint256 amountSeed, uint256 thresholdSeed, uint256 aboveSeed) public {
        address u = users[userSeed % users.length];
        uint256 amount = bound(amountSeed, 1 ether, 100 ether);
        uint256 threshold = bound(thresholdSeed, 1500e8, 2500e8);
        bool above = aboveSeed % 2 == 0;
        vm.prank(u);
        uint256 id = registry.createOrder(
            address(tokenA), address(tokenB), amount, threshold, above, block.timestamp + 1 days
        );
        orderAmount[id] = amount;
        orderCounted[id] = true;
        ghostActiveEscrow += amount;
        ghostCreatedTotal += amount;
    }

    function cancelOrder(uint256 orderSeed) public {
        uint256 id = bound(orderSeed, 1, registry.nextOrderId() - 1);
        if (registry.nextOrderId() <= 1) return;
        LimitOrderRegistry.Order memory o = registry.getOrder(id);
        if (o.status != LimitOrderRegistry.Status.Active) return;
        vm.prank(o.owner);
        registry.cancelOrder(id);
        ghostActiveEscrow -= o.amountIn;
        ghostCancelledTotal += o.amountIn;
    }

    function fillOrder(uint256 orderSeed, uint256 nonceSeed) public {
        uint256 id = bound(orderSeed, 1, registry.nextOrderId() - 1);
        if (registry.nextOrderId() <= 1) return;
        LimitOrderRegistry.Order memory o = registry.getOrder(id);
        if (o.status != LimitOrderRegistry.Status.Active) return;
        uint256 nonce = bound(nonceSeed, executor.lastNonce(reactive) + 1, executor.lastNonce(reactive) + 100);
        vm.prank(proxy);
        // Fill can revert on expiry/slippage edge cases; only count successes.
        try executor.executeFill(reactive, id, o.threshold, nonce) {
            ghostActiveEscrow -= o.amountIn;
            ghostFilledTotal += o.amountIn;
        } catch {}
    }

    function swap(uint256 userSeed, uint256 amountSeed) public {
        address u = users[userSeed % users.length];
        uint256 amount = bound(amountSeed, 1 ether, 50 ether);
        vm.prank(u);
        try amm.swap(address(tokenA), amount, 0) {} catch {}
    }
}

contract LimitOrderInvariant is Test {
    DemoToken internal tokenA;
    DemoToken internal tokenB;
    DemoAMM internal amm;
    LimitOrderRegistry internal registry;
    LimitOrderExecutor internal executor;
    LimitOrderHandler internal handler;
    address payable internal proxy = payable(makeAddr("proxy"));
    address internal reactive = makeAddr("reactive");
    uint256 internal kAtSeed;

    function setUp() public {
        tokenA = new DemoToken("Demo ETH", "dETH");
        tokenB = new DemoToken("Demo USD", "dUSD");
        amm = new DemoAMM(address(tokenA), address(tokenB));
        registry = new LimitOrderRegistry();
        executor = new LimitOrderExecutor(IPayable(proxy), reactive, address(registry), address(amm));
        registry.setExecutor(address(executor));

        tokenA.mint(address(this), 1_000_000 ether);
        tokenB.mint(address(this), 1_000_000_000 ether);
        tokenA.approve(address(amm), type(uint256).max);
        tokenB.approve(address(amm), type(uint256).max);
        amm.addLiquidity(10_000 ether, 20_000_000 ether);
        kAtSeed = amm.reserveA() * amm.reserveB();

        // Fund the handler's users (the test contract owns the token minters).
        for (uint256 i = 0; i < 3; i++) {
            address u = makeAddr(string(abi.encodePacked("inv-user-", i)));
            tokenA.mint(u, 10_000 ether);
            tokenB.mint(u, 10_000 ether);
        }

        handler = new LimitOrderHandler(tokenA, tokenB, amm, registry, executor, proxy, reactive);
        targetContract(address(handler));
    }

    /// @notice Escrow accounting: the registry must hold exactly the active orders' funds.
    function invariant_escrowAccounting() public view {
        assertEq(tokenA.balanceOf(address(registry)), handler.ghostActiveEscrow());
    }

    /// @notice Conservation: created == active + filled + cancelled.
    function invariant_orderConservation() public view {
        assertEq(
            handler.ghostCreatedTotal(),
            handler.ghostActiveEscrow() + handler.ghostFilledTotal() + handler.ghostCancelledTotal()
        );
    }

    /// @notice The constant-product invariant never decreases through swaps (fees grow k).
    function invariant_ammKNonDecreasing() public view {
        assertGe(amm.reserveA() * amm.reserveB(), kAtSeed);
    }
}
