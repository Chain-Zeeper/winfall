// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.36;

/// @notice the essentials every winfall pool implements, whatever its randomness source (chainlink vrf or other).
///         PoolManager clones a pool per lottery and owns it. source specific parts (vrf callback, request ids,
///         retries) and cosmetics (metadata uri) live on the implementation, not here.
/// @dev struct, errors and events live inside the interface so they don't clash with PoolManager's own Winfall / errors
interface IPool {
    struct PoolConfig {
        uint256 totalWinners;
        /// winnerShares[i] is the cut of the pot prize position i wins, in bps. they have to add up to 10_000
        uint256[] winnerShares;
        /// difficultiesBps[i] is the chance that position i has no winner, in bps (0 = always won, at most 9_000).
        /// empty = every position is always won
        uint16[] difficultiesBps;
        /// address(0) = native eth
        address currency;
        /// tickets are sold until then
        uint256 closeTime;
    }

    /// one winner: the ticket, the prize position it won (0 = first) and its prize. `holder` is who was paid once
    /// the prize is claimed, the ticket's current holder before that
    struct WinnerInfo {
        uint256 ticketId;
        uint256 position;
        address holder;
        uint256 prize;
        bool claimed;
    }

    event WinnersRequestRetried(uint256 indexed oldRequestId, uint256 indexed newRequestId);
    event RandomnessFulfilled(uint256 indexed requestId, uint256 randomSeed);
    event LateFulfillmentIgnored(uint256 indexed requestId);
    /// the share of the positions nobody won moved into pool `to`
    event RolledOver(address indexed to, uint256 amount);
    event TicketAirdropped(address indexed to, uint256 indexed ticketId);

    error RANDOMNESS_ALREADY_FULFILLED();
    error ONLY_VRF_COORDINATOR(address caller);
    error UNKNOWN_VRF_REQUEST(uint256 requestId);
    error POOL_CLOSED();
    error POOL_OPEN();
    error DRAW_ALREADY_STARTED();
    error RANDOMNESS_PENDING();
    error WINNERS_ALREADY_PICKED();
    error INVALID_WINNER_SHARES();
    error INVALID_DIFFICULTIES();
    error INVALID_CLOSE_TIME();
    error WINNERS_NOT_PICKED();
    error NOT_TICKET_OWNER();
    error ALREADY_CLAIMED(uint256 index);
    error EMPTY_POT();
    error TICKET_TAKEN(uint256 ticketId);
    error ALREADY_ROLLED_OVER();
    error NOTHING_TO_ROLL_OVER();

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
    /// @notice mints a free ticket that's in the draw like a bought one. how many can be given away is limited by the
    ///         owner (PoolManager.airdropsLeft)
    function airdrop(address to, uint256 tokenId) external;
    /// @notice starts the draw after close, how the randomness arrives is up to the implementation
    function requestWinners() external returns (uint256 requestId);
    function rescueFunds(address token, address to, uint256 amount) external;
    /// @notice sends the share of the positions nobody won to `to` (the next pool), once
    function rollover(address to) external returns (uint256 amount);

    // ---- anyone ----
    function pickWinners() external returns (uint256[] memory);
    function claim(uint256 index) external returns (uint256 amount);
    function distribute(uint256 maxWinners) external returns (uint256 paid);

    // ---- views ----
    function getConfig() external view returns (PoolConfig memory);
    function isOpen() external view returns (bool);
    function ticketExists(uint256 ticketId) external view returns (bool);
    /// @notice every ticket id `owner` holds in this pool
    function ticketsOf(address owner) external view returns (uint256[] memory);
    function getWinners() external view returns (uint256[] memory);
    function winnerAt(uint256 index) external view returns (address);
    function allClaimed() external view returns (bool);
    /// @notice the prize pot: the pool's balance of the pot currency until the snapshot is taken (first payout or
    ///         rollover), the snapshot from then on. payouts and later top ups don't change it anymore
    function pot() external view returns (uint256);
    /// @notice every winner with its position, holder, prize and claim status, in draw order. winnersInfo()[k]
    ///         is the winner claim(k) pays
    function winnersInfo() external view returns (WinnerInfo[] memory);
    /// @notice what every prize position pays (index 0 = first). uses the pot snapshot once it's taken, the
    ///         current pot before that
    function prizes() external view returns (uint256[] memory);
    /// @notice the draw is done (winners picked, possibly none)
    function drawn() external view returns (bool);
    /// @notice what rollover() would move, 0 before the draw or once rolled over
    function rolloverAmount() external view returns (uint256);
    /// @notice tickets that were bought (airdropped ones aren't counted)
    function ticketsSold() external view returns (uint256);
    function ticketsAirdropped() external view returns (uint256);
    /// @notice the pool closed without any ticket and its pot wasn't touched yet, so its seed can be taken back
    function unsoldAndClosed() external view returns (bool);
}
