# RNBWStaking

Shares-based staking contract for **$RNBW** on Base. Exit fees stay in the pool and automatically increase the exchange rate for remaining stakers (same model as Lido/Compound). Positions are non-transferable.

- **Chain:** Base (EVM)
- **Solidity:** 0.8.24
- **Framework:** Foundry
- **Dependencies:** OpenZeppelin Contracts

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

## Function Reference

### User Functions (UI direct or via relay)

| Function | Caller | Description |
|----------|--------|-------------|
| `stake(amount)` | User (direct or relay) | Stake RNBW to receive shares. `msg.sender` is always the user. |
| `unstake(sharesToBurn)` | User (direct or relay) | Burn shares to receive RNBW minus exit fee. `msg.sender` is always the user. |
| `unstakeAll()` | User (direct or relay) | Burn all shares. Convenience wrapper -- no need to query share balance first. |

Both functions use `msg.sender`, so they work with any relay service that preserves the user's address as the caller: Gelato Turbo Relayer, Relay.link, EIP-7702 delegated EOAs.

### Backend Functions (signature-gated)

| Function | Caller | Description |
|----------|--------|-------------|
| `allocateCashbackWithSignature(user, rnbwCashback, nonce, expiry, sig)` | Anyone (signature validated) | Mint shares from pre-funded cashback reserve. Requires EIP-712 signature from a trusted signer. |
| `batchAllocateCashbackWithSignature(users[], amounts[], nonces[], expiries[], sigs[])` | Anyone (signatures validated) | Batch version -- allocate cashback to multiple users in one transaction (max 50). |

Any `msg.sender` can submit these transactions (relayer, bot, user). The contract validates the signature, not the caller.

### Admin Functions (Safe multisig only)

| Function | Description |
|----------|-------------|
| `fundCashbackReserve(amount)` | Pre-fund the cashback reserve with RNBW |
| `setExitFeeBps(newExitFeeBps)` | Update exit fee (1%--75%) |
| `setMinStakeAmount(newMinStakeAmount)` | Update minimum first-time stake (1 RNBW -- 1M RNBW) |
| `setAllowPartialUnstake(allowed)` | Toggle partial unstake (default: disabled) |
| `proposeSafe(newSafe)` | Propose a new Safe address (step 1 of 2-step transfer) |
| `acceptSafe()` | Accept proposed Safe address (step 2, callable by pending safe only) |
| `addTrustedSigner(signer)` | Add an EIP-712 signer (max 3) |
| `removeTrustedSigner(signer)` | Remove an EIP-712 signer (cannot remove last) |
| `pause()` / `unpause()` | Pause/unpause stake, unstake, and cashback |
| `emergencyWithdraw(token, amount)` | Withdraw non-staked tokens. For RNBW, only excess above `totalPooledRnbw + cashbackReserve` |

### View Functions (anyone)

| Function | Returns |
|----------|---------|
| `getPosition(user)` | `(stakedAmount, userShares, lastUpdateTime, stakingStartTime, totalCashbackReceived, totalRnbwStaked, totalRnbwUnstaked, totalExitFeePaid)` |
| `getRnbwForShares(sharesAmount)` | RNBW value at current exchange rate |
| `getSharesForRnbw(rnbwAmount)` | Share equivalent at current exchange rate |
| `getExchangeRate()` | Current exchange rate scaled by 1e18 |
| `previewStake(amount)` | `sharesToMint` -- preview shares from staking (returns 0 for dust amounts) |
| `previewUnstake(sharesToBurn)` | `(rnbwValue, exitFee, netReceived)` -- preview unstake outcome |
| `isNonceUsed(user, nonce)` | Whether a cashback nonce has been used |
| `domainSeparator()` | EIP-712 domain separator |
| `isTrustedSigner(signer)` | Whether an address is a trusted signer |

---

## How It Works

### Core Concept: Shares and Exchange Rate

When you stake RNBW you receive **shares**, not a 1:1 token balance. The exchange rate between shares and RNBW changes over time as exit fees accumulate in the pool.

```
Exchange Rate = totalPooledRnbw / totalShares
Your RNBW Value = yourShares * totalPooledRnbw / totalShares
```

The first staker gets shares at a 1:1 ratio (minus 1000 dead shares for inflation protection). Every subsequent staker gets shares at the current exchange rate.

