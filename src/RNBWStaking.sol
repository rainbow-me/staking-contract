// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {IRNBWStaking} from "./interfaces/IRNBWStaking.sol";

/**
 * @title RNBWStaking
 * @author Rainbow Team
 * @notice Staking contract for $RNBW with exit fees using shares-based model
 * @dev Uses exchange rate model for automatic exit fee distribution:
 *      - Users receive "shares" when staking, not 1:1 RNBW
 *      - Exit fees stay in pool, increasing exchange rate for all stakers
 *      - No batch distribution needed - O(1) gas for any number of stakers
 *
 *      Tier configuration is managed off-chain.
 *      Staked positions are NOT transferable (locked staking).
 * @custom:security-contact security@rainbow.me
 */
contract RNBWStaking is IRNBWStaking, ReentrancyGuard, Pausable, EIP712 {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant BASIS_POINTS = 10_000; // 100% in basis points
    uint256 public constant MIN_EXIT_FEE_BPS = 100; // 1% minimum exit fee
    uint256 public constant MAX_EXIT_FEE_BPS = 7500; // 75% maximum exit fee
    uint256 public constant MAX_MIN_STAKE_AMOUNT = 1_000_000e18; // Upper bound for minStakeAmount
    uint256 public constant MAX_SIGNERS = 3; // Maximum number of trusted signers

    bytes32 public constant STAKE_TYPEHASH =
        keccak256("Stake(address user,uint256 amount,uint256 nonce,uint256 expiry)");
    bytes32 public constant UNSTAKE_TYPEHASH =
        keccak256("Unstake(address user,uint256 amount,uint256 nonce,uint256 expiry)");
    bytes32 public constant COMPOUND_TYPEHASH = keccak256("Compound(address user,uint256 nonce,uint256 expiry)");
    bytes32 public constant ALLOCATE_CASHBACK_TYPEHASH =
        keccak256("AllocateCashback(address user,uint256 rnbwCashback,uint256 nonce,uint256 expiry)");

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    IERC20 public immutable RNBW_TOKEN;

    address public safe;
    uint256 public exitFeeBps;
    uint256 public minStakeAmount;

    mapping(address user => uint256 shareBalance) public shares;
    uint256 public totalShares;
    uint256 public totalPooledRnbw;
    uint256 public totalAllocatedCashback;

    mapping(address user => UserMeta meta) public userMeta;
    /// @dev Nonces are shared across all signature-based operations (stake, unstake, compound, cashback).
    /// A nonce used by one operation cannot be reused by another, even for a different action type.
    mapping(address user => mapping(uint256 nonce => bool used)) public usedNonces;
    mapping(address signer => bool trusted) internal _trustedSigners;
    uint256 public trustedSignerCount;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _rnbwToken, address _safe, address _initialSigner) EIP712("RNBWStaking", "1") {
        if (_rnbwToken == address(0)) revert ZeroAddress();
        if (_safe == address(0)) revert ZeroAddress();
        if (_initialSigner == address(0)) revert ZeroAddress();

        RNBW_TOKEN = IERC20(_rnbwToken);
        safe = _safe;

        exitFeeBps = 1500;
        minStakeAmount = 1e18;

        _trustedSigners[_initialSigner] = true;
        trustedSignerCount = 1;
        emit SignerAdded(_initialSigner);
    }

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlySafe() {
        _checkSafe();
        _;
    }

    function _checkSafe() internal view {
        if (msg.sender != safe) revert Unauthorized();
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRNBWStaking
    function stake(uint256 amount) external nonReentrant whenNotPaused {
        _stake(msg.sender, amount);
    }

    /// @inheritdoc IRNBWStaking
    function unstake(uint256 sharesToBurn) external nonReentrant whenNotPaused {
        _unstake(msg.sender, sharesToBurn);
    }

    /// @inheritdoc IRNBWStaking
    function stakeWithSignature(address user, uint256 amount, uint256 nonce, uint256 expiry, bytes calldata signature)
        external
        nonReentrant
        whenNotPaused
    {
        _validateSignature(
            user, nonce, expiry, keccak256(abi.encode(STAKE_TYPEHASH, user, amount, nonce, expiry)), signature
        );
        _stake(user, amount);
    }

    /// @inheritdoc IRNBWStaking
    function unstakeWithSignature(
        address user,
        uint256 sharesToBurn,
        uint256 nonce,
        uint256 expiry,
        bytes calldata signature
    ) external nonReentrant whenNotPaused {
        _validateSignature(
            user, nonce, expiry, keccak256(abi.encode(UNSTAKE_TYPEHASH, user, sharesToBurn, nonce, expiry)), signature
        );
        _unstake(user, sharesToBurn);
    }

    /// @inheritdoc IRNBWStaking
    function compoundWithSignature(address user, uint256 nonce, uint256 expiry, bytes calldata signature)
        external
        nonReentrant
        whenNotPaused
    {
        _validateSignature(
            user, nonce, expiry, keccak256(abi.encode(COMPOUND_TYPEHASH, user, nonce, expiry)), signature
        );

        uint256 compounded = _compoundCashback(user);
        if (compounded == 0) revert NothingToCompound();
    }

    /// @inheritdoc IRNBWStaking
    /// @dev Contract must be pre-funded with RNBW for cashback rewards
    function allocateCashbackWithSignature(
        address user,
        uint256 rnbwCashback,
        uint256 nonce,
        uint256 expiry,
        bytes calldata signature
    ) external nonReentrant whenNotPaused {
        _validateSignature(
            user,
            nonce,
            expiry,
            keccak256(abi.encode(ALLOCATE_CASHBACK_TYPEHASH, user, rnbwCashback, nonce, expiry)),
            signature
        );

        _allocateCashback(user, rnbwCashback);
    }

    /// @dev Allocates cashback RNBW to user's pending balance
    /// Cashback is compounded into shares on next stake/unstake/compound action
    /// Contract must be pre-funded with sufficient RNBW for cashback rewards
    function _allocateCashback(address user, uint256 rnbwCashback) internal {
        if (shares[user] == 0) revert NoStakePosition();

        uint256 requiredBalance = totalPooledRnbw + totalAllocatedCashback + rnbwCashback;
        if (RNBW_TOKEN.balanceOf(address(this)) < requiredBalance) {
            revert InsufficientCashbackBalance();
        }

        totalAllocatedCashback += rnbwCashback;
        userMeta[user].cashbackAllocated += rnbwCashback;
        userMeta[user].lastUpdateTime = block.timestamp;

        emit CashbackAllocated(user, rnbwCashback);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRNBWStaking
    function getPosition(address user)
        external
        view
        returns (
            uint256 stakedAmount,
            uint256 userShares,
            uint256 cashbackAllocated,
            uint256 lastUpdateTime,
            uint256 stakingStartTime
        )
    {
        UserMeta memory meta = userMeta[user];
        return (
            getRnbwForShares(shares[user]),
            shares[user],
            meta.cashbackAllocated,
            meta.lastUpdateTime,
            meta.stakingStartTime
        );
    }

    /// @inheritdoc IRNBWStaking
    function getRnbwForShares(uint256 sharesAmount) public view returns (uint256) {
        if (totalShares == 0) return 0;
        return (sharesAmount * totalPooledRnbw) / totalShares;
    }

    /// @inheritdoc IRNBWStaking
    function getSharesForRnbw(uint256 rnbwAmount) public view returns (uint256) {
        if (totalPooledRnbw == 0) return rnbwAmount;
        return (rnbwAmount * totalShares) / totalPooledRnbw;
    }

    /// @inheritdoc IRNBWStaking
    function getExchangeRate() external view returns (uint256) {
        if (totalShares == 0) return 1e18;
        return (totalPooledRnbw * 1e18) / totalShares;
    }

    /// @inheritdoc IRNBWStaking
    function isNonceUsed(address user, uint256 nonce) external view returns (bool) {
        return usedNonces[user][nonce];
    }

    /// @inheritdoc IRNBWStaking
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRNBWStaking
    function addTrustedSigner(address signer) external onlySafe {
        if (signer == address(0)) revert ZeroAddress();
        if (_trustedSigners[signer]) revert SignerAlreadyAdded();
        if (trustedSignerCount >= MAX_SIGNERS) revert MaxSignersReached();

        _trustedSigners[signer] = true;
        ++trustedSignerCount;
        emit SignerAdded(signer);
    }

    /// @inheritdoc IRNBWStaking
    function removeTrustedSigner(address signer) external onlySafe {
        if (!_trustedSigners[signer]) revert SignerNotFound();
        if (trustedSignerCount <= 1) revert CannotRemoveLastSigner();

        _trustedSigners[signer] = false;
        --trustedSignerCount;
        emit SignerRemoved(signer);
    }

    /// @inheritdoc IRNBWStaking
    function isTrustedSigner(address signer) external view returns (bool) {
        return _trustedSigners[signer];
    }

    /// @inheritdoc IRNBWStaking
    function pause() external onlySafe {
        _pause();
    }

    /// @inheritdoc IRNBWStaking
    function unpause() external onlySafe {
        _unpause();
    }

    /// @inheritdoc IRNBWStaking
    function emergencyWithdraw(address token, uint256 amount) external onlySafe {
        if (token == address(RNBW_TOKEN)) {
            uint256 obligated = totalPooledRnbw + totalAllocatedCashback;
            uint256 balance = RNBW_TOKEN.balanceOf(address(this));
            uint256 excess = balance > obligated ? balance - obligated : 0;
            if (amount > excess) revert InsufficientExcess();
        }
        IERC20(token).safeTransfer(safe, amount);
    }

    /// @inheritdoc IRNBWStaking
    function setSafe(address newSafe) external onlySafe {
        if (newSafe == address(0)) revert ZeroAddress();
        emit SafeUpdated(safe, newSafe);
        safe = newSafe;
    }

    /// @inheritdoc IRNBWStaking
    function setExitFeeBps(uint256 newExitFeeBps) external onlySafe {
        if (newExitFeeBps < MIN_EXIT_FEE_BPS) revert ExitFeeTooLow();
        if (newExitFeeBps > MAX_EXIT_FEE_BPS) revert ExitFeeTooHigh();
        if (newExitFeeBps == exitFeeBps) revert NoChange();
        uint256 oldExitFeeBps = exitFeeBps;
        exitFeeBps = newExitFeeBps;
        emit ExitFeeBpsUpdated(oldExitFeeBps, newExitFeeBps);
    }

    /// @inheritdoc IRNBWStaking
    function depositCashbackRewards(uint256 amount) external onlySafe {
        if (amount == 0) revert ZeroAmount();
        RNBW_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        emit CashbackRewardsDeposited(msg.sender, amount);
    }

    /// @inheritdoc IRNBWStaking
    function setMinStakeAmount(uint256 newMinStakeAmount) external onlySafe {
        if (newMinStakeAmount > MAX_MIN_STAKE_AMOUNT) revert MinStakeTooHigh();
        if (newMinStakeAmount == minStakeAmount) revert NoChange();
        uint256 oldMinStakeAmount = minStakeAmount;
        minStakeAmount = newMinStakeAmount;
        emit MinStakeAmountUpdated(oldMinStakeAmount, newMinStakeAmount);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Validates EIP-712 signature for relayer operations
    function _validateSignature(
        address user,
        uint256 nonce,
        uint256 expiry,
        bytes32 structHash,
        bytes calldata signature
    ) internal {
        // 1. Check signature hasn't expired
        if (block.timestamp > expiry) revert SignatureExpired();

        // 2. Check nonce hasn't been used (prevents replay attacks)
        if (usedNonces[user][nonce]) revert NonceAlreadyUsed();

        // 3. Recover signer from EIP-712 typed data hash
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);

        // 4. Verify signer is trusted
        if (!_trustedSigners[signer]) revert InvalidSignature();

        // 5. Mark nonce as used
        usedNonces[user][nonce] = true;
    }

    /// @dev Core staking logic
    /// Flow: validate → compound pending cashback → transfer tokens → mint shares → update metadata
    function _stake(address user, uint256 amount) internal {
        // 1. Validate amount
        if (amount == 0) revert ZeroAmount();
        if (shares[user] == 0 && amount < minStakeAmount) {
            revert BelowMinimumStake();
        }

        // 2. Auto-compound any pending cashback for THIS user before staking
        //    This converts cashbackAllocated → shares at current exchange rate
        _compoundCashback(user);

        // 3. Transfer RNBW tokens from user to contract
        RNBW_TOKEN.safeTransferFrom(user, address(this), amount);

        // 4. Calculate shares to mint based on current exchange rate
        //    Formula: sharesToMint = (amount * totalShares) / totalPooledRnbw
        //    First staker: 1:1 ratio (shares = amount)
        uint256 sharesToMint;
        if (totalShares == 0) {
            sharesToMint = amount;
        } else {
            sharesToMint = (amount * totalShares) / totalPooledRnbw;
        }

        // 5. Update user's share balance and global totals
        shares[user] += sharesToMint;
        totalShares += sharesToMint;
        totalPooledRnbw += amount;

        // 6. Update user metadata (timestamps)
        UserMeta storage meta = userMeta[user];
        if (meta.stakingStartTime == 0) {
            meta.stakingStartTime = block.timestamp;
        }
        meta.lastUpdateTime = block.timestamp;

        // 7. Emit events
        emit Staked(user, amount, sharesToMint, shares[user]);
        emit ExchangeRateUpdated(totalPooledRnbw, totalShares);
    }

    /// @dev Core unstaking logic
    /// Flow: validate → compound → calculate value & fee → burn shares → transfer net amount
    /// Exit fee stays in pool, increasing exchange rate for remaining stakers
    function _unstake(address user, uint256 sharesToBurn) internal {
        // 1. Validate request
        if (sharesToBurn == 0) revert ZeroAmount();
        if (shares[user] == 0) revert NoStakePosition();
        if (shares[user] < sharesToBurn) revert InsufficientShares();

        // 2. Auto-compound any pending cashback for THIS user before unstaking
        _compoundCashback(user);

        // 3. Calculate RNBW value of shares at current exchange rate
        //    Formula: rnbwValue = (sharesToBurn * totalPooledRnbw) / totalShares
        uint256 rnbwValue = (sharesToBurn * totalPooledRnbw) / totalShares;

        // 4. Calculate exit fee (e.g., 15% of value)
        uint256 exitFee = (rnbwValue * exitFeeBps) / BASIS_POINTS;
        uint256 netAmount = rnbwValue - exitFee;

        // 5. Burn user's shares and update global totals
        //    NOTE: Exit fee stays in pool (totalPooledRnbw only decreases by netAmount)
        //    This increases exchange rate for remaining stakers
        shares[user] -= sharesToBurn;
        totalShares -= sharesToBurn;
        totalPooledRnbw -= netAmount; // exitFee remains in pool!

        // 6. Reset totalPooledRnbw when all shares are burned to prevent
        //    share inflation attack. Without this, orphaned exit-fee RNBW
        //    would remain in totalPooledRnbw while totalShares == 0.
        //    The next staker would hit the `totalShares == 0` branch (1:1 minting)
        //    but totalPooledRnbw += amount would stack on top of the orphaned dust,
        //    creating an accounting desync where the pool has more RNBW than shares
        //    represent. We sweep residual dust to the safe so the invariant
        //    `totalShares == 0 ⟹ totalPooledRnbw == 0` always holds.
        uint256 residual;
        if (totalShares == 0 && totalPooledRnbw > 0) {
            residual = totalPooledRnbw;
            totalPooledRnbw = 0;
        }

        // 7. Update user metadata
        UserMeta storage meta = userMeta[user];
        meta.lastUpdateTime = block.timestamp;
        if (shares[user] == 0) {
            meta.stakingStartTime = 0;
        }

        // 8. Transfer net RNBW to user (after exit fee deduction)
        RNBW_TOKEN.safeTransfer(user, netAmount);

        // 9. Sweep residual dust to safe (done after user transfer to keep
        //    reentrancy surface minimal and state fully settled first)
        if (residual > 0) {
            RNBW_TOKEN.safeTransfer(safe, residual);
        }

        // 10. Emit events
        emit Unstaked(user, sharesToBurn, rnbwValue, exitFee, netAmount);
        emit ExchangeRateUpdated(totalPooledRnbw, totalShares);
    }

    /// @dev Converts user's pending cashback into shares
    /// Called automatically on stake/unstake, or manually via compoundWithSignature
    /// Only affects THIS user's cashback - other users' cashback remains pending
    function _compoundCashback(address user) internal returns (uint256) {
        // 1. Read user's pending cashback
        UserMeta storage meta = userMeta[user];
        uint256 cashback = meta.cashbackAllocated;

        if (cashback > 0) {
            // 2. Reset pending cashback to 0 and update global tracking
            meta.cashbackAllocated = 0;
            totalAllocatedCashback -= cashback;

            // 3. Calculate shares to mint for this cashback amount
            //    Uses same formula as staking
            uint256 sharesToMint;
            if (totalShares == 0) {
                sharesToMint = cashback;
            } else {
                sharesToMint = (cashback * totalShares) / totalPooledRnbw;
            }

            // 4. If cashback is too small to mint shares at the current rate,
            //    restore it so the user retains it for a future compound
            //    without blocking stake/unstake operations
            if (sharesToMint == 0) {
                meta.cashbackAllocated = cashback;
                totalAllocatedCashback += cashback;
                return 0;
            }

            // 5. Mint shares to user and update global totals
            //    NOTE: No token transfer needed - RNBW is pre-funded in contract
            shares[user] += sharesToMint;
            totalShares += sharesToMint;
            totalPooledRnbw += cashback;

            // 6. Emit events
            emit CashbackCompounded(user, cashback, sharesToMint);
            emit ExchangeRateUpdated(totalPooledRnbw, totalShares);
        }

        return cashback;
    }
}
