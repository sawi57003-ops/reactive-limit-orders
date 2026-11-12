// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

interface IRegistry {
    function fillOrder(uint256 orderId)
        external
        returns (address tokenIn, address tokenOut, uint256 amountIn, address orderOwner);
}

interface IAMM {
    function getAmountOut(address tokenIn, uint256 amountIn) external view returns (uint256);
    function swap(address tokenIn, uint256 amountIn, uint256 minOut) external returns (uint256 amountOut);
}

interface IERC20Minimal {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title LimitOrderExecutor
/// @notice Lives on Unichain Sepolia. Receives callbacks from LimitOrderReactive and
///         executes the fill: pulls the escrow from the registry, swaps it on DemoAMM,
///         and pays the proceeds to the order owner — all atomically, so a failed swap
///         reverts the whole fill.
/// @dev Authentication is double, per Reactive docs: onlyServiceProvider (caller is the
///      official callback proxy) AND onlyCallbackSender (the injected first argument is
///      the authorized reactive contract). A strictly increasing per-reactive nonce
///      blocks replays; the registry's Filled flag is a second layer.
contract LimitOrderExecutor is AbstractCallback {
    address public immutable registry;
    address public immutable amm;
    mapping(address => uint256) public lastNonce;

    event OrderExecuted(
        uint256 indexed orderId, address indexed owner, uint256 amountIn, uint256 amountOut, uint256 price, uint256 nonce
    );

    constructor(IPayable callbackProxy_, address callbackSender_, address registry_, address amm_)
        payable
        AbstractCallback(callbackProxy_, callbackSender_)
    {
        registry = registry_;
        amm = amm_;
    }

    function executeFill(address reactive_, uint256 orderId, uint256 price, uint256 nonce)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        require(nonce > lastNonce[reactive_], "stale nonce");
        lastNonce[reactive_] = nonce;
        (address tokenIn, address tokenOut, uint256 amountIn, address orderOwner) =
            IRegistry(registry).fillOrder(orderId);
        uint256 expectedOut = IAMM(amm).getAmountOut(tokenIn, amountIn);
        uint256 minOut = expectedOut * 99 / 100; // 1% slippage tolerance
        require(IERC20Minimal(tokenIn).approve(amm, amountIn), "approve");
        uint256 amountOut = IAMM(amm).swap(tokenIn, amountIn, minOut);
        require(IERC20Minimal(tokenOut).transfer(orderOwner, amountOut), "payout");
        emit OrderExecuted(orderId, orderOwner, amountIn, amountOut, price, nonce);
    }

    /// @notice Settles outstanding callback debt from this contract's own balance.
    function coverDebt() external {
        _coverDebt();
    }
}