---

### Staking Flow

**Entry point:** `stake(amount)` -- user calls directly or via relay service (Gelato Turbo, Relay.link, EIP-7702). `msg.sender` is always the user.

**Preview:** Call `previewStake(amount)` to get `sharesToMint` before submitting. Returns 0 for dust amounts (< 1000 wei on empty pool).

**Steps:**

1. **Validate** -- amount must be > 0. First-time stakers must meet `minStakeAmount` (default 1 RNBW, floor 1 RNBW, max 1M RNBW).
2. **Transfer tokens** -- RNBW moves from user's wallet to the contract via `safeTransferFrom`.
3. **Calculate shares** -- `sharesToMint = (amount * totalShares) / totalPooledRnbw`. If pool is empty (first staker): `sharesToMint = amount - MINIMUM_SHARES`, and 1000 dead shares are minted to `0xdead`.
4. **Inflation guard** -- If `sharesToMint` rounds to 0 (manipulated exchange rate), the transaction reverts with `ZeroSharesMinted`.
5. **Mint shares** -- Update `shares[user]`, `totalShares`, `totalPooledRnbw`.
6. **Update metadata** -- Set `stakingStartTime` (first stake only), update `lastUpdateTime`, accumulate `totalRnbwStaked`.

**Example: Two users stake into an empty pool**

```
--- Alice stakes 50,000 RNBW (first staker) ---
Pool before: totalPooledRnbw = 0, totalShares = 0
Dead shares minted: 1000 to 0xdead
sharesToMint = 50,000e18 - 1000 (negligible difference)
Pool after:  totalPooledRnbw = 50,000, totalShares = 50,000
Alice: ~50,000 shares = 50,000 RNBW

--- Bob stakes 50,000 RNBW ---
Exchange rate: 50,000 / 50,000 = 1.0
sharesToMint = (50,000 * 50,000) / 50,000 = 50,000
Pool after:  totalPooledRnbw = 100,000, totalShares = 100,000
Bob: 50,000 shares = 50,000 RNBW
```

**Example: Staking after exit fees have accumulated (exchange rate > 1)**

```
Pool state: totalPooledRnbw = 107,500, totalShares = 100,000
Exchange rate: 107,500 / 100,000 = 1.075

--- Charlie stakes 10,000 RNBW ---
sharesToMint = (10,000 * 100,000) / 107,500 = 9,302 shares
Pool after:  totalPooledRnbw = 117,500, totalShares = 109,302
Charlie: 9,302 shares = 9,302 * 117,500 / 109,302 = 10,000 RNBW
```

Charlie receives fewer shares because each share is now worth more than 1 RNBW.

---

### Unstaking Flow

**Entry points:**
- `unstake(sharesToBurn)` -- burn specific number of shares. Subject to partial unstake toggle.
- `unstakeAll()` -- burn all caller's shares. Always allowed regardless of partial unstake setting.

`msg.sender` is always the user (works with relay services).

**Partial unstake toggle:** By default, partial unstake is **disabled** (`allowPartialUnstake = false`). When disabled, `unstake()` only accepts `sharesToBurn == shares[user]` (full unstake). The admin can enable partial unstake via `setAllowPartialUnstake(true)`. `unstakeAll()` is always available regardless of this setting.

**Important:** The parameter is **shares to burn**, not RNBW amount. The UI should convert a desired RNBW amount to shares: `sharesToBurn = getSharesForRnbw(desiredAmount)`. For full unstake, use `unstakeAll()` or `shares[user]`.

**Preview:** Call `previewUnstake(sharesToBurn)` to get `(rnbwValue, exitFee, netReceived)` before submitting.

**Steps:**

1. **Validate** -- shares > 0, user has enough shares, partial unstake check.
2. **Calculate RNBW value** -- `rnbwValue = (sharesToBurn * totalPooledRnbw) / totalShares`.
3. **Calculate exit fee** -- `exitFee = rnbwValue * exitFeeBps / 10,000` (ceil-rounded). Default: 15%.
4. **Dust guard** -- If `netAmount == 0` (ceil rounding consumed entire amount), reverts with `ZeroUnstakeAmount`.
5. **Calculate net amount** -- `netAmount = rnbwValue - exitFee`.
6. **Burn shares** -- Deduct from `shares[user]` and `totalShares`. Deduct only `netAmount` from `totalPooledRnbw`. The exit fee stays in the pool.
7. **Residual sweep** -- If only dead shares remain (`totalShares == MINIMUM_SHARES`), sweep remaining `totalPooledRnbw` to `safe`, reset dead shares and `totalShares` to 0 (clean slate for next cycle).
8. **Update metadata** -- Reset `stakingStartTime` to 0 if fully unstaked. Track `totalRnbwUnstaked` and `totalExitFeePaid`.
9. **Transfer** -- Send `netAmount` RNBW to user. Sweep residual to safe if applicable.

