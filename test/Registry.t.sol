// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { DemoToken } from "../src/DemoToken.sol";
import { LimitOrderRegistry } from "../src/LimitOrderRegistry.sol";

contract RegistryTest is Test {
    DemoToken internal tokenA;
    DemoToken internal tokenB;
    LimitOrderRegistry internal registry;
    address internal user = makeAddr("user");
    address internal executor = makeAddr("executor");

    function setUp() public {
        tokenA = new DemoToken("Demo ETH", "dETH");
        tokenB = new DemoToken("Demo USD", "dUSD");
        registry = new LimitOrderRegistry();
        registry.setExecutor(executor);
        tokenA.mint(user, 100 ether);
        vm.prank(user);
        tokenA.approve(address(registry), type(uint256).max);
    }

    function _createOrder() internal returns (uint256) {
        vm.prank(user);
        return registry.createOrder(address(tokenA), address(tokenB), 10 ether, 2100e8, true, block.timestamp + 1 days);
    }

    function test_createEscrowsFunds() public {
        uint256 id = _createOrder();
        assertEq(id, 1);
        assertEq(tokenA.balanceOf(address(registry)), 10 ether);
        assertEq(tokenA.balanceOf(user), 90 ether);
        LimitOrderRegistry.Order memory o = registry.getOrder(id);
        assertEq(uint256(o.status), 0); // Active
        assertEq(o.amountIn, 10 ether);
        assertTrue(o.above);
    }

    function test_cancelRefunds() public {
        uint256 id = _createOrder();
        vm.prank(user);
        registry.cancelOrder(id);
        assertEq(tokenA.balanceOf(user), 100 ether);
        assertEq(tokenA.balanceOf(address(registry)), 0);
        assertEq(uint256(registry.getOrder(id).status), 2); // Cancelled
    }

    function test_cancelOnlyOwner() public {
        uint256 id = _createOrder();
        vm.expectRevert("not order owner");
        registry.cancelOrder(id);
    }

    function test_cancelFilledReverts() public {
        uint256 id = _createOrder();
        vm.prank(executor);
        registry.fillOrder(id);
        vm.prank(user);
        vm.expectRevert("not active");
        registry.cancelOrder(id);
    }

    function test_fillOnlyExecutor() public {
        uint256 id = _createOrder();
        vm.expectRevert("not executor");
        registry.fillOrder(id);
    }

    function test_fillReleasesEscrowOnce() public {
        uint256 id = _createOrder();
        vm.prank(executor);
        (address tokenIn, address tokenOut, uint256 amountIn, address orderOwner) = registry.fillOrder(id);
        assertEq(tokenIn, address(tokenA));
        assertEq(tokenOut, address(tokenB));
        assertEq(amountIn, 10 ether);
        assertEq(orderOwner, user);
        assertEq(tokenA.balanceOf(executor), 10 ether);
        assertEq(uint256(registry.getOrder(id).status), 1); // Filled
        vm.prank(executor);
        vm.expectRevert("not active");
        registry.fillOrder(id);
    }

    function test_fillExpiredReverts() public {
        uint256 id = _createOrder();
        vm.warp(block.timestamp + 2 days);
        vm.prank(executor);
        vm.expectRevert("expired");
        registry.fillOrder(id);
    }

    function test_createExpiredReverts() public {
        vm.prank(user);
        vm.expectRevert("expired");
        registry.createOrder(address(tokenA), address(tokenB), 1 ether, 2100e8, true, block.timestamp);
    }

    function test_createZeroAmountReverts() public {
        vm.prank(user);
        vm.expectRevert("zero amount");
        registry.createOrder(address(tokenA), address(tokenB), 0, 2100e8, true, block.timestamp + 1 days);
    }
}
