// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title DemoAMM
/// @notice Small constant-product AMM (tokenA/tokenB) with a 0.3% fee. This is an honest
///         stand-in for the DEX leg: swaps are REAL on-chain trades against real reserves.
///         The mainnet version points the executor at real Uniswap v4 instead.
/// @dev LP shares use sqrt(x*y) for the first deposit, then the proportional minimum.
contract DemoAMM {
    address public immutable tokenA;
    address public immutable tokenB;
    uint256 public reserveA;
    uint256 public reserveB;
    uint256 public totalShares;
    mapping(address => uint256) public shares;
    uint256 public constant FEE_BPS = 30; // 0.3%

    event LiquidityAdded(address indexed provider, uint256 amountA, uint256 amountB, uint256 shares);
    event LiquidityRemoved(address indexed provider, uint256 amountA, uint256 amountB, uint256 shares);
    event Swap(address indexed sender, address indexed tokenIn, uint256 amountIn, uint256 amountOut);

    constructor(address tokenA_, address tokenB_) {
        require(tokenA_ != tokenB_, "same token");
        tokenA = tokenA_;
        tokenB = tokenB_;
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function addLiquidity(uint256 amountA, uint256 amountB) external returns (uint256 minted) {
        require(amountA > 0 && amountB > 0, "zero");
        if (totalShares == 0) {
            minted = _sqrt(amountA * amountB);
        } else {
            uint256 a = amountA * totalShares / reserveA;
            uint256 b = amountB * totalShares / reserveB;
            minted = a < b ? a : b;
        }
        require(minted > 0, "no shares");
        require(IERC20Minimal(tokenA).transferFrom(msg.sender, address(this), amountA), "transferA");
        require(IERC20Minimal(tokenB).transferFrom(msg.sender, address(this), amountB), "transferB");
        reserveA += amountA;
        reserveB += amountB;
        totalShares += minted;
        shares[msg.sender] += minted;
        emit LiquidityAdded(msg.sender, amountA, amountB, minted);
    }

    function removeLiquidity(uint256 shareAmount) external returns (uint256 amountA, uint256 amountB) {
        require(shareAmount > 0 && shares[msg.sender] >= shareAmount, "shares");
        amountA = shareAmount * reserveA / totalShares;
        amountB = shareAmount * reserveB / totalShares;
        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;
        reserveA -= amountA;
        reserveB -= amountB;
        require(IERC20Minimal(tokenA).transfer(msg.sender, amountA), "transferA");
        require(IERC20Minimal(tokenB).transfer(msg.sender, amountB), "transferB");
        emit LiquidityRemoved(msg.sender, amountA, amountB, shareAmount);
    }

    function getAmountOut(address tokenIn, uint256 amountIn) public view returns (uint256) {
        require(tokenIn == tokenA || tokenIn == tokenB, "token");
        (uint256 reserveIn, uint256 reserveOut) = tokenIn == tokenA ? (reserveA, reserveB) : (reserveB, reserveA);
        require(reserveIn > 0 && reserveOut > 0, "empty");
        uint256 amountInWithFee = amountIn * (10000 - FEE_BPS);
        return amountInWithFee * reserveOut / (reserveIn * 10000 + amountInWithFee);
    }

    function swap(address tokenIn, uint256 amountIn, uint256 minOut) external returns (uint256 amountOut) {
        amountOut = getAmountOut(tokenIn, amountIn);
        require(amountOut >= minOut, "slippage");
        require(IERC20Minimal(tokenIn).transferFrom(msg.sender, address(this), amountIn), "transferIn");
        address tokenOut = tokenIn == tokenA ? tokenB : tokenA;
        if (tokenIn == tokenA) {
            reserveA += amountIn;
            reserveB -= amountOut;
        } else {
            reserveB += amountIn;
            reserveA -= amountOut;
        }
        require(IERC20Minimal(tokenOut).transfer(msg.sender, amountOut), "transferOut");
        emit Swap(msg.sender, tokenIn, amountIn, amountOut);
    }
}