**Example: Bob unstakes all his shares (exit fee redistributes to Alice)**

```
Pool state: totalPooledRnbw = 100,000, totalShares = 100,000
Alice: 50,000 shares, Bob: 50,000 shares

--- Bob unstakes 50,000 shares ---
rnbwValue = (50,000 * 100,000) / 100,000 = 50,000 RNBW
exitFee   = 50,000 * 1500 / 10,000       = 7,500 RNBW
netAmount = 50,000 - 7,500                = 42,500 RNBW

Pool after: totalPooledRnbw = 100,000 - 42,500 = 57,500
            totalShares     = 100,000 - 50,000  = 50,000

Bob receives: 42,500 RNBW
Alice's value: 50,000 shares * 57,500 / 50,000 = 57,500 RNBW (+7,500 gain!)
```

The 7,500 RNBW exit fee stayed in the pool. Alice's shares are now worth more because the exchange rate increased from 1.0 to 1.15. No transaction was needed to "distribute" the fee -- it happened automatically.

**Example: Last staker unstakes (residual sweep)**

```
Pool state: totalPooledRnbw = 57,500, totalShares = 50,000 + 1000 (dead)
Alice: 50,000 shares (the only real staker)

--- Alice unstakes 50,000 shares ---
rnbwValue = (50,000 * 57,500) / 51,000 = 56,372 RNBW
exitFee   = 56,372 * 1500 / 10,000     = 8,455 RNBW
netAmount = 56,372 - 8,455             = 47,917 RNBW

After burn: totalShares = 1,000 (dead only), totalPooledRnbw = 57,500 - 47,917 = 9,583
Residual sweep triggers: 9,583 RNBW sent to safe
Dead shares reset: shares[0xdead] = 0, totalShares = 0, totalPooledRnbw = 0

Alice receives: 47,917 RNBW
Safe receives:  9,583 RNBW (orphaned exit fee)
Pool after:     totalPooledRnbw = 0, totalShares = 0 (clean slate)
```

---

### Cashback Flow

**Entry point:** `allocateCashbackWithSignature(user, rnbwCashback, nonce, expiry, sig)` -- called by backend (any `msg.sender`, signature validated).

**Prerequisites:** Contract must be pre-funded via `fundCashbackReserve(amount)` (admin). This adds RNBW to the `cashbackReserve`, which is tracked separately from the staking pool and protected from `emergencyWithdraw`.

Cashback mints shares **immediately in one step** -- no pending balance, no separate compound transaction.

**Steps:**

1. **Validate signature** -- EIP-712 with `AllocateCashback` typehash, expiry check, nonce replay protection.
2. **Check position** -- User must have `shares > 0` (active staker).
3. **Check reserve** -- `rnbwCashback` must not exceed `cashbackReserve`.
4. **Calculate shares** -- `sharesToMint = (rnbwCashback * totalShares) / totalPooledRnbw`.
5. **Dust guard** -- If `sharesToMint` rounds to 0, reverts with `ZeroSharesMinted`. Backend should batch small amounts or retry later.
6. **Mint shares** -- Update `shares[user]`, `totalShares`, `totalPooledRnbw`. Deduct from `cashbackReserve`. Accumulate `totalCashbackReceived` and `totalCashbackAllocated`.

No token transfer happens -- the RNBW is already in the contract from `fundCashbackReserve()`. The function moves it from `cashbackReserve` into `totalPooledRnbw` by minting shares.

**Example: Cashback after two swaps**

