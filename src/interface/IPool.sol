// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.36;

/// @notice the essentials every winfall pool implements, whatever its randomness source (chainlink vrf or other).
///         PoolManager clones a pool per round and owns it. source specific parts (vrf callback, request ids,
///         retries) and cosmetics (metadata uri) live on the implementation, not here.
/// @dev struct, errors and events live inside the interface so they don't clash with PoolManager's own Winfall / errors
interface IPool {
    struct PoolConfig {
        uint256 totalWinners;
        /// winnerShares[i] is the weight of draw position i, any unit (payout = pot * share / sum of drawn shares)
        uint256[] winnerShares;
        /// address(0) = native eth
        address currency;
        uint256 winfallAmount;
        uint256 threshold;
        uint256 closeTime;
    }

    error POOL_CLOSED();
    error POOL_OPEN();
    error NO_TICKETS();
    error DRAW_ALREADY_STARTED();
    error RANDOMNESS_PENDING();
    error WINNERS_ALREADY_PICKED();
    error INVALID_WINNER_SHARES();
    error WINNERS_NOT_PICKED();
    error NOT_TICKET_OWNER();
    error ALREADY_CLAIMED(uint256 index);
    error EMPTY_POT();
    error TICKET_TAKEN(uint256 ticketId);

    event WinnersRequested(uint256 indexed requestId);
    event WinnersPicked(uint256[] winners);
    event PotSnapshotTaken(uint256 pot);
    event PrizeClaimed(uint256 indexed index, uint256 indexed ticketId, address indexed to, uint256 amount);
    event PrizeTransferFailed(uint256 indexed index, uint256 indexed ticketId, address indexed to, uint256 amount);

    // ---- setup, called once by PoolManager right after cloning ----
    function initialize(
        address initialOwner,
        string calldata name_,
        string calldata symbol_,
        PoolConfig calldata config
    ) external;

    // ---- owner (PoolManager) ----
    function safeMint(address to, uint256 tokenId) external;
    /// @notice starts the draw after close, how the randomness arrives is up to the implementation
    function requestWinners() external returns (uint256 requestId);
    function rescueFunds(address token, address to, uint256 amount) external;

    // ---- anyone ----
    function pickWinners() external returns (uint256[] memory);
    function claim(uint256 index) external returns (uint256 amount);
    function distribute(uint256 maxWinners) external returns (uint256 paid);

    // ---- views ----
    function getConfig() external view returns (PoolConfig memory);
    function isOpen() external view returns (bool);
    function ticketExists(uint256 ticketId) external view returns (bool);
    function getWinners() external view returns (uint256[] memory);
    function winnerAt(uint256 index) external view returns (address);
    function allClaimed() external view returns (bool);
}
