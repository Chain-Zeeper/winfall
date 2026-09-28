// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.36;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPancakeV3Factory} from "@pancakeswap/v3-core/contracts/interfaces/IPancakeV3Factory.sol";
import {ISwapper} from "./interface/ISwapper.sol";
import {IV3SwapRouter} from "./interface/IV3SwapRouter.sol";
import {V3TwapOracle} from "./libraries/V3TwapOracle.sol";

error INVALID_TWAP_WINDOW();
error INVALID_SLIPPAGE();
error INVALID_ROUTE();
error ZERO_ADDRESS();
error WRONG_NATIVE_AMOUNT(uint256 expected, uint256 sent);
error ONLY_WRAPPED_NATIVE();
error NATIVE_REFUND_FAILED();

interface IWrappedNative {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @notice swaps on pancakeswap v3 with routes found on chain and every swap checked against the route's twap.
/// @dev routing: the direct pool if one exists, otherwise tokenIn -> hub -> tokenOut through the first hub (in
///      order) that has both pools. per pair the fee tier with the highest time weighted liquidity over the twap
///      window wins, so liquidity added for a single block can't steer the choice. pools too young to cover the
///      window are skipped, their twap isn't usable yet.
///      holds no funds between calls: it pulls from the caller, swaps and sends the output straight to the recipient
contract PancakeV3Swapper is ISwapper, Ownable, ReentrancyGuard {
    /// cap for maxSlippageBps
    uint16 public constant MAX_SLIPPAGE_CAP = 1_000;
    uint16 public constant BPS = 10_000;
    uint32 public constant MIN_TWAP_WINDOW = 5 minutes;
    uint32 public constant MAX_TWAP_WINDOW = 1 days;

    IV3SwapRouter public immutable ROUTER;
    address public immutable FACTORY;
    /// wbnb on bnb chain, native payments are wrapped into it before swapping
    address public immutable WRAPPED_NATIVE;

    /// intermediate tokens tried when there's no direct pool (e.g. wbnb, usdt), in priority order
    address[] public hubs;
    /// twap window every swap is checked against, also the window time weighted liquidity is measured over
    uint32 public twapWindow = 30 minutes;
    /// how far below the twap amount a swap may land, in bps
    uint16 public maxSlippageBps = 100;

    event HubsSet(address[] hubs);
    event TwapWindowSet(uint32 window);
    event MaxSlippageSet(uint16 bps);

    /// @param router pancakeswap v3 SmartRouter, @param factory pancakeswap v3 factory of the same deployment
    constructor(address initialOwner, address router, address factory, address wrappedNative, address[] memory _hubs)
        Ownable(initialOwner)
    {
        require(router != address(0) && factory != address(0) && wrappedNative != address(0), ZERO_ADDRESS());
        ROUTER = IV3SwapRouter(router);
        FACTORY = factory;
        WRAPPED_NATIVE = wrappedNative;
        hubs = _hubs;
        emit HubsSet(_hubs);
    }

    // ---- config ----

    function setHubs(address[] calldata _hubs) external onlyOwner {
        hubs = _hubs;
        emit HubsSet(_hubs);
    }

    function setTwapWindow(uint32 window) external onlyOwner {
        require(window >= MIN_TWAP_WINDOW && window <= MAX_TWAP_WINDOW, INVALID_TWAP_WINDOW());
        twapWindow = window;
        emit TwapWindowSet(window);
    }

    function setMaxSlippage(uint16 bps) external onlyOwner {
        require(bps <= MAX_SLIPPAGE_CAP, INVALID_SLIPPAGE());
        maxSlippageBps = bps;
        emit MaxSlippageSet(bps);
    }

    function getHubs() external view returns (address[] memory) {
        return hubs;
    }

    /// pancakeswap v3 fee tiers: 0.01%, 0.05%, 0.25%, 1%
    function feeTiers() public pure returns (uint24[4] memory) {
        return [uint24(100), 500, 2500, 10000];
    }

    // ---- routing ----

    function findRoute(address tokenIn, address tokenOut) public view returns (bytes memory route) {
        (uint24 fee, uint128 liquidity) = bestPool(tokenIn, tokenOut);
        if (liquidity > 0) {
            return abi.encodePacked(tokenIn, fee, tokenOut);
        }
        for (uint256 i = 0; i < hubs.length; i++) {
            address hub = hubs[i];
            if (hub == tokenIn || hub == tokenOut) continue;
            (uint24 feeIn, uint128 liquidityIn) = bestPool(tokenIn, hub);
            if (liquidityIn == 0) continue;
            (uint24 feeOut, uint128 liquidityOut) = bestPool(hub, tokenOut);
            if (liquidityOut == 0) continue;
            return abi.encodePacked(tokenIn, feeIn, hub, feeOut, tokenOut);
        }
        revert NO_ROUTE(tokenIn, tokenOut);
    }

    /// @notice fee tier of the tokenA/tokenB pool with the highest time weighted liquidity over twapWindow,
    ///         liquidity 0 if no pool exists or none is old enough for the window
    function bestPool(address tokenA, address tokenB) public view returns (uint24 fee, uint128 liquidity) {
        uint24[4] memory tiers = feeTiers();
        for (uint256 i = 0; i < tiers.length; i++) {
            address pool = IPancakeV3Factory(FACTORY).getPool(tokenA, tokenB, tiers[i]);
            if (pool == address(0)) continue;
            (bool ok,, uint128 l) = V3TwapOracle.tryConsult(pool, twapWindow);
            if (ok && l > liquidity) {
                (fee, liquidity) = (tiers[i], l);
            }
        }
    }

    // ---- swapping ----

    function minOut(bytes calldata route, uint256 amountIn) public view returns (uint256) {
        _checkRoute(route);
        uint256 fairOut = V3TwapOracle.quotePath(FACTORY, route, amountIn, twapWindow);
        return fairOut * (BPS - maxSlippageBps) / BPS;
    }

    /// @dev the output is checked against the route's twap, so a sandwich (pushing the spot price before the swap)
    ///      can't make the recipient get less than fair: it just reverts
    function swap(bytes calldata route, uint256 amountIn, address recipient)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        uint256 min = minOut(route, amountIn);
        IERC20 tokenIn = IERC20(address(bytes20(route[:20])));
        IERC20 tokenOut = IERC20(address(bytes20(route[route.length - 20:])));
        uint256 before = tokenOut.balanceOf(recipient);

        SafeERC20.safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
        SafeERC20.forceApprove(tokenIn, address(ROUTER), amountIn);
        ROUTER.exactInput(
            IV3SwapRouter.ExactInputParams({
                path: route, recipient: recipient, amountIn: amountIn, amountOutMinimum: min
            })
        );
        SafeERC20.forceApprove(tokenIn, address(ROUTER), 0);

        // measure what actually arrived instead of trusting the router's return value
        amountOut = tokenOut.balanceOf(recipient) - before;
        require(amountOut >= min, SWAP_OUTPUT_TOO_LOW(min, amountOut));
        emit Swapped(recipient, route, amountIn, amountOut, min);
    }