```
Pool state: totalPooledRnbw = 100,000, totalShares = 100,000
cashbackReserve = 5,000 (pre-funded by admin)
Alice: 50,000 shares

--- Backend allocates 500 RNBW cashback to Alice (after a swap) ---
sharesToMint = (500 * 100,000) / 100,000 = 500
Pool after: totalPooledRnbw = 100,500, totalShares = 100,500
cashbackReserve = 4,500
Alice: 50,500 shares = 50,500 RNBW

--- Backend allocates 1,250 RNBW cashback to Alice (after another swap) ---
sharesToMint = (1,250 * 100,500) / 100,500 = 1,250
Pool after: totalPooledRnbw = 101,750, totalShares = 101,750
cashbackReserve = 3,250
Alice: 51,750 shares = 51,750 RNBW
```

Each cashback allocation immediately increases Alice's shares. No separate compound step needed.

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

APY is computed off-chain using on-chain state at two different blocks. No indexer required.

### Industry Standard

This is the same approach used by major staking protocols:

| Protocol | Method | Window |
|----------|--------|--------|
| **Lido (stETH)** | `(postTotalEther/postTotalShares) / (preTotalEther/preTotalShares)` annualized | 7-day SMA of daily APR values |
| **Rocket Pool (rETH)** | rETH exchange rate change over time, annualized | 7-day rolling |
| **Coinbase (cbETH)** | cbETH exchange rate delta, annualized | 7-day rolling |

All protocols use the same core idea: **compare the exchange rate at two points in time, annualize the difference**. The only variations are window size and smoothing (simple vs. weighted average).

Lido exposes this via a public API (`/v1/protocol/steth/apr/sma`) that returns daily APR values and a 7-day simple moving average.

### Data Sources

| Component | What drives it | On-chain signal |
|-----------|---------------|-----------------|
| Exit Fee APY | Users unstaking (15% stays in pool) | `getExchangeRate()` increases |
| Cashback APY | Cashback allocated to stakers | `totalCashbackAllocated` increases |

Cashback does **not** move the exchange rate (shares and pool grow proportionally), so it must be tracked separately.

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

Use **7-day rolling window** (industry standard used by Lido, Rocket Pool, Coinbase):

| Window | Block gap (Base, 2s blocks) | Use case |
|--------|---------------------------|----------|
| 24 hours | ~43,200 blocks | Daily data point |
| **7 days** | **~302,400 blocks** | **Primary displayed APY** |
| 30 days | ~1,296,000 blocks | Secondary / long-term APY |

7 days balances smoothness (avoids single-whale-unstake spikes) with responsiveness (reflects recent activity).

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

**Global APY (2-block approach)**

| Metric | Formula | Meaning |
|--------|---------|---------|
| Total APY | `exitFeeApy + cashbackApy` | Annualized return for stakers |
| Exit Fee APY | `(rateB/rateA)^(year/elapsed) - 1` | Yield from other users unstaking |
| Cashback APY | `(deltaCashback/pool) * (year/elapsed)` | Yield from cashback program |

**Per-User P&L**

| Metric | Formula | Meaning |
|--------|---------|---------|
| Net Profit | `stakedAmount + totalUnstaked - totalStaked` | User's all-time profit/loss in RNBW |
| Cashback Earned | `totalCashbackReceived` | Lifetime cashback allocated |
| Exit Fees Paid | `totalExitFeePaid` | Lifetime exit fees deducted |
| Exchange Rate Gain | `netProfit - cashbackEarned + exitFeesPaid` | Pure staking yield (exit fee redistribution) |
| Decomposition | `netProfit == cashbackEarned + exchangeRateGain - exitFeesPaid` | Invariant check |

### Per-Wallet APY (Indexer-Based)

Per-wallet APY requires an indexer that replays contract events and computes **Time-Weighted Average Capital (TWAC)**.

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

> **Edge case:** The very first stake mints 1000 dead shares, so `sharesMinted = amount - 1000`. The derived rate is still correct but slightly above 1.0.

#### Walkthrough Example

**Events for Alice:**

| Event | Timestamp | RNBW Amount | Shares Delta | Exchange Rate |
|-------|-----------|-------------|-------------|---------------|
| stake | Jan 1 | 1000 | +1000 | 1.0 |
| cashback | Mar 1 | 50 | +50 | 1.0 |
| unstake | Jul 1 | 550 (gross) | -500 | 1.1 |

**Step 1 — Build capital periods** (what Alice had, for how long):

