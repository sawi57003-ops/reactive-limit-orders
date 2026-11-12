// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title MockPriceFeed
/// @notice Chainlink AggregatorV3-compatible price feed for the demo. The owner moves
///         the price; every move emits PriceUpdated, which LimitOrderReactive subscribes to.
/// @dev 8 decimals, same convention as Chainlink ETH/USD. Production config swaps this
///      address for the real Chainlink ETH/USD feed on Sepolia
///      (0x694AA1769357215DE4FAC081bf1f309aDC325306 — verified live 12 Nov 2026,
///      latestRoundData returned $2,050.72).
contract MockPriceFeed {
    int256 public price;
    uint80 public roundId;
    address public owner;
    uint8 public constant decimals = 8;

    event PriceUpdated(int256 price);

    constructor(int256 initialPrice) {
        owner = msg.sender;
        price = initialPrice;
        roundId = 1;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    function setPrice(int256 newPrice) external onlyOwner {
        price = newPrice;
        roundId += 1;
        emit PriceUpdated(newPrice);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, price, block.timestamp, block.timestamp, roundId);
    }

    function description() external pure returns (string memory) {
        return "MockPriceFeed: demo token price, 8 decimals";
    }
}
