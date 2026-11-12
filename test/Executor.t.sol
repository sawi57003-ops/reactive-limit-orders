// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { DemoToken } from "../src/DemoToken.sol";
import { DemoAMM } from "../src/DemoAMM.sol";
import { LimitOrderRegistry } from "../src/LimitOrderRegistry.sol";
import { LimitOrderExecutor } from "../src/LimitOrderExecutor.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";

contract ExecutorTest is Test {
    DemoToken internal tokenA;
    DemoToken internal tokenB;
    DemoAMM internal amm;
    LimitOrderRegistry internal registry;
    LimitOrderExecutor internal executor;
    address payable internal proxy = payable(makeAddr("proxy"));
    address internal reactive = makeAddr("reactive");
    address internal user = makeAddr("user");

    function setUp() public {
        tokenA = new DemoToken("Demo ETH", "dETH");
        tokenB = new DemoToken("Demo USD", "dUSD");
        amm = new DemoAMM(address(tokenA), address(tokenB));
        registry = new LimitOrderRegistry();
        executor = new LimitOrderExecutor(IPayable(proxy), reactive, address(registry), address(amm));
        registry.setExecutor(address(executor));

        // Seed the AMM: 10,000 A + 20,000,000 B (spot 2000 B per A).
        tokenA.mint(address(this), 1_000_000 ether);
        tokenB.mint(address(this), 1_000_000_000 ether);
        tokenA.approve(address(amm), type(uint256).max);
        tokenB.approve(address(amm), type(uint256).max);
        amm.addLiquidity(10_000 ether, 20_000_000 ether);

        // User funds + approves the registry.
        tokenA.mint(user, 100 ether);
        vm.prank(user);
        tokenA.approve(address(registry), type(uint256).max);
    }

    function _createOrder() internal returns (uint256) {
        vm.prank(user);
        return registry.createOrder(address(tokenA), address(tokenB), 10 ether, 2100e8, true, block.timestamp + 1 days);
    }

    function test_happyPathFill() public {
        uint256 id = _createOrder();
        uint256 userBBefore = tokenB.balanceOf(user);
        vm.prank(proxy);
        executor.executeFill(reactive, id, 2100e8, 1);
        uint256 received = tokenB.balanceOf(user) - userBBefore;
        assertGt(received, 19_900 ether); // 10 A -> ~19,940 B
        assertLt(received, 20_000 ether);
        assertEq(uint256(registry.getOrder(id).status), 1); // Filled
        assertEq(executor.lastNonce(reactive), 1);
    }

    function test_onlyProxyCanCall() public {
        uint256 id = _createOrder();
        vm.expectRevert();
        executor.executeFill(reactive, id, 2100e8, 1);
    }

    function test_onlyAuthorizedReactive() public {
        uint256 id = _createOrder();
        vm.prank(proxy);
        vm.expectRevert();
        executor.executeFill(makeAddr("other-reactive"), id, 2100e8, 1);
    }

    function test_staleNonceReverts() public {
        uint256 id = _createOrder();
        vm.prank(proxy);
        executor.executeFill(reactive, id, 2100e8, 1);
        uint256 id2 = _createOrder();
        vm.prank(proxy);
        vm.expectRevert("stale nonce");
        executor.executeFill(reactive, id2, 2100e8, 1);
    }

    function test_doubleFillReverts() public {
        uint256 id = _createOrder();
        vm.prank(proxy);
        executor.executeFill(reactive, id, 2100e8, 1);
        vm.prank(proxy);
        vm.expectRevert("not active");
        executor.executeFill(reactive, id, 2100e8, 2);
    }

    function test_expiredOrderReverts() public {
        uint256 id = _createOrder();
        vm.warp(block.timestamp + 2 days);
        vm.prank(proxy);
        vm.expectRevert("expired");
        executor.executeFill(reactive, id, 2100e8, 1);
    }
}