| Period | Running Shares | Rate | Capital (RNBW) | Duration (days) |
|--------|---------------|------|----------------|-----------------|
| Jan 1 → Mar 1 | 1000 | 1.0 | 1000 | 59 |
| Mar 1 → Jul 1 | 1050 | 1.0 | 1050 | 122 |
| Jul 1 → Dec 31 | 550 | 1.1 | 605 | 183 |

Each period starts when an event changes the wallet's share balance. The capital is `running_shares × exchange_rate` at that point.

**Step 2 — Compute TWAC:**

```
TWAC = (1000×59 + 1050×122 + 605×183) / (59 + 122 + 183)
     = (59000 + 128100 + 110715) / 364
     = 817.9 RNBW
```

**Step 3 — Compute net profit:**

```
netProfit = currentValue + totalUnstaked - totalStaked
          = 605 + 550 - 1000
          = 155 RNBW
```

**Step 4 — APY:**

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

> **Note:** Most users have 2-10 events, so per-wallet queries are trivially fast even at 500 tx/day.

---

## Security Features

- **Dead shares**: 1000 shares minted to `0xdead` on first deposit (prevents share inflation / first depositor attack)
- **Cashback reserve**: Tracked separately from staking pool, cannot be accidentally drained by `emergencyWithdraw`
- **Min stake floor**: `minStakeAmount` cannot be set below 1 RNBW (prevents dust griefing)
- **Inflation guard**: `ZeroSharesMinted` revert protects depositors from rounding attacks
- **Residual sweep**: When only dead shares remain, orphaned exit fees are swept to safe and pool is reset
- **Exit fee rounding**: Ceiling division (`Math.mulDiv` with `Rounding.Ceil`) ensures fractional wei always favors the protocol
- **Dust unstake guard**: `ZeroUnstakeAmount` revert prevents ceil-rounded exit fee from consuming 100% of a dust unstake
- **2-step safe transfer**: `proposeSafe()` + `acceptSafe()` prevents admin transfer to wrong address (same pattern as OpenZeppelin `Ownable2Step`)
- **Partial unstake toggle**: `allowPartialUnstake` (default: disabled) prevents users from partially withdrawing via contract calls when the product only supports full unstake
- **Preview dust guard**: `previewStake()` returns 0 instead of reverting for dust amounts, preventing unexpected UI errors
- **Batch size limit**: `batchAllocateCashbackWithSignature` capped at 50 entries with upfront reserve solvency check
- **Rich error context**: User-facing errors include address and value params for debugging (see table below)

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

Dead shares prevent the [share inflation / first depositor attack](https://docs.openzeppelin.com/contracts/5.x/erc4626#inflation-attack) (same pattern as UniswapV2 and OpenZeppelin ERC4626). The key design decision is that dead shares **do not accumulate** — they are always exactly 0 or 1000.

**Why dead shares exist:**

In a shares-based pool, an attacker can front-run the first depositor by staking 1 wei, then donating a large amount directly to the pool. This inflates the exchange rate so that the victim's deposit rounds down to 0 shares, effectively stealing their tokens. Minting 1000 shares to a burn address (`0xdead`) on the first stake makes this attack economically impractical — the attacker would need to donate ~1000x more to achieve the same rounding effect.

**Lifecycle (3 phases):**

```
Phase 1: Empty pool (totalShares == 0)
  → First stake triggers: shares[0xdead] += 1000, totalShares += 1000
  → User gets: amount - 1000 shares
  → Dead shares: 1000

Phase 2: Active pool (multiple stakers)
  → All subsequent stakes use: sharesToMint = (amount * totalShares) / totalPooledRnbw
  → No dead shares minted (totalShares > 0, hits else branch)
  → Dead shares: still 1000 (unchanged)

Phase 3: Last user unstakes (totalShares == MINIMUM_SHARES)
  → Residual sweep: totalPooledRnbw → safe, shares[0xdead] = 0, totalShares = 0
  → Dead shares: 0 (reset to clean slate)
  → Next staker re-enters Phase 1
```

**Invariant:** `totalShares == 0 ⟹ totalPooledRnbw == 0`. The residual sweep enforces this — without it, orphaned exit-fee RNBW would remain in the pool after all user shares are burned, creating an accounting desync where the next staker gets 1:1 share minting but the pool already holds leftover tokens.

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

## Security

security@rainbow.me
