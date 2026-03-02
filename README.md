# RNBWStaking

Shares-based staking contract for $RNBW on Base. Exit fees stay in the pool and increase the exchange rate for remaining stakers. Positions are non-transferable.

- Chain: Base (EVM)
- Solidity: 0.8.24
- Framework: Foundry
- Dependencies: OpenZeppelin Contracts

## Key Mechanics

| Feature | Details |
|---------|---------|
| Staking | `stake()` -- user calls directly or via relay (Gelato Turbo / Relay.link / EIP-7702) |
| Unstaking | `unstake()` -- user calls directly or via relay. Partial unstake toggleable by admin (default: disabled) |
| Exit fee | Configurable 1%--75%, default 15% -- stays in pool |
| Cashback | Backend allocates via `allocateCashbackWithSignature()` -- mints shares immediately in one step |
| Dead shares | First deposit mints 1000 shares to `0xdead` (UniswapV2-style inflation protection) |
| Cashback reserve | Pre-funded via `fundCashbackReserve()`, tracked separately, protected from emergency withdrawal |
| Access control | Safe (multisig) for admin ops, 2-step safe transfer, up to 3 trusted EIP-712 signers |
| Signatures | EIP-712 with expiry + nonce replay protection (cashback only) |

## How It Works

### Core Concept: Shares and Exchange Rate

When you stake RNBW you receive shares, not a 1:1 token balance. The exchange rate between shares and RNBW changes over time as exit fees accumulate in the pool.

```
Exchange Rate = totalPooledRnbw / totalShares
Your RNBW Value = yourShares * totalPooledRnbw / totalShares
```

The first staker gets shares at a 1:1 ratio (minus 1000 dead shares for inflation protection). Every subsequent staker gets shares at the current exchange rate.

---

### Staking Flow

Entry point: `stake(amount)` -- user calls directly or via relay. `msg.sender` is always the user.

Preview: `previewStake(amount)` returns `sharesToMint` (returns 0 for dust amounts).

Steps:

1. Validate -- amount > 0, first-time stakers must meet `minStakeAmount`.
2. Transfer -- RNBW moves from user to contract via `safeTransferFrom`.
3. Calculate shares -- `sharesToMint = (amount * totalShares) / totalPooledRnbw`. First staker: `sharesToMint = amount - 1000` (dead shares minted to `0xdead`).
4. Guard -- reverts with `ZeroSharesMinted` if shares round to 0.
5. Mint -- update `shares[user]`, `totalShares`, `totalPooledRnbw`.
6. Metadata -- set `stakingStartTime` (first stake), accumulate `totalRnbwStaked`.

Example:

```
Pool: totalPooledRnbw = 100,000, totalShares = 100,000

--- Alice stakes 50,000 RNBW ---
sharesToMint = (50,000 * 100,000) / 100,000 = 50,000
Pool after:  totalPooledRnbw = 150,000, totalShares = 150,000
Alice: 50,000 shares = 50,000 RNBW
```

---

### Unstaking Flow

Entry points:
- `unstake(sharesToBurn)` -- burn specific shares. Subject to partial unstake toggle.
- `unstakeAll()` -- burn all shares. Always allowed regardless of partial unstake setting.

Partial unstake is disabled by default. When disabled, `unstake()` only accepts full unstake (`sharesToBurn == shares[user]`). Admin can enable via `setAllowPartialUnstake(true)`.

The parameter is shares to burn, not RNBW amount. Use `getSharesForRnbw(desiredAmount)` to convert, or `unstakeAll()` for full exit.

Preview: `previewUnstake(sharesToBurn)` returns `(rnbwValue, exitFee, netReceived)`.

Steps:

1. Validate -- shares > 0, sufficient balance, partial unstake check.
2. Calculate value -- `rnbwValue = (sharesToBurn * totalPooledRnbw) / totalShares`.
3. Exit fee -- `exitFee = rnbwValue * exitFeeBps / 10,000` (ceil-rounded, default 15%).
4. Guard -- reverts with `ZeroUnstakeAmount` if net amount is 0.
5. Burn shares -- deduct from user and totals. Only `netAmount` leaves the pool; exit fee stays.
6. Residual sweep -- if only dead shares remain, sweep pool to safe and reset to clean slate.
7. Metadata -- track `totalRnbwUnstaked`, `totalExitFeePaid`. Reset `stakingStartTime` on full exit.
8. Transfer -- send `netAmount` to user.

Example:

