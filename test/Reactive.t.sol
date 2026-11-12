// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { DemoToken } from "../src/DemoToken.sol";
import { MockPriceFeed } from "../src/MockPriceFeed.sol";
import { LimitOrderRegistry } from "../src/LimitOrderRegistry.sol";
import { LimitOrderReactive } from "../src/LimitOrderReactive.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";

/// @notice Stand-in for the real Lasna system contract. Etched at the SYSTEM address so
///         the reactive contract's subscribe / requestCallback calls land somewhere
///         observable. Records every subscription and callback request for assertions.
contract MockSystem {
    struct Subscription {
        uint256 chainId;
        address contractAddr;
        uint256 topic0;
        uint256 topic1;
        uint256 topic2;
        uint256 topic3;
    }

    struct CallbackReq {
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
    }

    Subscription[] public subscriptions;
    CallbackReq[] public callbacks;

    function subscriptionCount() external view returns (uint256) {
        return subscriptions.length;
    }

    function callbackCount() external view returns (uint256) {
        return callbacks.length;
    }

    function subscribe(uint256 chainId_, address contract_, uint256 topic0_, uint256 topic1_, uint256 topic2_, uint256 topic3_)
        external
    {
        subscriptions.push(Subscription(chainId_, contract_, topic0_, topic1_, topic2_, topic3_));
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {}

    function requestCallback(ISystemContract.CallbackVersion, bytes memory) external {}

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config_) external {
        callbacks.push(CallbackReq(config_.chainId, config_.recipient, config_.gasLimit, config_.payload));
    }
}

