// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { DemoToken } from "../src/DemoToken.sol";
import { DemoAMM } from "../src/DemoAMM.sol";

contract DemoAMMTest is Test {
    DemoToken internal tokenA;
    DemoToken internal tokenB;
    DemoAMM internal amm;

    function setUp() public {
        tokenA = new DemoToken("Demo ETH", "dETH");
        tokenB = new DemoToken("Demo USD", "dUSD");
        tokenA.mint(address(this), 1_000_000 ether);
        tokenB.mint(address(this), 1_000_000_000 ether);
        amm = new DemoAMM(address(tokenA), address(tokenB));
        tokenA.approve(address(amm), type(uint256).max);
        tokenB.approve(address(amm), type(uint256).max);
        amm.addLiquidity(10_000 ether, 20_000_000 ether); // spot: 2000 B per A
    }

    function test_spotPrice() public view {
        // 1 A should buy ~1994 B (0.3% fee + tiny slippage).
        uint256 out = amm.getAmountOut(address(tokenA), 1 ether);
        assertGt(out, 1990 ether);
        assertLt(out, 2000 ether);
    }

    function test_swapUpdatesReserves() public {
        uint256 out = amm.swap(address(tokenA), 1 ether, 0);
        assertGt(out, 1990 ether);
        assertEq(amm.reserveA(), 10_001 ether);
        assertEq(amm.reserveB(), 20_000_000 ether - out);
        assertEq(tokenB.balanceOf(address(this)), 1_000_000_000 ether - 20_000_000 ether + out);
    }

    function test_swapSlippageReverts() public {
        vm.expectRevert("slippage");
        amm.swap(address(tokenA), 1 ether, 2000 ether);
    }

    function test_swapBothDirections() public {
        uint256 outB = amm.swap(address(tokenA), 10 ether, 0);
        assertGt(outB, 19_900 ether);
        uint256 outA = amm.swap(address(tokenB), outB, 0);
        // Round trip loses value to fees + price impact.
        assertLt(outA, 10 ether);
        assertGt(outA, 9 ether);
    }

    function test_removeLiquidityProportional() public {
        uint256 shares = amm.shares(address(this));
        (uint256 a, uint256 b) = amm.removeLiquidity(shares / 2);
        assertEq(a, 5_000 ether);
        assertEq(b, 10_000_000 ether);
    }

    function test_emptyPoolReverts() public {
        DemoAMM empty = new DemoAMM(address(tokenA), address(tokenB));
        vm.expectRevert("empty");
        empty.getAmountOut(address(tokenA), 1 ether);
    }
}
