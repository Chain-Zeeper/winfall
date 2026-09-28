// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.36;

struct Winfall {
    address pool;
    string name;
    /// price of one ticket, in paymentToken
    uint256 ticketPrice;
    /// what tickets are paid in (e.g. usdt), address(0) = native. if it differs from currency, the pot's share of
    /// every ticket is swapped into currency on pancakeswap v3
    address paymentToken;
    /// what the pot holds and winners are paid in, address(0) = native
    address currency;
    /// cut of every ticket sent to the fee treasury, in basis points (10_000 = 100%)
    uint16 feeBps;
    /// cut of every ticket for the buyer's referrer, in basis points (10_000 = 100%). goes to the pot when the buyer
    /// has no referrer
    uint16 referralBps;
    uint16 difficultyBps;
    uint256 closeTime;
    uint256[] winningShares;
}

interface IPoolManager {
    function winfalls(address _winfal) external view returns (Winfall memory);
    function buyTickets(address pool, uint256[] calldata ticketIds, address referrer) external payable;
    function buyTicketsWith(
        address pool,
        uint256[] calldata ticketIds,
        address tokenIn,
        uint256 maxAmountIn,
        uint256 deadline,
        address referrer
    ) external payable;
    function claimReferral(address token) external returns (uint256 amount);
}
