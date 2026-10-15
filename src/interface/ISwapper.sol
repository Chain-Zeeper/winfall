// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.36;

/// @notice what PoolManager needs to price a pot in another currency and to turn a buyer's payment into the tokens a
///         purchase owes. implementations own the dex specifics, so the manager can move to another dex by pointing
///         at a new swapper
interface ISwapper {
    error NO_ROUTE(address tokenIn, address tokenOut);
    error SWAP_OUTPUT_TOO_LOW(uint256 minOut, uint256 received);
    error SWAP_INPUT_TOO_HIGH(uint256 maxAmountIn, uint256 needed);

    event SwappedExactOut(
        address indexed recipient, bytes route, uint256 amountIn, uint256 amountOut, uint256 refunded
    );

    /// @notice best route from tokenIn to tokenOut, found on chain. reverts with NO_ROUTE if there is none
    function findRoute(address tokenIn, address tokenOut) external view returns (bytes memory route);

    /// @notice what amountIn of the route's first token is worth in its last token at a price that can't be moved
    ///         within one transaction (a twap). a price, not a swap result: no fee, impact or margin in it
    function quote(bytes calldata route, uint256 amountIn) external view returns (uint256);

    /// @notice buys exactly amountOut of tokenOut for `recipient` spending at most maxAmountIn of tokenIn, along
    ///         findRoute. tokenIn = address(0) means native: send maxAmountIn as msg.value. otherwise pulls
    ///         maxAmountIn from msg.sender (needs an approval). the unspent input goes back to `refundTo`.
    ///         the caller's own maxAmountIn is the limit on what it costs
    function swapExactOut(
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        uint256 maxAmountIn,
        address recipient,
        address refundTo
    ) external payable returns (uint256 amountIn);
}
