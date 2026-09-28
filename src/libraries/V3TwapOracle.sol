// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
// pancake's own TickMath is pinned to solidity <0.8, uniswap's 0.8 port has the exact same constants and logic
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {IPancakeV3Factory} from "@pancakeswap/v3-core/contracts/interfaces/IPancakeV3Factory.sol";
import {IPancakeV3Pool} from "@pancakeswap/v3-core/contracts/interfaces/IPancakeV3Pool.sol";
import {
    IPancakeV3PoolDerivedState
} from "@pancakeswap/v3-core/contracts/interfaces/pool/IPancakeV3PoolDerivedState.sol";

/// @notice time weighted average price quotes from pancakeswap v3 pools. a twap can't be moved inside one
///         transaction, so it's a safe reference to check a swap against, unlike the pool's current price
/// @dev every pool on the path needs enough observation slots for the window: call
///      increaseObservationCardinalityNext on it once (e.g. window / block time), otherwise observe() reverts with "OLD"
library V3TwapOracle {
    error NO_POOL(address tokenA, address tokenB, uint24 fee);
    error AMOUNT_TOO_LARGE();

    /// @notice twap quote of amountIn along a packed v3 path (tokenIn | fee | token | ... | tokenOut)
    function quotePath(address factory, bytes memory path, uint256 amountIn, uint32 window)
        internal
        view
        returns (uint256 amountOut)
    {
        amountOut = amountIn;
        uint256 hops = (path.length - 20) / 23;
        for (uint256 i = 0; i < hops; i++) {
            uint256 offset = i * 23;
            address tokenIn = _address(path, offset);
            uint24 fee = _fee(path, offset + 20);
            address tokenOut = _address(path, offset + 23);

            address pool = IPancakeV3Factory(factory).getPool(tokenIn, tokenOut, fee);
            require(pool != address(0), NO_POOL(tokenIn, tokenOut, fee));
            require(amountOut <= type(uint128).max, AMOUNT_TOO_LARGE());
            (int24 tick,) = consult(pool, window);
            amountOut = quoteAtTick(tick, uint128(amountOut), tokenIn, tokenOut);
        }
    }

    /// @notice mean tick (rounded toward negative infinity) and harmonic mean liquidity of `pool` over the last
    ///         `window` seconds (port of uniswap OracleLibrary.consult). both are time weighted, so liquidity added
    ///         and removed within one transaction barely moves them
    function consult(address pool, uint32 window) internal view returns (int24 tick, uint128 harmonicMeanLiquidity) {
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            IPancakeV3Pool(pool).observe(_secondsAgos(window));
        return _average(tickCumulatives, secondsPerLiquidityCumulativeX128s, window);
    }

    /// @notice like consult, but returns ok = false instead of reverting when the pool can't answer for the window
    ///         (too young / not enough observation slots)
    function tryConsult(address pool, uint32 window)
        internal
        view
        returns (bool ok, int24 tick, uint128 harmonicMeanLiquidity)
    {
        (bool success, bytes memory data) =
            pool.staticcall(abi.encodeCall(IPancakeV3PoolDerivedState.observe, (_secondsAgos(window))));
        if (!success || data.length == 0) {
            return (false, 0, 0);
        }
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            abi.decode(data, (int56[], uint160[]));
        (tick, harmonicMeanLiquidity) = _average(tickCumulatives, secondsPerLiquidityCumulativeX128s, window);
        ok = true;
    }

    function _secondsAgos(uint32 window) private pure returns (uint32[] memory secondsAgos) {
        secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        secondsAgos[1] = 0;
    }

    function _average(
        int56[] memory tickCumulatives,
        uint160[] memory secondsPerLiquidityCumulativeX128s,
        uint32 window
    ) private pure returns (int24 tick, uint128 harmonicMeanLiquidity) {
        int56 delta = tickCumulatives[1] - tickCumulatives[0];
        int56 w = int56(uint56(window));
        tick = int24(delta / w);
        if (delta < 0 && delta % w != 0) {
            tick--;
        }

        uint160 secondsPerLiquidityDelta = secondsPerLiquidityCumulativeX128s[1] - secondsPerLiquidityCumulativeX128s[0];
        if (secondsPerLiquidityDelta > 0) {
            uint192 windowX160 = uint192(window) * type(uint160).max;
            harmonicMeanLiquidity = uint128(windowX160 / (uint192(secondsPerLiquidityDelta) << 32));
        }
    }

    /// @notice amount of quoteToken worth baseAmount of baseToken at `tick` (port of uniswap OracleLibrary.getQuoteAtTick)
    function quoteAtTick(int24 tick, uint128 baseAmount, address baseToken, address quoteToken)
        internal
        pure
        returns (uint256)
    {
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);
        // square in 192 bits when it fits, else in 128 to avoid overflow
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            return baseToken < quoteToken
                ? Math.mulDiv(ratioX192, baseAmount, 1 << 192)
                : Math.mulDiv(1 << 192, baseAmount, ratioX192);
        }
        uint256 ratioX128 = Math.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
        return baseToken < quoteToken
            ? Math.mulDiv(ratioX128, baseAmount, 1 << 128)
            : Math.mulDiv(1 << 128, baseAmount, ratioX128);
    }

    function _address(bytes memory b, uint256 offset) private pure returns (address a) {
        assembly {
            a := shr(96, mload(add(add(b, 32), offset)))
        }
    }

    function _fee(bytes memory b, uint256 offset) private pure returns (uint24 f) {
        assembly {
            f := shr(232, mload(add(add(b, 32), offset)))
        }
    }
}
