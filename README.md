# Winfall

On-chain lottery pools on BNB Chain. Each round is a pool of NFT tickets. When sales close, Chainlink VRF provides the randomness, winners are drawn and the pot is paid out by prize share. Tickets can be priced in a stable token such as USDT while the pot is held in another token such as BTCB, with the conversion done on PancakeSwap V3 and checked against a TWAP.

Built with [Foundry](https://book.getfoundry.sh/).

## Contracts

| Contract | Role |
|---|---|
| [`PoolManager`](src/PoolManager.sol) | Creates pools, sells tickets, splits fees and referral cuts, and owns every pool. |
| [`MegaPool`](src/MegaPool.sol) | One lottery: ERC721 tickets, the pot, the VRF draws, and prize claims. The pot can roll over through several rounds, and with a difficulty set a round can end with no winner (see [MegaPool](#megapool-difficulty-and-rollover)). With difficulty `0` and one round, it's a plain single-round lottery. Deployed once as an implementation; every lottery is a cheap EIP-1167 clone of it. |
| [`PancakeV3Swapper`](src/PancakeV3Swapper.sol) | Finds routes and swaps on PancakeSwap V3. Every pot swap is checked against the route's TWAP. |
| [`V3TwapOracle`](src/libraries/V3TwapOracle.sol) | Library that reads PancakeSwap V3 pool observations: mean tick, time-weighted liquidity, and quotes along a route. |
| [`IPool`](src/interface/IPool.sol), [`ISwapper`](src/interface/ISwapper.sol), [`IPoolManager`](src/interface/IPoolManager.sol) | The interfaces the contracts talk through. `IPool` doesn't depend on the randomness source, and `ISwapper` doesn't depend on the DEX, so either side can be replaced. |

```text
  buyer
    |  buyTickets / buyTicketsWith
    v
  PoolManager --------- clone + initialize ---------> Pool (one per round)
    |                                                   ^         ^
    +--> protocol fee ------> feeTreasury               |         |
    |                                                   |         |
    +--> referral cut ------> referral earnings         |         |
    |                         (claimReferral)           |         |
    |                                                   |         |
    +--> pot share, same currency ----------------------+         |
    |                                                   |         |
    +--> pot share, other currency                      |         |
           |                                            |         |
           v                                            |         |
         PancakeV3Swapper --> PancakeSwap V3 -----------+         |
         (TWAP-checked swap, output sent to the pool)             |
                                                                  |
  Chainlink VRF ------------- random seed ------------------------+
```

## Round lifecycle

1. **Create.** An account with `POOL_CREATOR_ROLE` calls `PoolManager.createPool(symbol, winfall, winfallAmount, threshold)`. The manager clones `Pool`, initializes it with itself as owner, registers the clone as a VRF consumer, and, when the payment token differs from the pot currency, stores a swap route from the swapper.
2. **Sell.** Buyers call `buyTickets` or `buyTicketsWith` until `closeTime`. Buyers choose their own ticket numbers; the whole batch reverts with `TICKET_TAKEN` if any number is already sold. Frontends can check a number first with `MegaPool.ticketExists(number)`.
3. **Request randomness.** After `closeTime`, a pool creator calls `PoolManager.requestWinners(pool)`, which sends one VRF request.
   - If no answer arrives within `VRF_RETRY_DELAY` (10 minutes), the request can be sent again.
   - Earlier requests stay valid, and whichever answer arrives first becomes the seed. A retry therefore can't cancel a seed that is already on its way.
4. **Draw.** Once the seed has arrived, anyone calls `MegaPool.pickWinners()`. It uses a partial Fisher-Yates shuffle over ticket indexes, so every winner is a different ticket. Gas grows with the number of winners, not the number of tickets, and the full ticket list is never copied.
5. **Pay out.**
   - The first `claim` or `distribute` records the pot size (`potSnapshot`). Money added after that doesn't change any prize.
   - Winner `i` receives `potSnapshot * winnerShares[i] / sum(shares of drawn winners)`. If fewer tickets sold than there are prize positions, the unused shares are split among the actual winners.
   - `claim(index)`: the current holder of the winning ticket pulls their prize.
   - `distribute(maxWinners)`: anyone can push prizes in batches. A failed transfer is skipped instead of reverting, and that winner can still `claim`.
6. **Clean up.**
   - `PoolManager.releaseVrfConsumer(pool)` frees the pool's slot on the VRF subscription.
   - Once every winner has claimed, the admin can recover leftover dust or late top-ups with `rescuePoolFunds`.

## MegaPool: difficulty and rollover

Every winfall is a `MegaPool`. Its `difficultyBps`, `totalRounds` and `roundDuration` come from the `Winfall` passed to `createPool`.

- **Ticket numbers:** buyers still choose them. At purchase the contract combines the chosen number with the round that's open, so ticket `number` bought in round `r` becomes NFT id `(r << 128) | number` (`ticketId`, `decodeTicket`). The same number can be bought again in a later round without colliding.
- **Metadata:** `tokenURI` is `<baseURI>/<pool>/ticket/<round>/<number>`, so wallets and the metadata server see the round and the picked number rather than the packed id.
- **Old tickets aren't burned:** tickets from rounds without a winner stay with their holders. They just can't win, because each draw only picks from its own round's tickets.

- **Difficulty:** `difficultyBps` is the chance that a draw position misses. A draw picks from the round's tickets plus enough tickets nobody holds to make that share of picks miss: `tickets / (1 - difficulty)` slots in total. With `0`, every position is won.
- **Rounds:** `currentRound` starts at 1 and goes up to `totalRounds`. Each round sells its own tickets.
- **No winner:** the pot stays in the MegaPool and the next round opens for `roundDuration`, with its ticket sales adding to the pot. A round that sold nothing rolls over straight away when `requestWinners` is called, without a VRF request.
- **Winners:** the first round with at least one winner ends the MegaPool and pays out the whole pot, split by the shares of the positions that were won.
- **Last round:** difficulty is ignored, so the pot is always won as long as the round sold a ticket. If the last round sold nothing, the MegaPool ends with no winners and the admin can rescue the pot.
- **Old draws can't carry over:** a VRF answer for an earlier round, including a late retry, is ignored and can't seed a later round.

## Buying tickets

```solidity
// pay in the pool's paymentToken (e.g. USDT): cheapest path, no buyer-side swap
buyTickets(pool, ticketIds, referrer)

// pay with any routable token, or native BNB (tokenIn = address(0), msg.value = maxAmountIn)
buyTicketsWith(pool, ticketIds, tokenIn, maxAmountIn, deadline, referrer)
```

- **Price:** `ticketPrice × ticketIds.length`, in the pool's `paymentToken`.
- **`buyTicketsWith`:** swaps exactly the price into `paymentToken` (an exact-output swap) and refunds whatever of `maxAmountIn` wasn't needed straight to the buyer. The buyer's `maxAmountIn` and `deadline` are their slippage protection, so quote the amount off-chain (for example with the PancakeSwap Quoter) and add a small buffer.

**Where the payment goes:**

| Share | Destination |
|---|---|
| `feeBps` | `feeTreasury` |
| `referralBps` | the buyer's referrer, as earnings they claim with `claimReferral(token)`. With no referrer it goes into the pot. |
| the rest | the pool's pot. If the pot currency differs from `paymentToken`, it's swapped through the swapper directly into the pool. |

Fees are in basis points: `10_000` is 100%, and `feeBps` is capped at `MAX_PROTOCOL_CUT` (50%).

**Referrals:**
- A buyer's first non-zero referrer is saved permanently in `referrerOf[buyer]`, and every later purchase pays that referrer whatever `referrer` is passed.
- Self-referral is ignored.
- Earnings build up per token and are withdrawn with `claimReferral(token)`, so a referrer who can't receive funds never blocks a purchase.

## Swaps and price protection

Pot swaps spend the pot's money, not the buyer's, so the buyer has no reason to protect them. `PancakeV3Swapper` therefore checks every pot swap against an independent price:

- **Price reference:** the TWAP of the route's pools over `twapWindow` (default 30 minutes), not the current price. The current price can be moved within a single transaction, for example with a flash loan, so checking against it would protect nothing.
- **Minimum output:** at least `twapQuote × (1 − maxSlippageBps)`, default 1%. The contract measures what the pool actually received, not what the router reports.
- **Route finding:**
  - It uses the direct pool if one exists, picking the fee tier (0.01% / 0.05% / 0.25% / 1%) with the highest **time-weighted** liquidity over the TWAP window.
  - Otherwise it routes through the first hub token (for example WBNB, then USDT) that has pools on both sides.
  - Pools whose price history doesn't cover the window are skipped.
- **Routes are fixed per pool** when the pool is created. Buyers can't influence them. A pool creator can update one with `refreshSwapRoute(pool)`.
- **Buyer-side swaps** in `buyTicketsWith` are found at purchase time and aren't TWAP-checked. They spend the buyer's own money, limited by the buyer's `maxAmountIn`.

Native BNB can't be a swap input or output in a pool's configuration; use WBNB. Paying in native BNB through `buyTicketsWith` is supported, because the swapper wraps it.

## Roles and ownership

| Who | Can do |
|---|---|
| `DEFAULT_ADMIN_ROLE` on `PoolManager` | Grant and revoke roles; `setPoolImplementation`, `setSwapper`, `setFeeTreasury`, `rescuePoolFunds`. |
| `POOL_CREATOR_ROLE` on `PoolManager` (any number of accounts) | `createPool`, `requestWinners`, `releaseVrfConsumer`, `refreshSwapRoute`, `setPoolBaseURI`. |
| Owner of `PancakeV3Swapper` | `setHubs`, `setTwapWindow` (5 minutes to 1 day), `setMaxSlippage` (at most 10%). |
| Anyone | Buy tickets, `pickWinners`, `distribute`; winners `claim`; referrers `claimReferral`. |

`PoolManager` is the owner of every pool, so owner-only pool functions are reached through the manager.

## Deployment checklist (BNB Chain)

1. **Pool implementation:** deploy `MegaPool(vrfCoordinator, keyHash, subscriptionId)`. The VRF settings are immutable in its code and shared by every clone.
2. **Swapper:** deploy `PancakeV3Swapper(owner, smartRouter, v3Factory, WBNB, hubs)`, for example with `hubs = [WBNB, USDT]`.
3. **Manager:** deploy `PoolManager(admin, feeTreasury, poolImplementation, vrfCoordinator, subscriptionId)`, then call `setSwapper(swapper)`.
4. **VRF subscription:** transfer ownership of the Chainlink VRF subscription to `PoolManager`, which needs it to add and remove each pool as a consumer. Keep the subscription funded, because an underfunded subscription stalls the draw.
5. **Price history on routed pools:** make sure every PancakeSwap pool on a route has enough observation slots for the TWAP window. Call `increaseObservationCardinalityNext` once per pool, roughly `twapWindow / block time`, about 600 for 30 minutes on BNB Chain. Otherwise the swap reverts with `OLD` or the pool is skipped during routing.
6. **Admin account:** make the admin a multisig. Grant `POOL_CREATOR_ROLE` only to accounts you trust with the draw, because retrying a VRF request is a creator action.

Addresses used by the fork tests, verified on-chain:

| | Address |
|---|---|
| PancakeSwap V3 SmartRouter | `0x13f4EA83D0bd40E75C8222255bc855a974568Dd4` |
| PancakeSwap V3 Factory | `0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865` |
| WBNB | `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c` |
| USDT (BSC-USD, 18 decimals) | `0x55d398326f99059fF775485246999027B3197955` |
| BTCB (18 decimals) | `0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c` |

Check the Chainlink VRF coordinator and key hash against Chainlink's documentation for BNB Chain.

## Development

```shell
git submodule update --init --recursive   # forge-std, openzeppelin, chainlink, uniswap v3-core, pancake-v3-contracts
forge build
forge test
```

Solidity 0.8.36 (pinned with `solc_version` in [foundry.toml](foundry.toml)) with the optimizer on. The remappings are in [remappings.txt](remappings.txt), and the same remappings are in [.vscode/settings.json](.vscode/settings.json) for the Solidity extension.

**Fork tests** run against BNB Chain mainnet with the real PancakeSwap contracts:

```shell
BSC_RPC_URL=<rpc url> BSC_FORK_BLOCK=<block> forge test --match-contract ForkBscTest -vv
```

- `BSC_RPC_URL` defaults to a public node.
- Public nodes sometimes fail with "block not found" on the newest block, so pin `BSC_FORK_BLOCK` to a block slightly behind the tip.
- Use a private RPC for runs you need to repeat exactly.
- CI skips the fork tests (`--no-match-contract ForkBscTest`) because public RPCs are unreliable; run them locally.

**Why `TickMath` comes from Uniswap:** PancakeSwap's own `TickMath` is pinned to Solidity `<0.8`, so `V3TwapOracle` uses Uniswap's 0.8 port instead. Its constants and logic are identical to PancakeSwap's. All other DEX interfaces come from `pancake-v3-contracts`.

## Known limitations
- **No refund if randomness never arrives.** If no VRF answer ever arrives, the pot stays in the pool.
- **Buying many tickets at once can run out of gas.** There's no limit per transaction, and each ticket costs about 50k gas.
- **Routing is simple.** A direct pool is always preferred over a route through a hub, even if the direct pool is much shallower. Call `findRoute` before creating a pool to see which route it will use.
- **PancakeSwap Infinity (V4) isn't supported.** If liquidity moves there, write a new `ISwapper` implementation and switch to it with `setSwapper`. Infinity pools have no built-in TWAP, so the new swapper needs another price source.
