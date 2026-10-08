# Winfall

On-chain lottery pools on BNB Chain. Each round is a pool of NFT tickets. When sales close, Chainlink VRF provides the randomness, winners are drawn and the pot is paid out by prize share. Tickets can be priced in a stable token such as USDT while the pot is held in another token such as BTCB, with the conversion done on PancakeSwap V3 and checked against a TWAP.

Built with [Foundry](https://book.getfoundry.sh/).

## Contracts

| Contract | Role |
|---|---|
| [`PoolManager`](src/PoolManager.sol) | Creates pools, sells tickets, splits fees and referral cuts, and owns every pool. |
| [`Pool`](src/Pool.sol) | One lottery: ERC721 tickets, the pot, the VRF draw, prize claims, and the rollover of prizes nobody won. Deployed once as an implementation; every lottery is a cheap EIP-1167 clone of it. |
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

## Pool lifecycle

1. **Create.** An account with `POOL_CREATOR_ROLE` calls `PoolManager.createPool(symbol, winfall)`. The manager clones `Pool`, initializes it with itself as owner, registers the clone as a VRF consumer, and, when the payment token differs from the pot currency, stores a swap route from the swapper.
2. **Sell.** Buyers call `buyTickets` or `buyTicketsWith` until the pool's `closeTime`. Buyers choose their own ticket numbers, and the ticket's NFT id is that number. The whole batch reverts with `TICKET_TAKEN` if any number is already sold. Frontends can check a number first with `Pool.ticketExists(id)`.
3. **Request randomness.** After `closeTime`, a pool creator calls `PoolManager.requestWinners(pool)`, which sends one VRF request.
   - If no answer arrives within `VRF_RETRY_DELAY` (10 minutes), the request can be sent again.
   - Earlier requests stay valid, and whichever answer arrives first becomes the seed. A retry therefore can't cancel a seed that is already on its way.
   - A pool that sold no tickets needs no draw: it's marked as drawn without winners straight away.
4. **Draw.** Once the seed has arrived, anyone calls `Pool.pickWinners()`. Each prize position first misses with its own difficulty (see below); otherwise it wins a ticket that hasn't won yet, picked with a partial Fisher-Yates shuffle over ticket indexes. Gas grows with the number of winners, not the number of tickets, and the full ticket list is never copied.
5. **Pay out.**
   - The first `claim`, `distribute` or `rollover` records the pot size (`potSnapshot`). Money added after that doesn't change any amount.
   - `Pool.pot()` and `PoolManager.getPrizePool(pool)` return the live balance until that snapshot, and the snapshot from then on, so the reported pot doesn't shrink as prizes are paid.
   - The winner of position `i` receives `potSnapshot * winnerShares[i] / 10_000`. The shares are the prize split in basis points and must add up to exactly 10,000, so `[5000, 3000, 2000]` is 50% / 30% / 20%.
   - `claim(index)`: the current holder of the winning ticket pulls their prize. `index` is the winner's place in `getWinners()`, not the prize position.
   - Views for frontends: `winnersInfo()` returns every winner's ticket, prize position, holder, prize and claim status in one call. The holder is the ticket's current owner until the prize is claimed, and the address that was paid (`prizePaidTo`) after that. `prizes()` gives what each position pays, using the current pot before the snapshot.
   - `distribute(maxWinners)`: anyone can push prizes in batches. A failed transfer is skipped instead of reverting, and that winner can still `claim`.
6. **Roll over.** The shares of the positions nobody won stay in the pool until a pool creator calls `PoolManager.rollover(fromPool, toPool)` (see below). Winners don't have to wait for it.
7. **Clean up.**
   - `PoolManager.releaseVrfConsumer(pool)` frees the pool's slot on the VRF subscription once the draw is done.
   - Once every winner has been paid and the unwon share has been rolled over, the admin can recover leftover dust or late top-ups with `rescuePoolFunds`.
   - A pool that closed without a single ticket, sold or airdropped, gives its seeded money back: `rescuePoolFunds` lets the admin withdraw up to `seededPot(pool)`. Money that rolled over into it still has to be rolled on.
   - Tokens other than the pot currency (and stray BNB in a token pool) can be rescued at any time.

## Difficulty and rollover

- **Difficulty per prize position:** `difficultiesBps[i]` is the chance, in basis points, that position `i` has no winner. `[9000, 5000, 0]` makes 1st place miss 90% of the time, 2nd place 50%, and 3rd place always won. An empty list means every position is always won. The cap is 9,000 (`MAX_DIFFICULTY_BPS`), so every position has at least a 10% chance of being won.
- **Too few tickets:** a position also has no winner when there are fewer tickets than positions.
- **Unwon shares aren't split among the winners.** Each winner gets exactly their own position's share. The rest, `potSnapshot * unwon shares / 10_000`, is what `rolloverAmount()` reports.
- **Rollover moves that money from pool to pool:** `PoolManager.rollover(fromPool, toPool)` sends it straight into `toPool`'s pot. `toPool` must be another pool of this manager with the same pot currency that hasn't been drawn yet. It can't go to a wallet, and it can only be done once per pool.
- **The admin can't take the unwon share.** `rescuePoolFunds` refuses the pot currency until every winner is paid and the rest has been rolled over. The one exception is a pool that closed without any ticket: its seeded money can be withdrawn, because nobody has a stake in it. Rolled-over money never can.
- **A jackpot ends with a guaranteed pool:** to make sure a rolled-over pot is finally paid, the operator creates a pool with no difficulties and rolls into it. That is operator policy; the contracts don't force it.

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

| Share of the ticket price | Destination |
|---|---|
| `feeBps` | the protocol fee. Out of it, on a buyer's first referred purchase, `referralBps` of the ticket price goes to the referrer, as earnings they claim with `claimReferral(token)`. What's left of the fee, or all of it when no referral is paid, goes to `feeTreasury`. |
| the rest | the pool's pot. If the pot currency differs from `paymentToken`, it's swapped through the swapper directly into the pool. |

Both are in basis points of the ticket price (`10_000` is 100%). `feeBps` is capped at `MAX_PROTOCOL_CUT` (50%), and `referralBps` can't be more than `feeBps`, because the referral is paid out of the fee.

Example with a 100 USDT purchase, `feeBps = 500` and `referralBps = 100`: the fee is 5 USDT, of which the referrer gets 1 USDT and the treasury 4 USDT. The pot gets 95 USDT, with or without a referrer.

**Referrals:**
- **A buyer pays a referral once.** Their first purchase made with a referrer pays that referrer and records them in `referrerOf[buyer]`. After that, none of the buyer's purchases, in any pool, pay a referral, whatever `referrer` is passed; the whole fee goes to the treasury.
- A purchase without a referrer doesn't use up that one referral.
- Any address can be a referrer. It doesn't need to hold a ticket.
- Self-referral is ignored.
- Earnings build up per token and are withdrawn with `claimReferral(token)`, so a referrer who can't receive funds never blocks a purchase.

## Airdrops

A pool creator can give away free tickets with `PoolManager.airdrop(pool, to[], ticketIds[])`.

- **Limited by the money seeded into the pot:** airdropped tickets can be worth as much as the seeded money, counted at the ticket price. A 1 BNB seed with 0.01 BNB tickets allows 100 free tickets. `PoolManager.airdropsLeft(pool)` returns how many are available right now, and `seededPot(pool)` the seeded amount.
- **Every free ticket is backed by seeded money,** the way a bought ticket is backed by its price. A seeded pool can airdrop before its first sale, and seeding more allows more.
- **Ticket sales and rolled-over money add no allowance.** That's the players' money. The manager records both per pool (`soldIntoPot`, `rolledIn`); whatever else is in the pot counts as seeded.
- **Pots in another currency** than the tickets (USDT tickets, BTCB pot) are valued in the ticket's token at the swapper's TWAP, minus its slippage margin.
- **Airdropped tickets are ordinary tickets:** they take part in the draw and can win. `Pool` counts them in `ticketsAirdropped`, separately from `ticketsSold`.
- **Same rules as buying:** only while the pool is open, and a taken ticket number is rejected. A batch that would cross the limit reverts as a whole.

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
| `DEFAULT_ADMIN_ROLE` on `PoolManager` | Grant and revoke roles; `setPoolImplementation`, `setSwapper`, `setFeeTreasury`, `rescuePoolFunds`, `acceptVrfSubscription`, `transferVrfSubscription`. |
| `POOL_CREATOR_ROLE` on `PoolManager` (any number of accounts) | `createPool`, `requestWinners`, `rollover`, `airdrop`, `releaseVrfConsumer`, `refreshSwapRoute`, `setPoolBaseURI`. |
| Owner of `PancakeV3Swapper` | `setHubs`, `setTwapWindow` (5 minutes to 1 day), `setMaxSlippage` (at most 10%). |
| Anyone | Buy tickets, `pickWinners`, `distribute`; winners `claim`; referrers `claimReferral`. |

`PoolManager` is the owner of every pool, so owner-only pool functions are reached through the manager.

**Several limits are enforced by the manager, not by the pool:** which pool a rollover can go into, how many tickets can be airdropped, and what `rescuePoolFunds` can take out of a pot (only the seed of an unsold pool, or leftovers once winners are paid and the rest is rolled over). A `Pool` on its own only refuses to release its pot while it has tickets and unpaid winners. These guarantees therefore depend on `PoolManager` staying the owner of its pools, which it always is: it has no function to transfer a pool's ownership.

## Deployment

The scripts in [script/](script/) deploy everything. BSC testnet (chain 97) and BNB Chain mainnet (chain 56) are configured in [NetworkConfig.sol](script/NetworkConfig.sol).

**Setup, once:**

```shell
cp .env.example .env                       # set the RPC URLs
cast wallet import deployer --interactive  # keeps the key in an encrypted keystore, not in .env
source .env
```

**1. Create a Chainlink VRF subscription** owned by the deployer, either at [vrf.chain.link](https://vrf.chain.link) or with the script:

```shell
forge script script/CreateVrfSubscription.s.sol --rpc-url bsc_testnet --broadcast --account deployer
# the id printed during the simulation is not the real one, read it from the transaction:
cast receipt <tx hash> --rpc-url bsc_testnet --json | jq -r '.logs[0].topics[1]' | cast to-dec
```

The subscription has to exist before the deployment, because its id depends on the block it's created in and is built into the `Pool` implementation.

**2. Deploy:**

```shell
VRF_SUBSCRIPTION_ID=<id> forge script script/Deploy.s.sol --rpc-url bsc_testnet --broadcast --account deployer
```

- **What it does:** deploys the `Pool` implementation, `PancakeV3Swapper` and `PoolManager`, sets the swapper, and hands the subscription to the manager (`requestSubscriptionOwnerTransfer`, then `PoolManager.acceptVrfSubscription`). The manager has to own the subscription to register each pool as a consumer.
- **`ADMIN` and `FEE_TREASURY`** default to the deployer. With a different `ADMIN`, the script grants it both manager roles and removes them from the deployer at the end.
- **`VRF_FUND_LINK=<wei>`** also funds the subscription with LINK from the deployer. Draws are paid in LINK, so the subscription needs a balance before the first `requestWinners`. On testnet, get LINK from [faucets.chain.link](https://faucets.chain.link).

**3. Create a pool** (the sender needs `POOL_CREATOR_ROLE`):

```shell
POOL_MANAGER=<manager> forge script script/CreatePool.s.sol --rpc-url bsc_testnet --broadcast --account deployer
```

Defaults: a native BNB pool, 0.001 BNB per ticket, prizes 70% / 30%, open for 1 day and 10 minutes. Price, tokens, shares, difficulties and duration are set with the env vars listed at the top of [CreatePool.s.sol](script/CreatePool.s.sol).

**On mainnet:**
- Set `VRF_COORDINATOR` and `VRF_KEY_HASH` from Chainlink's documentation for BNB Chain and check them on-chain; they aren't hard-coded.
- Make the admin a multisig, and grant `POOL_CREATOR_ROLE` only to accounts you trust with the draw, because retrying a VRF request and rolling over are creator actions.
- Make sure every PancakeSwap pool on a swap route has enough observation slots for the TWAP window (`increaseObservationCardinalityNext`, roughly `twapWindow / block time`). Otherwise the pool is skipped during routing.

**Addresses, checked on-chain:**

| | BSC testnet | BNB Chain mainnet |
|---|---|---|
| Chainlink VRF v2.5 coordinator | `0xDA3b641D438362C440Ac5458c57e00a712b66700` | from Chainlink's docs |
| VRF key hash | `0x8596b430971ac45bdf6088665b9ad8e8630c9d5049ab54b14dff711bee7c0e26` (50 gwei lane) | from Chainlink's docs |
| PancakeSwap V3 SmartRouter | `0x9a489505a00cE272eAa5e07Dba6491314CaE3796` | `0x13f4EA83D0bd40E75C8222255bc855a974568Dd4` |
| PancakeSwap V3 Factory | `0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865` | `0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865` |
| WBNB | `0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd` | `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c` |
| USDT | `0x337610d27c682E347C9cD60BD4b3b107C9d34dDd` | `0x55d398326f99059fF775485246999027B3197955` |

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
- **Public nodes:** leave `BSC_FORK_BLOCK` unset so the tests use the latest block. Public nodes only keep recent state, and BNB Chain's blocks are fast enough that a pinned block ages out during a run ("missing trie node" or "archive requests require a token"). If a run fails with an RPC error such as "block not found", run it again.
- **Pinned blocks:** set `BSC_FORK_BLOCK` only with a private or archive RPC. That's what you need for runs you can repeat exactly.
- CI skips the fork tests (`--no-match-contract ForkBscTest`) because public RPCs are unreliable; run them locally.

**Why `TickMath` comes from Uniswap:** PancakeSwap's own `TickMath` is pinned to Solidity `<0.8`, so `V3TwapOracle` uses Uniswap's 0.8 port instead. Its constants and logic are identical to PancakeSwap's. All other DEX interfaces come from `pancake-v3-contracts`.

## Known limitations
- **No refund if randomness never arrives.** If no VRF answer ever arrives, the pot stays in the pool.
- **A rollover needs a target pool.** The unwon share stays in the finished pool until a pool with the same pot currency exists and someone with the creator role rolls it over.
- **Buying many tickets at once can run out of gas.** There's no limit per transaction, and each ticket costs about 50k gas.
- **Routing is simple.** A direct pool is always preferred over a route through a hub, even if the direct pool is much shallower. Call `findRoute` before creating a pool to see which route it will use.
- **PancakeSwap Infinity (V4) isn't supported.** If liquidity moves there, write a new `ISwapper` implementation and switch to it with `setSwapper`. Infinity pools have no built-in TWAP, so the new swapper needs another price source.
