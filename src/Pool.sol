// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.36;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IVRFCoordinatorV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {IPool} from "./interface/IPool.sol";

/// @notice one lottery: nft tickets, a pot, one chainlink vrf draw. every prize position has its own difficulty, the
///         chance that nobody wins it. winners are paid their share of the pot, the share of the positions nobody
///         won can only leave through rollover() into another pool.
/// @dev cloned by PoolManager, which owns every pool
contract Pool is IPool, ERC721Enumerable, Ownable, ReentrancyGuard, Initializable {
    using Strings for address;

    uint16 public constant BPS = 10_000;
    /// a prize position misses at most 90% of the time
    uint16 public constant MAX_DIFFICULTY_BPS = 9_000;

    // chainlink vrf v2.5, set on the implementation and shared by its clones
    IVRFCoordinatorV2Plus public immutable VRF_COORDINATOR;
    bytes32 public immutable vrfKeyHash;
    uint256 public immutable vrfSubscriptionId;
    uint32 public constant VRF_CALLBACK_GAS_LIMIT = 100_000;
    uint16 public constant VRF_REQUEST_CONFIRMATIONS = 3;
    /// wait before an unanswered vrf request can be retried
    uint256 public constant VRF_RETRY_DELAY = 10 minutes;
    /// gas cap per native payout in distribute(), so a winner contract can't burn the caller's gas
    uint256 public constant DISTRIBUTE_ETH_GAS = 50_000;

    string private _baseUri;
    string private _poolName;
    string private _poolSymbol;
    PoolConfig public winfall;

    /// tickets that were bought
    uint256 public ticketsSold;
    /// tickets that were given away
    uint256 public ticketsAirdropped;

    // ---- vrf ----

    /// latest request, earlier ones stay valid
    uint256 public vrfRequestId;
    uint256 public vrfRequestedAt;
    mapping(uint256 => bool) public isVrfRequest;
    uint256 public randomSeed;
    bool public randomnessFulfilled;

    // ---- draw and payout ----

    /// winners picked, possibly none
    bool public drawn;
    /// winning ticket ids, in draw order
    uint256[] public winners;
    /// index into winnerShares each winner won
    uint256[] public winnerPositions;
    /// sum of the shares of the positions that were won
    uint256 public wonShares;
    /// pot at the first payout or rollover, every amount is computed from it
    uint256 public potSnapshot;
    bool public potSnapshotTaken;
    mapping(uint256 => bool) public prizeClaimed;
    /// who winner `index`'s prize was paid to, fixed at claim time
    mapping(uint256 => address) public prizePaidTo;
    uint256 public claimedCount;
    uint256 public distributeCursor;
    bool public rolledOver;

    /// @dev the implementation is locked, only clones get initialized
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
        uint256 positions = _winfall.totalWinners;
        require(positions > 0 && _winfall.winnerShares.length == positions, INVALID_WINNER_SHARES());
        require(
            _winfall.difficultiesBps.length == 0 || _winfall.difficultiesBps.length == positions, INVALID_DIFFICULTIES()
        );
        uint256 shares;
        for (uint256 i = 0; i < positions; i++) {
            require(_winfall.winnerShares[i] > 0, INVALID_WINNER_SHARES());
            shares += _winfall.winnerShares[i];
        }
        // shares are the prize split in bps, so a typo can't silently change everyone's cut
        require(shares == BPS, INVALID_WINNER_SHARES());
        for (uint256 i = 0; i < _winfall.difficultiesBps.length; i++) {
            require(_winfall.difficultiesBps[i] <= MAX_DIFFICULTY_BPS, INVALID_DIFFICULTIES());
        }
        require(_winfall.closeTime > block.timestamp, INVALID_CLOSE_TIME());

        winfall = _winfall;
        _poolName = name_;
        _poolSymbol = symbol_;
        _baseUri = "https://winfall/pool/";
        _transferOwnership(initialOwner);
    }

    function name() public view override returns (string memory) {
        return _poolName;
    }

    function symbol() public view override returns (string memory) {
        return _poolSymbol;
    }

    // ---- tickets ----

    function safeMint(address to, uint256 tokenId) public onlyOwner {
        require(isOpen(), POOL_CLOSED());
        require(_ownerOf(tokenId) == address(0), TICKET_TAKEN(tokenId));
        _safeMint(to, tokenId);
        ticketsSold += 1;
    }

    /// @notice mints a free ticket that takes part in the draw like a bought one. the owner (PoolManager) limits how
    ///         many can be given away
    function airdrop(address to, uint256 tokenId) external onlyOwner {
        require(isOpen(), POOL_CLOSED());
        require(_ownerOf(tokenId) == address(0), TICKET_TAKEN(tokenId));
        _safeMint(to, tokenId);
        ticketsAirdropped += 1;
        emit TicketAirdropped(to, tokenId);
    }

    /// @notice every ticket id `owner` holds in this pool. for very large holdings page through balanceOf and
    ///         tokenOfOwnerByIndex instead
    function ticketsOf(address owner) external view returns (uint256[] memory ids) {
        uint256 count = balanceOf(owner);
        ids = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            ids[i] = tokenOfOwnerByIndex(owner, i);
        }
    }

    /// @notice `ticketId` is already sold (ownerOf reverts for unknown ids, this doesn't)
    function ticketExists(uint256 ticketId) public view returns (bool) {
        return _ownerOf(ticketId) != address(0);
    }

    function isOpen() public view returns (bool) {
        return block.timestamp < winfall.closeTime;
    }

    /// @notice chance in bps that prize position `index` has no winner
    function difficultyOf(uint256 index) public view returns (uint16) {
        return winfall.difficultiesBps.length == 0 ? 0 : winfall.difficultiesBps[index];
    }

    // ---- draw ----

    /// @notice after close, asks chainlink vrf for the seed. a pool that sold no tickets needs no draw: it's marked
    ///         drawn without winners right away and returns 0
    /// @dev can be retried after VRF_RETRY_DELAY. earlier requests stay valid, so a retry can't cancel a seed that's
    ///      already on its way
    function requestWinners() external onlyOwner returns (uint256 requestId) {
        require(block.timestamp >= winfall.closeTime, POOL_OPEN());
        require(!drawn, WINNERS_ALREADY_PICKED());
        require(!randomnessFulfilled, RANDOMNESS_ALREADY_FULFILLED());

        if (totalSupply() == 0) {
            drawn = true;
            emit WinnersPicked(winners);
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

        isVrfRequest[requestId] = true;
        vrfRequestId = requestId;
        vrfRequestedAt = block.timestamp;
        if (oldRequestId != 0) {
            emit WinnersRequestRetried(oldRequestId, requestId);
        }
        emit WinnersRequested(requestId);
    }

    /// @notice vrf callback. the first answer becomes the seed, later ones are ignored
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        require(msg.sender == address(VRF_COORDINATOR), ONLY_VRF_COORDINATOR(msg.sender));
        require(isVrfRequest[requestId], UNKNOWN_VRF_REQUEST(requestId));
        if (randomnessFulfilled) {
            emit LateFulfillmentIgnored(requestId);
            return;
        }
        randomSeed = randomWords[0];
        randomnessFulfilled = true;
        emit RandomnessFulfilled(requestId, randomWords[0]);
    }

    /// @notice draws every prize position: it first misses with its own difficulty, otherwise it wins a ticket that
    ///         hasn't won yet. positions that miss (or find no ticket left) have no winner, their share rolls over
    function pickWinners() external returns (uint256[] memory) {
        require(randomnessFulfilled, RANDOMNESS_PENDING());
        require(!drawn, WINNERS_ALREADY_PICKED());
        drawn = true;

        // tickets are never burned, so the enumerable list keeps its order: index i is the i-th ticket minted
        uint256 total = totalSupply();
        uint256 positions = winfall.totalWinners;
        uint256 seed = randomSeed;
        // partial fisher-yates over ticket indexes, only the positions a swap touched are kept in memory
        uint256 maxHits = positions < total ? positions : total;
        uint256[] memory movedPos = new uint256[](maxHits);
        uint256[] memory movedVal = new uint256[](maxHits);
        uint256 moved = 0;
        uint256 hits = 0;
        for (uint256 i = 0; i < positions && hits < total; i++) {
            if (uint256(keccak256(abi.encode(seed, "miss", i))) % BPS < difficultyOf(i)) {
                continue;
            }
            uint256 j = hits + (uint256(keccak256(abi.encode(seed, i))) % (total - hits));
            uint256 picked = _indexAt(j, movedPos, movedVal, moved);
            if (j != hits) {
                moved = _setIndexAt(j, _indexAt(hits, movedPos, movedVal, moved), movedPos, movedVal, moved);
            }
            winners.push(tokenByIndex(picked));
            winnerPositions.push(i);
            wonShares += winfall.winnerShares[i];
            hits++;
        }

        emit WinnersPicked(winners);
        return winners;
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

    /// @dev returns the new number of moved positions
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

    /// @notice pays winner `index` (into getWinners()) to the current holder of that ticket
    function claim(uint256 index) external nonReentrant returns (uint256 amount) {
        require(winners.length > 0, WINNERS_NOT_PICKED());
        uint256 ticketId = winners[index];
        require(ownerOf(ticketId) == msg.sender, NOT_TICKET_OWNER());
        require(!prizeClaimed[index], ALREADY_CLAIMED(index));

        _takePotSnapshot();
        amount = _prizeOf(index);
        prizeClaimed[index] = true;
        prizePaidTo[index] = msg.sender;
        claimedCount += 1;
        emit PrizeClaimed(index, ticketId, msg.sender, amount);

        if (winfall.currency == address(0)) {
            (bool ok,) = payable(msg.sender).call{value: amount}("");
            require(ok, "prize transfer failed");
        } else {
            SafeERC20.safeTransfer(IERC20(winfall.currency), msg.sender, amount);
        }
    }

    /// @notice pushes up to maxWinners unclaimed prizes to the ticket holders. a failed transfer is skipped, that
    ///         winner can still claim()
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

            uint256 ticketId = winners[i];
            address to = ownerOf(ticketId);
            uint256 amount = _prizeOf(i);
            prizeClaimed[i] = true;
            claimedCount += 1;

            if (_tryPay(to, amount)) {
                paid++;
                prizePaidTo[i] = to;
                emit PrizeClaimed(i, ticketId, to, amount);
            } else {
                prizeClaimed[i] = false;
                claimedCount -= 1;
                emit PrizeTransferFailed(i, ticketId, to, amount);
            }
        }
        distributeCursor = i;
    }

    /// @notice sends the share of the positions nobody won to `to`, once. the owner (PoolManager) only passes pools
    ///         it created, so this money can't go anywhere but into another pool's pot
    function rollover(address to) external onlyOwner nonReentrant returns (uint256 amount) {
        require(drawn, WINNERS_NOT_PICKED());
        require(!rolledOver, ALREADY_ROLLED_OVER());
        _takePotSnapshot();
        amount = _unwonAmount();
        require(amount > 0, NOTHING_TO_ROLL_OVER());
        rolledOver = true;
        emit RolledOver(to, amount);

        if (winfall.currency == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            require(ok, "rollover transfer failed");
        } else {
            SafeERC20.safeTransfer(IERC20(winfall.currency), to, amount);
        }
    }

    function rolloverAmount() external view returns (uint256) {
        if (!drawn || rolledOver) {
            return 0;
        }
        return _pot() * (BPS - wonShares) / BPS;
    }

    function pot() external view returns (uint256) {
        return _pot();
    }

    /// @dev the snapshot once it's taken, the current balance before
    function _pot() internal view returns (uint256) {
        return potSnapshotTaken ? potSnapshot : _potBalance();
    }

    function _unwonAmount() internal view returns (uint256) {
        return potSnapshot * (BPS - wonShares) / BPS;
    }

    function _takePotSnapshot() internal {
        if (potSnapshotTaken) {
            return;
        }
        uint256 balance = _potBalance();
        require(balance > 0, EMPTY_POT());
        potSnapshot = balance;
        potSnapshotTaken = true;
        emit PotSnapshotTaken(balance);
    }

    function _prizeOf(uint256 index) internal view returns (uint256) {
        return potSnapshot * winfall.winnerShares[winnerPositions[index]] / BPS;
    }

    /// @dev never reverts on a bad recipient
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

    /// @notice the draw is done and every winner (if any) was paid
    function allClaimed() public view returns (bool) {
        return drawn && claimedCount == winners.length;
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

    function winnersInfo() external view returns (WinnerInfo[] memory info) {
        uint256 potSize = _pot();
        info = new WinnerInfo[](winners.length);
        for (uint256 k = 0; k < info.length; k++) {
            uint256 position = winnerPositions[k];
            info[k] = WinnerInfo({
                ticketId: winners[k],
                position: position,
                holder: winnerAt(k),
                prize: potSize * winfall.winnerShares[position] / BPS,
                claimed: prizeClaimed[k]
            });
        }
    }

    function prizes() external view returns (uint256[] memory amounts) {
        uint256 potSize = _pot();
        amounts = new uint256[](winfall.totalWinners);
        for (uint256 i = 0; i < amounts.length; i++) {
            amounts[i] = potSize * winfall.winnerShares[i] / BPS;
        }
    }

    /// @notice who was paid winner `index`'s prize, or the ticket's current holder while it's unclaimed
    function winnerAt(uint256 index) public view returns (address) {
        return prizeClaimed[index] ? prizePaidTo[index] : ownerOf(winners[index]);
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

    /// @notice the pot currency can be rescued while the pool has no ticket at all, or once every winner was paid.
    ///         other tokens can always be rescued. the pool itself doesn't protect the unwon share or rolled over
    ///         money here: its owner does (PoolManager.rescuePoolFunds), so never give a pool another owner
    function rescueFunds(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "cannot rescue to zero address");
        if (token == winfall.currency) {
            require(totalSupply() == 0 || allClaimed(), "pot locked until every winner has claimed");
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

    /// @notice the pool closed without any ticket and its pot wasn't touched yet
    function unsoldAndClosed() public view returns (bool) {
        return totalSupply() == 0 && block.timestamp >= winfall.closeTime && !potSnapshotTaken;
    }

    receive() external payable {}
}