```
Pool: totalPooledRnbw = 100,000, totalShares = 100,000
Alice: 50,000 shares, Bob: 50,000 shares

--- Bob unstakes 50,000 shares ---
rnbwValue = (50,000 * 100,000) / 100,000 = 50,000 RNBW
exitFee   = 50,000 * 1500 / 10,000       = 7,500 RNBW
netAmount = 50,000 - 7,500                = 42,500 RNBW

Pool after: totalPooledRnbw = 57,500, totalShares = 50,000
Bob receives: 42,500 RNBW
Alice's value: 50,000 * 57,500 / 50,000 = 57,500 RNBW (+7,500 gain)
```

The exit fee stays in the pool, increasing the exchange rate from 1.0 to 1.15 for remaining stakers.

---

### Cashback Flow

Entry point: `allocateCashbackWithSignature(user, rnbwCashback, nonce, expiry, sig)` -- any `msg.sender`, signature validated.

Contract must be pre-funded via `fundCashbackReserve(amount)`. The reserve is tracked separately from the staking pool and protected from `emergencyWithdraw`.

Cashback mints shares immediately -- no pending balance or compound step.

Steps:

1. Validate signature -- EIP-712, expiry check, nonce replay protection.
2. Check position -- user must have `shares > 0`.
3. Check reserve -- `rnbwCashback <= cashbackReserve`.
4. Calculate shares -- `sharesToMint = (rnbwCashback * totalShares) / totalPooledRnbw`.
5. Guard -- reverts with `ZeroSharesMinted` if shares round to 0.
6. Mint shares -- update balances, deduct from `cashbackReserve`, accumulate `totalCashbackReceived`.

No token transfer happens -- RNBW is already in the contract from `fundCashbackReserve()`. It moves from reserve into `totalPooledRnbw` by minting shares.

Cashback requires `shares[user] > 0`. If a user fully unstakes before their pending cashback is allocated, the call reverts with `NoStakePosition`. The backend must allocate cashback before or alongside unstaking -- never after a full exit. Unused reserve stays available for other users or can be recovered via `emergencyWithdraw`.

Nonces are arbitrary per `(user, nonce)` -- not sequential. Nonce 9999 can be used before nonce 1. This allows out-of-order processing (retries, parallel workers, batch resubmission). The `expiry` timestamp is the invalidation mechanism -- use short expiries (e.g., 1 hour) so stale signatures die quickly.

Example:

```
Pool: totalPooledRnbw = 100,000, totalShares = 100,000
cashbackReserve = 5,000, Alice: 50,000 shares

--- 500 RNBW cashback to Alice ---
sharesToMint = (500 * 100,000) / 100,000 = 500
Pool after: totalPooledRnbw = 100,500, totalShares = 100,500
cashbackReserve = 4,500, Alice: 50,500 shares
```

---

### What the UI Shows

| UI Element | Source |
|------------|--------|
| Staked RNBW | `getPosition(user).stakedAmount` (= shares converted at current exchange rate) |
| Exchange Rate | `getExchangeRate()` (scaled by 1e18) |
| Shares (advanced) | `getPosition(user).userShares` |
| Staking Since | `getPosition(user).stakingStartTime` |
| Lifetime Cashback | `getPosition(user).totalCashbackReceived` |
| Lifetime Staked | `getPosition(user).totalRnbwStaked` |
| Lifetime Unstaked | `getPosition(user).totalRnbwUnstaked` (net, after exit fee) |
| Lifetime Exit Fees | `getPosition(user).totalExitFeePaid` |
| Preview Stake | `previewStake(amount)` → shares to mint |
| Preview Unstake | `previewUnstake(shares)` → `(rnbwValue, exitFee, netReceived)` |

---

## APY Calculation (Off-Chain)

Global APY is computed off-chain by comparing on-chain state at two blocks. No indexer required.

### Data Sources

| Component | What drives it | On-chain signal |
|-----------|---------------|-----------------|
| Exit Fee APY | Users unstaking (15% stays in pool) | `getExchangeRate()` increases |
| Cashback APY | Cashback allocated to stakers | `totalCashbackAllocated` increases |

Cashback does not move the exchange rate (shares and pool grow proportionally), so it must be tracked separately.

### Reads (2 RPC calls at block A and block B)

