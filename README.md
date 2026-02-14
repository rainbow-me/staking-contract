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
| Unstaking | `unstake()` -- user calls directly or via relay |
| Exit fee | Configurable 1%--75%, default 15% -- stays in pool |
| Cashback | Backend allocates via `allocateCashbackWithSignature()` -- mints shares immediately in one step |
| Dead shares | First deposit mints 1000 shares to `0xdead` (UniswapV2-style inflation protection) |
| Cashback reserve | Pre-funded via `depositCashbackRewards()`, tracked separately, protected from emergency withdrawal |
| Access control | Safe (multisig) for admin ops, up to 3 trusted EIP-712 signers |
| Signatures | EIP-712 with expiry + nonce replay protection (cashback only) |

## Function Reference

### User Functions (UI direct or via relay)

| Function | Caller | Description |
|----------|--------|-------------|
| `stake(amount)` | User (direct or relay) | Stake RNBW to receive shares. `msg.sender` is always the user. |
| `unstake(sharesToBurn)` | User (direct or relay) | Burn shares to receive RNBW minus exit fee. `msg.sender` is always the user. |

Both functions use `msg.sender`, so they work with any relay service that preserves the user's address as the caller: Gelato Turbo Relayer, Relay.link, EIP-7702 delegated EOAs.

### Backend Functions (signature-gated)

| Function | Caller | Description |
|----------|--------|-------------|
| `allocateCashbackWithSignature(user, rnbwCashback, nonce, expiry, sig)` | Anyone (signature validated) | Mint shares from pre-funded cashback reserve. Requires EIP-712 signature from a trusted signer. |

Any `msg.sender` can submit this transaction (relayer, bot, user). The contract validates the signature, not the caller.

### Admin Functions (Safe multisig only)

| Function | Description |
|----------|-------------|
| `depositCashbackRewards(amount)` | Pre-fund the cashback reserve with RNBW |
| `setExitFeeBps(newExitFeeBps)` | Update exit fee (1%--75%) |
| `setMinStakeAmount(newMinStakeAmount)` | Update minimum first-time stake (1 RNBW -- 1M RNBW) |
| `setSafe(newSafe)` | Transfer admin to a new Safe address |
| `addTrustedSigner(signer)` | Add an EIP-712 signer (max 3) |
| `removeTrustedSigner(signer)` | Remove an EIP-712 signer (cannot remove last) |
| `pause()` / `unpause()` | Pause/unpause stake, unstake, and cashback |
| `emergencyWithdraw(token, amount)` | Withdraw non-staked tokens. For RNBW, only excess above `totalPooledRnbw + cashbackReserve` |

### View Functions (anyone)

| Function | Returns |
|----------|---------|
| `getPosition(user)` | `(stakedAmount, userShares, lastUpdateTime, stakingStartTime)` |
| `getRnbwForShares(sharesAmount)` | RNBW value at current exchange rate |
| `getSharesForRnbw(rnbwAmount)` | Share equivalent at current exchange rate |
| `getExchangeRate()` | Current exchange rate scaled by 1e18 |
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

**Steps:**

1. **Validate** -- amount must be > 0. First-time stakers must meet `minStakeAmount` (default 1 RNBW, floor 1 RNBW, max 1M RNBW).
2. **Transfer tokens** -- RNBW moves from user's wallet to the contract via `safeTransferFrom`.
3. **Calculate shares** -- `sharesToMint = (amount * totalShares) / totalPooledRnbw`. If pool is empty (first staker): `sharesToMint = amount - MINIMUM_SHARES`, and 1000 dead shares are minted to `0xdead`.
4. **Inflation guard** -- If `sharesToMint` rounds to 0 (manipulated exchange rate), the transaction reverts with `ZeroSharesMinted`.
5. **Mint shares** -- Update `shares[user]`, `totalShares`, `totalPooledRnbw`.
6. **Update metadata** -- Set `stakingStartTime` (first stake only), update `lastUpdateTime`.

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

**Entry point:** `unstake(sharesToBurn)` -- user calls directly or via relay service. `msg.sender` is always the user.

