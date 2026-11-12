// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title LimitOrderRegistry
/// @notice Users escrow demo tokens here against a price threshold. A limit order sells
///         `tokenIn` for `tokenOut` when the feed price crosses `threshold` (`above` picks
///         the direction). Orders can be cancelled for a full refund before they fill.
/// @dev Only the registered executor can release escrow (via fillOrder), and only once:
///      status flips to Filled atomically in the same call. The reactive contract mirrors
///      orders purely from the OrderCreated / OrderCancelled events.
contract LimitOrderRegistry {
    enum Status {
        Active,
        Filled,
        Cancelled
    }

    struct Order {
        address owner;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 threshold;
        bool above;
        uint256 expiry;
        Status status;
    }

    uint256 public nextOrderId = 1;
    mapping(uint256 => Order) public orders;
    address public executor;
    address public owner;

    event OrderCreated(
        uint256 indexed orderId,
        address owner,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 threshold,
        bool above,
        uint256 expiry
    );
    event OrderCancelled(uint256 indexed orderId);
    event OrderFilled(uint256 indexed orderId, address indexed executor);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier onlyExecutor() {
        require(msg.sender == executor, "not executor");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function setExecutor(address executor_) external onlyOwner {
        executor = executor_;
    }

    function createOrder(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 threshold,
        bool above,
        uint256 expiry
    ) external returns (uint256 orderId) {
        require(amountIn > 0, "zero amount");
        require(threshold > 0, "zero threshold");
        require(expiry > block.timestamp, "expired");
        require(tokenIn != tokenOut, "same token");
        orderId = nextOrderId++;
        orders[orderId] = Order({
            owner: msg.sender,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            threshold: threshold,
            above: above,
            expiry: expiry,
            status: Status.Active
        });
        require(IERC20Minimal(tokenIn).transferFrom(msg.sender, address(this), amountIn), "escrow");
        emit OrderCreated(orderId, msg.sender, tokenIn, tokenOut, amountIn, threshold, above, expiry);
    }

    function cancelOrder(uint256 orderId) external {
        Order storage o = orders[orderId];
        require(o.owner == msg.sender, "not order owner");
        require(o.status == Status.Active, "not active");
        o.status = Status.Cancelled;
        require(IERC20Minimal(o.tokenIn).transfer(msg.sender, o.amountIn), "refund");
        emit OrderCancelled(orderId);
    }

    /// @notice Called by the executor after a callback proved the trigger. Releases the
    ///         escrow to the executor and marks the order Filled, atomically.
    function fillOrder(uint256 orderId)
        external
        onlyExecutor
        returns (address tokenIn, address tokenOut, uint256 amountIn, address orderOwner)
    {
        Order storage o = orders[orderId];
        require(o.status == Status.Active, "not active");
        require(block.timestamp <= o.expiry, "expired");
        o.status = Status.Filled;
        require(IERC20Minimal(o.tokenIn).transfer(msg.sender, o.amountIn), "release");
        emit OrderFilled(orderId, msg.sender);
        return (o.tokenIn, o.tokenOut, o.amountIn, o.owner);
    }

    function getOrder(uint256 orderId) external view returns (Order memory) {
        return orders[orderId];
    }
}