```javascript
// Block A (7 days ago)
const rateA     = await contract.getExchangeRate({ blockTag: blockA });
const cashbackA = await contract.totalCashbackAllocated({ blockTag: blockA });
const poolA     = await contract.totalPooledRnbw({ blockTag: blockA });
const tsA       = (await provider.getBlock(blockA)).timestamp;

// Block B (now)
const rateB     = await contract.getExchangeRate({ blockTag: blockB });
const cashbackB = await contract.totalCashbackAllocated({ blockTag: blockB });
const tsB       = (await provider.getBlock(blockB)).timestamp;
```

### Formula

```javascript
const SECONDS_PER_YEAR = 365.25 * 86400; // 31_557_600
const elapsed = tsB - tsA;

// 1. Exit Fee APY (from exchange rate growth)
const exitFeeApy = ((rateB / rateA) ** (SECONDS_PER_YEAR / elapsed) - 1) * 100;

// 2. Cashback APY (from global counter delta)
const cashbackApy = ((cashbackB - cashbackA) / poolA) * (SECONDS_PER_YEAR / elapsed) * 100;

// 3. Total APY
const totalApy = exitFeeApy + cashbackApy;
```

### Recommended Time Window

| Window | Block gap (Base, 2s blocks) | Use case |
|--------|---------------------------|----------|
| 24 hours | ~43,200 blocks | Daily data point |
| 7 days | ~302,400 blocks | Primary displayed APY |
| 30 days | ~1,296,000 blocks | Long-term APY |

7 days balances smoothness (avoids single-whale-unstake spikes) with responsiveness.

```javascript
const blockB = await provider.getBlockNumber();  // now
const blockA = blockB - 302_400;                 // ~7 days ago on Base
```

### Per-User Lifetime P&L (single `getPosition` call)

```javascript
const [
    stakedAmount, userShares, lastUpdateTime, stakingStartTime,
    totalCashbackReceived, totalRnbwStaked, totalRnbwUnstaked, totalExitFeePaid
] = await contract.getPosition(user);

// Lifetime net profit (cashback already included in stakedAmount via shares)
const netProfit = stakedAmount + totalRnbwUnstaked - totalRnbwStaked;

// Decomposition
const totalCashbackEarned = totalCashbackReceived;
const exchangeRateGain    = netProfit - totalCashbackEarned + totalExitFeePaid;

// Invariant: netProfit == totalCashbackEarned + exchangeRateGain - totalExitFeePaid
```

Global APY (2-block approach):

| Metric | Formula | Meaning |
|--------|---------|---------|
| Total APY | `exitFeeApy + cashbackApy` | Annualized return for stakers |
| Exit Fee APY | `(rateB/rateA)^(year/elapsed) - 1` | Yield from other users unstaking |
| Cashback APY | `(deltaCashback/pool) * (year/elapsed)` | Yield from cashback program |

Per-User P&L:

| Metric | Formula | Meaning |
|--------|---------|---------|
| Net Profit | `stakedAmount + totalUnstaked - totalStaked` | User's all-time profit/loss in RNBW |
| Cashback Earned | `totalCashbackReceived` | Lifetime cashback allocated |
| Exit Fees Paid | `totalExitFeePaid` | Lifetime exit fees deducted |
| Exchange Rate Gain | `netProfit - cashbackEarned + exitFeesPaid` | Pure staking yield (exit fee redistribution) |
| Decomposition | `netProfit == cashbackEarned + exchangeRateGain - exitFeesPaid` | Invariant check |

### Per-Wallet APY (Indexer-Based)

Per-wallet APY requires an indexer that replays contract events and computes Time-Weighted Average Capital (TWAC).

#### Event Table

```sql
CREATE TABLE staking_events (
    id              BIGSERIAL PRIMARY KEY,
    wallet          TEXT NOT NULL,
    event_type      TEXT NOT NULL,  -- 'stake', 'unstake', 'cashback'
    block_number    BIGINT NOT NULL,
    block_timestamp TIMESTAMPTZ NOT NULL,
    rnbw_amount     NUMERIC(78,0) NOT NULL,
    shares_delta    NUMERIC(78,0) NOT NULL,
    exchange_rate   NUMERIC(38,18) NOT NULL,
    exit_fee        NUMERIC(78,0) DEFAULT 0,
    tx_hash         TEXT NOT NULL,
    UNIQUE(tx_hash, wallet, event_type)
);

CREATE INDEX idx_staking_events_wallet ON staking_events(wallet, block_timestamp);
```

#### Deriving Exchange Rate From Events (No Extra RPC Calls)

The exchange rate is implicit in every event — no need to emit it separately:

