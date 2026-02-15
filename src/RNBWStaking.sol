// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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
 *      Cashback configuration is managed off-chain.
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
    uint256 public constant MIN_STAKE_FLOOR = 1e18; // 1 RNBW minimum floor for minStakeAmount
    uint256 public constant MAX_MIN_STAKE_AMOUNT = 1_000_000e18; // Upper bound for minStakeAmount
    uint256 public constant MAX_SIGNERS = 3; // Maximum number of trusted signers
    uint256 public constant MAX_BATCH_SIZE = 50;
    uint256 public constant MINIMUM_SHARES = 1000;
    address public constant DEAD_ADDRESS = address(0xdead);

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
    uint256 public cashbackReserve;

    mapping(address user => UserMeta meta) public userMeta;
    /// @dev Nonces for signature-based cashback allocation (prevents replay attacks).
    mapping(address user => mapping(uint256 nonce => bool used)) public usedNonces;
    mapping(address signer => bool trusted) internal _trustedSigners;
    uint256 public trustedSignerCount;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _rnbwToken The RNBW ERC20 token address
    /// @param _safe The admin multisig (Safe) address
    /// @param _initialSigner The first trusted EIP-712 signer for cashback operations
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
    /// @dev Contract must be pre-funded with RNBW via depositCashbackRewards().
    ///      Cashback is converted to shares immediately in a single step.
    function allocateCashbackWithSignature(
        address user,
        uint256 rnbwCashback,
        uint256 nonce,
        uint256 expiry,
        bytes calldata signature
    ) external nonReentrant whenNotPaused {
        _validateAndAllocateCashback(user, rnbwCashback, nonce, expiry, signature);
    }

    /// @inheritdoc IRNBWStaking
    function batchAllocateCashbackWithSignature(
        address[] calldata users,
        uint256[] calldata rnbwCashbacks,
        uint256[] calldata nonces,
        uint256[] calldata expiries,
        bytes[] calldata signatures
    ) external nonReentrant whenNotPaused {
        uint256 len = users.length;
        if (len > MAX_BATCH_SIZE) revert BatchTooLarge();
        if (len != rnbwCashbacks.length || len != nonces.length || len != expiries.length || len != signatures.length) {
            revert ArrayLengthMismatch();
        }

        uint256 totalCashback;
        for (uint256 i; i < len; ++i) {
            totalCashback += rnbwCashbacks[i];
        }
        if (totalCashback > cashbackReserve) revert InsufficientCashbackBalance();

        for (uint256 i; i < len; ++i) {
            _validateAndAllocateCashback(users[i], rnbwCashbacks[i], nonces[i], expiries[i], signatures[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRNBWStaking
    function getPosition(address user)
        external
        view
        returns (uint256 stakedAmount, uint256 userShares, uint256 lastUpdateTime, uint256 stakingStartTime)
    {
        UserMeta memory meta = userMeta[user];
        return (getRnbwForShares(shares[user]), shares[user], meta.lastUpdateTime, meta.stakingStartTime);
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
            uint256 balance = RNBW_TOKEN.balanceOf(address(this));
            uint256 reserved = totalPooledRnbw + cashbackReserve;
            uint256 excess = balance > reserved ? balance - reserved : 0;
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
        cashbackReserve += amount;
        emit CashbackRewardsDeposited(msg.sender, amount);
    }

    /// @inheritdoc IRNBWStaking
    function setMinStakeAmount(uint256 newMinStakeAmount) external onlySafe {
        if (newMinStakeAmount < MIN_STAKE_FLOOR) revert MinStakeTooLow();
        if (newMinStakeAmount > MAX_MIN_STAKE_AMOUNT) revert MinStakeTooHigh();
        if (newMinStakeAmount == minStakeAmount) revert NoChange();
        uint256 oldMinStakeAmount = minStakeAmount;
        minStakeAmount = newMinStakeAmount;
        emit MinStakeAmountUpdated(oldMinStakeAmount, newMinStakeAmount);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Validates signature and allocates cashback in one call (avoids stack-too-deep in batch)
    function _validateAndAllocateCashback(
        address user,
        uint256 rnbwCashback,
        uint256 nonce,
        uint256 expiry,
        bytes calldata signature
    ) internal {
        _validateSignature(
            user,
            nonce,
            expiry,
            keccak256(abi.encode(ALLOCATE_CASHBACK_TYPEHASH, user, rnbwCashback, nonce, expiry)),
            signature
        );
        _allocateCashback(user, rnbwCashback);
    }

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
    /// Flow: validate → transfer tokens → mint shares → update metadata
    function _stake(address user, uint256 amount) internal {
        // 1. Validate amount
        if (amount == 0) revert ZeroAmount();
        if (shares[user] == 0 && amount < minStakeAmount) {
            revert BelowMinimumStake();
        }

        // 2. Transfer RNBW tokens from user to contract
        RNBW_TOKEN.safeTransferFrom(user, address(this), amount);

        // 3. Calculate shares to mint based on current exchange rate
        //    Formula: sharesToMint = (amount * totalShares) / totalPooledRnbw
        //    First staker: 1:1 ratio (shares = amount)
        uint256 sharesToMint;
        if (totalShares == 0) {
            sharesToMint = amount - MINIMUM_SHARES;
            shares[DEAD_ADDRESS] += MINIMUM_SHARES;
            totalShares += MINIMUM_SHARES;
        } else {
            sharesToMint = (amount * totalShares) / totalPooledRnbw;
        }

        // 4. Prevent share inflation attack: if exchange rate is so high that
        //    the deposit rounds to 0 shares, revert to protect the depositor.
        //    Without this, the depositor's RNBW would be absorbed into the pool
        //    with no shares minted, effectively donating to existing stakers.
        if (sharesToMint == 0) revert ZeroSharesMinted();

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
    /// Flow: validate → calculate value & fee → burn shares → transfer net amount
    /// Exit fee stays in pool, increasing exchange rate for remaining stakers
    function _unstake(address user, uint256 sharesToBurn) internal {
        // 1. Validate request
        if (sharesToBurn == 0) revert ZeroAmount();
        if (shares[user] == 0) revert NoStakePosition();
        if (shares[user] < sharesToBurn) revert InsufficientShares();

        // 2. Calculate RNBW value of shares at current exchange rate
        //    Formula: rnbwValue = (sharesToBurn * totalPooledRnbw) / totalShares
        uint256 rnbwValue = (sharesToBurn * totalPooledRnbw) / totalShares;

        // 3. Calculate exit fee (e.g., 15% of value)
        //    Rounds up to ensure fractional wei always favors the protocol
        //    (user pays at most 1 wei more, protocol is never short-changed).
        uint256 exitFee = Math.mulDiv(rnbwValue, exitFeeBps, BASIS_POINTS, Math.Rounding.Ceil);
        uint256 netAmount = rnbwValue - exitFee;

        // 4. Burn user's shares and update global totals
        //    NOTE: Exit fee stays in pool (totalPooledRnbw only decreases by netAmount)
        //    This increases exchange rate for remaining stakers
        shares[user] -= sharesToBurn;
        totalShares -= sharesToBurn;
        totalPooledRnbw -= netAmount; // exitFee remains in pool!

        // 5. Reset totalPooledRnbw when all shares are burned to prevent
        //    share inflation attack. Without this, orphaned exit-fee RNBW
        //    would remain in totalPooledRnbw while totalShares == 0.
        //    The next staker would hit the `totalShares == 0` branch (1:1 minting)
        //    but totalPooledRnbw += amount would stack on top of the orphaned dust,
        //    creating an accounting desync where the pool has more RNBW than shares
        //    represent. We sweep residual dust to the safe so the invariant
        //    `totalShares == 0 ⟹ totalPooledRnbw == 0` always holds.
        uint256 residual;
        if (totalShares == MINIMUM_SHARES && totalPooledRnbw > 0) {
            residual = totalPooledRnbw;
            totalPooledRnbw = 0;
            shares[DEAD_ADDRESS] = 0;
            totalShares = 0;
        }

        // 6. Update user metadata
        UserMeta storage meta = userMeta[user];
        meta.lastUpdateTime = block.timestamp;
        if (shares[user] == 0) {
            meta.stakingStartTime = 0;
        }

        // 7. Transfer net RNBW to user (after exit fee deduction)
        RNBW_TOKEN.safeTransfer(user, netAmount);

        // 8. Sweep residual dust to safe (done after user transfer to keep
        //    reentrancy surface minimal and state fully settled first)
        if (residual > 0) {
            RNBW_TOKEN.safeTransfer(safe, residual);
        }

        // 9. Emit events
        emit Unstaked(user, sharesToBurn, rnbwValue, exitFee, netAmount);
        emit ExchangeRateUpdated(totalPooledRnbw, totalShares);
    }

    /// @dev Allocates cashback by minting shares directly in one step.
    ///      Contract must be pre-funded with RNBW via depositCashbackRewards().
    ///      Reverts if cashback is too small to mint at least 1 share (backend should batch).
    function _allocateCashback(address user, uint256 rnbwCashback) internal {
        // 1. Validate
        if (rnbwCashback == 0) revert ZeroAmount();
        if (shares[user] == 0) revert NoStakePosition();

        // 2. Verify cashback reserve has enough RNBW to cover this allocation
        if (rnbwCashback > cashbackReserve) {
            revert InsufficientCashbackBalance();
        }

        // 3. Calculate shares to mint at the current exchange rate
        uint256 sharesToMint;
        if (totalShares == 0) {
            sharesToMint = rnbwCashback;
        } else {
            sharesToMint = (rnbwCashback * totalShares) / totalPooledRnbw;
        }

        // 4. Revert if cashback is too small to mint shares — backend should
        //    batch small amounts or retry when the exchange rate is more favorable
        if (sharesToMint == 0) revert ZeroSharesMinted();

        // 5. Mint shares and move cashback RNBW from reserve into the pool
        shares[user] += sharesToMint;
        totalShares += sharesToMint;
        totalPooledRnbw += rnbwCashback;
        cashbackReserve -= rnbwCashback;

        // 6. Update metadata
        userMeta[user].lastUpdateTime = block.timestamp;

        // 7. Emit events
        emit CashbackAllocated(user, rnbwCashback, sharesToMint);
        emit ExchangeRateUpdated(totalPooledRnbw, totalShares);
    }
}