**Important:** The parameter is **shares to burn**, not RNBW amount. The UI should convert a desired RNBW amount to shares: `sharesToBurn = getSharesForRnbw(desiredAmount)`. For full unstake, use `shares[user]`.

**Steps:**

1. **Validate** -- shares > 0, user has enough shares.
2. **Calculate RNBW value** -- `rnbwValue = (sharesToBurn * totalPooledRnbw) / totalShares`.
3. **Calculate exit fee** -- `exitFee = rnbwValue * exitFeeBps / 10,000`. Default: 15%.
4. **Calculate net amount** -- `netAmount = rnbwValue - exitFee`.
5. **Burn shares** -- Deduct from `shares[user]` and `totalShares`. Deduct only `netAmount` from `totalPooledRnbw`. The exit fee stays in the pool.
6. **Residual sweep** -- If only dead shares remain (`totalShares == MINIMUM_SHARES`), sweep remaining `totalPooledRnbw` to `safe`, reset dead shares and `totalShares` to 0 (clean slate for next cycle).
7. **Update metadata** -- Reset `stakingStartTime` to 0 if fully unstaked.
8. **Transfer** -- Send `netAmount` RNBW to user. Sweep residual to safe if applicable.

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

**Prerequisites:** Contract must be pre-funded via `depositCashbackRewards(amount)` (admin). This adds RNBW to the `cashbackReserve`, which is tracked separately from the staking pool and protected from `emergencyWithdraw`.

Cashback mints shares **immediately in one step** -- no pending balance, no separate compound transaction.

**Steps:**

1. **Validate signature** -- EIP-712 with `AllocateCashback` typehash, expiry check, nonce replay protection.
2. **Check position** -- User must have `shares > 0` (active staker).
3. **Check reserve** -- `rnbwCashback` must not exceed `cashbackReserve`.
4. **Calculate shares** -- `sharesToMint = (rnbwCashback * totalShares) / totalPooledRnbw`.
5. **Dust guard** -- If `sharesToMint` rounds to 0, reverts with `ZeroSharesMinted`. Backend should batch small amounts or retry later.
6. **Mint shares** -- Update `shares[user]`, `totalShares`, `totalPooledRnbw`. Deduct from `cashbackReserve`.

No token transfer happens -- the RNBW is already in the contract from `depositCashbackRewards()`. The function moves it from `cashbackReserve` into `totalPooledRnbw` by minting shares.

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

## Security Features

- **Dead shares**: 1000 shares minted to `0xdead` on first deposit (prevents share inflation / first depositor attack)
- **Cashback reserve**: Tracked separately from staking pool, cannot be accidentally drained by `emergencyWithdraw`
- **Min stake floor**: `minStakeAmount` cannot be set below 1 RNBW (prevents dust griefing)
- **Inflation guard**: `ZeroSharesMinted` revert protects depositors from rounding attacks
- **Residual sweep**: When only dead shares remain, orphaned exit fees are swept to safe and pool is reset

## Build

```shell
forge build
```

## Test

```shell
forge test
```

60 tests across two suites: unit tests (`RNBWStaking.t.sol`) and simulation tests (`RNBWStakingSimulation.t.sol`).

```shell
forge test -vvv                                          # verbose output
forge test --match-contract RNBWStakingSimulation -vvv   # simulation only
```

## Format

```shell
forge fmt
```

## Contracts

| File | Description |
|------|-------------|
| `src/RNBWStaking.sol` | Main staking contract |
| `src/interfaces/IRNBWStaking.sol` | Interface with events, errors, and function signatures |

## EIP-7702 Compatibility

The contract is compatible with EIP-7702 (account abstraction via code delegation). `stake()` and `unstake()` use `msg.sender`, so a 7702-delegated EOA can call them directly through its delegated code. These functions also work with Gelato Turbo Relayer and Relay.link, which use smart account patterns where `msg.sender` is the user's address. `allocateCashbackWithSignature()` works with any `msg.sender` since it validates the trusted backend signer, not the caller.

## Security

security@rainbow.me