    /// @dev the input side is the caller's money, protected by their own maxAmountIn, so there's no twap check here
    function swapExactOut(
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        uint256 maxAmountIn,
        address recipient,
        address refundTo
    ) external payable nonReentrant returns (uint256 amountIn) {
        bool native = tokenIn == address(0);
        IERC20 input = IERC20(native ? WRAPPED_NATIVE : tokenIn);
        bytes memory route = findRoute(address(input), tokenOut);

        if (native) {
            require(msg.value == maxAmountIn, WRONG_NATIVE_AMOUNT(maxAmountIn, msg.value));
            IWrappedNative(WRAPPED_NATIVE).deposit{value: msg.value}();
        } else {
            require(msg.value == 0, WRONG_NATIVE_AMOUNT(0, msg.value));
            SafeERC20.safeTransferFrom(input, msg.sender, address(this), maxAmountIn);
        }

        uint256 before = IERC20(tokenOut).balanceOf(recipient);
        SafeERC20.forceApprove(input, address(ROUTER), maxAmountIn);
        amountIn = ROUTER.exactOutput(
            IV3SwapRouter.ExactOutputParams({
                path: _reverse(route), recipient: recipient, amountOut: amountOut, amountInMaximum: maxAmountIn
            })
        );
        SafeERC20.forceApprove(input, address(ROUTER), 0);
        uint256 received = IERC20(tokenOut).balanceOf(recipient) - before;
        require(received >= amountOut, SWAP_OUTPUT_TOO_LOW(amountOut, received));

        uint256 refund = maxAmountIn - amountIn;
        if (refund > 0) {
            if (native) {
                IWrappedNative(WRAPPED_NATIVE).withdraw(refund);
                (bool ok,) = payable(refundTo).call{value: refund}("");
                require(ok, NATIVE_REFUND_FAILED());
            } else {
                SafeERC20.safeTransfer(input, refundTo, refund);
            }
        }
        emit SwappedExactOut(recipient, route, amountIn, received, refund);
    }

    /// @dev only for unwrapping refunds
    receive() external payable {
        require(msg.sender == WRAPPED_NATIVE, ONLY_WRAPPED_NATIVE());
    }

    /// @dev exact output swaps take the path reversed: tokenOut | fee | ... | tokenIn
    function _reverse(bytes memory route) private pure returns (bytes memory reversed) {
        uint256 hops = (route.length - 20) / 23;
        reversed = new bytes(route.length);
        for (uint256 i = 0; i <= hops; i++) {
            // token i of the route becomes token (hops - i) of the reversed route
            uint256 from = i * 23;
            uint256 to = (hops - i) * 23;
            for (uint256 k = 0; k < 20; k++) {
                reversed[to + k] = route[from + k];
            }
            if (i < hops) {
                // fee between token i and i+1 sits right before token (hops - i) in the reversed route
                for (uint256 k = 0; k < 3; k++) {
                    reversed[to - 3 + k] = route[from + 20 + k];
                }
            }
        }
    }

    function _checkRoute(bytes calldata route) private pure {
        require(route.length >= 43 && (route.length - 20) % 23 == 0, INVALID_ROUTE());
    }
}
