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
| Access control | Safe (multisig) for admin ops, up to 3 trusted EIP-712 signers |
| Signatures | EIP-712 with expiry + nonce replay protection (cashback only) |

## How It Works

### Core Concept: Shares and Exchange Rate

When you stake RNBW you receive **shares**, not a 1:1 token balance. The exchange rate between shares and RNBW changes over time as exit fees accumulate in the pool.

```
Exchange Rate = totalPooledRnbw / totalShares
Your RNBW Value = yourShares * totalPooledRnbw / totalShares
```

The first staker gets shares at a 1:1 ratio. Every subsequent staker gets shares at the current exchange rate.

---

### Staking Flow

**Entry point:** `stake(amount)` -- user calls directly or via relay service (Gelato Turbo, Relay.link, EIP-7702). `msg.sender` is always the user.

**Steps:**

1. **Validate** -- amount must be > 0. First-time stakers must meet `minStakeAmount` (default 1 RNBW).
2. **Transfer tokens** -- RNBW moves from user's wallet to the contract via `safeTransferFrom`.
3. **Calculate shares** -- `sharesToMint = (amount * totalShares) / totalPooledRnbw`. If pool is empty: `sharesToMint = amount` (1:1).
4. **Inflation guard** -- If `sharesToMint` rounds to 0 (manipulated exchange rate), the transaction reverts with `ZeroSharesMinted`.
5. **Mint shares** -- Update `shares[user]`, `totalShares`, `totalPooledRnbw`.
6. **Update metadata** -- Set `stakingStartTime` (first stake only), update `lastUpdateTime`.

**Example: Two users stake into an empty pool**

```
--- Alice stakes 50,000 RNBW (first staker) ---
Pool before: totalPooledRnbw = 0, totalShares = 0
sharesToMint = 50,000 (1:1 ratio, empty pool)
Pool after:  totalPooledRnbw = 50,000, totalShares = 50,000
Alice: 50,000 shares = 50,000 RNBW

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
6. **Residual sweep** -- If `totalShares == 0` after burn, any remaining `totalPooledRnbw` (orphaned exit fee dust) is swept to `safe` and `totalPooledRnbw` is reset to 0.
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
Pool state: totalPooledRnbw = 57,500, totalShares = 50,000
Alice: 50,000 shares (the only staker)

--- Alice unstakes 50,000 shares ---
rnbwValue = (50,000 * 57,500) / 50,000 = 57,500 RNBW
exitFee   = 57,500 * 1500 / 10,000     = 8,625 RNBW
netAmount = 57,500 - 8,625             = 48,875 RNBW

After burn: totalShares = 0, totalPooledRnbw = 57,500 - 48,875 = 8,625
Residual sweep triggers: 8,625 RNBW sent to safe, totalPooledRnbw reset to 0

Alice receives: 48,875 RNBW
Safe receives:  8,625 RNBW (orphaned exit fee)
Pool after:     totalPooledRnbw = 0, totalShares = 0 (clean slate)
```

---

### Cashback Flow

**Entry point:** `allocateCashbackWithSignature(user, rnbwCashback, nonce, expiry, sig)` -- backend only.

**Prerequisites:** Contract must be pre-funded via `depositCashbackRewards(amount)` (admin).

Cashback mints shares **immediately in one step** -- no pending balance, no separate compound transaction.

**Steps:**

1. **Validate signature** -- EIP-712 with `AllocateCashback` typehash.
2. **Check position** -- User must have `shares > 0` (active staker).
3. **Check solvency** -- Contract RNBW balance must cover `totalPooledRnbw + rnbwCashback`.
4. **Calculate shares** -- `sharesToMint = (rnbwCashback * totalShares) / totalPooledRnbw`.
5. **Dust guard** -- If `sharesToMint` rounds to 0, reverts with `ZeroSharesMinted`. Backend should batch small amounts or retry later.
6. **Mint shares** -- Update `shares[user]`, `totalShares`, `totalPooledRnbw`.

No token transfer happens -- the RNBW is already in the contract from `depositCashbackRewards()`. The function just moves it from the excess balance into the staking pool by minting shares.

**Example: Cashback after two swaps**

```
Pool state: totalPooledRnbw = 100,000, totalShares = 100,000
Alice: 50,000 shares

--- Backend allocates 500 RNBW cashback to Alice (after a swap) ---
sharesToMint = (500 * 100,000) / 100,000 = 500
Pool after: totalPooledRnbw = 100,500, totalShares = 100,500
Alice: 50,500 shares = 50,500 RNBW

--- Backend allocates 1,250 RNBW cashback to Alice (after another swap) ---
sharesToMint = (1,250 * 100,500) / 100,500 = 1,250
Pool after: totalPooledRnbw = 101,750, totalShares = 101,750
Alice: 51,750 shares = 51,750 RNBW

--- Alice stakes another 1,000 RNBW ---
sharesToMint = (1,000 * 101,750) / 101,750 = 1,000
Pool after: totalPooledRnbw = 102,750, totalShares = 102,750
Alice: 52,750 shares = 52,750 RNBW
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

## Build

```shell
forge build
```

## Test

```shell
forge test
```

58 tests across two suites: unit tests (`RNBWStaking.t.sol`) and simulation tests (`RNBWStakingSimulation.t.sol`).

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
