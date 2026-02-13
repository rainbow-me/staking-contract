# RNBWStaking

Shares-based staking contract for **$RNBW** on Base. Exit fees stay in the pool and automatically increase the exchange rate for remaining stakers (same model as Lido/Compound). Positions are non-transferable.

- **Chain:** Base (EVM)
- **Solidity:** 0.8.24
- **Framework:** Foundry
- **Dependencies:** OpenZeppelin Contracts

## Key Mechanics

| Feature | Details |
|---------|---------|
| Staking | `stake()` (direct) or `stakeWithSignature()` (relayer/backend) |
| Unstaking | `unstake()` (direct) or `unstakeWithSignature()` (relayer/backend) |
| Exit fee | Configurable 1%–75%, default 15% — stays in pool |
| Cashback | Backend allocates via `allocateCashbackWithSignature()`, auto-compounds on next action |
| Access control | Safe (multisig) for admin ops, up to 3 trusted EIP-712 signers |
| Signatures | EIP-712 with expiry + nonce replay protection |

## Build

```shell
forge build
```

## Test

```shell
forge test
```

59 tests across two suites: unit tests (`RNBWStaking.t.sol`) and simulation tests (`RNBWStakingSimulation.t.sol`).

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

## Security

security@rainbow.me