| Event | Formula |
|-------|---------|
| `Staked(user, rnbwAmount, sharesMinted, _)` | `rnbwAmount / sharesMinted` |
| `Unstaked(user, sharesBurned, rnbwValue, _, _)` | `rnbwValue / sharesBurned` |
| `CashbackAllocated(user, rnbwAmount, sharesMinted)` | `rnbwAmount / sharesMinted` |

> Edge case: the very first stake mints 1000 dead shares, so `sharesMinted = amount - 1000`. The derived rate is still correct but slightly above 1.0.

#### Walkthrough Example

Events for Alice:

| Event | Timestamp | RNBW Amount | Shares Delta | Exchange Rate |
|-------|-----------|-------------|-------------|---------------|
| stake | Jan 1 | 1000 | +1000 | 1.0 |
| cashback | Mar 1 | 50 | +50 | 1.0 |
| unstake | Jul 1 | 550 (gross) | -500 | 1.1 |

Step 1 — Build capital periods (what Alice had, for how long):

| Period | Running Shares | Rate | Capital (RNBW) | Duration (days) |
|--------|---------------|------|----------------|-----------------|
| Jan 1 → Mar 1 | 1000 | 1.0 | 1000 | 59 |
| Mar 1 → Jul 1 | 1050 | 1.0 | 1050 | 122 |
| Jul 1 → Dec 31 | 550 | 1.1 | 605 | 183 |

Each period starts when an event changes the wallet's share balance. The capital is `running_shares × exchange_rate` at that point.

Step 2 — Compute TWAC:

```
TWAC = (1000×59 + 1050×122 + 605×183) / (59 + 122 + 183)
     = (59000 + 128100 + 110715) / 364
     = 817.9 RNBW
```

Step 3 — Compute net profit:

```
netProfit = currentValue + totalUnstaked - totalStaked
          = 605 + 550 - 1000
          = 155 RNBW
```

Step 4 — APY:

```
duration = 364 days
APY = (netProfit / TWAC) × (365.25 / duration)
    = (155 / 817.9) × (365.25 / 364)
    = 0.19
    = 19%
```

#### Formula Summary

```
Per-Wallet APY = (netProfit / TWAC) × (secondsPerYear / durationSeconds)

Where:
  netProfit       = stakedAmount + totalUnstaked - totalStaked
  TWAC            = Σ(capital_i × duration_i) / Σ(duration_i)
  secondsPerYear  = 31,557,600 (365.25 days)
  durationSeconds = now - first_stake_timestamp
```

> Most users have 2-10 events, so per-wallet queries are trivially fast even at 500 tx/day.

---

## Security Features

- Dead shares: 1000 shares minted to `0xdead` on first deposit (prevents share inflation / first depositor attack)
- Cashback reserve: tracked separately from staking pool, protected from `emergencyWithdraw`
- Emergency withdraw: for RNBW, only excess above `totalPooledRnbw + cashbackReserve` can be withdrawn -- the pool and reserve are untouchable. Non-RNBW tokens have no restriction (rescue for accidental sends).
- Min stake floor: `minStakeAmount` cannot be set below 1 RNBW
- Inflation guard: `ZeroSharesMinted` revert protects depositors from rounding attacks
- Residual sweep: when only dead shares remain, orphaned exit fees are swept to safe and pool is reset
- Exit fee rounding: ceiling division ensures fractional wei favors the protocol
- Dust unstake guard: `ZeroUnstakeAmount` revert prevents ceil-rounded exit fee from consuming 100% of a dust unstake
- 2-step safe transfer: `proposeSafe()` + `acceptSafe()` prevents transfer to wrong address
- Partial unstake toggle: `allowPartialUnstake` (default: disabled)
- Preview dust guard: `previewStake()` returns 0 instead of reverting for dust amounts
- Batch size limit: `batchAllocateCashbackWithSignature` capped at 50 entries with upfront reserve check
- Rich error context: user-facing errors include address and value params for debugging

### Custom Errors

All user-facing errors include contextual parameters for off-chain debugging. Admin errors use bare selectors since `msg.sender` provides sufficient context.

| Error | Parameters | Thrown in |
|-------|-----------|-----------|
| `NoStakePosition` | `(user)` | `_unstake`, `_allocateCashback` |
| `InsufficientShares` | `(user, requested, available)` | `_unstake` |
| `BelowMinimumStake` | `(user, amount, minRequired)` | `_stake` |
| `ZeroSharesMinted` | `(user, amount)` | `_stake`, `_allocateCashback` |
| `ZeroUnstakeAmount` | `(user, rnbwValue)` | `_unstake` |
| `PartialUnstakeDisabled` | `(user, sharesToBurn, totalUserShares)` | `_unstake` |

