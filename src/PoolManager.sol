// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.36;
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ISwapper} from "./interface/ISwapper.sol";
import {IVRFCoordinatorV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";
import {Winfall, IPoolManager} from "./interface/IPoolManager.sol";
import {IPool} from "./interface/IPool.sol";
import {Pool} from "./Pool.sol";

error INVALID_CLOSE_TIME();
error INVALID_ROLLOVER_TARGET();
error LENGTH_MISMATCH();
error AIRDROP_LIMIT(uint256 left, uint256 requested);
error ONLY_SEED_WITHDRAWABLE(uint256 seeded, uint256 requested);
error POT_LOCKED();
error WINFALL_STILL_OPEN();
error UNKNOWN_POOL(address pool);
error VRF_CONFIG_MISMATCH();
error INVALID_FEES();
error INVALID_TICKET_PRICE();
error ZERO_ADDRESS();
error POOL_CLOSED();
error ZERO_TICKETS();
error WRONG_PAYMENT(uint256 expected, uint256 sent);
error NATIVE_SWAP_UNSUPPORTED();
error SWAPPER_NOT_SET();
error NO_SWAP_NEEDED();
error USE_BUY_TICKETS();
error EXPIRED();
error NOTHING_TO_CLAIM();

/// @notice deploys every winfall as a cheap EIP-1167 clone of one Pool implementation and owns all of them.
/// @dev this contract must own the chainlink vrf subscription, it adds each new pool as a consumer.
///      roles: DEFAULT_ADMIN_ROLE grants/revokes roles and does the sensitive actions (implementation, rescue),
///      POOL_CREATOR_ROLE creates and runs pools, any number of accounts can hold it
contract PoolManager is IPoolManager, AccessControl, ReentrancyGuard {
    bytes32 public constant POOL_CREATOR_ROLE = keccak256("POOL_CREATOR_ROLE");

    /// a winfall has to stay open at least this long
    uint256 public constant MIN_WINFALL_DURATION = 1 days;
    /// 100% in basis points (1 = 0.01%), feeBps and referralBps are both of the ticket price
    uint16 public constant FEE_DENOMINATOR = 10_000;
    uint16 public constant MAX_PROTOCOL_CUT = 5_000;
    /// receives the protocol fee (feeBps) of every ticket
    address public feeTreasury;

    IVRFCoordinatorV2Plus public immutable VRF_COORDINATOR;
    uint256 public immutable vrfSubscriptionId;

    /// Pool implementation new winfalls are cloned from
    address public poolImplementation;
    address[] public allPools;

    mapping(address => Winfall) private _winfalls;

    /// swaps the pot's share of a ticket into the pot currency when paymentToken != currency
    ISwapper public swapper;
    /// route used for each pool's swaps, found by the swapper when the pool is created
    mapping(address => bytes) public swapRoute;

    /// who referred each buyer: set by their first purchase with a referrer, the only one that pays a referral
    mapping(address => address) public referrerOf;
    /// how much of a pool's pot arrived by rollover from other pools, in the pot currency
    mapping(address => uint256) public rolledIn;
    /// how much of a pool's pot came from ticket sales, in the pot currency. what's in the pot beyond rolledIn and
    /// this was seeded, and only seeded money can be airdropped against
    mapping(address => uint256) public soldIntoPot;
    /// unclaimed referral earnings per referrer per token (address(0) = native)
    mapping(address => mapping(address => uint256)) public referralEarnings;

    event PoolImplementationSet(address indexed implementation);
    event PoolCreated(address indexed pool, string name, uint256 closeTime);
    event PotRolledOver(address indexed fromPool, address indexed toPool, uint256 amount);
    event TicketsAirdropped(address indexed pool, address[] to, uint256[] ticketIds);
    event FeeTreasurySet(address indexed treasury);
    event TicketsBought(
        address indexed pool,
        address indexed buyer,
        uint256[] ticketIds,
        uint256 paid,
        /// the whole protocol fee, referralCut is the part of it that went to the referrer
        uint256 fee,
        address referrer,
        uint256 referralCut
    );
    event ReferrerSet(address indexed buyer, address indexed referrer);
    event ReferralClaimed(address indexed referrer, address indexed token, uint256 amount);
    event SwapperSet(address indexed swapper);
    event PaidWithSwap(address indexed pool, address indexed buyer, address indexed tokenIn, uint256 amountIn);
    event SwapRouteSet(address indexed pool, bytes route);

    constructor(
        address admin,
        address _feeTreasury,
        address _poolImplementation,
        address _vrfCoordinator,
        uint256 _vrfSubscriptionId
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(POOL_CREATOR_ROLE, admin);
        _setFeeTreasury(_feeTreasury);
        VRF_COORDINATOR = IVRFCoordinatorV2Plus(_vrfCoordinator);
        vrfSubscriptionId = _vrfSubscriptionId;
        _setPoolImplementation(_poolImplementation);
    }

    function setFeeTreasury(address treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setFeeTreasury(treasury);
    }

    function _setFeeTreasury(address treasury) internal {
        require(treasury != address(0), ZERO_ADDRESS());
        feeTreasury = treasury;
        emit FeeTreasurySet(treasury);
    }

    /// @notice swapper used for pools whose paymentToken differs from their pot currency.
    ///         pools created before keep their stored route, refresh it with refreshSwapRoute if the new swapper
    ///         routes differently
    function setSwapper(address _swapper) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_swapper != address(0), ZERO_ADDRESS());
        swapper = ISwapper(_swapper);
        emit SwapperSet(_swapper);
    }

    /// @notice asks the swapper for the current best route of `pool` (e.g. after liquidity moved to another fee tier)
    function refreshSwapRoute(address pool) external onlyRole(POOL_CREATOR_ROLE) {
        Winfall storage w = _winfalls[pool];
        require(w.pool != address(0), UNKNOWN_POOL(pool));
        require(w.paymentToken != w.currency, NO_SWAP_NEEDED());
        _setSwapRoute(pool, swapper.findRoute(w.paymentToken, w.currency));
    }

    function _setSwapRoute(address pool, bytes memory route) internal {
        swapRoute[pool] = route;
        emit SwapRouteSet(pool, route);
    }

    /// @notice new pools use `implementation`, pools that already exist keep theirs
    function setPoolImplementation(address implementation) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setPoolImplementation(implementation);
    }

    function _setPoolImplementation(address implementation) internal {
        _checkVrfConfig(implementation);
        poolImplementation = implementation;
        emit PoolImplementationSet(implementation);
    }

    /// @dev vrf config is baked into an implementation, it has to point at the subscription this manager owns.
    function _checkVrfConfig(address implementation) internal view {
        require(
            address(Pool(payable(implementation)).VRF_COORDINATOR()) == address(VRF_COORDINATOR)
                && Pool(payable(implementation)).vrfSubscriptionId() == vrfSubscriptionId,
            VRF_CONFIG_MISMATCH()
        );
    }

    /// @notice clones a new pool, initializes it with this manager as owner and registers it as a vrf consumer
    /// @param w fees / price / shares of the winfall, w.pool is ignored and set to the new clone
    function createPool(string calldata symbol, Winfall calldata w)
        external
        onlyRole(POOL_CREATOR_ROLE)
        returns (address pool)
    {
        require(w.closeTime >= block.timestamp + MIN_WINFALL_DURATION, INVALID_CLOSE_TIME());
        require(w.ticketPrice > 0, INVALID_TICKET_PRICE());
        // the referral is paid out of the fee, so it can't be bigger than the fee
        require(w.feeBps <= MAX_PROTOCOL_CUT && w.referralBps <= w.feeBps, INVALID_FEES());
        bytes memory route;
        if (w.paymentToken != w.currency) {
            // swapping only between erc20s, use wrapped tokens (wbnb, weth) for native value
            require(w.paymentToken != address(0) && w.currency != address(0), NATIVE_SWAP_UNSUPPORTED());
            require(address(swapper) != address(0), SWAPPER_NOT_SET());
            // reverts if there's no usable route, so a pool can't be created that nobody could buy into
            route = swapper.findRoute(w.paymentToken, w.currency);
        }

        pool = _deployPool(symbol, w);
        VRF_COORDINATOR.addConsumer(vrfSubscriptionId, pool);

        _winfalls[pool] = w;
        _winfalls[pool].pool = pool;
        allPools.push(pool);
        if (route.length > 0) {
            _setSwapRoute(pool, route);
        }
        emit PoolCreated(pool, w.name, w.closeTime);
    }

    function _deployPool(string calldata symbol, Winfall calldata w) internal returns (address pool) {
        pool = Clones.clone(poolImplementation);
        IPool(pool).initialize(address(this), w.name, symbol, _poolConfig(w));
    }

    function _poolConfig(Winfall calldata w) internal pure returns (IPool.PoolConfig memory) {
        return IPool.PoolConfig({
            totalWinners: w.winningShares.length,
            winnerShares: w.winningShares,
            difficultiesBps: w.difficultiesBps,
            currency: w.currency,
            closeTime: w.closeTime
        });
    }

    // ---- pool owner actions, the manager owns every pool and forwards them by role ----

    function requestWinners(address pool) external onlyRole(POOL_CREATOR_ROLE) returns (uint256 requestId) {
        return _pool(pool).requestWinners();
    }

    /// @notice moves the share of the prize positions nobody won in `fromPool` straight into `toPool`'s pot.
    ///         the money can only go into another pool of this manager with the same pot currency that hasn't been
    ///         drawn yet, never to a wallet
    function rollover(address fromPool, address toPool) external onlyRole(POOL_CREATOR_ROLE) returns (uint256 amount) {
        IPool from = _pool(fromPool);
        require(
            fromPool != toPool && _winfalls[toPool].pool != address(0)
                && _winfalls[toPool].currency == _winfalls[fromPool].currency && !IPool(toPool).drawn(),
            INVALID_ROLLOVER_TARGET()
        );
        amount = from.rollover(toPool);
        rolledIn[toPool] += amount;
        emit PotRolledOver(fromPool, toPool, amount);
    }

    /// @notice second step of handing the vrf subscription to this manager: its current owner first calls
    ///         requestSubscriptionOwnerTransfer(subId, manager) on the coordinator, then the admin calls this.
    ///         the manager has to own the subscription to register pools as consumers
    function acceptVrfSubscription() external onlyRole(DEFAULT_ADMIN_ROLE) {
        VRF_COORDINATOR.acceptSubscriptionOwnerTransfer(vrfSubscriptionId);
    }

    /// @notice offers the vrf subscription to `newOwner` (e.g. a new manager), who then has to accept it
    function transferVrfSubscription(address newOwner) external onlyRole(DEFAULT_ADMIN_ROLE) {
        VRF_COORDINATOR.requestSubscriptionOwnerTransfer(vrfSubscriptionId, newOwner);
    }

    /// @notice frees the pool's slot on the vrf subscription once its draw is done
    function releaseVrfConsumer(address pool) external onlyRole(POOL_CREATOR_ROLE) {
        require(_pool(pool).drawn(), WINFALL_STILL_OPEN());
        VRF_COORDINATOR.removeConsumer(vrfSubscriptionId, pool);
    }

    function setPoolBaseURI(address pool, string calldata newBaseURI) external onlyRole(POOL_CREATOR_ROLE) {
        Pool(payable(address(_pool(pool)))).setBaseURI(newBaseURI);
    }

    /// @notice gives away free tickets of `pool`: ticketIds[i] goes to to[i]. limited by airdropsLeft
    function airdrop(address pool, address[] calldata to, uint256[] calldata ticketIds)
        external
        onlyRole(POOL_CREATOR_ROLE)
    {
        require(to.length == ticketIds.length, LENGTH_MISMATCH());
        uint256 left = airdropsLeft(pool);
        require(to.length <= left, AIRDROP_LIMIT(left, to.length));
        IPool p = IPool(pool);
        for (uint256 i = 0; i < to.length; i++) {
            p.airdrop(to[i], ticketIds[i]);
        }
        emit TicketsAirdropped(pool, to, ticketIds);
    }

    /// @notice how many more tickets of `pool` can be airdropped right now. airdropped tickets can be worth as much
    ///         as the money seeded into the pot, counted at the ticket price: every free ticket is backed by seeded
    ///         money like a bought one is by its price. ticket sales and money rolled over from another pool don't
    ///         add any allowance. a pot in another currency than the tickets is valued at the swapper's twap (minus
    ///         its slippage)
    function airdropsLeft(address pool) public view returns (uint256) {
        Winfall storage w = _winfalls[pool];
        require(w.pool != address(0), UNKNOWN_POOL(pool));
        uint256 seeded = seededPot(pool);
        if (seeded > 0 && w.paymentToken != w.currency) {
            seeded = swapper.minOut(swapper.findRoute(w.currency, w.paymentToken), seeded);
        }
        uint256 allowed = seeded / w.ticketPrice;
        uint256 airdropped = IPool(pool).ticketsAirdropped();
        return allowed > airdropped ? allowed - airdropped : 0;
    }

    /// @notice the part of `pool`'s pot that was seeded: what's in it beyond ticket sales and rollovers
    function seededPot(address pool) public view returns (uint256) {
        uint256 pot = _pool(pool).pot();
        uint256 notSeeded = rolledIn[pool] + soldIntoPot[pool];
        return pot > notSeeded ? pot - notSeeded : 0;
    }

    /// @notice rescues tokens from a pool. its pot currency only when the pool allows it: leftovers once winners
    ///         are paid and the unwon share rolled over, or the seeded money of a pool that closed without any
    ///         ticket (pass type(uint256).max for all of the seed)
    function rescuePoolFunds(address pool, address token, address to, uint256 amount)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        IPool p = _pool(pool);
        // the pool allows more than this, the limits on its pot currency are enforced here
        if (token == _winfalls[pool].currency) {
            if (p.unsoldAndClosed()) {
                // a pool that closed without any ticket gives its seed back, but not money that rolled over into it
                uint256 seeded = seededPot(pool);
                if (amount == type(uint256).max) {
                    amount = seeded;
                }
                require(amount <= seeded, ONLY_SEED_WITHDRAWABLE(seeded, amount));
            } else {
                // otherwise only leftovers: every winner paid and the unwon share rolled over
                require(p.allClaimed() && p.rolloverAmount() == 0, POT_LOCKED());
            }
        }
        p.rescueFunds(token, to, amount);
    }

    // ---- tickets ----

    /// @notice buys the tickets numbered `ticketIds` of `pool` for msg.sender at the pool's ticketPrice each.
    ///         the whole batch reverts with TICKET_TAKEN if any id is already bought (check with pool.ticketExists first).
    ///         paid in paymentToken: feeBps of the price is the protocol fee, the rest goes into the pool's pot.
    ///         out of that fee the buyer's referrer gets referralBps of the price (claimable with claimReferral),
    ///         the fee treasury gets what's left of it.
    ///         if the pot currency differs, the swapper swaps that rest into the pot currency straight into the pool
    ///         along the pool's stored route, reverting if the pool would get less than the twap fair amount.
    ///         native pools take exact msg.value, token pools need an approval of the full price.
    /// @param referrer who referred the buyer, address(0) for nobody. a buyer pays a referral once, on their first
    ///        purchase with a referrer. it's ignored on every purchase after that, in any pool
    function buyTickets(address pool, uint256[] calldata ticketIds, address referrer) external payable nonReentrant {
        Winfall storage w = _checkBuy(pool, ticketIds.length);
        uint256 total = w.ticketPrice * ticketIds.length;

        if (w.paymentToken == address(0)) {
            // native in, native pot (createPool rules out native swaps)
            require(msg.value == total, WRONG_PAYMENT(total, msg.value));
        } else {
            require(msg.value == 0, WRONG_PAYMENT(0, msg.value));
        }
        address paidReferrer = _referrer(referrer);
        _distribute(w, pool, total, msg.sender, paidReferrer);
        _mint(pool, ticketIds, total, w, paidReferrer);
    }

    /// @notice like buyTickets, but pays with any token (or native, tokenIn = address(0) with msg.value = maxAmountIn)
    ///         that the swapper can route into the pool's paymentToken. swaps exactly the ticket price's worth and
    ///         refunds whatever of maxAmountIn wasn't needed straight to the buyer.
    /// @param maxAmountIn the most tokenIn the buyer is willing to spend, their slippage limit (quote it off chain)
    /// @param deadline the purchase reverts after this timestamp, so a stuck transaction can't fill at a stale price
    /// @param referrer same as in buyTickets
    function buyTicketsWith(
        address pool,
        uint256[] calldata ticketIds,
        address tokenIn,
        uint256 maxAmountIn,
        uint256 deadline,
        address referrer
    ) external payable nonReentrant {
        require(block.timestamp <= deadline, EXPIRED());
        Winfall storage w = _checkBuy(pool, ticketIds.length);
        address payToken = w.paymentToken;
        require(payToken != address(0), NATIVE_SWAP_UNSUPPORTED());
        require(tokenIn != payToken, USE_BUY_TICKETS());
        require(address(swapper) != address(0), SWAPPER_NOT_SET());
        uint256 total = w.ticketPrice * ticketIds.length;

        // swap into exactly `total` paymentToken held here, the buyer gets the unspent input back directly
        uint256 spent;
        if (tokenIn == address(0)) {
            require(msg.value == maxAmountIn, WRONG_PAYMENT(maxAmountIn, msg.value));
            spent = swapper.swapExactOut{value: msg.value}(
                address(0), payToken, total, msg.value, address(this), msg.sender
            );
        } else {
            require(msg.value == 0, WRONG_PAYMENT(0, msg.value));
            IERC20 input = IERC20(tokenIn);
            SafeERC20.safeTransferFrom(input, msg.sender, address(this), maxAmountIn);
            SafeERC20.forceApprove(input, address(swapper), maxAmountIn);
            spent = swapper.swapExactOut(tokenIn, payToken, total, maxAmountIn, address(this), msg.sender);
            SafeERC20.forceApprove(input, address(swapper), 0);
        }
        emit PaidWithSwap(pool, msg.sender, tokenIn, spent);

        address paidReferrer = _referrer(referrer);
        _distribute(w, pool, total, address(this), paidReferrer);
        _mint(pool, ticketIds, total, w, paidReferrer);
    }

    function _checkBuy(address pool, uint256 count) internal view returns (Winfall storage w) {
        w = _winfalls[pool];
        require(w.pool != address(0), UNKNOWN_POOL(pool));
        require(IPool(pool).isOpen(), POOL_CLOSED());
        require(count > 0, ZERO_TICKETS());
    }

    /// @notice sends msg.sender their referral earnings in `token` (address(0) = native)
    function claimReferral(address token) external nonReentrant returns (uint256 amount) {
        amount = referralEarnings[msg.sender][token];
        require(amount > 0, NOTHING_TO_CLAIM());
        referralEarnings[msg.sender][token] = 0;
        if (token == address(0)) {
            _sendEth(msg.sender, amount);
        } else {
            SafeERC20.safeTransfer(IERC20(token), msg.sender, amount);
        }
        emit ReferralClaimed(msg.sender, token, amount);
    }

    /// @dev the referrer this purchase pays, if any. a buyer pays a referral once: on their first purchase made with
    ///      a referrer (not themselves). that referrer stays on record in referrerOf, and no later purchase of the
    ///      buyer, in any pool, pays a referral again
    function _referrer(address referrer) internal returns (address) {
        if (referrerOf[msg.sender] != address(0)) return address(0);
        if (referrer == address(0) || referrer == msg.sender) return address(0);
        referrerOf[msg.sender] = referrer;
        emit ReferrerSet(msg.sender, referrer);
        return referrer;
    }

    /// @dev splits `total` paymentToken into the protocol fee and the pot, and the fee into the referrer's cut and
    ///      the treasury's. `from` is the buyer (pull with an approval) or this contract (already holds it after a
    ///      swap). native payments already arrived as msg.value. the referral cut stays here as claimable earnings,
    ///      so a referrer that can't receive can't block purchases
    function _distribute(Winfall storage w, address pool, uint256 total, address from, address referrer) internal {
        uint256 fee = total * w.feeBps / FEE_DENOMINATOR;
        uint256 toPot = total - fee;
        // a share of the ticket price like the fee, but taken out of the fee, never out of the pot
        uint256 referralCut = referrer == address(0) ? 0 : total * w.referralBps / FEE_DENOMINATOR;
        uint256 protocolFee = fee - referralCut;

        address payToken = w.paymentToken;
        if (referralCut > 0) {
            referralEarnings[referrer][payToken] += referralCut;
        }
        if (payToken == address(0)) {
            _sendEth(feeTreasury, protocolFee);
            _sendEth(pool, toPot);
            soldIntoPot[pool] += toPot;
            return;
        }

        IERC20 token = IERC20(payToken);
        _move(token, from, feeTreasury, protocolFee);
        _move(token, from, address(this), referralCut);
        if (payToken == w.currency) {
            _move(token, from, pool, toPot);
            soldIntoPot[pool] += toPot;
        } else {
            // swapper checks the output against the route's twap and sends it straight into the pool
            _move(token, from, address(this), toPot);
            SafeERC20.forceApprove(token, address(swapper), toPot);
            soldIntoPot[pool] += swapper.swap(swapRoute[pool], toPot, pool);
            SafeERC20.forceApprove(token, address(swapper), 0);
        }
    }

    function _move(IERC20 token, address from, address to, uint256 amount) internal {
        if (amount == 0 || from == to) return;
        if (from == address(this)) {
            SafeERC20.safeTransfer(token, to, amount);
        } else {
            SafeERC20.safeTransferFrom(token, from, to, amount);
        }
    }

    /// @param referrer the referrer this purchase paid, address(0) if none
    function _mint(address pool, uint256[] calldata ticketIds, uint256 total, Winfall storage w, address referrer)
        internal
    {
        for (uint256 i = 0; i < ticketIds.length; i++) {
            IPool(pool).safeMint(msg.sender, ticketIds[i]);
        }
        uint256 fee = total * w.feeBps / FEE_DENOMINATOR;
        emit TicketsBought(
            pool,
            msg.sender,
            ticketIds,
            total,
            fee,
            referrer,
            referrer == address(0) ? 0 : total * w.referralBps / FEE_DENOMINATOR
        );
    }

    function _sendEth(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = payable(to).call{value: amount}("");
        require(ok, "eth transfer failed");
    }

    // ---- views ----

    function winfalls(address pool) external view returns (Winfall memory) {
        return _winfalls[pool];
    }

    function totalPools() external view returns (uint256) {
        return allPools.length;
    }

    /// @notice the pool's prize pot: its live balance while it fills up, the snapshot once payouts started
    function getPrizePool(address pool) external view returns (uint256) {
        return _pool(pool).pot();
    }

    function _pool(address pool) internal view returns (IPool) {
        require(_winfalls[pool].pool != address(0), UNKNOWN_POOL(pool));
        return IPool(pool);
    }

    // TODO airdrop: cant mint more than 10 % of ticket price of pool
}
