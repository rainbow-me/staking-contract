# Technical Specification: Offchain Rewards Computation & Drip System Review

## Difficulty: Medium (advisory/review — no contract code changes)

## Context
- **Language**: Solidity 0.8.24, Foundry project on Base
- **Contract**: `src/RNBWStaking.sol` — shares-based staking with exit fees and drip system
- **Branch**: `drip-system` — implements linear fee distribution over 7-day windows

## 1. Offchain Rewards Computation

### Exit Fee APY (pool-wide)
```
APY = (rateB / rateA) ^ (365.25 days / elapsed) - 1
```
- `rateA` = `getExchangeRate()` at window start block
- `rateB` = `getExchangeRate()` at current block
- Uses two on-chain snapshots, no contract changes needed

### Cashback APY (pool-wide)
```
APY = (deltaCashback / poolA) × (365.25 days / elapsed)
```
- `deltaCashback` = `totalCashbackAllocated(B) - totalCashbackAllocated(A)`
- `poolA` = `totalPooledRnbw` at window start

### Per-Wallet APY
Uses TWAC (Time-Weighted Average Capital) approach documented in README:
- `netProfit = stakedAmount + totalUnstaked - totalStaked` (exact, on-chain)
- Reconstruct capital history from Staked/Unstaked/CashbackAllocated events
- Final open period should use `getPosition().stakedAmount`, not `shares × lastEventRate`
- Display guard recommended for durations < 7 days (noisy annualized values)

## 2. Drip System Validation

### Implementation: Correct
- `_syncPool()` and `_effectivePooledRnbw()` are consistent
- All 175 tests pass (unit + invariant + simulation)
- Emergency withdraw, residual sweep, and drip state transitions are correct

### Known Issue: `_addFees()` Griefing
Current implementation resets `dripEndTime` on every unstake, enabling micro-unstake griefing.

### Recommended Fix (OpenZeppelin proposal — validated correct)
```solidity
function _addFees(uint256 amount) internal {
    if (amount == 0) return;
    undistributedFees += amount;

    if (block.timestamp >= dripEndTime) {
        rewardRate = undistributedFees / dripDuration;
        dripEndTime = block.timestamp + dripDuration;
    } else {
        uint256 proposedRate = undistributedFees / dripDuration;
        if (proposedRate >= rewardRate) {
            rewardRate = proposedRate;
            dripEndTime = block.timestamp + dripDuration;
        } else {
            dripEndTime = block.timestamp + (undistributedFees / rewardRate);
        }
    }
}
```

**Properties verified:**
- No division by zero (rewardRate=0 always takes the if branch)
- dripEndTime monotonically non-decreasing
- Fee conservation maintained (cliff flush catches dust)
- Rate monotonicity: can only increase or stay the same during active drip
- Micro-unstake extends window by < 1 second (economically irrational to grief)

## 3. Risk Assessment Summary

| # | Risk | Verdict |
|---|------|---------|
| 1 | _addFees griefing via micro-unstake | Real — fix above recommended |
| 2 | Pool empties during drip | Not a bug — sweep fires only when no real stakers remain |
| 3 | rewardRate precision drift | Not a bug — remainder tracked in undistributedFees, flushed at cliff |
| 4 | previewStake/mintShares inconsistency | Minor UI issue — previewStake uses _effectivePooledRnbw but _mintShares uses raw totalPooledRnbw |

## 4. No Implementation Required
This task is advisory. No source code changes are being made — the drip-system branch already contains the implementation. The `_addFees` fix should be applied by the contract team.
