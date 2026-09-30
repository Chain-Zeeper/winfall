// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.36;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IVRFCoordinatorV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {IPool} from "./interface/IPool.sol";

/// @notice a pool whose pot can roll over through several rounds. every round sells its own tickets and has its own
///         draw. with difficultyBps > 0 a draw position can land on a ticket that doesn't exist, so a round can end
///         with no winner: the pot stays and the next round opens for roundDuration. the first round with a winner
///         pays out the whole pot and ends the MegaPool. the last round ignores difficulty, so it always has winners
///         (as long as it sold a ticket).
/// @dev cloned by PoolManager like Pool. ticket numbers restart every round, so the nft id of ticket `number` in
///      round `r` is (r << 128) | number, see ticketId(). the IPool functions that take a ticket id (safeMint,
///      ticketExists) take the plain number of the current round.
contract MegaPool is IPool, ERC721, Ownable, ReentrancyGuard, Initializable {
    using Strings for address;
    using Strings for uint256;

    error RANDOMNESS_ALREADY_FULFILLED();
    error ONLY_VRF_COORDINATOR(address caller);
    error UNKNOWN_VRF_REQUEST(uint256 requestId);
    error TICKET_NUMBER_TOO_LARGE(uint256 number);
    error POOL_ENDED();

    event WinnersRequestRetried(uint256 indexed oldRequestId, uint256 indexed newRequestId);
    event RandomnessFulfilled(uint256 indexed requestId, uint256 randomSeed);
    event LateFulfillmentIgnored(uint256 indexed requestId);
    event RoundStarted(uint256 indexed round, uint256 closeTime);
    /// no ticket of `round` won, the pot rolls into the next round
    event RoundRolledOver(uint256 indexed round, uint256 tickets, uint256 pot);
    event RoundWon(uint256 indexed round, uint256 winners);

    uint16 public constant BPS = 10_000;

    // chainlink vrf v2.5, set on the implementation and shared by its clones
    IVRFCoordinatorV2Plus public immutable VRF_COORDINATOR;
    bytes32 public immutable vrfKeyHash;
    uint256 public immutable vrfSubscriptionId;
    uint32 public constant VRF_CALLBACK_GAS_LIMIT = 100_000;
    uint16 public constant VRF_REQUEST_CONFIRMATIONS = 3;
    /// how long a vrf request may stay unanswered before the owner can request again
    uint256 public constant VRF_RETRY_DELAY = 10 minutes;
    /// gas forwarded to an eth winner in distribute(), so a winner contract can't burn the caller's gas
    uint256 public constant DISTRIBUTE_ETH_GAS = 50_000;

    string private _baseUri;
    string private _poolName;
    string private _poolSymbol;
    PoolConfig public winfall;

    // ---- rounds ----

    /// round tickets are sold for and drawn in now, starts at 1
    uint256 public currentRound;
    /// the last round, it ignores difficulty so the pot is always won
    uint256 public totalRounds;
    /// close time of the current round
    uint256 public roundCloseTime;
    /// set once a round had winners (or the last round sold nothing), no more rounds after that
    bool public ended;
    /// round that had the winners
    uint256 public winningRound;

    /// tickets sold over all rounds
    uint256 public ticketsMinted;
    /// nft ids of every round's tickets, in sale order
    mapping(uint256 round => uint256[]) internal _roundTickets;

    // ---- vrf, one draw per round ----

    /// latest request of the current round, earlier ones of the same round stay valid
    uint256 public vrfRequestId;
    uint256 public vrfRequestedAt;
    /// round each request was made for, 0 = not ours
    mapping(uint256 requestId => uint256 round) public vrfRequestRound;
    mapping(uint256 round => uint256) public roundSeed;
    mapping(uint256 round => bool) public roundFulfilled;

    // ---- payout, same as Pool once a round is won ----

    /// winning nft ids of the winning round, in draw order
    uint256[] public winners;
    /// draw position (index into winnerShares) each winner won
    uint256[] public winnerPositions;
    uint256 public potSnapshot;
    bool public potSnapshotTaken;
    /// sum of winnerShares of the positions that were won, payout = potSnapshot * share / totalDrawnShares
    uint256 public totalDrawnShares;
    mapping(uint256 => bool) public prizeClaimed;
    uint256 public claimedCount;
    uint256 public distributeCursor;

    /// @dev the implementation itself is locked, only clones get initialized
    constructor(address _vrfCoordinator, bytes32 _vrfKeyHash, uint256 _vrfSubscriptionId)
        ERC721("", "")
        Ownable(msg.sender)
    {
        VRF_COORDINATOR = IVRFCoordinatorV2Plus(_vrfCoordinator);
        vrfKeyHash = _vrfKeyHash;
        vrfSubscriptionId = _vrfSubscriptionId;
        _disableInitializers();
    }

    function initialize(
        address initialOwner,
        string calldata name_,
        string calldata symbol_,
        PoolConfig calldata _winfall
    ) external initializer {
        require(initialOwner != address(0), OwnableInvalidOwner(address(0)));
        require(_winfall.winnerShares.length == _winfall.totalWinners, INVALID_WINNER_SHARES());
        for (uint256 i = 0; i < _winfall.winnerShares.length; i++) {
            require(_winfall.winnerShares[i] > 0, INVALID_WINNER_SHARES());
        }
        uint256 rounds = _winfall.totalRounds == 0 ? 1 : _winfall.totalRounds;
        require(_winfall.difficultyBps < BPS, INVALID_ROUNDS());
        require(rounds == 1 || _winfall.roundDuration > 0, INVALID_ROUNDS());

        winfall = _winfall;
        totalRounds = rounds;
        currentRound = 1;
        roundCloseTime = _winfall.closeTime;
        _poolName = name_;
        _poolSymbol = symbol_;
        _baseUri = "https://winfall/megapool/";
        _transferOwnership(initialOwner);
        emit RoundStarted(1, _winfall.closeTime);
    }

    function name() public view override returns (string memory) {
        return _poolName;
    }

    function symbol() public view override returns (string memory) {
        return _poolSymbol;
    }

    // ---- tickets ----

    /// @param number ticket number in the current round, the nft minted is ticketId(currentRound, number)
    function safeMint(address to, uint256 number) public onlyOwner {
        require(isOpen(), POOL_CLOSED());
        require(number <= type(uint128).max, TICKET_NUMBER_TOO_LARGE(number));
        uint256 id = ticketId(currentRound, number);
        require(_ownerOf(id) == address(0), TICKET_TAKEN(number));
        _safeMint(to, id);
        ticketsMinted += 1;
        _roundTickets[currentRound].push(id);
    }

    /// @notice nft id of ticket `number` in `round`
    function ticketId(uint256 round, uint256 number) public pure returns (uint256) {
        return (round << 128) | number;
    }

    /// @notice round and ticket number of an nft id
    function decodeTicket(uint256 id) public pure returns (uint256 round, uint256 number) {
        return (id >> 128, uint256(uint128(id)));
    }

    /// @notice true if ticket `number` of the current round is already sold
    function ticketExists(uint256 number) public view returns (bool) {
        return number <= type(uint128).max && _ownerOf(ticketId(currentRound, number)) != address(0);
    }

    function roundTickets(uint256 round) external view returns (uint256[] memory) {
        return _roundTickets[round];
    }

    function roundTicketCount(uint256 round) external view returns (uint256) {
        return _roundTickets[round].length;
    }

    /// @notice tickets of the current round are on sale
    function isOpen() public view returns (bool) {
        return !ended && block.timestamp < roundCloseTime;
    }

    /// @notice difficulty the current round's draw uses: winfall.difficultyBps, or 0 in the last round
    function currentDifficultyBps() public view returns (uint16) {
        return currentRound >= totalRounds ? 0 : winfall.difficultyBps;
    }

    // ---- draw ----

    /// @notice after the current round closes, asks chainlink vrf for its seed. a round that sold no tickets
    ///         needs no draw: it rolls over right away (or ends the MegaPool if it was the last round), returns 0
    /// @dev retry after VRF_RETRY_DELAY like Pool, earlier requests of the same round stay valid
    function requestWinners() external onlyOwner returns (uint256 requestId) {
        require(!ended, POOL_ENDED());
        require(block.timestamp >= roundCloseTime, POOL_OPEN());
        uint256 round = currentRound;
        require(!roundFulfilled[round], RANDOMNESS_ALREADY_FULFILLED());

        if (_roundTickets[round].length == 0) {
            _noWinner(round);
            return 0;
        }

        uint256 oldRequestId = vrfRequestId;
        require(oldRequestId == 0 || block.timestamp >= vrfRequestedAt + VRF_RETRY_DELAY, DRAW_ALREADY_STARTED());
        requestId = VRF_COORDINATOR.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: vrfKeyHash,
                subId: vrfSubscriptionId,
                requestConfirmations: VRF_REQUEST_CONFIRMATIONS,
                callbackGasLimit: VRF_CALLBACK_GAS_LIMIT,
                numWords: 1,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: false}))
            })
        );

        vrfRequestRound[requestId] = round;
        vrfRequestId = requestId;
        vrfRequestedAt = block.timestamp;
        if (oldRequestId != 0) {
            emit WinnersRequestRetried(oldRequestId, requestId);
        }
        emit WinnersRequested(requestId);
    }

    /// @notice vrf callback, kept minimal so it always fits VRF_CALLBACK_GAS_LIMIT. the first answer for the
    ///         current round becomes its seed, answers for old rounds or late retries are ignored
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        require(msg.sender == address(VRF_COORDINATOR), ONLY_VRF_COORDINATOR(msg.sender));
        uint256 round = vrfRequestRound[requestId];
        require(round != 0, UNKNOWN_VRF_REQUEST(requestId));
        if (ended || round != currentRound || roundFulfilled[round]) {
            emit LateFulfillmentIgnored(requestId);
            return;
        }
        roundSeed[round] = randomWords[0];
        roundFulfilled[round] = true;
        emit RandomnessFulfilled(requestId, randomWords[0]);
    }

    /// @notice kept for PoolManager.releaseVrfConsumer: true once no more draws are needed
    function randomnessFulfilled() external view returns (bool) {
        return ended;
    }

    /// @notice draws the current round. each of the totalWinners positions picks, without repeats, from the round's
    ///         tickets plus enough tickets that don't exist to make difficultyBps of the picks miss. positions that
    ///         hit a real ticket win. no winner: the pot rolls into the next round and an empty array is returned
    function pickWinners() external returns (uint256[] memory) {
        require(!ended, POOL_ENDED());
        uint256 round = currentRound;
        require(roundFulfilled[round], RANDOMNESS_PENDING());

        uint256[] storage tickets = _roundTickets[round];
        uint256 total = tickets.length;
        // with difficulty d a pick misses with probability d: draw from total / (1 - d) slots, the ones past
        // `total` are tickets nobody holds. rounded up, so difficulty 0 gives exactly `total` slots
        uint256 slots = (total * BPS + (BPS - currentDifficultyBps()) - 1) / (BPS - currentDifficultyBps());
        uint256 count = winfall.totalWinners;
        if (count > slots) {
            count = slots;
        }

        // same partial fisher-yates as Pool, over slot indexes, remembering only the touched positions
        uint256 seed = roundSeed[round];
        uint256[] memory movedPos = new uint256[](count);
        uint256[] memory movedVal = new uint256[](count);
        uint256 moved = 0;
        for (uint256 i = 0; i < count; i++) {
            uint256 j = i + (uint256(keccak256(abi.encode(seed, i))) % (slots - i));
            uint256 picked = _indexAt(j, movedPos, movedVal, moved);
            if (j != i) {
                moved = _setIndexAt(j, _indexAt(i, movedPos, movedVal, moved), movedPos, movedVal, moved);
            }
            if (picked < total) {
                winners.push(tickets[picked]);
                winnerPositions.push(i);
                totalDrawnShares += winfall.winnerShares[i];
            }
        }

        if (winners.length == 0) {
            _noWinner(round);
        } else {
            ended = true;
            winningRound = round;
            emit RoundWon(round, winners.length);
            emit WinnersPicked(winners);
        }
        return winners;
    }

    /// @dev the round had no winner: open the next one, or end the MegaPool if this was the last round (only
    ///      possible when it sold nothing, the last round's draw can't miss)
    function _noWinner(uint256 round) internal {
        emit RoundRolledOver(round, _roundTickets[round].length, _potBalance());
        if (round >= totalRounds) {
            ended = true;
            return;
        }
        currentRound = round + 1;
        roundCloseTime = block.timestamp + winfall.roundDuration;
        vrfRequestId = 0;
        vrfRequestedAt = 0;
        emit RoundStarted(round + 1, roundCloseTime);
    }

    function _indexAt(uint256 pos, uint256[] memory movedPos, uint256[] memory movedVal, uint256 moved)
        private
        pure
        returns (uint256)
    {
        for (uint256 k = 0; k < moved; k++) {
            if (movedPos[k] == pos) {
                return movedVal[k];
            }
        }
        return pos;
    }

    /// @dev writes into the memory arrays in place, returns the new number of moved positions
    function _setIndexAt(uint256 pos, uint256 val, uint256[] memory movedPos, uint256[] memory movedVal, uint256 moved)
        private
        pure
        returns (uint256)
    {
        for (uint256 k = 0; k < moved; k++) {
            if (movedPos[k] == pos) {
                movedVal[k] = val;
                return moved;
            }
        }
        movedPos[moved] = pos;
        movedVal[moved] = val;
        return moved + 1;
    }

    // ---- payout ----

    /// @notice pays winner `index` (index into getWinners()) to the current holder of that ticket
    function claim(uint256 index) external nonReentrant returns (uint256 amount) {
        require(winners.length > 0, WINNERS_NOT_PICKED());
        uint256 id = winners[index];
        require(ownerOf(id) == msg.sender, NOT_TICKET_OWNER());
        require(!prizeClaimed[index], ALREADY_CLAIMED(index));

        _takePotSnapshot();
        amount = _prizeOf(index);
        prizeClaimed[index] = true;
        claimedCount += 1;
        emit PrizeClaimed(index, id, msg.sender, amount);

        if (winfall.currency == address(0)) {
            (bool ok,) = payable(msg.sender).call{value: amount}("");
            require(ok, "prize transfer failed");
        } else {
            SafeERC20.safeTransfer(IERC20(winfall.currency), msg.sender, amount);
        }
    }

    /// @notice pushes prizes to the current ticket holders in batches, same as Pool.distribute
    function distribute(uint256 maxWinners) external nonReentrant returns (uint256 paid) {
        uint256 total = winners.length;
        require(total > 0, WINNERS_NOT_PICKED());
        _takePotSnapshot();

        uint256 i = distributeCursor;
        uint256 handled = 0;
        for (; i < total && handled < maxWinners; i++) {
            if (prizeClaimed[i]) {
                continue;
            }
            handled++;

            uint256 id = winners[i];
            address to = ownerOf(id);
            uint256 amount = _prizeOf(i);
            prizeClaimed[i] = true;
            claimedCount += 1;

            if (_tryPay(to, amount)) {
                paid++;
                emit PrizeClaimed(i, id, to, amount);
            } else {
                prizeClaimed[i] = false;
                claimedCount -= 1;
                emit PrizeTransferFailed(i, id, to, amount);
            }
        }
        distributeCursor = i;
    }

    function _takePotSnapshot() internal {
        if (potSnapshotTaken) {
            return;
        }
        uint256 pot = _potBalance();
        require(pot > 0, EMPTY_POT());
        potSnapshot = pot;
        potSnapshotTaken = true;
        emit PotSnapshotTaken(pot);
    }

    function _prizeOf(uint256 index) internal view returns (uint256) {
        return potSnapshot * winfall.winnerShares[winnerPositions[index]] / totalDrawnShares;
    }

    /// @dev never reverts on a bad recipient. eth goes out with a gas cap and without copying return data
    function _tryPay(address to, uint256 amount) internal returns (bool ok) {
        if (winfall.currency == address(0)) {
            uint256 gasLimit = DISTRIBUTE_ETH_GAS;
            assembly {
                ok := call(gasLimit, to, amount, 0, 0, 0, 0)
            }
        } else {
            ok = SafeERC20.trySafeTransfer(IERC20(winfall.currency), to, amount);
        }
    }

    function allClaimed() public view returns (bool) {
        return winners.length > 0 && claimedCount == winners.length;
    }

    function _potBalance() internal view returns (uint256) {
        if (winfall.currency == address(0)) {
            return address(this).balance;
        }
        return IERC20(winfall.currency).balanceOf(address(this));
    }

    // ---- views ----

    function getConfig() external view returns (PoolConfig memory) {
        return winfall;
    }

    function getWinners() external view returns (uint256[] memory) {
        return winners;
    }

    function getWinnerPositions() external view returns (uint256[] memory) {
        return winnerPositions;
    }

    /// @notice current holder of winning ticket `index`
    function winnerAt(uint256 index) external view returns (address) {
        return ownerOf(winners[index]);
    }

    /// @notice metadata url of a ticket: <baseURI>/<pool>/ticket/<round>/<number>, so the metadata server gets the
    ///         round and the number the buyer picked instead of the packed nft id
    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        (uint256 round, uint256 number) = decodeTicket(id);
        return string.concat(_baseURI(), round.toString(), "/", number.toString());
    }

    function _baseURI() internal view override returns (string memory) {
        return string.concat(_baseUri, address(this).toHexString(), "/ticket/");
    }

    function baseURI() external view returns (string memory) {
        return _baseURI();
    }

    function setBaseURI(string calldata newBaseURI) external onlyOwner {
        _baseUri = newBaseURI;
    }

    /// @notice the pot can only leave through prizes: rescue is open before any ticket sold, once every winner
    ///         claimed (dust, late top ups), or when the MegaPool ended without winners (last round sold nothing)
    function rescueFunds(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "cannot rescue to zero address");
        if (token == winfall.currency) {
            require(
                ticketsMinted == 0 || allClaimed() || (ended && winners.length == 0),
                "pot locked until every winner has claimed"
            );
        }

        if (token == address(0)) {
            uint256 balance = address(this).balance;
            if (amount == type(uint256).max) {
                amount = balance;
            }
            require(amount <= balance, "insufficient balance");
            (bool ok,) = payable(to).call{value: amount}("");
            require(ok, "eth rescue failed");
        } else {
            if (amount == type(uint256).max) {
                amount = IERC20(token).balanceOf(address(this));
            }
            SafeERC20.safeTransfer(IERC20(token), to, amount);
        }
    }

    receive() external payable {}
}
