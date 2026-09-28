// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.36;

/// @notice what PoolManager needs to turn ticket money into the pot currency. implementations own the dex specifics
///         (routing, price check), so the manager can move to another dex by pointing at a new swapper
interface ISwapper {
    error NO_ROUTE(address tokenIn, address tokenOut);
    error SWAP_OUTPUT_TOO_LOW(uint256 minOut, uint256 received);

    event Swapped(address indexed recipient, bytes route, uint256 amountIn, uint256 amountOut, uint256 minOut);
    event SwappedExactOut(
        address indexed recipient, bytes route, uint256 amountIn, uint256 amountOut, uint256 refunded
    );

    /// @notice best route from tokenIn to tokenOut, found on chain. reverts with NO_ROUTE if there is none
    function findRoute(address tokenIn, address tokenOut) external view returns (bytes memory route);

    /// @notice least amount of the route's last token a swap of amountIn must return (fair price minus slippage)
    function minOut(bytes calldata route, uint256 amountIn) external view returns (uint256);

    /// @notice pulls amountIn of the route's first token from msg.sender (needs an approval), swaps along `route` and
    ///         sends the output to `recipient`. reverts if recipient gets less than minOut(route, amountIn)
    function swap(bytes calldata route, uint256 amountIn, address recipient) external returns (uint256 amountOut);

    /// @notice buys exactly amountOut of tokenOut for `recipient` spending at most maxAmountIn of tokenIn, along
    ///         findRoute. tokenIn = address(0) means native: send maxAmountIn as msg.value. otherwise pulls
    ///         maxAmountIn from msg.sender (needs an approval). the unspent input goes back to `refundTo`.
    ///         no twap check: the caller's own maxAmountIn is the slippage limit
    function swapExactOut(
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        uint256 maxAmountIn,
        address recipient,
        address refundTo
    ) external payable returns (uint256 amountIn);
}
