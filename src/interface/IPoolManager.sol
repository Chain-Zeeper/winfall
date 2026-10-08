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
    /// protocol fee: cut of every ticket that doesn't go into the pot, in basis points (10_000 = 100%)
    uint16 feeBps;
    /// what a buyer's referrer gets on the buyer's first referred purchase, in basis points of the ticket price like
    /// feeBps (a buyer pays a referral only once, over all pools). it's taken out of the protocol fee, so it can't
    /// be more than feeBps and the pot is the same with or without a referral. the rest of the fee, or all of it
    /// when no referral is paid, goes to the fee treasury
    uint16 referralBps;
    /// tickets are sold until then
    uint256 closeTime;
    /// winningShares[i] is the cut of the pot prize position i wins, in bps. they have to add up to 10_000
    uint256[] winningShares;
    /// difficultiesBps[i] is the chance that position i has no winner, in bps (0 = always won, at most 9_000). its share then
    /// stays in the pool until it's rolled over into another pool. empty = every position is always won
    uint16[] difficultiesBps;
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
    function rollover(address fromPool, address toPool) external returns (uint256 amount);
}
