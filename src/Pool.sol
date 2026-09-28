// SPDX-License-Identifier: UNLICENSED
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
pragma solidity ^0.8.36;

/// @notice deployed once as an implementation, PoolManager makes cheap EIP-1167 clones of it and calls initialize().
///         constructors don't run for clones, so every per-pool value is set in initialize(). immutables live in the
///         implementation's bytecode, so the vrf config is shared by all clones of one implementation.
contract Pool is IPool, ERC721, Ownable, ReentrancyGuard, Initializable {
    using Strings for address;

    uint256 immutable timelock = 7 days;
    string private _baseUri;
    /// ERC721's own _name/_symbol are constructor only, clones keep theirs here
    string private _poolName;
    string private _poolSymbol;
    PoolConfig public winfall;
    uint256 public ticketsMinted = 0;

    uint256[] public allTickets;

    // chainlink specific, kept out of IPool so other randomness sources can implement it
    error RANDOMNESS_ALREADY_FULFILLED();
    error ONLY_VRF_COORDINATOR(address caller);
    error UNKNOWN_VRF_REQUEST(uint256 requestId);
    event WinnersRequestRetried(uint256 indexed oldRequestId, uint256 indexed newRequestId);
    event RandomnessFulfilled(uint256 indexed requestId, uint256 randomSeed);
    event LateFulfillmentIgnored(uint256 indexed requestId);

    // chainlink vrf v2.5, set on the implementation and shared by its clones.
    // every clone must be added as a consumer of the subscription before requestWinners()
    IVRFCoordinatorV2Plus public immutable VRF_COORDINATOR;
    bytes32 public immutable vrfKeyHash;
    uint256 public immutable vrfSubscriptionId;
    uint32 public constant VRF_CALLBACK_GAS_LIMIT = 100_000;
    uint16 public constant VRF_REQUEST_CONFIRMATIONS = 3;
    /// how long a vrf request may stay unanswered before the owner can request again
    uint256 public constant VRF_RETRY_DELAY = 10 minutes;

    /// latest vrf request, earlier ones stay valid (see isVrfRequest)
    uint256 public vrfRequestId;
    uint256 public vrfRequestedAt;
    /// every request this pool made, the first one to be fulfilled decides the draw
    mapping(uint256 => bool) public isVrfRequest;
    /// request whose random word became randomSeed
    uint256 public fulfilledRequestId;
    uint256 public randomSeed;
    bool public randomnessFulfilled;

    /// winning ticket ids, in draw order (winfall.winnerShares[i] belongs to winners[i])
    uint256[] public winners;

    /// pot size taken at the first claim, every payout is computed from it (later top ups don't count)
    uint256 public potSnapshot;
    bool public potSnapshotTaken;
    /// sum of winnerShares of the drawn winners, payout = potSnapshot * share / totalDrawnShares
    uint256 public totalDrawnShares;
    mapping(uint256 => bool) public prizeClaimed;
    uint256 public claimedCount;
    /// next draw position distribute() looks at
    uint256 public distributeCursor;
    /// gas forwarded to an eth winner in distribute(), so a winner contract can't burn the caller's gas
    uint256 public constant DISTRIBUTE_ETH_GAS = 50_000;

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

    function safeMint(address to, uint256 tokenId) public onlyOwner {
        require(block.timestamp < winfall.closeTime, POOL_CLOSED());
        require(_ownerOf(tokenId) == address(0), TICKET_TAKEN(tokenId));
        _safeMint(to, tokenId);
        ticketsMinted += 1;
        allTickets.push(tokenId);
    }

    /// @notice closes the winfall and asks chainlink vrf for the seed of the draw
    /// @dev can be called again if the latest request stayed unanswered for VRF_RETRY_DELAY.
    ///      earlier requests stay valid, so a retry cannot cancel a seed that is already on its way:
    ///      whichever request is fulfilled first becomes the seed, later ones are ignored
    function requestWinners() external onlyOwner returns (uint256 requestId) {
        require(block.timestamp >= winfall.closeTime, POOL_OPEN());
        require(allTickets.length > 0, NO_TICKETS());
        require(!randomnessFulfilled, RANDOMNESS_ALREADY_FULFILLED());
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

    /// @notice true if `ticketId` was already bought (ownerOf reverts for unknown ids, this doesn't)
    function ticketExists(uint256 ticketId) public view returns (bool) {
        return _ownerOf(ticketId) != address(0);
    }

    function isOpen() public view returns (bool) {
        return block.timestamp < winfall.closeTime;
    }

    /// @notice vrf callback, kept minimal so it always fits VRF_CALLBACK_GAS_LIMIT
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        require(msg.sender == address(VRF_COORDINATOR), ONLY_VRF_COORDINATOR(msg.sender));
        require(isVrfRequest[requestId], UNKNOWN_VRF_REQUEST(requestId));
        // first fulfilled request wins, a retry's (or the original's) late answer can't override it
        if (randomnessFulfilled) {
            emit LateFulfillmentIgnored(requestId);
            return;
        }
        randomSeed = randomWords[0];
        randomnessFulfilled = true;
        fulfilledRequestId = requestId;
        emit RandomnessFulfilled(requestId, randomWords[0]);
    }

    /// @notice picks winfall.totalWinners distinct tickets out of allTickets and assigns them to winners
    function pickWinners() external returns (uint256[] memory) {
        require(randomnessFulfilled, RANDOMNESS_PENDING());
        require(winners.length == 0, WINNERS_ALREADY_PICKED());
        require(this.isOpen() == false, POOL_OPEN());
        uint256 total = allTickets.length;
        uint256 count = winfall.totalWinners;
        if (count > total) {
            count = total;
        }

        uint256 seed = randomSeed;
        // partial fisher-yates over indexes 0..total-1 without copying allTickets: only the positions a swap
        // touched are remembered (at most `count`), every other position still holds its own index.
        // same draw as swapping a full copy, but gas only grows with the number of winners, not tickets
        uint256[] memory movedPos = new uint256[](count);
        uint256[] memory movedVal = new uint256[](count);
        uint256 moved = 0;
        for (uint256 i = 0; i < count; i++) {
            uint256 j = i + (uint256(keccak256(abi.encode(seed, i))) % (total - i));
            uint256 pickedIndex = _indexAt(j, movedPos, movedVal, moved);
            if (j != i) {
                // position i is never looked at again, so only j needs to remember what was at i
                moved = _setIndexAt(j, _indexAt(i, movedPos, movedVal, moved), movedPos, movedVal, moved);
            }
            uint256 picked = allTickets[pickedIndex];
            winners.push(picked);
            totalDrawnShares += winfall.winnerShares[i];
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

    /// @notice pays the prize of draw position `index` to the current holder of that winning ticket
    function claim(uint256 index) external nonReentrant returns (uint256 amount) {
        require(winners.length > 0, WINNERS_NOT_PICKED());
        uint256 ticketId = winners[index];
        require(ownerOf(ticketId) == msg.sender, NOT_TICKET_OWNER());
        require(!prizeClaimed[index], ALREADY_CLAIMED(index));

        _takePotSnapshot();
        amount = _prizeOf(index);
        prizeClaimed[index] = true;
        claimedCount += 1;
        emit PrizeClaimed(index, ticketId, msg.sender, amount);

        if (winfall.currency == address(0)) {
            (bool ok,) = payable(msg.sender).call{value: amount}("");
            require(ok, "prize transfer failed");
        } else {
            SafeERC20.safeTransfer(IERC20(winfall.currency), msg.sender, amount);
        }
    }

    /// @notice fallback for winners who don't claim: pushes prizes to the current ticket holders.
    ///         callable by anyone, handles up to `maxWinners` unclaimed positions per call starting at
    ///         distributeCursor, so big draws can be paid out over several calls.
    ///         a failed transfer doesn't revert, that position just stays unclaimed and its holder can still claim()
    /// @return paid number of prizes paid in this call
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
                emit PrizeClaimed(i, ticketId, to, amount);
            } else {
                prizeClaimed[i] = false;
                claimedCount -= 1;
                emit PrizeTransferFailed(i, ticketId, to, amount);
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
        return potSnapshot * winfall.winnerShares[index] / totalDrawnShares;
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

    /// @notice true once every drawn winner has claimed
    function allClaimed() public view returns (bool) {
        return winners.length > 0 && claimedCount == winners.length;
    }

    function _potBalance() internal view returns (uint256) {
        if (winfall.currency == address(0)) {
            return address(this).balance;
        }
        return IERC20(winfall.currency).balanceOf(address(this));
    }

    function getConfig() external view returns (PoolConfig memory) {
        return winfall;
    }

    function getWinners() external view returns (uint256[] memory) {
        return winners;
    }

    /// @notice current holder of the ticket that won position `index`
    function winnerAt(uint256 index) external view returns (address) {
        return ownerOf(winners[index]);
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

    function rescueFunds(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "cannot rescue to zero address");
        if (token == winfall.currency) {
            require(ticketsMinted == 0 || allClaimed(), "pot locked until every winner has claimed");
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
