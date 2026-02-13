# Technical Design Document: RNBW Staking Service

**Version:** 1.1  
**Date:** 2026-02-12  
**Author:** Engineering Team  
**Status:** Updated to match implemented contract

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Goals and Non-Goals](#2-goals-and-non-goals)
3. [System Architecture](#3-system-architecture)
4. [Smart Contracts](#4-smart-contracts)
5. [Database Schema](#5-database-schema)
6. [Domain Models](#6-domain-models)
7. [API Endpoints](#7-api-endpoints)
8. [Temporal Workflows](#8-temporal-workflows)
9. [Fee Tier System](#9-fee-tier-system)
10. [Security Considerations](#10-security-considerations)
11. [Migration Strategy](#11-migration-strategy)
12. [Monitoring and Observability](#12-monitoring-and-observability)

---

## 1. Executive Summary

### 1.1 Problem Statement

Rainbow needs to add utility to the $RNBW token and increase "share of wallet" (currently ~20%). Trading volume is leaking to other platforms, and we need mechanisms to:
- Create buy pressure on the token
- Increase user retention and engagement
- Capture more trading volume within Rainbow

### 1.2 Proposed Solution

Implement a tiered staking system where users:
1. Stake $RNBW to unlock fee cashback tiers (10% - 100%)
2. Receive cashback in staked $RNBW (auto-compounding)
3. Pay an exit fee (15%) when unstaking, distributed to other stakers

### 1.3 Key Benefits

- **Token Utility**: Staking provides direct utility for $RNBW
- **Lock-in Effect**: Rewards deposited as staked RNBW create loss aversion
- **Buy Pressure**: Users need to purchase RNBW to stake
- **Yield Generation**: Exit fees create sustainable yield for stakers

---

## 2. Goals and Non-Goals

### 2.1 Goals

- Implement on-chain staking contract for $RNBW
- Create tiered fee discount system based on stake amount
- Auto-compound cashback rewards as staked RNBW
- Implement exit fee mechanism with distribution to stakers
- Track staking positions and fee tiers per wallet
- Integrate with existing swap, bridge, and Polymarket fee systems

### 2.2 Non-Goals (Phase 1)

- Account-based staking (Phase 1 is per-wallet only)
- Perps fee discounts
- APY display (nice-to-have, can be cut)
- Solana support
- Sponsored transactions for staked users
- LST (Liquid Staking Token) - may be introduced by third party if staking is popular
- Subsidized onramp fees for stakers
- Increased card cashback for stakers
- Increased yield on cash balance for stakers
- L30D swap volume-based tier qualification (future enhancement)

### 2.3 Success Metrics

- Increase in share of wallet from 20% to target TBD
- Total Value Locked (TVL) in staking contract
- Number of unique stakers
- Retention rate of staked users

---

## 3. System Architecture

### 3.1 High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Rainbow Mobile App                              │
└─────────────────────────────────────────────────────────────────────────────┘
                                       │
                                       ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              API Gateway                                     │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │
│  │ GET /stake  │  │ POST /stake │  │POST /unstake│  │ GET /stake/balance  │ │
│  │   /tiers    │  │             │  │             │  │                     │ │
│  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
                                       │
                                       ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Staking Service (Go)                               │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────────────┐  │
│  │  StakingUseCase │  │  TierUseCase    │  │  CashbackUseCase            │  │
│  │  - Stake        │  │  - GetTier      │  │  - CalculateCashback        │  │
│  │  - Unstake      │  │  - GetDiscount  │  │  - DistributeCashback       │  │
│  │  - GetBalance   │  │                 │  │  - CompoundRewards          │  │
│  └─────────────────┘  └─────────────────┘  └─────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
                                       │
                    ┌──────────────────┼──────────────────┐
                    ▼                  ▼                  ▼
┌─────────────────────────┐ ┌─────────────────┐ ┌─────────────────────────────┐
│      PostgreSQL         │ │    Temporal     │ │       Base Chain            │
│  ┌───────────────────┐  │ │  ┌───────────┐  │ │  ┌─────────────────────┐    │
│  │ staking_positions │  │ │  │  Stake    │  │ │  │ RNBWStaking.sol     │    │
│  │ staking_events    │  │ │  │  Workflow │  │ │  │ - stake()           │    │
│  │ cashback_ledger   │  │ │  ├───────────┤  │ │  │ - unstake()         │    │
│  │ exit_fee_pool     │  │ │  │  Unstake  │  │ │  │ - claimCashback()   │    │
│  │ fee_tier_cache    │  │ │  │  Workflow │  │ │  │ - distributeExitFee │    │
│  └───────────────────┘  │ │  ├───────────┤  │ │  └─────────────────────┘    │
└─────────────────────────┘ │  │ Cashback  │  │ │                             │
                            │  │  Workflow │  │ │  ┌─────────────────────┐    │
                            │  └───────────┘  │ │  │ $RNBW ERC20         │    │
                            └─────────────────┘ │  └─────────────────────┘    │
                                                └─────────────────────────────┘
```

### 3.2 Component Overview

| Component | Responsibility |
|-----------|---------------|
| **Staking Service** | Core business logic: StakingUseCase, TierUseCase, CashbackUseCase |
| **StakingUseCase** | Stake, unstake, get balance |
| **TierUseCase** | Fee tier calculation and caching |
| **CashbackUseCase** | Cashback calculation and distribution |
| **Staking Contract** | On-chain staking, unstaking, exit fees (RNBWStaking.sol) |
| **Temporal Workflows** | Async processing: StakeWorkflow, UnstakeWorkflow, CashbackWorkflow |
| **PostgreSQL** | Staking state, ledger, audit trail |

### 3.3 Integration Points

```
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│   Swap Service   │────▶│  Staking Service │◀────│  Bridge Service  │
└──────────────────┘     └──────────────────┘     └──────────────────┘
                                  ▲
                                  │
                         ┌────────┴────────┐
                         │Polymarket Service│
                         └─────────────────┘
```

**Fee Discount Flow:**
1. Swap/Bridge/Polymarket service queries staking service for wallet's tier
2. Staking service returns discount percentage
3. Caller applies discount to fee calculation
4. After transaction, caller notifies staking service of fee paid
5. Staking service calculates and queues cashback

### 3.4 End-to-End Flows

#### 3.4.1 Staking Flow (Frontend Direct)

```
STEP 1: User Initiates Stake
├─ User enters amount to stake in Rainbow App
├─ App calls POST /api/stake/prepare to check approval status
├─ If not approved: User signs ERC20 approve() for staking contract
└─ User signs stake() transaction directly from wallet

---

STEP 2: On-Chain Execution
├─ Contract: RNBWStaking.sol
├─ Function: stake(uint256 amount)
│
├─ 2.1: Validation
│   ├─ Validates amount > 0
│   └─ Checks MIN_STAKE_AMOUNT for first-time stakers
│
├─ 2.2: Auto-Compound
│   └─ _compoundCashback() moves any pending cashback → stakedAmount
│
├─ 2.3: Token Transfer
│   └─ rnbwToken.safeTransferFrom(user, contract, amount)
│
├─ 2.4: Update Position
│   ├─ positions[user].stakedAmount += amount
│   ├─ positions[user].stakingStartTime = block.timestamp (if first stake)
│   └─ totalStaked += amount
│
└─ 2.5: Emit Event
    └─ Staked(user, amount, newTotal, viaRelayer=false)

---

STEP 3: Backend Indexes Event
├─ Service: StakingEventIndexer
├─ Listens for Staked event on-chain
│
├─ 3.1: Record Event
│   └─ INSERT INTO staking_events (event_type='stake', ...)
│
├─ 3.2: Update Position
│   └─ UPDATE staking_positions SET staked_amount = X WHERE wallet = '0xuser'
│
└─ 3.3: Recalculate Tier
    ├─ Query fee_tier_config for tier based on staked_amount
    └─ UPDATE fee_tier_cache SET tier_level = X, cashback_bps = Y

---

STEP 4: User Views Updated Position
└─ GET /api/stake/balance/{wallet}
    └─ Response: { stakedAmount: "25000...", tier: 2, cashbackBps: 5000 }
    
✅ USER SEES: "Staked: 25,000 RNBW | Tier: Gold | Cashback: 50%"
```

#### 3.4.2 Unstaking Flow (Backend Relayer or Direct)

```
STEP 1: User Initiates Unstake
├─ User enters amount to unstake in Rainbow App
├─ App shows exit fee warning: "You will lose 15% as exit fee"
├─ User confirms unstake request
└─ App calls POST /api/unstake
    └─ Body: { wallet_address: "0xuser", amount: "10000000000000000000000" }

---

STEP 2: Backend Validates & Starts Workflow
├─ Handler: UnstakeHandler
├─ Endpoint: POST /api/unstake
│
├─ 2.1: Validation
│   ├─ Validates amount > 0
│   └─ Checks user has sufficient stake
│
├─ 2.2: Generate Nonce & Expiry
│   ├─ nonce = crypto.randomUUID() → big int
│   └─ expiry = now + 60 seconds
│
└─ 2.3: Start Temporal Workflow
    └─ temporal.StartWorkflow(UnstakeWorkflow, { user, amount, nonce, expiry })

---

STEP 3: Temporal Workflow Executes
├─ Workflow: UnstakeWorkflow
│
├─ Activity 1: CreateUnstakeSignature
│   ├─ Build EIP-712 typed data:
│   │   {
│   │     domain: { name: "RNBWStaking", version: "1", chainId: 8453 },
│   │     types: { Unstake: [user, amount, nonce, expiry] },
│   │     message: { user: "0xuser", amount: "10000...", nonce: "...", expiry: "..." }
│   │   }
│   ├─ Sign with authorized signer private key
│   └─ Store in unstake_signatures table (status='active')
│
├─ Activity 2: PublishUnstakeTransaction
│   ├─ Call RNBWStaking.unstakeWithSignature() via Gelato relayer
│   └─ Params: (user, amount, nonce, expiry, signature)
│
└─ Activity 3: WaitForTransactionCompletion
    ├─ Poll Gelato for tx status
    └─ On timeout: check on-chain if usedNonces[user][nonce] == true

---

STEP 4: On-Chain Execution
├─ Contract: RNBWStaking.sol
├─ Function: unstakeWithSignature(user, amount, nonce, expiry, sig)
│
├─ 4.1: Verify Signature (if via relayer)
│   ├─ Verify block.timestamp <= expiry
│   ├─ Verify usedNonces[user][nonce] == false
│   ├─ Recover signer from EIP-712 signature
│   ├─ Verify _trustedSigners[signer] == true
│   └─ Mark usedNonces[user][nonce] = true
│   (If direct unstake(): msg.sender is the user, no signature needed)
│
├─ 4.2: Auto-Compound
│   └─ _compoundCashback(user) — converts pending cashback → shares
│
├─ 4.3: Calculate Exit Fee
│   ├─ rnbwValue = (sharesToBurn * totalPooledRnbw) / totalShares
│   ├─ exitFee = rnbwValue * exitFeeBps / 10000
│   └─ netAmount = rnbwValue - exitFee
│
├─ 4.4: Update State (shares-based)
│   ├─ shares[user] -= sharesToBurn
│   ├─ totalShares -= sharesToBurn
│   ├─ totalPooledRnbw -= netAmount  (exit fee stays in pool!)
│   └─ If totalShares == 0: sweep residual to safe, reset totalPooledRnbw = 0
│
├─ 4.5: Transfer
│   └─ rnbwToken.safeTransfer(user, netAmount)
│
└─ 4.6: Emit Events
    ├─ Unstaked(user, sharesToBurn, rnbwValue, exitFee, netAmount)
    └─ ExchangeRateUpdated(totalPooledRnbw, totalShares)

---

STEP 5: Backend Confirms & Indexes
├─ StakingEventIndexer:
│   ├─ Index Unstaked event
│   ├─ INSERT INTO staking_events (event_type='unstake', ...)
│   ├─ UPDATE staking_positions SET staked_amount = X
│   └─ Recalculate tier, UPDATE fee_tier_cache
│
└─ UnstakeWorkflow (Activity 4: ConfirmUnstake):
    ├─ UPDATE unstake_signatures SET status='used'
    └─ Mark unstake record status='confirmed'

✅ USER RECEIVES: 8,500 RNBW (after 15% exit fee)
```

#### 3.4.3 Cashback Flow (After Swap/Bridge/Polymarket)

```
STEP 1: Backend Receives Swap Transaction Event
├─ 1.1: Transaction Event Received
│   └─ Backend receives swap transaction event (from indexer/webhook)
│
├─ 1.2: Wait for Confirmation
│   └─ Backend waits for tx confirmation on-chain
│
├─ 1.3: Derive Fee from Swap API
│   ├─ Once confirmed, call Swap API to get transaction details
│   └─ Extract feeUSD from swap response
│
├─ 1.4: Lookup User Tier
│   ├─ Call StakingUseCase.GetTierInfo(walletAddress)
│   ├─ Get tier and cashback percentage (e.g., Tier 2 = 50%)
│   └─ Note: Fee discount is via cashback, not reduced fee
│
└─ 1.5: Record Fee & Trigger Cashback
    └─ Call StakingUseCase.RecordFeeAndCashback(wallet, feeUSD, tier)

---

STEP 2: Backend Calculates Cashback
├─ Function: StakingUseCase.RecordFeeAndCashback()
│
├─ 2.1: Lookup Tier
│   └─ Query fee_tier_cache → tier=2, cashback_bps=5000 (50%)
│
├─ 2.2: Calculate RNBW Cashback
│   ├─ feesPaidUSD = $10.00
│   ├─ cashbackUSD = $10.00 * 50% = $5.00
│   ├─ rnbwPrice = $0.01 (from price feed)
│   └─ rnbwCashback = $5.00 / $0.01 = 500 RNBW
│
├─ 2.3: Record in DB
│   └─ INSERT INTO cashback_ledger (status='pending', rnbw_amount=500...)
│
└─ 2.4: Queue Workflow
    └─ temporal.StartWorkflow(CashbackWorkflow, { user, feesPaidUSD, rnbwCashback })

---

STEP 3: Temporal Workflow Allocates Cashback
├─ Workflow: CashbackWorkflow
│
├─ Activity 1: AllocateCashbackOnChain
│   ├─ Generate nonce & expiry
│   ├─ Sign EIP-712 AllocateCashback message with trusted signer key
│   ├─ Call RNBWStaking.allocateCashbackWithSignature(user, rnbwCashback, nonce, expiry, sig)
│   └─ Contract must be pre-funded via depositCashbackRewards()
│
└─ Activity 2: ConfirmCashbackAllocation
    └─ UPDATE cashback_ledger SET status='allocated'

---

STEP 4: On-Chain Allocation
├─ Contract: RNBWStaking.sol
├─ Function: allocateCashbackWithSignature(user, rnbwCashback, nonce, expiry, sig)
│
├─ 4.1: Validate Signature
│   ├─ Verify block.timestamp <= expiry
│   ├─ Verify usedNonces[user][nonce] == false
│   ├─ Recover signer, verify _trustedSigners[signer] == true
│   └─ Mark usedNonces[user][nonce] = true
│
├─ 4.2: Validation
│   ├─ Verify shares[user] > 0 (must have active stake)
│   └─ Verify contract RNBW balance >= totalPooledRnbw + totalAllocatedCashback + rnbwCashback
│
├─ 4.3: Update State
│   ├─ totalAllocatedCashback += rnbwCashback
│   ├─ userMeta[user].cashbackAllocated += rnbwCashback
│   └─ userMeta[user].lastUpdateTime = block.timestamp
│
└─ 4.4: Emit Event
    └─ CashbackAllocated(user, rnbwCashback)

📊 Note: Cashback is NOT yet in stakedAmount - just accrued

---

STEP 5: Compounding (Automatic or Manual)
│
├─ Option A: Auto-compound on next stake/unstake
│   ├─ When user calls stake() or unstakeWithSignature()
│   ├─ _compoundCashback() is called internally
│   └─ Moves cashbackAccrued → stakedAmount
│
└─ Option B: Manual compound via backend
    ├─ Backend calls compoundWithSignature(user, nonce, expiry, sig)
    ├─ Requires EIP-712 signature from authorized signer
    └─ Useful for batch compounding or scheduled compounding

Contract: _compoundCashback(user)
├─ cashback = userMeta[user].cashbackAllocated
├─ userMeta[user].cashbackAllocated = 0
├─ totalAllocatedCashback -= cashback
├─ sharesToMint = (cashback * totalShares) / totalPooledRnbw
├─ If sharesToMint == 0: restore cashback (dust protection), return 0
├─ shares[user] += sharesToMint
├─ totalShares += sharesToMint
├─ totalPooledRnbw += cashback
└─ Emit CashbackCompounded(user, cashback, sharesToMint)

---

📊 Cashback Lifecycle:
Swap Fee Paid → Pending (DB) → Allocated (On-chain) → Compounded (Shares)
    $10 fee      500 RNBW      cashbackAllocated     shares minted at
                 queued        += 500 RNBW            current exchange rate
```

#### 3.4.4 Exit Fee Distribution Flow

**Where does exitFeePool come from?**

```
HOW EXIT FEE POOL ACCUMULATES:

User A stakes 10,000 RNBW
├─ RNBW.transferFrom(userA, contract, 10000)
├─ Contract now HOLDS 10,000 RNBW
└─ positions[userA].stakedAmount = 10,000

User A unstakes 10,000 RNBW
├─ Exit fee = 15% = 1,500 RNBW
├─ Net to user = 8,500 RNBW
│
├─ Contract sends OUT only 8,500 RNBW to user
│   └─ RNBW.transfer(userA, 8500)
│
├─ 1,500 RNBW remains IN the contract (never leaves)
│
└─ Accounting update:
    ├─ positions[userA].stakedAmount = 0
    ├─ totalStaked -= 10,000
    └─ exitFeePool += 1,500  ← tracks available yield for other stakers

📊 Key insight: exitFeePool is an ACCOUNTING variable.
   The actual RNBW is already in the contract from original stakes.
   It just tracks "how much is available to distribute."
```

---

**Two Options for Distribution:**

---

**OPTION A: Batch Distribution (Backend Job)**

*Pros:* Lower gas per unstake, simpler contract
*Cons:* Delayed yield, requires scheduled job

```
STEP 1: Exit Fee Accumulates (On Unstake)
├─ User unstakes → contract keeps 15%
├─ exitFeePool += exitFee
└─ No immediate distribution (accumulates)

---

STEP 2: Scheduled Job Calculates Shares (Daily/Weekly)
├─ Job: ExitFeeDistributionJob
│
├─ 2.1: Read Exit Fee Pool
│   └─ Call RNBWStaking.exitFeePool() → 10,000 RNBW
│
├─ 2.2: Query Active Stakers
│   └─ SELECT wallet_address, staked_amount FROM staking_positions WHERE staked_amount > 0
│
├─ 2.3: Calculate Pro-Rata Shares
│   ├─ totalStaked = 1,000,000 RNBW
│   ├─ For each staker:
│   │   └─ userShare = (userStakedAmount / totalStaked) * exitFeePool
│   └─ Example: User with 100,000 RNBW (10%) gets 1,000 RNBW
│
└─ 2.4: Start Distribution Workflow
    └─ temporal.StartWorkflow(ExitFeeDistributionWorkflow, { recipients[], shares[] })

---

STEP 3: Temporal Workflow Distributes
├─ Workflow: ExitFeeDistributionWorkflow
│
├─ Activity 1: DistributeExitFeesOnChain
│   ├─ Call RNBWStaking.distributeExitFees(recipients[], shares[])
│   ├─ Uses OPERATOR_ROLE
│   └─ Batches in groups of 500 max (gas limit)
│
└─ Activity 2: RecordDistribution
    └─ INSERT INTO exit_fee_distributions (...)

---

STEP 4: On-Chain Distribution
├─ Contract: RNBWStaking.sol
├─ Function: distributeExitFees(recipients[], shares[])
│
├─ For each recipient:
│   └─ positions[recipient].stakedAmount += share
│
├─ exitFeePool -= totalDistributed
└─ Emit ExitFeeDistributed(totalDistributed, recipientCount)

✅ STAKERS RECEIVE: Exit fees added directly to stakedAmount
```

---

**OPTION B: Immediate Distribution (On-Chain at Unstake Time)**

*Pros:* Real-time yield, no backend job needed
*Cons:* Higher gas per unstake (O(n) stakers), may hit gas limit

```
STEP 1: User Unstakes → Immediate Distribution
├─ Contract: RNBWStaking.sol
├─ Function: _unstake(user, amount)
│
├─ 1.1: Calculate Exit Fee
│   ├─ exitFee = amount * 15%
│   └─ netAmount = amount - exitFee
│
├─ 1.2: Distribute Exit Fee Immediately
│   ├─ For each staker (excluding unstaking user):
│   │   ├─ share = (stakerAmount / (totalStaked - amount)) * exitFee
│   │   └─ positions[staker].stakedAmount += share
│   └─ ⚠️ Gas scales with number of stakers
│
├─ 1.3: Update Unstaker Position
│   ├─ positions[user].stakedAmount -= amount
│   └─ totalStaked -= amount
│
├─ 1.4: Transfer
│   └─ RNBW.transfer(user, netAmount)
│
└─ 1.5: Emit Events
    ├─ Unstaked(user, amount, exitFee, netAmount)
    └─ ExitFeeDistributed(exitFee, stakerCount)

⚠️ WARNING: If 1000+ stakers, this may exceed block gas limit.
   Would need to limit active stakers or use different approach.

✅ STAKERS RECEIVE: Exit fees instantly on every unstake
```

---

**OPTION C: Exchange Rate / Shares Approach (Industry Standard) ✅ IMPLEMENTED**

*Pros:* No distribution needed, O(1) gas, instant yield, infinitely scalable
*Cons:* Slightly more complex math, users see "shares" not raw RNBW

This is how **Lido (stETH), Compound (cTokens), Rocket Pool (rETH), Aave (aTokens), Yearn (yVaults)** handle reward distribution.

> **This approach is implemented in the contract (Section 4.2).**

**Core Idea:** Instead of tracking "User has X RNBW", track "User has X shares" with a floating exchange rate.

```
HOW IT WORKS:

Initial State:
├─ totalPooledRNBW = 0
├─ totalShares = 0
└─ exchangeRate = 1.0 (1 share = 1 RNBW)

---

User A stakes 10,000 RNBW:
├─ sharesToMint = 10,000 / 1.0 = 10,000 shares
├─ shares[A] = 10,000
├─ totalShares = 10,000
├─ totalPooledRNBW = 10,000
└─ exchangeRate = 10,000 / 10,000 = 1.0

---

User B stakes 20,000 RNBW:
├─ sharesToMint = 20,000 / 1.0 = 20,000 shares
├─ shares[B] = 20,000
├─ totalShares = 30,000
├─ totalPooledRNBW = 30,000
└─ exchangeRate = 1.0

---

User C stakes 30,000 RNBW, then UNSTAKES (15% exit fee):
│
├─ On Stake:
│   ├─ shares[C] = 30,000
│   ├─ totalShares = 60,000
│   └─ totalPooledRNBW = 60,000
│
├─ On Unstake:
│   ├─ rnbwValue = 30,000 shares × (60,000 / 60,000) = 30,000 RNBW
│   ├─ exitFee = 30,000 × 15% = 4,500 RNBW
│   ├─ userReceives = 25,500 RNBW
│   │
│   ├─ totalShares = 60,000 - 30,000 = 30,000 (C's shares burned)
│   ├─ totalPooledRNBW = 60,000 - 25,500 = 34,500 (exitFee stays!)
│   │
│   └─ NEW exchangeRate = 34,500 / 30,000 = 1.15 🎉
│
└─ RESULT (no distribution needed):
    ├─ User A: 10,000 shares × 1.15 = 11,500 RNBW value (+1,500)
    ├─ User B: 20,000 shares × 1.15 = 23,000 RNBW value (+3,000)
    └─ Total: 34,500 RNBW ✓

📊 Exit fee automatically distributed proportionally via exchange rate increase.
   No iteration. No batch job. No gas explosion. O(1) complexity.
```

**The Math:**
```
// Stake
sharesToMint = depositAmount × totalShares / totalPooledRNBW
(if pool empty: sharesToMint = depositAmount)

// Get user's RNBW value
userRNBW = shares[user] × totalPooledRNBW / totalShares

// Unstake
rnbwToReceive = sharesToBurn × totalPooledRNBW / totalShares
exitFee = rnbwToReceive × 15%
actualPayout = rnbwToReceive - exitFee

// Update state
totalShares -= sharesToBurn
totalPooledRNBW -= actualPayout  // exitFee stays in pool!
```

**Contract Changes Required:**
```solidity
// OLD approach
mapping(address => uint256) public stakedAmount;

// NEW approach
mapping(address => uint256) public shares;
uint256 public totalShares;
uint256 public totalPooledRNBW;

function getStakedAmount(address user) public view returns (uint256) {
    if (totalShares == 0) return 0;
    return shares[user] * totalPooledRNBW / totalShares;
}
```

**Note:** This is the same math used for LST tokens, but shares can remain internal (non-transferable). If LST is desired later, simply make shares an ERC20.

---

**RECOMMENDATION:**

| Factor | Option A (Batch) | Option B (Immediate) | **Option C (Exchange Rate) ✅** |
|--------|------------------|----------------------|--------------------------------|
| Gas per unstake | Low O(1) | High O(n) | **Low O(1)** |
| Yield timing | Delayed | Instant | **Instant** |
| Backend job | Required | Not needed | **Not needed** |
| Scalability | Unlimited | Limited by gas | **Unlimited** |
| Complexity | Medium | High | **Low (proven pattern)** |
| Used by | - | - | **Lido, Compound, Aave, Yearn** |

**✅ IMPLEMENTED: Option C (Exchange Rate)** is the industry-standard approach. Used by all major DeFi protocols. No distribution logic needed. See Section 4.2 for contract implementation.

---

## 4. Smart Contracts

### 4.1 Design Principles

| Aspect | Decision |
|--------|----------|
| **Tier configuration** | Backend only (not in contract) |
| **stake()** | Two paths: Frontend (direct) OR Backend (relayer via `stakeWithSignature`) |
| **unstake()** | Two paths: Frontend (direct) OR Backend (relayer via `unstakeWithSignature`) |
| **Cashback allocation** | Backend only (via `allocateCashbackWithSignature`) |
| **Access control** | Safe (multisig) for admin, trusted signers (max 3) for signatures |
| **Signature scheme** | EIP-712 with expiry + random nonce, shared nonce namespace across all operations |
| **Token representation** | Internal shares mapping (no ERC20, not transferable) |
| **Exit fee distribution** | Exchange rate model (Option C) - automatic via shares |
| **Exit fee bounds** | Configurable: min 1% (`MIN_EXIT_FEE_BPS=100`), max 75% (`MAX_EXIT_FEE_BPS=7500`), default 15% |
| **Min stake bounds** | Configurable: max 1M RNBW (`MAX_MIN_STAKE_AMOUNT`), default 1 RNBW |
| **Residual dust** | When last staker exits, residual exit fees are swept to safe to maintain `totalShares==0 => totalPooledRnbw==0` invariant |
| **Dust cashback** | If cashback is too small to mint shares, it is preserved (not lost) for future compounding |
| **EIP-7702** | Compatible — no `msg.sender == tx.origin` or code-length checks |

### 4.2 RNBWStaking.sol (Implemented) - Exchange Rate Model (Option C)

> **Design Choice:** This contract uses the **shares-based exchange rate model** (like Lido stETH, Compound cTokens, Rocket Pool rETH). Exit fees automatically distribute to all stakers via exchange rate increase - no batch distribution needed.

> **Implementation:** See `src/RNBWStaking.sol` and `src/interfaces/IRNBWStaking.sol` for the actual contract code.

**Key differences from the original draft:**

| Aspect | Original Draft | Implemented |
|--------|---------------|-------------|
| **Access control** | OpenZeppelin `AccessControl` with roles (`OPERATOR_ROLE`, `RELAYER_ROLE`, `CASHBACK_DISTRIBUTOR_ROLE`) | Simple `safe` address (multisig) + trusted signers (max 3) |
| **unstake()** | Backend-only via `unstakeWithSignature` | Also available as direct `unstake()` from frontend |
| **Cashback accrual** | Role-based `accrueCashback()` with `feesPaidUSD` param | Signature-based `allocateCashbackWithSignature()` with pre-funded RNBW, no USD param |
| **Batch cashback** | `batchAccrueCashback()` | Removed — individual allocations only |
| **Exit fee** | Constant `EXIT_FEE_BPS = 1500` | Configurable `exitFeeBps` with bounds: min 1% (`MIN_EXIT_FEE_BPS=100`), max 75% (`MAX_EXIT_FEE_BPS=7500`) |
| **Min stake** | Constant `MIN_STAKE_AMOUNT = 1e18` | Configurable `minStakeAmount` with upper bound `MAX_MIN_STAKE_AMOUNT = 1_000_000e18` |
| **Signer management** | `setSigner(address, bool)` | `addTrustedSigner()` / `removeTrustedSigner()` with count cap (3) and cannot-remove-last guard |
| **Emergency withdraw** | Cannot withdraw staked RNBW | Can withdraw excess RNBW (above obligated `totalPooledRnbw + totalAllocatedCashback`), sends to `safe` |
| **Cashback model** | `cashbackAccrued` field, role-based accrual | `cashbackAllocated` field, signature-based allocation with contract pre-funding check |
| **Dust protection** | None | Residual dust swept to safe when `totalShares == 0`; dust cashback preserved when `sharesToMint` rounds to 0 |
| **Cashback rewards funding** | Implicit | Explicit `depositCashbackRewards()` by safe, with balance validation on allocation |
| **Staked event** | Includes `viaRelayer` bool | No `viaRelayer` flag — event is the same regardless of path |
| **Pause scope** | Not specified | All user operations paused including `allocateCashbackWithSignature` |
| **Nonce namespace** | Per-operation implied | Shared across all signature operations (stake, unstake, compound, cashback) |
| **Solidity version** | `^0.8.20` | `0.8.24` (pinned) |

**Cashback Model: Two-Step Design (Allocate → Compound)**

The contract uses a two-step cashback model where cashback is first **allocated** to `cashbackAllocated`, then **compounded** into shares on the user's next action.

**Reasons FOR this separation:**

| Benefit | Explanation |
|---------|-------------|
| **Gas efficiency via batching** | Instead of minting shares on every swap, cashback accumulates in `cashbackAllocated`. Compounding happens once on the next stake/unstake, saving gas when users do many swaps between staking actions. |
| **UI clarity** | Users can see "Pending Cashback: 500 RNBW" separate from their staked principal. This makes earnings visible and provides a sense of accumulation. |
| **Tier stability** | User's tier (based on staked amount) doesn't fluctuate with micro-amounts from frequent swaps. Tier only changes on explicit stake/unstake actions. |
| **Dust protection** | If cashback is too small to mint shares at current exchange rate, it's preserved for future compounding rather than being lost to rounding. |

**Alternative considered (direct staking):**

A simpler design would remove `cashbackAllocated` entirely and mint shares directly on each `allocateCashbackWithSignature` call. This was rejected because:
- Higher gas per swap (share minting on every cashback allocation)
- Less UI clarity (no distinction between earned vs staked)
- Potential for dust loss if amounts are too small to mint shares

**Compounding triggers:**
- **Automatic**: `_compoundCashback(user)` is called internally on `stake()` and `unstake()`
- **Manual**: Backend can call `compoundWithSignature()` for explicit compounding

**Lifecycle:**
```
Swap Fee Paid → Backend calculates → allocateCashbackWithSignature() → User stakes/unstakes → _compoundCashback() → Shares minted
                cashback amount       cashbackAllocated += X            auto-compounds              at current rate
```

**Constants (as implemented):**

```solidity
uint256 public constant BASIS_POINTS = 10_000;        // 100% in basis points
uint256 public constant MIN_EXIT_FEE_BPS = 100;       // 1% minimum exit fee
uint256 public constant MAX_EXIT_FEE_BPS = 7500;      // 75% maximum exit fee
uint256 public constant MAX_MIN_STAKE_AMOUNT = 1_000_000e18; // Upper bound for minStakeAmount
uint256 public constant MAX_SIGNERS = 3;               // Maximum number of trusted signers
```

**EIP-712 Type Hashes:**

```solidity
STAKE_TYPEHASH = keccak256("Stake(address user,uint256 amount,uint256 nonce,uint256 expiry)");
UNSTAKE_TYPEHASH = keccak256("Unstake(address user,uint256 amount,uint256 nonce,uint256 expiry)");
COMPOUND_TYPEHASH = keccak256("Compound(address user,uint256 nonce,uint256 expiry)");
ALLOCATE_CASHBACK_TYPEHASH = keccak256("AllocateCashback(address user,uint256 rnbwCashback,uint256 nonce,uint256 expiry)");
```

**The original draft code below is preserved for reference but is superseded by `src/RNBWStaking.sol`.**

<details>
<summary>Original Draft Contract (superseded)</summary>

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title RNBWStaking
 * @notice Staking contract for $RNBW with exit fees using shares-based model
 * @dev Uses exchange rate model for automatic exit fee distribution:
 *      - Users receive "shares" when staking, not 1:1 RNBW
 *      - Exit fees stay in pool, increasing exchange rate for all stakers
 *      - No batch distribution needed - O(1) gas for any number of stakers
 *      
 *      Tier configuration is managed off-chain in backend.
 *      Staked positions are NOT transferable (locked staking).
 */
contract RNBWStaking is ReentrancyGuard, Pausable, AccessControl, EIP712 {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // ============================================
    // Constants & Roles
    // ============================================
    
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");
    bytes32 public constant CASHBACK_DISTRIBUTOR_ROLE = keccak256("CASHBACK_DISTRIBUTOR_ROLE");
    
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant EXIT_FEE_BPS = 1500; // 15%
    uint256 public constant MIN_STAKE_AMOUNT = 1e18; // 1 RNBW minimum
    
    // EIP-712 type hashes
    bytes32 public constant STAKE_TYPEHASH = keccak256(
        "Stake(address user,uint256 amount,uint256 nonce,uint256 expiry)"
    );
    bytes32 public constant UNSTAKE_TYPEHASH = keccak256(
        "Unstake(address user,uint256 amount,uint256 nonce,uint256 expiry)"
    );
    bytes32 public constant COMPOUND_TYPEHASH = keccak256(
        "Compound(address user,uint256 nonce,uint256 expiry)"
    );
    
    // ============================================
    // State Variables
    // ============================================
    
    IERC20 public immutable rnbwToken;
    
    // Shares-based model (like Lido stETH)
    mapping(address => uint256) public shares;           // User's share balance
    uint256 public totalShares;                          // Sum of all shares
    uint256 public totalPooledRNBW;                      // Total RNBW in staking pool
    
    // User metadata (not used for balance calculation)
    struct UserMeta {
        uint256 cashbackAccrued;   // Pending cashback to be compounded (in RNBW)
        uint256 lastUpdateTime;    // Last time position was updated
        uint256 stakingStartTime;  // When user first staked
    }
    mapping(address => UserMeta) public userMeta;
    
    // Nonce tracking for replay protection (random nonces)
    mapping(address => mapping(uint256 => bool)) public usedNonces;
    
    // Authorized signers for backend operations
    mapping(address => bool) public authorizedSigners;
    
    // ============================================
    // Events
    // ============================================
    
    event Staked(address indexed user, uint256 rnbwAmount, uint256 sharesMinted, uint256 newShareBalance, bool viaRelayer);
    event Unstaked(address indexed user, uint256 sharesBurned, uint256 rnbwValue, uint256 exitFee, uint256 netReceived);
    event CashbackAccrued(address indexed user, uint256 rnbwAmount, uint256 feesPaidUSD);
    event CashbackCompounded(address indexed user, uint256 rnbwAmount, uint256 sharesMinted);
    event SignerUpdated(address indexed signer, bool authorized);
    event ExchangeRateUpdated(uint256 totalPooledRNBW, uint256 totalShares);
    
    // ============================================
    // Errors
    // ============================================
    
    error ZeroAmount();
    error InsufficientShares();
    error BelowMinimumStake();
    error NoStakePosition();
    error InvalidSignature();
    error SignatureExpired();
    error NonceAlreadyUsed();
    error NothingToCompound();
    error Unauthorized();
    
    // ============================================
    // Constructor
    // ============================================
    
    constructor(
        address _rnbwToken,
        address _admin,
        address _initialSigner
    ) EIP712("RNBWStaking", "1") {
        rnbwToken = IERC20(_rnbwToken);
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _admin);
        
        authorizedSigners[_initialSigner] = true;
        emit SignerUpdated(_initialSigner, true);
    }
    
    // ============================================
    // External Functions - Direct User Actions (Frontend)
    // ============================================
    
    /**
     * @notice Stake RNBW tokens directly (frontend path)
     * @dev User calls this directly from their wallet, no signature needed
     * @param amount Amount of RNBW to stake
     */
    function stake(uint256 amount) external nonReentrant whenNotPaused {
        _stake(msg.sender, amount, false);
    }
    
    // ============================================
    // External Functions - Relayed Actions (Backend)
    // ============================================
    
    /**
     * @notice Stake RNBW tokens via relayer (backend path)
     * @dev Requires EIP-712 signature from authorized signer
     */
    function stakeWithSignature(
        address user,
        uint256 amount,
        uint256 nonce,
        uint256 expiry,
        bytes calldata signature
    ) external nonReentrant whenNotPaused onlyRole(RELAYER_ROLE) {
        if (block.timestamp > expiry) revert SignatureExpired();
        if (usedNonces[user][nonce]) revert NonceAlreadyUsed();
        
        bytes32 structHash = keccak256(abi.encode(
            STAKE_TYPEHASH, user, amount, nonce, expiry
        ));
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        
        if (!authorizedSigners[signer]) revert InvalidSignature();
        
        usedNonces[user][nonce] = true;
        _stake(user, amount, true);
    }
    
    /**
     * @notice Unstake RNBW tokens via relayer (backend only)
     * @dev Requires EIP-712 signature from authorized signer
     *      Amount is in SHARES, not RNBW. Use getSharesForRNBW() to convert.
     *      Returns RNBW minus 15% exit fee
     */
    function unstakeWithSignature(
        address user,
        uint256 sharesToBurn,
        uint256 nonce,
        uint256 expiry,
        bytes calldata signature
    ) external nonReentrant whenNotPaused onlyRole(RELAYER_ROLE) {
        if (block.timestamp > expiry) revert SignatureExpired();
        if (usedNonces[user][nonce]) revert NonceAlreadyUsed();
        
        bytes32 structHash = keccak256(abi.encode(
            UNSTAKE_TYPEHASH, user, sharesToBurn, nonce, expiry
        ));
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        
        if (!authorizedSigners[signer]) revert InvalidSignature();
        
        usedNonces[user][nonce] = true;
        _unstake(user, sharesToBurn);
    }
    
    /**
     * @notice Compound cashback via relayer (backend path)
     * @dev Converts cashbackAccrued RNBW into shares at current exchange rate
     */
    function compoundWithSignature(
        address user,
        uint256 nonce,
        uint256 expiry,
        bytes calldata signature
    ) external nonReentrant onlyRole(RELAYER_ROLE) {
        if (block.timestamp > expiry) revert SignatureExpired();
        if (usedNonces[user][nonce]) revert NonceAlreadyUsed();
        
        bytes32 structHash = keccak256(abi.encode(
            COMPOUND_TYPEHASH, user, nonce, expiry
        ));
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        
        if (!authorizedSigners[signer]) revert InvalidSignature();
        
        usedNonces[user][nonce] = true;
        
        uint256 compounded = _compoundCashback(user);
        if (compounded == 0) revert NothingToCompound();
    }
    
    // ============================================
    // External Functions - Operator Actions
    // ============================================
    
    /**
     * @notice Accrue cashback for a user based on fees paid
     * @dev Called by backend after swap/bridge/polymarket transaction
     *      Cashback is stored as pending RNBW, compounded on next stake/unstake
     * @param user User address
     * @param feesPaidUSD Fees paid in USD (6 decimals) - for event logging only
     * @param rnbwCashback RNBW cashback amount (18 decimals)
     */
    function accrueCashback(
        address user,
        uint256 feesPaidUSD,
        uint256 rnbwCashback
    ) external onlyRole(CASHBACK_DISTRIBUTOR_ROLE) {
        if (shares[user] == 0) revert NoStakePosition();
        
        userMeta[user].cashbackAccrued += rnbwCashback;
        userMeta[user].lastUpdateTime = block.timestamp;
        
        emit CashbackAccrued(user, rnbwCashback, feesPaidUSD);
    }
    
    /**
     * @notice Batch accrue cashback for multiple users
     */
    function batchAccrueCashback(
        address[] calldata users,
        uint256[] calldata feesPaidUSD,
        uint256[] calldata rnbwCashbacks
    ) external onlyRole(CASHBACK_DISTRIBUTOR_ROLE) {
        require(users.length == feesPaidUSD.length && users.length == rnbwCashbacks.length, "Length mismatch");
        require(users.length <= 100, "Batch too large");
        
        for (uint256 i = 0; i < users.length; i++) {
            if (shares[users[i]] > 0) {
                userMeta[users[i]].cashbackAccrued += rnbwCashbacks[i];
                userMeta[users[i]].lastUpdateTime = block.timestamp;
                emit CashbackAccrued(users[i], rnbwCashbacks[i], feesPaidUSD[i]);
            }
        }
    }
    
    // ============================================
    // View Functions
    // ============================================
    
    /**
     * @notice Get user's staking position in RNBW terms
     * @dev Converts shares to RNBW value at current exchange rate
     */
    function getPosition(address user) external view returns (
        uint256 stakedAmount,      // RNBW value of user's shares
        uint256 userShares,        // Raw share balance
        uint256 cashbackAccrued,   // Pending cashback in RNBW
        uint256 lastUpdateTime,
        uint256 stakingStartTime
    ) {
        UserMeta memory meta = userMeta[user];
        return (
            getRNBWForShares(shares[user]),
            shares[user],
            meta.cashbackAccrued,
            meta.lastUpdateTime,
            meta.stakingStartTime
        );
    }
    
    /**
     * @notice Get RNBW value for a given share amount
     * @dev Formula: rnbw = shares * totalPooledRNBW / totalShares
     */
    function getRNBWForShares(uint256 _shares) public view returns (uint256) {
        if (totalShares == 0) return 0;
        return (_shares * totalPooledRNBW) / totalShares;
    }
    
    /**
     * @notice Get shares needed for a given RNBW amount
     * @dev Formula: shares = rnbw * totalShares / totalPooledRNBW
     */
    function getSharesForRNBW(uint256 _rnbw) public view returns (uint256) {
        if (totalPooledRNBW == 0) return _rnbw; // 1:1 for first stake
        return (_rnbw * totalShares) / totalPooledRNBW;
    }
    
    /**
     * @notice Get current exchange rate (RNBW per share, scaled by 1e18)
     * @dev Returns 1e18 when pool is empty (1:1 ratio)
     */
    function getExchangeRate() external view returns (uint256) {
        if (totalShares == 0) return 1e18;
        return (totalPooledRNBW * 1e18) / totalShares;
    }
    
    /**
     * @notice Check if a nonce has been used
     */
    function isNonceUsed(address user, uint256 nonce) external view returns (bool) {
        return usedNonces[user][nonce];
    }
    
    /**
     * @notice Get the EIP-712 domain separator
     */
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
    
    // ============================================
    // Admin Functions
    // ============================================
    
    /**
     * @notice Add or remove an authorized signer
     */
    function setSigner(address signer, bool authorized) external onlyRole(DEFAULT_ADMIN_ROLE) {
        authorizedSigners[signer] = authorized;
        emit SignerUpdated(signer, authorized);
    }
    
    function pause() external onlyRole(OPERATOR_ROLE) {
        _pause();
    }
    
    function unpause() external onlyRole(OPERATOR_ROLE) {
        _unpause();
    }
    
    /**
     * @notice Emergency withdraw stuck tokens (not staked RNBW)
     */
    function emergencyWithdraw(
        address token,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token != address(rnbwToken), "Cannot withdraw staked RNBW");
        IERC20(token).safeTransfer(msg.sender, amount);
    }
    
    // ============================================
    // Internal Functions
    // ============================================
    
    function _stake(address user, uint256 amount, bool viaRelayer) internal {
        if (amount == 0) revert ZeroAmount();
        
        // First-time staker check
        if (shares[user] == 0 && amount < MIN_STAKE_AMOUNT) {
            revert BelowMinimumStake();
        }
        
        // Auto-compound any pending cashback before updating position
        _compoundCashback(user);
        
        // Transfer tokens from user (user must have approved this contract)
        rnbwToken.safeTransferFrom(user, address(this), amount);
        
        // Calculate shares to mint at current exchange rate
        uint256 sharesToMint;
        if (totalShares == 0) {
            // First stake: 1:1 ratio
            sharesToMint = amount;
        } else {
            // Subsequent stakes: mint proportional shares
            sharesToMint = (amount * totalShares) / totalPooledRNBW;
        }
        
        // Update state
        shares[user] += sharesToMint;
        totalShares += sharesToMint;
        totalPooledRNBW += amount;
        
        // Update user metadata
        UserMeta storage meta = userMeta[user];
        if (meta.stakingStartTime == 0) {
            meta.stakingStartTime = block.timestamp;
        }
        meta.lastUpdateTime = block.timestamp;
        
        emit Staked(user, amount, sharesToMint, shares[user], viaRelayer);
        emit ExchangeRateUpdated(totalPooledRNBW, totalShares);
    }
    
    function _unstake(address user, uint256 sharesToBurn) internal {
        if (sharesToBurn == 0) revert ZeroAmount();
        if (shares[user] == 0) revert NoStakePosition();
        if (shares[user] < sharesToBurn) revert InsufficientShares();
        
        // Auto-compound any pending cashback before unstaking
        _compoundCashback(user);
        
        // Calculate RNBW value of shares at current exchange rate
        uint256 rnbwValue = (sharesToBurn * totalPooledRNBW) / totalShares;
        
        // Calculate exit fee (15%)
        uint256 exitFee = (rnbwValue * EXIT_FEE_BPS) / BASIS_POINTS;
        uint256 netAmount = rnbwValue - exitFee;
        
        // Update state
        // Key: Only reduce totalPooledRNBW by netAmount, exitFee stays in pool!
        shares[user] -= sharesToBurn;
        totalShares -= sharesToBurn;
        totalPooledRNBW -= netAmount;  // Exit fee remains, increasing exchange rate
        
        // Update user metadata
        UserMeta storage meta = userMeta[user];
        meta.lastUpdateTime = block.timestamp;
        if (shares[user] == 0) {
            meta.stakingStartTime = 0;
        }
        
        // Transfer net amount to user
        rnbwToken.safeTransfer(user, netAmount);
        
        emit Unstaked(user, sharesToBurn, rnbwValue, exitFee, netAmount);
        emit ExchangeRateUpdated(totalPooledRNBW, totalShares);
    }
    
    function _compoundCashback(address user) internal returns (uint256) {
        UserMeta storage meta = userMeta[user];
        uint256 cashback = meta.cashbackAccrued;
        
        if (cashback > 0) {
            meta.cashbackAccrued = 0;
            
            // Mint shares for cashback at current exchange rate
            uint256 sharesToMint;
            if (totalShares == 0) {
                sharesToMint = cashback;
            } else {
                sharesToMint = (cashback * totalShares) / totalPooledRNBW;
            }
            
            shares[user] += sharesToMint;
            totalShares += sharesToMint;
            totalPooledRNBW += cashback;
            
            emit CashbackCompounded(user, cashback, sharesToMint);
            emit ExchangeRateUpdated(totalPooledRNBW, totalShares);
        }
        
        return cashback;
    }
}
```

</details>

### 4.3 Function Access Summary (Implemented)

**User Operations:**

| Function | Caller | Signature | Notes |
|----------|--------|-----------|-------|
| `stake(amount)` | User (direct) | No | User stakes directly, pays own gas |
| `unstake(sharesToBurn)` | User (direct) | No | User unstakes directly, pays own gas |
| `stakeWithSignature(...)` | Any (relayer) | Yes (trusted signer) | Backend signs, relayer/UI submits. Tokens pulled from `user`. |
| `unstakeWithSignature(...)` | Any (relayer) | Yes (trusted signer) | Backend signs, relayer/UI submits |
| `compoundWithSignature(...)` | Any (relayer) | Yes (trusted signer) | Converts pending cashback → shares |
| `allocateCashbackWithSignature(...)` | Any (relayer) | Yes (trusted signer) | Contract must be pre-funded with RNBW |

**Admin Operations (safe only):**

| Function | Notes |
|----------|-------|
| `addTrustedSigner(address)` | Max 3 signers |
| `removeTrustedSigner(address)` | Cannot remove last signer |
| `setExitFeeBps(uint256)` | Bounded: 1%–75% |
| `setMinStakeAmount(uint256)` | Bounded: 0–1M RNBW |
| `setSafe(address)` | Transfer admin to new safe |
| `depositCashbackRewards(uint256)` | Fund contract for cashback allocations |
| `emergencyWithdraw(token, amount)` | For RNBW: only excess above obligations. Sends to `safe`. |
| `pause()` / `unpause()` | Pauses all user operations |

**View Functions:**

| Function | Notes |
|----------|-------|
| `getPosition(user)` | Returns: stakedAmount (RNBW value), shares, cashbackAllocated, timestamps |
| `getRnbwForShares(shares)` | Convert shares → RNBW at current rate |
| `getSharesForRnbw(rnbw)` | Convert RNBW → shares at current rate |
| `getExchangeRate()` | Current RNBW per share (scaled by 1e18) |
| `isNonceUsed(user, nonce)` | Check nonce status |
| `domainSeparator()` | EIP-712 domain separator |
| `isTrustedSigner(address)` | Check signer status |

> **Note:** `distributeExitFees()` is NOT needed with the exchange rate model. Exit fees automatically distribute via exchange rate increase when users unstake.

### 4.4 Signature Scheme (Implemented)

```
EIP-712 Domain:
  name: "RNBWStaking"
  version: "1"
  chainId: 8453 (Base)
  verifyingContract: <staking contract address>

Stake Message:
  user: address      // User receiving the stake
  amount: uint256    // RNBW amount to stake
  nonce: uint256     // Random nonce (generated by backend)
  expiry: uint256    // Unix timestamp when signature expires

Unstake Message:
  user: address           // User unstaking
  amount: uint256         // SHARES to burn (use getSharesForRnbw to convert)
  nonce: uint256          // Random nonce
  expiry: uint256         // Unix timestamp when signature expires

Compound Message:
  user: address      // User whose cashback to compound
  nonce: uint256     // Random nonce
  expiry: uint256    // Unix timestamp when signature expires

AllocateCashback Message:
  user: address           // User receiving cashback
  rnbwCashback: uint256   // RNBW cashback amount (18 decimals)
  nonce: uint256          // Random nonce
  expiry: uint256         // Unix timestamp when signature expires

IMPORTANT: Nonces are shared across ALL operations for a given user.
A nonce used by stakeWithSignature cannot be reused by unstakeWithSignature.
The signer must be a trusted signer (added via addTrustedSigner), NOT the user.
```

**Relayer Flow (UI gas sponsorship):**

The `stakeWithSignature` / `unstakeWithSignature` functions can be used for gas-sponsored transactions from the UI:

1. UI requests backend to authorize a stake for `(user, amount)`
2. Backend signs the EIP-712 typed data with the trusted signer key
3. Backend returns `(nonce, expiry, signature)` to UI
4. UI builds the `stakeWithSignature(user, amount, nonce, expiry, signature)` calldata
5. UI submits via relayer SDK (any `msg.sender` works — the contract only validates the signature)

This works because signature-based functions never check `msg.sender` — they only verify the EIP-712 signature came from a trusted signer.

### 4.5 What Moved to Backend

| Not in Contract | Backend Responsibility |
|----------------|----------------------|
| Tier thresholds & cashback rates | `fee_tier_config` table |
| Tier lookup | `StakingUseCase.GetTierInfo()` |
| Fee discount calculation | `StakingUseCase.GetFeeDiscount()` |
| Tier configuration updates | Database update (no contract upgrade needed) |
| Cashback amount calculation | Backend calculates RNBW from USD fees + price feed |
| `feesPaidUSD` tracking | Not stored on-chain — backend ledger only |
| Batch cashback accrual | Backend batches then calls `allocateCashbackWithSignature` per user |
| Exit fee distribution | **Not needed** — handled automatically by exchange rate model |

**Benefits:**
- Tier changes don't require contract upgrade
- No gas costs for tier lookups
- More flexible tier configuration
- Contract is simpler and cheaper to deploy
- Exit fee distribution is O(1) with no backend job needed

### 4.6 Potential Enhancements (Future)

#### External LST (Liquid Staking Token) Support

If staking becomes popular, a third party may create an LST wrapper for staked positions. To support this in a future contract upgrade:

**Option 1: External LST Token**
- Deploy a separate ERC20 token contract (e.g., `stRNBW`)
- Add `setExternalLstToken(address)` admin function to staking contract
- When external LST is set:
  - `stake()` → mints external LST tokens to user
  - `unstake()` → burns external LST tokens from user
  - External token is fully transferable on DEXs

**Option 2: Make Staking Contract ERC20**
- Upgrade staking contract to inherit from ERC20
- Add `transfersEnabled` flag (starts false)
- When enabled, staked positions become transferable tokens

**Interface for External LST:**
```solidity
interface IMintableBurnable {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}
```

**Benefits:**
- Users can exit positions without 15% penalty by selling LST
- Creates secondary market for staked positions
- Increases liquidity and utility of staked RNBW

**Considerations:**
- LST holders can unstake (still pay 15% exit fee)
- Cashback must be auto-compounded before transfers
- Tier calculations must use LST balance instead of internal mapping

#### Exit Fee Cap Options (Future)

The current design uses a flat 15% exit fee. Future options to consider:

1. **Capped exit fee**: Set a maximum exit fee amount (e.g., max 1000 RNBW regardless of stake size)
2. **Accrued fees cap**: Exit fee = min(15% of unstake amount, sum of all accrued cashback since deposit)
   - This creates fairer exit for users who haven't benefited much from cashback yet
3. **Time-based decay**: Exit fee decreases over time (e.g., 15% → 10% → 5% over 12 months)

Implementation would require contract upgrade or configurable parameters.

#### Volume-Based Tier Qualification (Future)

Tiers could factor in L30D (last 30 days) swap volume in addition to stake amount:

| Volume Tier | L30D Swap Volume |
|-------------|------------------|
| 0 | < $10,000 |
| 1 | $10,000 - $100,000 |
| 2 | $100,000 - $250,000 |
| 3 | $250,000 - $500,000 |
| 4 | $500,000+ |

User's effective tier = max(stake-based tier, volume-based tier)

#### Gas Sponsorship for Stakers (Future)

High-tier stakers could receive gas sponsorship for transactions:
- Backend identifies eligible wallets based on tier
- Uses Gelato 1Balance or similar for gas sponsorship
- Priority given to highest tiers first

#### Card & Yield Benefits (Future)

Staker benefits could extend to other Rainbow products:
- **Card cashback**: Increased percentage based on tier
- **Cash balance yield**: Increased APY on Rainbow cash balance
- **Onramp subsidies**: Reduced onramp fees for stakers

---

## 5. Database Schema

### 5.1 New Tables

```sql
-- ============================================
-- ENUM TYPES
-- ============================================

-- Staking event types
DO $$
BEGIN
    CREATE TYPE staking_event_type_enum AS ENUM (
        'stake',
        'unstake', 
        'cashback_accrued',
        'cashback_compounded',
        'exit_fee_distributed'
    );
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

-- Staking position status
DO $$
BEGIN
    CREATE TYPE staking_position_status_enum AS ENUM (
        'active',
        'closed'
    );
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

-- Staking transaction status
DO $$
BEGIN
    CREATE TYPE staking_tx_status_enum AS ENUM (
        'pending',
        'confirmed',
        'failed'
    );
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

-- ============================================
-- TABLE: staking_positions
-- Tracks current staking positions per wallet
-- ============================================

CREATE TABLE IF NOT EXISTS staking_positions (
    id                  INT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    wallet_address      VARCHAR NOT NULL CHECK (wallet_address = LOWER(wallet_address)),
    
    -- Current position state (synced with on-chain)
    staked_amount       NUMERIC(78, 0) NOT NULL DEFAULT 0,      -- Current staked amount
    cashback_accrued    NUMERIC(78, 0) NOT NULL DEFAULT 0,      -- Pending cashback
    
    -- Tier information (cached, updated on stake/unstake)
    current_tier        INT NOT NULL DEFAULT 0,                  -- 0-4
    cashback_bps        INT NOT NULL DEFAULT 1000,               -- Basis points (1000 = 10%)
    
    -- Timestamps
    staking_started_at  TIMESTAMPTZ,                             -- When first staked
    last_updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Status
    status              staking_position_status_enum NOT NULL DEFAULT 'active',
    
    CONSTRAINT unique_wallet_position UNIQUE (wallet_address)
);

CREATE INDEX IF NOT EXISTS idx_staking_positions_wallet ON staking_positions (wallet_address);
CREATE INDEX IF NOT EXISTS idx_staking_positions_tier ON staking_positions (current_tier) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS idx_staking_positions_staked ON staking_positions (staked_amount DESC) WHERE status = 'active';

-- ============================================
-- TABLE: staking_events
-- Immutable event log for all staking activities
-- ============================================

CREATE TABLE IF NOT EXISTS staking_events (
    id                  INT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    wallet_address      VARCHAR NOT NULL CHECK (wallet_address = LOWER(wallet_address)),
    position_id         INT NOT NULL REFERENCES staking_positions(id),
    
    event_type          staking_event_type_enum NOT NULL,
    
    -- Amounts (all in raw RNBW, 18 decimals)
    amount              NUMERIC(78, 0) NOT NULL,                 -- Event amount
    exit_fee            NUMERIC(78, 0) DEFAULT 0,                -- Exit fee (for unstake events)
    
    -- Position snapshot after event
    staked_after        NUMERIC(78, 0) NOT NULL,                 -- Staked amount after event
    tier_after          INT NOT NULL,                            -- Tier after event
    
    -- Transaction details
    tx_hash             VARCHAR,                                 -- On-chain tx hash
    chain_id            INT NOT NULL DEFAULT 8453,               -- Base chain
    
    -- Metadata
    source_event_id     VARCHAR,                                 -- For cashback: source swap/bridge event
    metadata            JSONB DEFAULT '{}',
    
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_staking_events_wallet ON staking_events (wallet_address, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_staking_events_type ON staking_events (event_type, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_staking_events_tx ON staking_events (tx_hash) WHERE tx_hash IS NOT NULL;

-- ============================================
-- TABLE: staking_transactions
-- Tracks pending/confirmed blockchain transactions
-- ============================================

CREATE TABLE IF NOT EXISTS staking_transactions (
    id                  INT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    external_id         VARCHAR NOT NULL DEFAULT gen_random_uuid()::VARCHAR,
    wallet_address      VARCHAR NOT NULL CHECK (wallet_address = LOWER(wallet_address)),
    position_id         INT NOT NULL REFERENCES staking_positions(id),
    
    -- Transaction type
    tx_type             VARCHAR NOT NULL CHECK (tx_type IN ('stake', 'unstake', 'compound')),
    
    -- Amounts
    amount              NUMERIC(78, 0) NOT NULL,
    exit_fee            NUMERIC(78, 0) DEFAULT 0,
    
    -- Blockchain details
    chain_id            INT NOT NULL DEFAULT 8453,
    tx_hash             VARCHAR,
    
    -- Status tracking
    status              staking_tx_status_enum NOT NULL DEFAULT 'pending',
    failure_reason      TEXT,
    debug_data          JSONB DEFAULT '{}',
    
    -- Gelato relay tracking
    relay_task_id       VARCHAR,
    
    -- Timestamps
    submitted_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    confirmed_at        TIMESTAMPTZ,
    
    CONSTRAINT unique_external_id UNIQUE (external_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_one_pending_staking_tx_per_wallet 
    ON staking_transactions (wallet_address) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_staking_tx_status ON staking_transactions (status, submitted_at);

-- ============================================
-- TABLE: cashback_ledger
-- Append-only ledger for cashback accruals
-- ============================================

CREATE TABLE IF NOT EXISTS cashback_ledger (
    id                  INT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    wallet_address      VARCHAR NOT NULL CHECK (wallet_address = LOWER(wallet_address)),
    position_id         INT NOT NULL REFERENCES staking_positions(id),
    entry_num           BIGINT NOT NULL,                         -- Per-wallet sequence
    
    -- Source of cashback
    source_type         VARCHAR NOT NULL CHECK (source_type IN ('swap', 'bridge', 'polymarket', 'exit_fee')),
    source_event_id     VARCHAR,                                 -- Reference to source transaction
    
    -- Amounts
    fees_paid_usd       NUMERIC(20, 6) NOT NULL,                 -- Fees paid in USD
    cashback_bps        INT NOT NULL,                            -- Cashback rate at time of accrual
    rnbw_amount         NUMERIC(78, 0) NOT NULL,                 -- RNBW cashback amount
    rnbw_balance        NUMERIC(78, 0) NOT NULL,                 -- Running balance of accrued cashback
    
    -- Compounding
    compounded          BOOLEAN NOT NULL DEFAULT FALSE,
    compounded_at       TIMESTAMPTZ,
    compound_tx_id      INT REFERENCES staking_transactions(id),
    
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    CONSTRAINT unique_wallet_cashback_entry UNIQUE (wallet_address, entry_num)
);

CREATE INDEX IF NOT EXISTS idx_cashback_ledger_wallet ON cashback_ledger (wallet_address, entry_num DESC);
CREATE INDEX IF NOT EXISTS idx_cashback_ledger_pending ON cashback_ledger (wallet_address) WHERE compounded = FALSE;

-- ============================================
-- TABLE: exit_fee_distributions
-- Tracks exit fee distributions to stakers
-- ============================================

CREATE TABLE IF NOT EXISTS exit_fee_distributions (
    id                  INT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    
    -- Source unstake event
    source_event_id     INT NOT NULL REFERENCES staking_events(id),
    source_wallet       VARCHAR NOT NULL,
    
    -- Distribution details
    total_exit_fee      NUMERIC(78, 0) NOT NULL,
    distributed_amount  NUMERIC(78, 0) NOT NULL,
    recipient_count     INT NOT NULL,
    
    -- Transaction
    tx_hash             VARCHAR,
    status              staking_tx_status_enum NOT NULL DEFAULT 'pending',
    
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    distributed_at      TIMESTAMPTZ
);

-- ============================================
-- TABLE: fee_tier_config
-- Configurable tier thresholds and cashback rates
-- ============================================

CREATE TABLE IF NOT EXISTS fee_tier_config (
    id                  INT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    tier_level          INT NOT NULL,
    
    -- Thresholds (in raw RNBW, 18 decimals)
    min_stake_amount    NUMERIC(78, 0) NOT NULL,
    
    -- Cashback rate
    cashback_bps        INT NOT NULL,                            -- Basis points (10000 = 100%)
    
    -- Metadata
    tier_name           VARCHAR,
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    CONSTRAINT unique_tier_level UNIQUE (tier_level)
);

-- Insert default tiers (ILLUSTRATIVE - subject to change based on analysis)
INSERT INTO fee_tier_config (tier_level, min_stake_amount, cashback_bps, tier_name) VALUES
    (0, 0, 1000, 'Green'),                            -- 0 RNBW = 10%
    (1, 10000000000000000000000, 2500, 'Silver'),     -- 10,000 RNBW = 25%
    (2, 20000000000000000000000, 5000, 'Gold'),       -- 20,000 RNBW = 50%
    (3, 30000000000000000000000, 7500, 'Platinum'),   -- 30,000 RNBW = 75%
    (4, 40000000000000000000000, 10000, 'Diamond')    -- 40,000 RNBW = 100%
ON CONFLICT (tier_level) DO NOTHING;
```

### 5.2 Schema Diagram

```
┌─────────────────────────┐       ┌─────────────────────────┐
│   staking_positions     │       │     staking_events      │
├─────────────────────────┤       ├─────────────────────────┤
│ id (PK)                 │◄──────│ position_id (FK)        │
│ wallet_address (UNIQUE) │       │ wallet_address          │
│ staked_amount           │       │ event_type              │
│ cashback_accrued        │       │ amount                  │
│ current_tier            │       │ exit_fee                │
│ cashback_bps            │       │ staked_after            │
│ staking_started_at      │       │ tier_after              │
│ status                  │       │ tx_hash                 │
└─────────────────────────┘       └─────────────────────────┘
           │                                 │
           │                                 │
           ▼                                 ▼
┌─────────────────────────┐       ┌─────────────────────────┐
│  staking_transactions   │       │    cashback_ledger      │
├─────────────────────────┤       ├─────────────────────────┤
│ id (PK)                 │       │ id (PK)                 │
│ external_id             │       │ wallet_address          │
│ wallet_address          │       │ position_id (FK)        │
│ position_id (FK)        │       │ entry_num               │
│ tx_type                 │       │ source_type             │
│ amount                  │       │ fees_paid_usd           │
│ status                  │       │ cashback_bps            │
│ tx_hash                 │       │ rnbw_amount             │
│ relay_task_id           │       │ compounded              │
└─────────────────────────┘       └─────────────────────────┘
                                             │
                                             ▼
                                  ┌─────────────────────────┐
                                  │   fee_tier_config       │
                                  ├─────────────────────────┤
                                  │ tier_level (UNIQUE)     │
                                  │ min_stake_amount        │
                                  │ cashback_bps            │
                                  │ tier_name               │
                                  └─────────────────────────┘
```

---

## 6. Domain Models

### 6.1 Go Models

```go
// internal/domain/staking/model.go

package staking

import (
    "time"
    "github.com/shopspring/decimal"
)

// StakingPosition represents a user's staking position
type StakingPosition struct {
    ID               int
    WalletAddress    string
    StakedAmount     decimal.Decimal
    CashbackAccrued  decimal.Decimal
    CurrentTier      int
    CashbackBps      int
    StakingStartedAt *time.Time
    LastUpdatedAt    time.Time
    Status           PositionStatus
}

type PositionStatus string

const (
    PositionStatusActive PositionStatus = "active"
    PositionStatusClosed PositionStatus = "closed"
)

// StakingEvent represents an immutable staking event
type StakingEvent struct {
    ID            int
    WalletAddress string
    PositionID    int
    EventType     StakingEventType
    Amount        decimal.Decimal
    ExitFee       decimal.Decimal
    StakedAfter   decimal.Decimal
    TierAfter     int
    TxHash        *string
    ChainID       int
    SourceEventID *string
    CreatedAt     time.Time
}

type StakingEventType string

const (
    EventTypeStake              StakingEventType = "stake"
    EventTypeUnstake            StakingEventType = "unstake"
    EventTypeCashbackAccrued    StakingEventType = "cashback_accrued"
    EventTypeCashbackCompounded StakingEventType = "cashback_compounded"
    EventTypeExitFeeDistributed StakingEventType = "exit_fee_distributed"
)

// StakingTransaction represents a pending/confirmed blockchain transaction
type StakingTransaction struct {
    ID            int
    ExternalID    string
    WalletAddress string
    PositionID    int
    TxType        StakingTxType
    Amount        decimal.Decimal
    ExitFee       decimal.Decimal
    ChainID       int
    TxHash        *string
    Status        TxStatus
    FailureReason *string
    RelayTaskID   *string
    SubmittedAt   time.Time
    ConfirmedAt   *time.Time
}

type StakingTxType string

const (
    TxTypeStake    StakingTxType = "stake"
    TxTypeUnstake  StakingTxType = "unstake"
    TxTypeCompound StakingTxType = "compound"
)

type TxStatus string

const (
    TxStatusPending   TxStatus = "pending"
    TxStatusConfirmed TxStatus = "confirmed"
    TxStatusFailed    TxStatus = "failed"
)

// CashbackEntry represents a cashback accrual in the ledger
type CashbackEntry struct {
    ID            int
    WalletAddress string
    PositionID    int
    EntryNum      int64
    SourceType    CashbackSourceType
    SourceEventID *string
    FeesPaidUSD   decimal.Decimal
    CashbackBps   int
    RNBWAmount    decimal.Decimal
    RNBWBalance   decimal.Decimal
    Compounded    bool
    CompoundedAt  *time.Time
    CreatedAt     time.Time
}

type CashbackSourceType string

const (
    SourceTypeSwap      CashbackSourceType = "swap"
    SourceTypeBridge    CashbackSourceType = "bridge"
    SourceTypePolymarket CashbackSourceType = "polymarket"
    SourceTypeExitFee   CashbackSourceType = "exit_fee"
)

// FeeTier represents a fee tier configuration
type FeeTier struct {
    TierLevel      int
    MinStakeAmount decimal.Decimal
    CashbackBps    int
    TierName       string
    IsActive       bool
}

// TierInfo contains computed tier information for a wallet
type TierInfo struct {
    CurrentTier     int
    CashbackBps     int
    TierName        string
    StakedAmount    decimal.Decimal
    NextTier        *int
    NextTierMinimum *decimal.Decimal
    AmountToNextTier *decimal.Decimal
}
```

### 6.2 Interfaces

```go
// internal/domain/staking/interface.go

package staking

import (
    "context"
    "math/big"

    "github.com/ethereum/go-ethereum/common"
    "github.com/shopspring/decimal"
)

// DataStore defines database operations for staking
type DataStore interface {
    // Position operations
    GetPosition(ctx context.Context, walletAddress string) (*StakingPosition, error)
    GetOrCreatePosition(ctx context.Context, walletAddress string) (*StakingPosition, error)
    UpdatePosition(ctx context.Context, position *StakingPosition) error
    
    // Transaction operations
    CreateTransaction(ctx context.Context, tx *StakingTransaction) (*StakingTransaction, error)
    GetTransactionByID(ctx context.Context, id int) (*StakingTransaction, error)
    GetTransactionByExternalID(ctx context.Context, externalID string) (*StakingTransaction, error)
    ConfirmTransaction(ctx context.Context, id int, txHash string) error
    FailTransaction(ctx context.Context, id int, reason string) error
    HasPendingTransaction(ctx context.Context, walletAddress string) (bool, error)
    
    // Event operations
    CreateEvent(ctx context.Context, event *StakingEvent) (*StakingEvent, error)
    GetEventsByWallet(ctx context.Context, walletAddress string, limit int) ([]StakingEvent, error)
    
    // Cashback operations
    AccrueCashback(ctx context.Context, entry *CashbackEntry) error
    GetPendingCashback(ctx context.Context, walletAddress string) ([]CashbackEntry, error)
    MarkCashbackCompounded(ctx context.Context, walletAddress string, txID int) error
    
    // Tier operations
    GetTierConfig(ctx context.Context) ([]FeeTier, error)
    GetTierForAmount(ctx context.Context, amount decimal.Decimal) (*FeeTier, error)
    
    // Aggregates
    GetTotalStaked(ctx context.Context) (decimal.Decimal, error)
    GetStakerCount(ctx context.Context) (int, error)
    GetTopStakers(ctx context.Context, limit int) ([]StakingPosition, error)
}

// StakingContractCaller defines on-chain read operations
type StakingContractCaller interface {
    GetPosition(ctx context.Context, user common.Address) (*ContractPosition, error)
    GetTier(ctx context.Context, user common.Address) (*big.Int, error)
    GetTotalStaked(ctx context.Context) (*big.Int, error)
    GetExitFeePool(ctx context.Context) (*big.Int, error)
}

// ContractPosition represents on-chain position data
type ContractPosition struct {
    StakedAmount    *big.Int
    CashbackAccrued *big.Int
    LastUpdateTime  *big.Int
    StakingStartTime *big.Int
}

// Relayer defines relay service operations
type Relayer interface {
    SubmitStakeCall(ctx context.Context, wallet common.Address, amount *big.Int) (*RelayResult, error)
    SubmitUnstakeCall(ctx context.Context, wallet common.Address, amount *big.Int) (*RelayResult, error)
    SubmitCompoundCall(ctx context.Context, wallet common.Address) (*RelayResult, error)
    GetTaskStatus(ctx context.Context, taskID string) (*RelayResult, error)
}

type RelayResult struct {
    TaskID    string
    TaskState string
    TxHash    string
}

// PriceClient defines price service operations
type PriceClient interface {
    GetRNBWPriceUSD(ctx context.Context) (decimal.Decimal, error)
}
```

### 6.3 Use Case

```go
// internal/domain/staking/usecase.go

package staking

import (
    "context"
    "github.com/shopspring/decimal"
)

type UseCaseConfig struct {
    StakingContract    ContractConfig
    RNBWToken          ContractConfig
    ExitFeeBps         int    // 1500 = 15%
    MinStakeAmount     decimal.Decimal
}

type ContractConfig struct {
    Address  string
    ChainID  int64
    Decimals int
}

type StakingUseCase struct {
    DataStore      DataStore
    ContractCaller StakingContractCaller
    Relayer        Relayer
    PriceClient    PriceClient
    config         UseCaseConfig
}

func NewStakingUseCase(
    dataStore DataStore,
    contractCaller StakingContractCaller,
    relayer Relayer,
    priceClient PriceClient,
    config UseCaseConfig,
) *StakingUseCase {
    return &StakingUseCase{
        DataStore:      dataStore,
        ContractCaller: contractCaller,
        Relayer:        relayer,
        PriceClient:    priceClient,
        config:         config,
    }
}

// GetStakingBalance returns the current staking position for a wallet
func (u *StakingUseCase) GetStakingBalance(ctx context.Context, walletAddress string) (*StakingBalanceResponse, error) {
    // Implementation
    return nil, nil
}

// GetTierInfo returns tier information for a wallet
func (u *StakingUseCase) GetTierInfo(ctx context.Context, walletAddress string) (*TierInfo, error) {
    // Implementation
    return nil, nil
}

// GetFeeDiscount returns the fee discount percentage for a wallet
func (u *StakingUseCase) GetFeeDiscount(ctx context.Context, walletAddress string) (int, error) {
    // Returns cashback BPS (e.g., 5000 = 50% cashback)
    return 0, nil
}

// CalculateCashback calculates cashback for a fee payment
func (u *StakingUseCase) CalculateCashback(
    ctx context.Context,
    walletAddress string,
    feesPaidUSD decimal.Decimal,
) (*CashbackCalculation, error) {
    // Implementation
    return nil, nil
}

// Response types

type StakingBalanceResponse struct {
    Position        *StakingPosition
    TierInfo        *TierInfo
    PendingCashback decimal.Decimal
    TotalValue      decimal.Decimal // In USD
}

type CashbackCalculation struct {
    CashbackBps     int
    FeesPaidUSD     decimal.Decimal
    CashbackUSD     decimal.Decimal
    CashbackRNBW    decimal.Decimal
    RNBWPriceUSD    decimal.Decimal
}
```

---

## 7. API Endpoints

### 7.1 Endpoint Summary

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/v1/staking/balance/{wallet}` | Get staking position and tier info |
| GET | `/v1/staking/tiers` | Get all tier configurations |
| GET | `/v1/staking/tier/{wallet}` | Get wallet's current tier and discount |
| POST | `/v1/staking/stake` | Initiate stake transaction |
| POST | `/v1/staking/unstake` | Initiate unstake transaction |
| POST | `/v1/staking/compound` | Compound pending cashback |
| GET | `/v1/staking/transaction/{id}` | Get transaction status |
| GET | `/v1/staking/history/{wallet}` | Get staking event history |
| POST | `/v1/staking/cashback/accrue` | Accrue cashback (internal) |

### 7.2 Request/Response Schemas

#### GET /v1/staking/balance/{wallet}

**Response:**
```json
{
  "position": {
    "walletAddress": "0x1234...abcd",
    "stakedAmount": "50000000000000000000000",
    "stakedAmountFormatted": "50000.00",
    "cashbackAccrued": "1500000000000000000000",
    "cashbackAccruedFormatted": "1500.00",
    "stakingStartedAt": "2026-01-15T10:30:00Z",
    "status": "active"
  },
  "tier": {
    "currentTier": 2,
    "tierName": "Gold",
    "cashbackBps": 5000,
    "cashbackPercentage": "50%",
    "nextTier": 3,
    "nextTierName": "Platinum",
    "nextTierMinimum": "75000000000000000000000",
    "amountToNextTier": "25000000000000000000000"
  },
  "stats": {
    "totalValueUSD": "1250.50",
    "pendingCashbackUSD": "37.50",
    "lifetimeCashbackRNBW": "5000000000000000000000",
    "lifetimeCashbackUSD": "125.00"
  }
}
```

#### GET /v1/staking/tiers

**Response:**
```json
{
  "tiers": [
    {
      "level": 0,
      "name": "Bronze",
      "minStakeAmount": "0",
      "minStakeFormatted": "0",
      "cashbackBps": 1000,
      "cashbackPercentage": "10%"
    },
    {
      "level": 1,
      "name": "Silver",
      "minStakeAmount": "25000000000000000000000",
      "minStakeFormatted": "25,000",
      "cashbackBps": 2500,
      "cashbackPercentage": "25%"
    },
    {
      "level": 2,
      "name": "Gold",
      "minStakeAmount": "50000000000000000000000",
      "minStakeFormatted": "50,000",
      "cashbackBps": 5000,
      "cashbackPercentage": "50%"
    },
    {
      "level": 3,
      "name": "Platinum",
      "minStakeAmount": "75000000000000000000000",
      "minStakeFormatted": "75,000",
      "cashbackBps": 7500,
      "cashbackPercentage": "75%"
    },
    {
      "level": 4,
      "name": "Diamond",
      "minStakeAmount": "100000000000000000000000",
      "minStakeFormatted": "100,000",
      "cashbackBps": 10000,
      "cashbackPercentage": "100%"
    }
  ],
  "exitFeeBps": 1500,
  "exitFeePercentage": "15%"
}
```

#### POST /v1/staking/stake

**Request:**
```json
{
  "walletAddress": "0x1234...abcd",
  "amount": "25000000000000000000000",
  "signature": "0x..."
}
```

**Response:**
```json
{
  "transactionId": "tx_abc123",
  "status": "pending",
  "amount": "25000000000000000000000",
  "estimatedTierAfter": 2,
  "estimatedCashbackBps": 5000
}
```

#### POST /v1/staking/unstake

**Request:**
```json
{
  "walletAddress": "0x1234...abcd",
  "amount": "10000000000000000000000",
  "signature": "0x..."
}
```

**Response:**
```json
{
  "transactionId": "tx_def456",
  "status": "pending",
  "amount": "10000000000000000000000",
  "exitFee": "1500000000000000000000",
  "netAmount": "8500000000000000000000",
  "exitFeePercentage": "15%",
  "estimatedTierAfter": 1,
  "estimatedCashbackBps": 2500,
  "warning": "You will lose 15% of your unstaked amount as an exit fee."
}
```

#### GET /v1/staking/tier/{wallet}

**Response:**
```json
{
  "walletAddress": "0x1234...abcd",
  "tier": 2,
  "tierName": "Gold",
  "cashbackBps": 5000,
  "feeDiscountPercentage": "50%"
}
```

Used by swap/bridge/polymarket services to get fee discount.

#### POST /v1/staking/cashback/accrue (Internal)

**Request:**
```json
{
  "walletAddress": "0x1234...abcd",
  "sourceType": "swap",
  "sourceEventId": "swap_evt_123",
  "feesPaidUSD": "10.50",
  "rnbwPriceUSD": "0.025"
}
```

**Response:**
```json
{
  "success": true,
  "cashbackBps": 5000,
  "cashbackRNBW": "210000000000000000000",
  "newAccruedBalance": "1710000000000000000000"
}
```

### 7.3 Handler Implementation

```go
// internal/inbound/server/staking.go

package server

import (
    "net/http"

    "github.com/labstack/echo/v4"
    "github.com/rainbow-me/rewards/internal/domain/staking"
)

type StakingHandler struct {
    useCase *staking.StakingUseCase
}

func NewStakingHandler(useCase *staking.StakingUseCase) *StakingHandler {
    return &StakingHandler{useCase: useCase}
}

// GetBalance handles GET /v1/staking/balance/{wallet}
func (h *StakingHandler) GetBalance(c echo.Context) error {
    wallet := c.Param("wallet")
    
    if err := validateAddress(wallet); err != nil {
        return c.JSON(http.StatusBadRequest, errorResponse(err))
    }
    
    balance, err := h.useCase.GetStakingBalance(c.Request().Context(), wallet)
    if err != nil {
        return handleError(c, err)
    }
    
    return c.JSON(http.StatusOK, mapBalanceResponse(balance))
}

// GetTiers handles GET /v1/staking/tiers
func (h *StakingHandler) GetTiers(c echo.Context) error {
    tiers, err := h.useCase.GetAllTiers(c.Request().Context())
    if err != nil {
        return handleError(c, err)
    }
    
    return c.JSON(http.StatusOK, mapTiersResponse(tiers))
}

// GetTier handles GET /v1/staking/tier/{wallet}
func (h *StakingHandler) GetTier(c echo.Context) error {
    wallet := c.Param("wallet")
    
    if err := validateAddress(wallet); err != nil {
        return c.JSON(http.StatusBadRequest, errorResponse(err))
    }
    
    tierInfo, err := h.useCase.GetTierInfo(c.Request().Context(), wallet)
    if err != nil {
        return handleError(c, err)
    }
    
    return c.JSON(http.StatusOK, mapTierResponse(wallet, tierInfo))
}

// Stake handles POST /v1/staking/stake
func (h *StakingHandler) Stake(c echo.Context) error {
    var req StakeRequest
    if err := c.Bind(&req); err != nil {
        return c.JSON(http.StatusBadRequest, errorResponse(err))
    }
    
    if err := validateStakeRequest(&req); err != nil {
        return c.JSON(http.StatusBadRequest, errorResponse(err))
    }
    
    result, err := h.useCase.InitiateStake(c.Request().Context(), &staking.StakeParams{
        WalletAddress: req.WalletAddress,
        Amount:        req.Amount,
        Signature:     req.Signature,
    })
    if err != nil {
        return handleError(c, err)
    }
    
    return c.JSON(http.StatusAccepted, mapStakeResponse(result))
}

// Unstake handles POST /v1/staking/unstake
func (h *StakingHandler) Unstake(c echo.Context) error {
    var req UnstakeRequest
    if err := c.Bind(&req); err != nil {
        return c.JSON(http.StatusBadRequest, errorResponse(err))
    }
    
    if err := validateUnstakeRequest(&req); err != nil {
        return c.JSON(http.StatusBadRequest, errorResponse(err))
    }
    
    result, err := h.useCase.InitiateUnstake(c.Request().Context(), &staking.UnstakeParams{
        WalletAddress: req.WalletAddress,
        Amount:        req.Amount,
        Signature:     req.Signature,
    })
    if err != nil {
        return handleError(c, err)
    }
    
    return c.JSON(http.StatusAccepted, mapUnstakeResponse(result))
}

// AccrueCashback handles POST /v1/staking/cashback/accrue (internal)
func (h *StakingHandler) AccrueCashback(c echo.Context) error {
    var req AccrueCashbackRequest
    if err := c.Bind(&req); err != nil {
        return c.JSON(http.StatusBadRequest, errorResponse(err))
    }
    
    result, err := h.useCase.AccrueCashback(c.Request().Context(), &staking.AccrueCashbackParams{
        WalletAddress: req.WalletAddress,
        SourceType:    req.SourceType,
        SourceEventID: req.SourceEventID,
        FeesPaidUSD:   req.FeesPaidUSD,
        RNBWPriceUSD:  req.RNBWPriceUSD,
    })
    if err != nil {
        return handleError(c, err)
    }
    
    return c.JSON(http.StatusOK, mapCashbackResponse(result))
}
```

---

## 8. Temporal Workflows

### 8.1 Workflow Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Staking Workflows                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────────────┐  │
│  │  StakeWorkflow  │    │ UnstakeWorkflow │    │ CashbackDistribution    │  │
│  │                 │    │                 │    │ Workflow                │  │
│  │ 1. Validate     │    │ 1. Validate     │    │                         │  │
│  │ 2. Create TX    │    │ 2. Calc Exit Fee│    │ 1. Get stakers snapshot │  │
│  │ 3. Submit Relay │    │ 3. Create TX    │    │ 2. Calculate pro-rata   │  │
│  │ 4. Poll Status  │    │ 4. Submit Relay │    │ 3. Batch accrue         │  │
│  │ 5. Confirm      │    │ 5. Poll Status  │    │ 4. Update on-chain      │  │
│  │ 6. Update Tier  │    │ 6. Confirm      │    │                         │  │
│  └─────────────────┘    │ 7. Distribute   │    └─────────────────────────┘  │
│                         │    Exit Fee     │                                  │
│                         └─────────────────┘                                  │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                    CompoundCashbackWorkflow                          │    │
│  │                                                                      │    │
│  │  1. Get pending cashback entries                                     │    │
│  │  2. Submit compound transaction                                      │    │
│  │  3. Poll status                                                      │    │
│  │  4. Mark entries as compounded                                       │    │
│  │  5. Update position                                                  │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 8.2 Stake Workflow

```go
// internal/workflows/staking/workflow_stake.go

package staking

import (
    "time"

    "github.com/shopspring/decimal"
    "go.temporal.io/api/enums/v1"
    "go.temporal.io/sdk/temporal"
    "go.temporal.io/sdk/workflow"
)

// StakeRequest is the input for the Stake workflow
type StakeRequest struct {
    WalletAddress string
    Amount        decimal.Decimal
    Signature     string
}

// StakeResult is the output of the Stake workflow
type StakeResult struct {
    TransactionID string
    TxHash        string
    StakedAmount  decimal.Decimal
    NewTotal      decimal.Decimal
    NewTier       int
    CashbackBps   int
}

// Stake is the main workflow for staking RNBW
func (w *Workflow) Stake(ctx workflow.Context, req *StakeRequest) (*StakeResult, error) {
    logger := workflow.GetLogger(ctx)
    ctx = workflow.WithActivityOptions(ctx, getDefaultActivityOptions())

    logger.Info("Starting stake workflow", "wallet", req.WalletAddress, "amount", req.Amount)

    // 1. Validate staking request
    validateResult := &ValidateStakeResponse{}
    err := workflow.ExecuteActivity(ctx, w.ValidateStakeRequest, req).Get(ctx, validateResult)
    if err != nil {
        return nil, err
    }

    if !validateResult.IsValid {
        return nil, temporal.NewApplicationError(validateResult.Reason, ErrTypeValidation)
    }

    // 2. Check for pending transactions
    hasPending := false
    err = workflow.ExecuteActivity(ctx, w.HasPendingTransaction, req.WalletAddress).Get(ctx, &hasPending)
    if err != nil {
        return nil, err
    }
    if hasPending {
        return nil, temporal.NewApplicationError("pending transaction exists", ErrTypePendingTx)
    }

    // 3. Create transaction record
    createTxResult := &CreateTransactionResponse{}
    err = workflow.ExecuteActivity(ctx, w.CreateStakeTransaction, &CreateStakeTransactionRequest{
        WalletAddress: req.WalletAddress,
        Amount:        req.Amount,
    }).Get(ctx, createTxResult)
    if err != nil {
        return nil, err
    }

    // 4. Submit to relay (Gelato)
    relayResult := &RelaySubmitResponse{}
    err = workflow.ExecuteActivity(ctx, w.SubmitStakeToRelay, &SubmitToRelayRequest{
        TransactionID: createTxResult.TransactionID,
        WalletAddress: req.WalletAddress,
        Amount:        req.Amount,
        Signature:     req.Signature,
    }).Get(ctx, relayResult)
    if err != nil {
        _ = workflow.ExecuteActivity(ctx, w.FailTransaction, createTxResult.TransactionID, err.Error()).Get(ctx, nil)
        return nil, err
    }

    // 5. Poll for transaction completion
    pollCtx := workflow.WithActivityOptions(ctx, getPollingActivityOptions())
    pollResult := &PollTransactionResponse{}
    err = workflow.ExecuteActivity(pollCtx, w.PollTransactionStatus, &PollTransactionRequest{
        TaskID:        relayResult.TaskID,
        TransactionID: createTxResult.TransactionID,
        MaxAttempts:   25,
        IntervalSec:   2,
    }).Get(pollCtx, pollResult)
    if err != nil {
        _ = workflow.ExecuteActivity(ctx, w.FailTransaction, createTxResult.TransactionID, err.Error()).Get(ctx, nil)
        return nil, err
    }

    if !pollResult.Success {
        _ = workflow.ExecuteActivity(ctx, w.FailTransaction, createTxResult.TransactionID, pollResult.FailureReason).Get(ctx, nil)
        return nil, temporal.NewApplicationError(pollResult.FailureReason, ErrTypeTransactionFailed)
    }

    // 6. Confirm transaction and update position
    confirmResult := &ConfirmStakeResponse{}
    err = workflow.ExecuteActivity(ctx, w.ConfirmStakeTransaction, &ConfirmStakeRequest{
        TransactionID: createTxResult.TransactionID,
        TxHash:        pollResult.TxHash,
        WalletAddress: req.WalletAddress,
        Amount:        req.Amount,
    }).Get(ctx, confirmResult)
    if err != nil {
        return nil, err
    }

    logger.Info("Stake workflow completed",
        "wallet", req.WalletAddress,
        "txHash", pollResult.TxHash,
        "newTier", confirmResult.NewTier)

    return &StakeResult{
        TransactionID: createTxResult.TransactionID,
        TxHash:        pollResult.TxHash,
        StakedAmount:  req.Amount,
        NewTotal:      confirmResult.NewTotal,
        NewTier:       confirmResult.NewTier,
        CashbackBps:   confirmResult.CashbackBps,
    }, nil
}
```

### 8.3 Unstake Workflow

```go
// internal/workflows/staking/workflow_unstake.go

package staking

import (
    "go.temporal.io/api/enums/v1"
    "go.temporal.io/sdk/temporal"
    "go.temporal.io/sdk/workflow"
)

// UnstakeRequest is the input for the Unstake workflow
type UnstakeRequest struct {
    WalletAddress string
    Amount        decimal.Decimal
    Signature     string
}

// UnstakeResult is the output of the Unstake workflow
type UnstakeResult struct {
    TransactionID string
    TxHash        string
    Amount        decimal.Decimal
    ExitFee       decimal.Decimal
    NetReceived   decimal.Decimal
    NewTotal      decimal.Decimal
    NewTier       int
}

// Unstake is the main workflow for unstaking RNBW
func (w *Workflow) Unstake(ctx workflow.Context, req *UnstakeRequest) (*UnstakeResult, error) {
    logger := workflow.GetLogger(ctx)
    ctx = workflow.WithActivityOptions(ctx, getDefaultActivityOptions())

    logger.Info("Starting unstake workflow", "wallet", req.WalletAddress, "amount", req.Amount)

    // 1. Validate unstake request and calculate exit fee
    validateResult := &ValidateUnstakeResponse{}
    err := workflow.ExecuteActivity(ctx, w.ValidateUnstakeRequest, req).Get(ctx, validateResult)
    if err != nil {
        return nil, err
    }

    if !validateResult.IsValid {
        return nil, temporal.NewApplicationError(validateResult.Reason, ErrTypeValidation)
    }

    exitFee := validateResult.ExitFee
    netAmount := req.Amount.Sub(exitFee)

    // 2. Check for pending transactions
    hasPending := false
    err = workflow.ExecuteActivity(ctx, w.HasPendingTransaction, req.WalletAddress).Get(ctx, &hasPending)
    if err != nil {
        return nil, err
    }
    if hasPending {
        return nil, temporal.NewApplicationError("pending transaction exists", ErrTypePendingTx)
    }

    // 3. Create transaction record
    createTxResult := &CreateTransactionResponse{}
    err = workflow.ExecuteActivity(ctx, w.CreateUnstakeTransaction, &CreateUnstakeTransactionRequest{
        WalletAddress: req.WalletAddress,
        Amount:        req.Amount,
        ExitFee:       exitFee,
        NetAmount:     netAmount,
    }).Get(ctx, createTxResult)
    if err != nil {
        return nil, err
    }

    // 4. Submit to relay (Gelato)
    relayResult := &RelaySubmitResponse{}
    err = workflow.ExecuteActivity(ctx, w.SubmitUnstakeToRelay, &SubmitToRelayRequest{
        TransactionID: createTxResult.TransactionID,
        WalletAddress: req.WalletAddress,
        Amount:        req.Amount,
        Signature:     req.Signature,
    }).Get(ctx, relayResult)
    if err != nil {
        _ = workflow.ExecuteActivity(ctx, w.FailTransaction, createTxResult.TransactionID, err.Error()).Get(ctx, nil)
        return nil, err
    }

    // 5. Poll for transaction completion
    pollCtx := workflow.WithActivityOptions(ctx, getPollingActivityOptions())
    pollResult := &PollTransactionResponse{}
    err = workflow.ExecuteActivity(pollCtx, w.PollTransactionStatus, &PollTransactionRequest{
        TaskID:        relayResult.TaskID,
        TransactionID: createTxResult.TransactionID,
        MaxAttempts:   25,
        IntervalSec:   2,
    }).Get(pollCtx, pollResult)
    if err != nil {
        _ = workflow.ExecuteActivity(ctx, w.FailTransaction, createTxResult.TransactionID, err.Error()).Get(ctx, nil)
        return nil, err
    }

    if !pollResult.Success {
        _ = workflow.ExecuteActivity(ctx, w.FailTransaction, createTxResult.TransactionID, pollResult.FailureReason).Get(ctx, nil)
        return nil, temporal.NewApplicationError(pollResult.FailureReason, ErrTypeTransactionFailed)
    }

    // 6. Confirm transaction and update position
    confirmResult := &ConfirmUnstakeResponse{}
    err = workflow.ExecuteActivity(ctx, w.ConfirmUnstakeTransaction, &ConfirmUnstakeRequest{
        TransactionID: createTxResult.TransactionID,
        TxHash:        pollResult.TxHash,
        WalletAddress: req.WalletAddress,
        Amount:        req.Amount,
        ExitFee:       exitFee,
    }).Get(ctx, confirmResult)
    if err != nil {
        return nil, err
    }

    // 7. Schedule exit fee distribution (fire and forget child workflow)
    childCtx := workflow.WithChildOptions(ctx, workflow.ChildWorkflowOptions{
        WorkflowID:        getExitFeeDistributionWorkflowID(createTxResult.TransactionID),
        TaskQueue:         workflow.GetInfo(ctx).TaskQueueName,
        ParentClosePolicy: enums.PARENT_CLOSE_POLICY_ABANDON,
    })

    _ = workflow.ExecuteChildWorkflow(childCtx, w.DistributeExitFee, &DistributeExitFeeRequest{
        SourceTransactionID: createTxResult.TransactionID,
        SourceWallet:        req.WalletAddress,
        ExitFeeAmount:       exitFee,
    })

    logger.Info("Unstake workflow completed",
        "wallet", req.WalletAddress,
        "txHash", pollResult.TxHash,
        "exitFee", exitFee,
        "netReceived", netAmount)

    return &UnstakeResult{
        TransactionID: createTxResult.TransactionID,
        TxHash:        pollResult.TxHash,
        Amount:        req.Amount,
        ExitFee:       exitFee,
        NetReceived:   netAmount,
        NewTotal:      confirmResult.NewTotal,
        NewTier:       confirmResult.NewTier,
    }, nil
}
```

### 8.4 Cashback Accrual Workflow

```go
// internal/workflows/staking/workflow_cashback.go

package staking

import (
    "go.temporal.io/sdk/workflow"
)

// AccrueCashbackRequest is the input for cashback accrual
type AccrueCashbackRequest struct {
    WalletAddress string
    SourceType    string // swap, bridge, polymarket
    SourceEventID string
    FeesPaidUSD   decimal.Decimal
}

// AccrueCashbackResult is the output of cashback accrual
type AccrueCashbackResult struct {
    CashbackBps   int
    CashbackRNBW  decimal.Decimal
    CashbackUSD   decimal.Decimal
    NewAccrued    decimal.Decimal
}

// AccrueCashback handles cashback accrual after fee payment
func (w *Workflow) AccrueCashback(ctx workflow.Context, req *AccrueCashbackRequest) (*AccrueCashbackResult, error) {
    logger := workflow.GetLogger(ctx)
    ctx = workflow.WithActivityOptions(ctx, getDefaultActivityOptions())

    // 1. Get wallet's staking position and tier
    position := &StakingPositionResponse{}
    err := workflow.ExecuteActivity(ctx, w.GetStakingPosition, req.WalletAddress).Get(ctx, position)
    if err != nil {
        return nil, err
    }

    // No staking position = no cashback
    if position.StakedAmount.IsZero() {
        return &AccrueCashbackResult{
            CashbackBps:  0,
            CashbackRNBW: decimal.Zero,
            CashbackUSD:  decimal.Zero,
            NewAccrued:   decimal.Zero,
        }, nil
    }

    // 2. Get current RNBW price
    rnbwPrice := decimal.Zero
    err = workflow.ExecuteActivity(ctx, w.GetRNBWPrice).Get(ctx, &rnbwPrice)
    if err != nil {
        logger.Warn("Failed to get RNBW price, skipping cashback", "error", err)
        return nil, err
    }

    // 3. Calculate cashback
    cashbackBps := position.CashbackBps
    cashbackUSD := req.FeesPaidUSD.Mul(decimal.NewFromInt(int64(cashbackBps))).Div(decimal.NewFromInt(10000))
    
    var cashbackRNBW decimal.Decimal
    if rnbwPrice.GreaterThan(decimal.Zero) {
        // Convert USD to RNBW (with 18 decimals)
        cashbackRNBW = cashbackUSD.Div(rnbwPrice).Shift(18)
    }

    // 4. Record cashback accrual
    accrueResult := &AccrueCashbackDBResponse{}
    err = workflow.ExecuteActivity(ctx, w.RecordCashbackAccrual, &RecordCashbackRequest{
        WalletAddress: req.WalletAddress,
        SourceType:    req.SourceType,
        SourceEventID: req.SourceEventID,
        FeesPaidUSD:   req.FeesPaidUSD,
        CashbackBps:   cashbackBps,
        RNBWAmount:    cashbackRNBW,
        RNBWPriceUSD:  rnbwPrice,
    }).Get(ctx, accrueResult)
    if err != nil {
        return nil, err
    }

    logger.Info("Cashback accrued",
        "wallet", req.WalletAddress,
        "source", req.SourceType,
        "feesPaidUSD", req.FeesPaidUSD,
        "cashbackRNBW", cashbackRNBW)

    return &AccrueCashbackResult{
        CashbackBps:  cashbackBps,
        CashbackRNBW: cashbackRNBW,
        CashbackUSD:  cashbackUSD,
        NewAccrued:   accrueResult.NewAccruedBalance,
    }, nil
}
```

### 8.5 Exit Fee Distribution Workflow

```go
// internal/workflows/staking/workflow_exit_fee.go

package staking

import (
    "go.temporal.io/sdk/workflow"
)

// DistributeExitFeeRequest is the input for exit fee distribution
type DistributeExitFeeRequest struct {
    SourceTransactionID string
    SourceWallet        string
    ExitFeeAmount       decimal.Decimal
}

// DistributeExitFee distributes exit fees to all stakers pro-rata
func (w *Workflow) DistributeExitFee(ctx workflow.Context, req *DistributeExitFeeRequest) error {
    logger := workflow.GetLogger(ctx)
    ctx = workflow.WithActivityOptions(ctx, getDefaultActivityOptions())

    logger.Info("Starting exit fee distribution",
        "sourceTx", req.SourceTransactionID,
        "amount", req.ExitFeeAmount)

    // 1. Get snapshot of all active stakers (excluding source wallet)
    stakersSnapshot := &StakersSnapshotResponse{}
    err := workflow.ExecuteActivity(ctx, w.GetStakersSnapshot, &GetStakersSnapshotRequest{
        ExcludeWallet: req.SourceWallet,
        MinStake:      decimal.NewFromInt(1), // Minimum 1 RNBW
    }).Get(ctx, stakersSnapshot)
    if err != nil {
        return err
    }

    if len(stakersSnapshot.Stakers) == 0 {
        logger.Info("No stakers to distribute to, adding to pool")
        return nil
    }

    // 2. Calculate pro-rata shares
    shares := make([]ShareAllocation, len(stakersSnapshot.Stakers))
    totalStaked := stakersSnapshot.TotalStaked

    for i, staker := range stakersSnapshot.Stakers {
        // share = (stakerAmount / totalStaked) * exitFeeAmount
        share := staker.StakedAmount.Mul(req.ExitFeeAmount).Div(totalStaked)
        shares[i] = ShareAllocation{
            WalletAddress: staker.WalletAddress,
            Share:         share,
        }
    }

    // 3. Batch accrue exit fee shares as cashback
    batchSize := 100
    for i := 0; i < len(shares); i += batchSize {
        end := i + batchSize
        if end > len(shares) {
            end = len(shares)
        }
        batch := shares[i:end]

        err = workflow.ExecuteActivity(ctx, w.BatchAccrueExitFeeShare, &BatchAccrueRequest{
            SourceTransactionID: req.SourceTransactionID,
            Allocations:         batch,
        }).Get(ctx, nil)
        if err != nil {
            logger.Error("Failed to accrue batch", "batchStart", i, "error", err)
            // Continue with remaining batches
        }
    }

    // 4. Record distribution event
    err = workflow.ExecuteActivity(ctx, w.RecordExitFeeDistribution, &RecordDistributionRequest{
        SourceTransactionID: req.SourceTransactionID,
        TotalAmount:         req.ExitFeeAmount,
        RecipientCount:      len(stakersSnapshot.Stakers),
    }).Get(ctx, nil)
    if err != nil {
        logger.Error("Failed to record distribution", "error", err)
    }

    logger.Info("Exit fee distribution completed",
        "recipients", len(stakersSnapshot.Stakers),
        "totalDistributed", req.ExitFeeAmount)

    return nil
}
```

---

## 9. Fee Tier System

### 9.1 Tier Configuration

**ILLUSTRATIVE - Subject to change based on analysis**

| Tier | Name | Min Stake (RNBW) | Cashback % | Use Case |
|------|------|------------------|------------|----------|
| 0 | Green | 0 | 10% | Default for all users |
| 1 | Silver | 10,000 | 25% | Entry-level stakers |
| 2 | Gold | 20,000 | 50% | Active traders |
| 3 | Platinum | 30,000 | 75% | Power users |
| 4 | Diamond | 40,000 | 100% | Whales/Evangelists |

**Future consideration**: Tiers may also factor in L30D Swap Volume (e.g., $10k-$100k, $100k-$250k, etc.)

### 9.2 Fee Integration Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Fee Discount Integration                             │
└─────────────────────────────────────────────────────────────────────────────┘

    User initiates swap/bridge/polymarket trade
                        │
                        ▼
    ┌───────────────────────────────────────┐
    │  1. Swap/Bridge Service calls         │
    │     GET /v1/staking/tier/{wallet}     │
    └───────────────────────────────────────┘
                        │
                        ▼
    ┌───────────────────────────────────────┐
    │  2. Staking Service returns:          │
    │     - tier: 2                         │
    │     - cashbackBps: 5000 (50%)         │
    └───────────────────────────────────────┘
                        │
                        ▼
    ┌───────────────────────────────────────┐
    │  3. Swap Service executes trade       │
    │     - Collects full fee (85 bps)      │
    │     - Records fee amount              │
    └───────────────────────────────────────┘
                        │
                        ▼
    ┌───────────────────────────────────────┐
    │  4. Post-trade: Swap Service calls    │
    │     POST /v1/staking/cashback/accrue  │
    │     {                                 │
    │       "walletAddress": "0x...",       │
    │       "sourceType": "swap",           │
    │       "sourceEventId": "swap_123",    │
    │       "feesPaidUSD": "10.50"          │
    │     }                                 │
    └───────────────────────────────────────┘
                        │
                        ▼
    ┌───────────────────────────────────────┐
    │  5. Staking Service:                  │
    │     - Calculates: $10.50 × 50% = $5.25│
    │     - Converts to RNBW at market price│
    │     - Accrues as staked cashback      │
    └───────────────────────────────────────┘
```

### 9.3 Tier Lookup Caching

```go
// internal/domain/staking/tier_cache.go

package staking

import (
    "context"
    "sync"
    "time"

    "github.com/shopspring/decimal"
)

type TierCache struct {
    mu          sync.RWMutex
    tiers       []FeeTier
    lastRefresh time.Time
    ttl         time.Duration
}

func NewTierCache(ttl time.Duration) *TierCache {
    return &TierCache{
        tiers: make([]FeeTier, 0),
        ttl:   ttl,
    }
}

// GetTierForAmount returns the tier for a given staked amount
// Uses cached tier config with periodic refresh
func (c *TierCache) GetTierForAmount(ctx context.Context, amount decimal.Decimal, store DataStore) (*FeeTier, error) {
    c.mu.RLock()
    if time.Since(c.lastRefresh) < c.ttl && len(c.tiers) > 0 {
        tier := c.findTier(amount)
        c.mu.RUnlock()
        return tier, nil
    }
    c.mu.RUnlock()

    // Refresh cache
    c.mu.Lock()
    defer c.mu.Unlock()

    // Double-check after acquiring write lock
    if time.Since(c.lastRefresh) < c.ttl && len(c.tiers) > 0 {
        return c.findTier(amount), nil
    }

    tiers, err := store.GetTierConfig(ctx)
    if err != nil {
        return nil, err
    }

    c.tiers = tiers
    c.lastRefresh = time.Now()

    return c.findTier(amount), nil
}

func (c *TierCache) findTier(amount decimal.Decimal) *FeeTier {
    var result *FeeTier
    for i := range c.tiers {
        if amount.GreaterThanOrEqual(c.tiers[i].MinStakeAmount) {
            result = &c.tiers[i]
        }
    }
    if result == nil && len(c.tiers) > 0 {
        result = &c.tiers[0] // Default to tier 0
    }
    return result
}
```

### 9.4 Fee Scope

**Included in Phase 1:**
- Swap fees (85 bps)
- Bridge fees
- Polymarket fees

**Excluded from Phase 1:**
- Perps fees
- Gas sponsorship

### 9.5 Compatibility with Existing Rewards

The staking cashback system operates **independently** of the existing swap rewards program:

1. **Existing Rewards**: Users earn RNBW for swaps (allocation-based)
2. **Staking Cashback**: Users earn back a % of fees paid (based on stake tier)

Both can be active simultaneously. The cashback is deposited as staked RNBW, while existing rewards go to the claimable balance.

---

## 10. Security Considerations

### 10.1 Smart Contract Security

| Risk | Mitigation |
|------|------------|
| Reentrancy | `nonReentrant` modifier on all state-changing functions |
| Integer overflow | Solidity 0.8+ with built-in overflow checks |
| Access control | Role-based access (OpenZeppelin AccessControl) |
| Front-running | No MEV-sensitive operations in staking |
| Flash loan attacks | No oracle-dependent calculations |
| Centralization | Multi-sig admin, timelocked upgrades |

### 10.2 Backend Security

| Risk | Mitigation |
|------|------------|
| Double cashback | Idempotent accrual with source_event_id |
| Race conditions | Database transactions + unique constraints |
| Signature replay | EIP-712 signatures with nonce/expiry |
| API abuse | Rate limiting, API key authentication |
| Data tampering | Immutable event log, audit trail |

### 10.3 Operational Security

```yaml
# Security checklist for deployment

pre_deployment:
  - [ ] Smart contract audit completed
  - [ ] Formal verification of critical invariants
  - [ ] Testnet deployment and testing
  - [ ] Multi-sig wallet setup for admin functions
  - [ ] Emergency pause mechanism tested

deployment:
  - [ ] Deploy with minimal admin permissions
  - [ ] Verify contract on block explorer
  - [ ] Test all functions with small amounts
  - [ ] Monitor for anomalies

post_deployment:
  - [ ] Set up alerts for large unstakes
  - [ ] Monitor exit fee pool balance
  - [ ] Regular reconciliation checks
  - [ ] Incident response plan documented
```

### 10.4 Invariants

The following invariants must always hold:

```solidity
// Contract invariants
assert(totalStaked == sum(positions[*].stakedAmount));
assert(exitFeePool >= 0);
assert(positions[user].stakedAmount >= 0);
assert(positions[user].cashbackAccrued >= 0);

// Database invariants
-- Sum of staking events = current position
SELECT SUM(CASE WHEN event_type = 'stake' THEN amount 
                WHEN event_type = 'unstake' THEN -amount 
                ELSE 0 END) = staked_amount
FROM staking_events e
JOIN staking_positions p ON e.wallet_address = p.wallet_address
GROUP BY p.wallet_address;

-- Cashback ledger balance matches position
SELECT SUM(CASE WHEN compounded THEN 0 ELSE rnbw_amount END) = cashback_accrued
FROM cashback_ledger cl
JOIN staking_positions p ON cl.wallet_address = p.wallet_address
WHERE cl.compounded = FALSE
GROUP BY p.wallet_address;
```

---

## 11. Migration Strategy

### 11.1 Phased Rollout

```
Phase 1: Contract Deployment (Week 1)
├── Deploy RNBWStaking contract to Base
├── Verify contract on Basescan
├── Configure tier parameters
├── Test with internal wallets
└── Set up monitoring

Phase 2: Backend Services (Week 2)
├── Deploy database migrations
├── Deploy staking service
├── Internal API testing
├── Integration testing with swap service
└── Load testing

Phase 3: Limited Beta (Week 3)
├── Enable for allowlisted wallets
├── Monitor transaction success rates
├── Gather user feedback
├── Fix any issues
└── Prepare for full launch

Phase 4: General Availability (Week 4)
├── Remove allowlist restrictions
├── Enable mobile UI
├── Marketing announcement
└── Monitor adoption metrics
```

### 11.2 Database Migration

```sql
-- Migration: 000023_staking_system.up.sql

BEGIN;

-- Create enum types
CREATE TYPE staking_event_type_enum AS ENUM (...);
CREATE TYPE staking_position_status_enum AS ENUM (...);
CREATE TYPE staking_tx_status_enum AS ENUM (...);

-- Create tables
CREATE TABLE IF NOT EXISTS staking_positions (...);
CREATE TABLE IF NOT EXISTS staking_events (...);
CREATE TABLE IF NOT EXISTS staking_transactions (...);
CREATE TABLE IF NOT EXISTS cashback_ledger (...);
CREATE TABLE IF NOT EXISTS exit_fee_distributions (...);
CREATE TABLE IF NOT EXISTS fee_tier_config (...);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_staking_positions_wallet ...;
-- ... other indexes

-- Insert default tier configuration
INSERT INTO fee_tier_config (...) VALUES ...;

COMMIT;
```

### 11.3 Rollback Plan

```sql
-- Migration: 000023_staking_system.down.sql

BEGIN;

DROP TABLE IF EXISTS exit_fee_distributions CASCADE;
DROP TABLE IF EXISTS cashback_ledger CASCADE;
DROP TABLE IF EXISTS staking_transactions CASCADE;
DROP TABLE IF EXISTS staking_events CASCADE;
DROP TABLE IF EXISTS staking_positions CASCADE;
DROP TABLE IF EXISTS fee_tier_config CASCADE;

DROP TYPE IF EXISTS staking_tx_status_enum;
DROP TYPE IF EXISTS staking_position_status_enum;
DROP TYPE IF EXISTS staking_event_type_enum;

COMMIT;
```

### 11.4 Feature Flags

```go
// internal/config/config.go

type StakingConfig struct {
    Enabled             bool     `mapstructure:"enabled"`
    AllowedWallets      []string `mapstructure:"allowedWallets"` // For beta
    CashbackEnabled     bool     `mapstructure:"cashbackEnabled"`
    ExitFeeDistribution bool     `mapstructure:"exitFeeDistribution"`
    ContractAddress     string   `mapstructure:"contractAddress"`
    ChainID             int64    `mapstructure:"chainId"`
}
```

---

## 12. Monitoring and Observability

### 12.1 Key Metrics

| Metric | Description | Alert Threshold |
|--------|-------------|-----------------|
| `staking_total_staked` | Total RNBW staked | N/A (gauge) |
| `staking_unique_stakers` | Number of unique stakers | N/A (gauge) |
| `staking_transactions_total` | Total transactions by type/status | Error rate > 5% |
| `staking_tx_duration_seconds` | Transaction confirmation time | p99 > 60s |
| `staking_cashback_accrued_total` | Total cashback accrued | N/A (counter) |
| `staking_exit_fees_collected_total` | Total exit fees collected | N/A (counter) |
| `staking_tier_distribution` | Stakers per tier | N/A (gauge) |
| `staking_api_requests_total` | API requests by endpoint | Error rate > 1% |

### 12.2 Dashboards

```yaml
# Grafana dashboard panels

staking_overview:
  - title: "Total Value Locked"
    query: staking_total_staked * rnbw_price_usd
  
  - title: "Unique Stakers"
    query: staking_unique_stakers

  - title: "Tier Distribution"
    query: staking_tier_distribution by tier

  - title: "24h Stake/Unstake Volume"
    query: rate(staking_transactions_total[24h]) by type

  - title: "Cashback Distributed (24h)"
    query: increase(staking_cashback_accrued_total[24h])

  - title: "Exit Fees Collected (24h)"
    query: increase(staking_exit_fees_collected_total[24h])

  - title: "Transaction Success Rate"
    query: |
      sum(rate(staking_transactions_total{status="confirmed"}[1h])) /
      sum(rate(staking_transactions_total[1h]))

  - title: "API Latency (p99)"
    query: histogram_quantile(0.99, staking_api_duration_seconds_bucket)
```

### 12.3 Alerts

```yaml
# Prometheus alerting rules

groups:
  - name: staking
    rules:
      - alert: StakingTransactionFailureRateHigh
        expr: |
          sum(rate(staking_transactions_total{status="failed"}[5m])) /
          sum(rate(staking_transactions_total[5m])) > 0.05
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Staking transaction failure rate > 5%"

      - alert: StakingContractBalanceMismatch
        expr: |
          abs(staking_contract_balance - staking_db_total_staked) > 1000e18
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Contract balance differs from DB by > 1000 RNBW"

      - alert: LargeUnstakeDetected
        expr: |
          staking_unstake_amount > 100000e18
        labels:
          severity: info
        annotations:
          summary: "Large unstake detected (> 100k RNBW)"

      - alert: StakingAPILatencyHigh
        expr: |
          histogram_quantile(0.99, staking_api_duration_seconds_bucket) > 2
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Staking API p99 latency > 2s"
```

### 12.4 Logging

```go
// Structured logging for staking operations

// Stake event
logger.Info("stake_completed",
    "wallet", walletAddress,
    "amount", amount.String(),
    "tx_hash", txHash,
    "new_tier", newTier,
    "duration_ms", duration.Milliseconds(),
)

// Unstake event
logger.Info("unstake_completed",
    "wallet", walletAddress,
    "amount", amount.String(),
    "exit_fee", exitFee.String(),
    "net_received", netReceived.String(),
    "tx_hash", txHash,
    "new_tier", newTier,
)

// Cashback accrual
logger.Info("cashback_accrued",
    "wallet", walletAddress,
    "source_type", sourceType,
    "source_event_id", sourceEventID,
    "fees_paid_usd", feesPaidUSD.String(),
    "cashback_bps", cashbackBps,
    "cashback_rnbw", cashbackRNBW.String(),
)

// Exit fee distribution
logger.Info("exit_fee_distributed",
    "source_tx", sourceTxID,
    "total_amount", totalAmount.String(),
    "recipient_count", recipientCount,
)
```

---

## 13. Appendix

### 13.1 Configuration Example

```yaml
# config/production.yaml

staking:
  enabled: true
  cashbackEnabled: true
  exitFeeDistribution: true
  
  contract:
    address: "0x..." # RNBWStaking contract
    chainId: 8453    # Base
    
  rnbwToken:
    address: "0xa53887f7e7c1bf5010b8627f1c1ba94fe7a5d6e0"
    decimals: 18
    chainId: 8453
    
  exitFeeBps: 1500  # 15%
  minStakeAmount: "1000000000000000000"  # 1 RNBW
  
  transactionPolling:
    maxAttempts: 25
    pollingIntervalSec: 2
    
  tierCache:
    ttlSeconds: 300  # 5 minutes
```

### 13.2 API Error Codes

| Code | Message | HTTP Status |
|------|---------|-------------|
| `INVALID_ADDRESS` | Invalid wallet address | 400 |
| `INVALID_AMOUNT` | Invalid staking amount | 400 |
| `INSUFFICIENT_BALANCE` | Insufficient RNBW balance | 400 |
| `BELOW_MINIMUM_STAKE` | Amount below minimum stake | 400 |
| `INSUFFICIENT_STAKE` | Unstake amount exceeds staked | 400 |
| `NO_POSITION` | No staking position found | 404 |
| `PENDING_TX_EXISTS` | Pending transaction exists | 409 |
| `TX_FAILED` | Transaction failed on-chain | 500 |
| `RELAY_ERROR` | Relay service error | 502 |

### 13.3 Open Questions

1. **Tier thresholds**: Final amounts TBD based on analysis
2. **Exit fee percentage**: 15% subject to change (options: cap it, or use lesser of 15% vs accrued fees)
3. **Grandfathering**: Policy for future tier changes
4. **Account-based staking**: Timeline for multi-wallet support
5. **LST compatibility**: Impact of liquid staking tokens
6. **Gas sponsorship**: Timeline for sponsored transactions

### 13.4 References

- [Synthetix Staking](https://github.com/Synthetixio/synthetix/blob/develop/contracts/StakingRewards.sol)
- [Curve Fee Distribution](https://github.com/curvefi/curve-dao-contracts/blob/master/contracts/FeeDistributor.vy)
- [Aave Safety Module](https://github.com/aave/aave-stake-v2)
- [OpenZeppelin AccessControl](https://docs.openzeppelin.com/contracts/4.x/access-control)
- [EIP-712](https://eips.ethereum.org/EIPS/eip-712)

---

**Document History:**

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2026-02-09 | Engineering | Initial draft |