contract ReactiveTest is Test {
    address internal constant SYSTEM = 0x8888888888888888888888888888888888888888;
    address internal constant LEGACY_SYSTEM = 0x0000000000000000000000000000000000fffFfF;
    uint256 internal constant CRON100_TOPIC_0 = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;

    DemoToken internal tokenA;
    DemoToken internal tokenB;
    MockPriceFeed internal feed;
    LimitOrderRegistry internal registry;
    LimitOrderReactive internal reactive;
    MockSystem internal mockSystem;
    address internal executor = makeAddr("executor");
    address internal user = makeAddr("user");

    bytes32 internal orderCreatedTopic0;
    bytes32 internal orderCancelledTopic0;
    bytes32 internal priceUpdatedTopic0;

    event OrderTriggered(uint256 indexed orderId, int256 price, uint256 nonce);

    function setUp() public {
        tokenA = new DemoToken("Demo ETH", "dETH");
        tokenB = new DemoToken("Demo USD", "dUSD");
        feed = new MockPriceFeed(2000e8);
        registry = new LimitOrderRegistry();
        mockSystem = new MockSystem();
        vm.etch(SYSTEM, address(mockSystem).code);
        reactive = new LimitOrderReactive(1301, address(registry), address(feed));
        reactive.setExecutor(executor);

        orderCreatedTopic0 = keccak256("OrderCreated(uint256,address,address,address,uint256,uint256,bool,uint256)");
        orderCancelledTopic0 = keccak256("OrderCancelled(uint256)");
        priceUpdatedTopic0 = keccak256("PriceUpdated(int256)");

        tokenA.mint(user, 100 ether);
        vm.prank(user);
        tokenA.approve(address(registry), type(uint256).max);
    }

    function _log(uint256 topic0, uint256 topic1, bytes memory data, uint256 opCode, address contractAddr)
        internal
        view
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chainId: 1301,
            contractAddress: contractAddr,
            topic0: topic0,
            topic1: topic1,
            topic2: 0,
            topic3: 0,
            data: data,
            blockNumber: block.number,
            opCode: opCode,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function _mirrorOrder(uint256 orderId) internal {
        bytes memory data = abi.encode(
            user, address(tokenA), address(tokenB), uint256(10 ether), uint256(2100e8), true, block.timestamp + 1 days
        );
        vm.prank(SYSTEM);
        reactive.react(_log(uint256(orderCreatedTopic0), orderId, data, 2, address(registry)));
    }

    function _priceLog(int256 price) internal view returns (IReactive.LogRecord memory) {
        return _log(uint256(priceUpdatedTopic0), 0, abi.encode(price), 1, address(feed));
    }

    function test_mirrorOrderCreated() public {
        _mirrorOrder(1);
        (address o, , , , , , , bool active) = reactive.orders(1);
        assertEq(o, user);
        assertTrue(active);
        uint256[] memory act = reactive.getActiveOrders();
        assertEq(act.length, 1);
        assertEq(act[0], 1);
    }

    function test_unmirrorOnCancel() public {
        _mirrorOrder(1);
        vm.prank(SYSTEM);
        reactive.react(_log(uint256(orderCancelledTopic0), 1, "", 2, address(registry)));
        (, , , , , , , bool active) = reactive.orders(1);
        assertFalse(active);
        assertEq(reactive.getActiveOrders().length, 0);
    }

    function test_subscribesOnDeploy() public view {
        // NOTE: the mock's code is etched at SYSTEM, so its state lives at SYSTEM's
        // address — read it through MockSystem(SYSTEM), not the mock instance.
        assertEq(MockSystem(SYSTEM).subscriptionCount(), 4);
        (uint256 chainId, address contractAddr, uint256 topic0,,,) = MockSystem(SYSTEM).subscriptions(0);
        assertEq(chainId, 1301);
        assertEq(contractAddr, address(registry));
        assertEq(topic0, uint256(orderCreatedTopic0));
    }

    function test_priceAboveTriggers() public {
        _mirrorOrder(1);
        vm.prank(SYSTEM);
        vm.expectEmit(true, false, false, true, address(reactive));
        emit OrderTriggered(1, 2100e8, 1);
        reactive.react(_priceLog(2100e8));
        assertEq(reactive.callbackNonce(), 1);
        assertEq(reactive.lastPrice(), 2100e8);
        assertEq(reactive.getActiveOrders().length, 0);
        // The callback request must target the executor with a decodable payload.
        assertEq(MockSystem(SYSTEM).callbackCount(), 1);
        (uint256 chainId, address recipient, uint64 gasLimit, bytes memory payload) = MockSystem(SYSTEM).callbacks(0);
        assertEq(chainId, 1301);
        assertEq(recipient, executor);
        assertGe(gasLimit, 100000);
        (address r, uint256 orderId, uint256 price, uint256 nonce) =
            abi.decode(_stripSelector(payload), (address, uint256, uint256, uint256));
        assertEq(r, address(0)); // placeholder the network replaces with the reactive address
        assertEq(orderId, 1);
        assertEq(price, 2100e8);
        assertEq(nonce, 1);
    }

    function _stripSelector(bytes memory payload) internal pure returns (bytes memory) {
        bytes memory body = new bytes(payload.length - 4);
        for (uint256 i = 0; i < body.length; i++) {
            body[i] = payload[i + 4];
        }
        return body;
    }

    function test_priceBelowThresholdDoesNotTrigger() public {
        _mirrorOrder(1);
        vm.prank(SYSTEM);
        reactive.react(_priceLog(2050e8));
        assertEq(reactive.callbackNonce(), 0);
        assertEq(reactive.getActiveOrders().length, 1);
    }

    function test_belowDirectionTriggers() public {
        bytes memory data = abi.encode(
            user, address(tokenA), address(tokenB), uint256(10 ether), uint256(1900e8), false, block.timestamp + 1 days
        );
        vm.prank(SYSTEM);
        reactive.react(_log(uint256(orderCreatedTopic0), 7, data, 2, address(registry)));
        vm.prank(SYSTEM);
        reactive.react(_priceLog(1900e8));
        assertEq(reactive.callbackNonce(), 1);
        assertEq(reactive.getActiveOrders().length, 0);
    }

    function test_triggerOnlyOnce() public {
        _mirrorOrder(1);
        vm.prank(SYSTEM);
        reactive.react(_priceLog(2100e8));
        vm.prank(SYSTEM);
        reactive.react(_priceLog(2200e8));
        assertEq(reactive.callbackNonce(), 1); // second price move finds no active order
    }

    function test_noExecutorNoTrigger() public {
        LimitOrderReactive unwired = new LimitOrderReactive(1301, address(registry), address(feed));
        bytes memory data = abi.encode(
            user, address(tokenA), address(tokenB), uint256(10 ether), uint256(2100e8), true, block.timestamp + 1 days
        );
        vm.prank(SYSTEM);
        unwired.react(_log(uint256(orderCreatedTopic0), 1, data, 2, address(registry)));
        vm.prank(SYSTEM);
        unwired.react(_priceLog(2100e8));
        assertEq(unwired.callbackNonce(), 0);
        assertEq(unwired.getActiveOrders().length, 1);
    }

    function test_onlySystemCanReact() public {
        vm.expectRevert();
        reactive.react(_priceLog(2100e8));
    }

    function test_unknownLogIgnored() public {
        _mirrorOrder(1);
        vm.prank(SYSTEM);
        reactive.react(_log(uint256(keccak256("SomethingElse(uint256)")), 0, abi.encode(uint256(1)), 1, address(feed)));
        assertEq(reactive.callbackNonce(), 0);
        assertEq(reactive.getActiveOrders().length, 1);
    }

    function test_cronSweepsExpired() public {
        _mirrorOrder(1);
        vm.warp(block.timestamp + 2 days);
        IReactive.LogRecord memory cron = IReactive.LogRecord({
            chainId: 5318007,
            contractAddress: LEGACY_SYSTEM,
            topic0: CRON100_TOPIC_0,
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: abi.encode(block.number),
            blockNumber: block.number,
            opCode: 1,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
        vm.prank(SYSTEM);
        reactive.react(cron);
        assertEq(reactive.getActiveOrders().length, 0);
    }
}
