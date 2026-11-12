// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

/// @title LimitOrderReactive
/// @notice Lives on Lasna. Mirrors limit orders purely from the registry's on-chain
///         events (it cannot read Unichain Sepolia state), watches the price feed's
///         PriceUpdated events, and requests a callback to the executor when a mirrored
///         order's threshold is crossed. A CRON100 tick (~2 min) re-evaluates against the
///         last seen price and sweeps expired orders, as a backup for missed price events.
/// @dev Omni API: react() is guarded by onlySystem; callbacks go through
///      SYSTEM.requestCallbackV_1_0. The contract must stay funded in lREACT (reactive
///      transactions bill the contract). Non-matching logs fall through silently — a
///      revert inside react() still bills gas, so filtering never reverts.
contract LimitOrderReactive is AbstractReactive {
    address internal constant LEGACY_SYSTEM_ADDR = 0x0000000000000000000000000000000000fffFfF;
    uint256 internal constant CRON100_TOPIC_0 = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;
    uint64 internal constant CALLBACK_GAS_LIMIT = 1000000;

    address public owner;
    uint256 public originChainId;
    address public registry;
    address public feed;
    address public executor;

    struct MirrorOrder {
        address owner;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 threshold;
        bool above;
        uint256 expiry;
        bool active;
    }

    mapping(uint256 => MirrorOrder) public orders;
    uint256[] public activeOrderIds;
    mapping(uint256 => uint256) internal activeIndex; // orderId => index + 1
    int256 public lastPrice;
    uint256 public callbackNonce;

    bytes32 public immutable orderCreatedTopic0;
    bytes32 public immutable orderCancelledTopic0;
    bytes32 public immutable priceUpdatedTopic0;

    event OrderMirrored(uint256 indexed orderId);
    event OrderUnmirrored(uint256 indexed orderId);
    event PriceSeen(int256 price);
    event OrderTriggered(uint256 indexed orderId, int256 price, uint256 nonce);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(uint256 originChainId_, address registry_, address feed_) payable {
        owner = msg.sender;
        originChainId = originChainId_;
        registry = registry_;
        feed = feed_;
        orderCreatedTopic0 = keccak256("OrderCreated(uint256,address,address,address,uint256,uint256,bool,uint256)");
        orderCancelledTopic0 = keccak256("OrderCancelled(uint256)");
        priceUpdatedTopic0 = keccak256("PriceUpdated(int256)");
        _subscribe();
    }

    function _subscribe() internal {
        SYSTEM.subscribe(
            originChainId, registry, uint256(orderCreatedTopic0), REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        SYSTEM.subscribe(
            originChainId, registry, uint256(orderCancelledTopic0), REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        SYSTEM.subscribe(
            originChainId, feed, uint256(priceUpdatedTopic0), REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        SYSTEM.subscribe(
            block.chainid, LEGACY_SYSTEM_ADDR, CRON100_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }

    /// @notice Breaks the deploy cycle: the executor needs this contract's address, so it
    ///         is set after the executor deploys. Owner-only.
    function setExecutor(address executor_) external onlyOwner {
        executor = executor_;
    }

    /// @notice Settles outstanding reactive-transaction debt from this contract's balance.
    function coverDebt() external {
        _coverDebt();
    }

    function getActiveOrders() external view returns (uint256[] memory) {
        return activeOrderIds;
    }

    /// @inheritdoc IReactive
    function react(LogRecord memory log_) external onlySystem {
        if (log_.topic0 == uint256(orderCreatedTopic0) && log_.contractAddress == registry) {
            _onOrderCreated(log_);
        } else if (log_.topic0 == uint256(orderCancelledTopic0) && log_.contractAddress == registry) {
            _onOrderCancelled(log_);
        } else if (log_.topic0 == uint256(priceUpdatedTopic0) && log_.contractAddress == feed) {
            int256 price = abi.decode(log_.data, (int256));
            lastPrice = price;
            emit PriceSeen(price);
            _evaluate(price);
        } else if (log_.topic0 == CRON100_TOPIC_0) {
            if (lastPrice != 0) {
                _evaluate(lastPrice);
            }
            _sweepExpired();
        }
        // Unknown logs fall through silently.
    }

    function _onOrderCreated(LogRecord memory log_) internal {
        uint256 orderId = log_.topic1;
        if (orders[orderId].active) {
            return; // Already mirrored (duplicate delivery).
        }
        (address o, address tokenIn, address tokenOut, uint256 amountIn, uint256 threshold, bool above, uint256 expiry)
            = abi.decode(log_.data, (address, address, address, uint256, uint256, bool, uint256));
        orders[orderId] =
            MirrorOrder({ owner: o, tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amountIn, threshold: threshold, above: above, expiry: expiry, active: true });
        activeIndex[orderId] = activeOrderIds.length + 1;
        activeOrderIds.push(orderId);
        emit OrderMirrored(orderId);
    }

    function _onOrderCancelled(LogRecord memory log_) internal {
        uint256 orderId = log_.topic1;
        if (!orders[orderId].active) {
            return;
        }
        _deactivate(orderId);
        emit OrderUnmirrored(orderId);
    }

    function _evaluate(int256 price) internal {
        if (executor == address(0)) {
            return; // Not wired yet; keep mirroring, trigger nothing.
        }
        uint256 i = 0;
        while (i < activeOrderIds.length) {
            uint256 orderId = activeOrderIds[i];
            MirrorOrder storage o = orders[orderId];
            bool expired = block.timestamp > o.expiry;
            bool triggered =
                !expired && (o.above ? price >= int256(o.threshold) : price <= int256(o.threshold));
            if (expired) {
                _deactivateAt(orderId, i);
                // Do not advance i: the swapped-in order now sits at i.
            } else if (triggered) {
                _deactivateAt(orderId, i);
                callbackNonce += 1;
                bytes memory payload = abi.encodeWithSignature(
                    "executeFill(address,uint256,uint256,uint256)", address(0), orderId, uint256(price), callbackNonce
                );
                SYSTEM.requestCallbackV_1_0(
                    ISystemContract.CallbackConfiguration_V_1_0({
                        chainId: originChainId,
                        recipient: executor,
                        gasLimit: CALLBACK_GAS_LIMIT,
                        payload: payload
                    })
                );
                emit OrderTriggered(orderId, price, callbackNonce);
            } else {
                i++;
            }
        }
    }

    function _sweepExpired() internal {
        uint256 i = 0;
        while (i < activeOrderIds.length) {
            uint256 orderId = activeOrderIds[i];
            if (block.timestamp > orders[orderId].expiry) {
                _deactivateAt(orderId, i);
            } else {
                i++;
            }
        }
    }

    function _deactivate(uint256 orderId) internal {
        uint256 idx = activeIndex[orderId];
        if (idx == 0) {
            return;
        }
        _deactivateAt(orderId, idx - 1);
    }

    function _deactivateAt(uint256 orderId, uint256 index) internal {
        orders[orderId].active = false;
        uint256 last = activeOrderIds.length - 1;
        if (index != last) {
            uint256 moved = activeOrderIds[last];
            activeOrderIds[index] = moved;
            activeIndex[moved] = index + 1;
        }
        activeOrderIds.pop();
        delete activeIndex[orderId];
    }
}
