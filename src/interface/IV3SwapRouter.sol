// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.36;

/// @notice the part of the pancakeswap v3 SmartRouter (same as uniswap SwapRouter02) PoolManager uses:
///         multi hop exact input / exact output, no deadline field
interface IV3SwapRouter {
    struct ExactInputParams {
        /// tokenIn | fee (uint24) | token | fee | ... | tokenOut, abi.encodePacked
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);

    struct ExactOutputParams {
        /// reversed: tokenOut | fee | token | ... | tokenIn
        bytes path;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
    }

    function exactOutput(ExactOutputParams calldata params) external payable returns (uint256 amountIn);
}