### Dead Shares Lifecycle

Dead shares prevent the [share inflation / first depositor attack](https://docs.openzeppelin.com/contracts/5.x/erc4626#inflation-attack). They do not accumulate -- always exactly 0 or 1000.

```
Empty pool → first stake mints 1000 dead shares to 0xdead
Active pool → no dead shares minted, count stays at 1000
Last user unstakes → residual sweep resets dead shares to 0 (clean slate)
```

Invariant: `totalShares == 0 ⟹ totalPooledRnbw == 0`.

## Build

```shell
forge build
```

## Test

```shell
forge test
```

Unit tests (`RNBWStaking.t.sol`) and simulation tests (`RNBWStakingSimulation.t.sol`).

```shell
forge test -vvv                                          # verbose output
forge test --match-contract RNBWStakingSimulation -vvv   # simulation only
```

## Format

```shell
forge fmt
```

## Deployment

### Environment Variables

Copy the appropriate example file and fill in values:

```shell
cp .env.staging.example .env.staging    # for staging (Tenderly Virtual TestNet)
cp .env.production.example .env.production  # for production (Base mainnet)
```

| Variable | Description |
|----------|-------------|
| `RPC_URL` | RPC endpoint (Tenderly for staging, `https://mainnet.base.org` for production) |
| `PRIVATE_KEY` | Deployer wallet private key |
| `ETHERSCAN_API_KEY` | Tenderly access token (staging) or Basescan API key (production) |
| `RNBW_TOKEN` | RNBW ERC20 token contract address |
| `SAFE_ADDRESS` | Admin multisig (Safe) address |
| `SIGNER` | Initial trusted EIP-712 signer address for cashback operations |

### Deploy

```shell
make deploy-staging       # deploy to Tenderly Virtual TestNet
make deploy-production    # deploy to Base mainnet (confirmation prompt)
```

### Verify

```shell
make verify-staging ADDRESS=0x...     # verify on staging
make verify-production ADDRESS=0x...  # verify on Basescan
```

## EIP-7702 Compatibility

The contract is compatible with EIP-7702 (account abstraction via code delegation). `stake()` and `unstake()` use `msg.sender`, so a 7702-delegated EOA can call them directly through its delegated code. These functions also work with Gelato Turbo Relayer and Relay.link, which use smart account patterns where `msg.sender` is the user's address. `allocateCashbackWithSignature()` works with any `msg.sender` since it validates the trusted backend signer, not the caller.

## Deployment Assumptions

Deployed on Base (Optimistic Rollup). No public mempool, so signature extraction / front-running is not practical. Block time ~2s.

RNBW is a standard ERC20 -- not fee-on-transfer, not deflationary, no transfer callbacks. The token address is `immutable` in the constructor. `_stake` does not do a balance-before/after check because there is no fee-on-transfer to reconcile.

### Batch cashback: all-or-nothing

`batchAllocateCashbackWithSignature` reverts the whole tx if any item fails. We considered skip-on-failure (emit `ClaimSkipped`, continue loop) but rejected it -- partial execution makes backend reconciliation harder, and on Base the main failure mode is rate drift causing `ZeroSharesMinted` on micro-cashbacks, which the backend should filter out before submitting.

The upfront `totalCashback > cashbackReserve` check is a gas optimization (fail before N ECDSA recovers). Each `_allocateCashback` also checks individually, so the batch pre-check is redundant for correctness.

Backend responsibility: filter amounts that would mint 0 shares at current rate, retry failed batches after removing stale items.

### No slippage protection

`stake()` and `unstake()` do not accept `minSharesOut` / `minAmountOut` parameters. On Base there is no public mempool and no transaction reordering, so sandwich attacks are not practical. The exchange rate only moves favorably for stakers (exit fees increase it). This is a deliberate simplification for Base-only deployment.

### No admin access to pool or reserve

There is no function that lets the admin withdraw from `totalPooledRnbw` or `cashbackReserve`. Pool RNBW is only withdrawable by stakers burning shares. Cashback reserve is only consumable via signed allocations. `emergencyWithdraw` is restricted to excess RNBW above both. To wind down the protocol: pause, let users unstake, residual sweeps to safe when pool empties.

## Security

security@rainbow.me
