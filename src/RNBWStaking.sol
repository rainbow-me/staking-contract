// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IRNBWStaking} from "./interfaces/IRNBWStaking.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title RNBWStaking
 * @author Rainbow Team
 * @notice Staking contract for $RNBW with exit fees using shares-based model
 * @dev Uses exchange rate model with linear fee drip for exit fee distribution:
 *      - Users receive "shares" when staking, not 1:1 RNBW
 *      - Exit fees are buffered in undistributedFees and dripped linearly into
 *        the pool over dripDuration (default 7 days, configurable 1–60 days), producing a smooth exchange rate
 *        curve and preventing whale self-absorption / APY manipulation attacks
 *      - Dead shares (MINIMUM_SHARES = 1000 → DEAD_ADDRESS) prevent the
 *        share inflation / first-depositor attack
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
    uint256 public constant MIN_SHARES_THRESHOLD = 1e14;
    address public constant DEAD_ADDRESS = address(0xdead);
    uint256 public constant MIN_DRIP_DURATION = 1 days;
    uint256 public constant MAX_DRIP_DURATION = 60 days;

    bytes32 public constant ALLOCATE_CASHBACK_TYPEHASH =
        keccak256("AllocateCashback(address user,uint256 rnbwCashback,uint256 nonce,uint256 expiry)");

    bytes32 public constant STAKE_FOR_TYPEHASH =
        keccak256("StakeFor(address recipient,uint256 amount,uint256 nonce,uint256 expiry)");

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    IERC20 public immutable RNBW_TOKEN;

    // --- Admin ---
    address public safe;
    address public pendingSafe;
    uint256 public exitFeeBps;
    uint256 public minStakeAmount;
    bool public allowPartialUnstake;

    // --- Pool ---
    mapping(address => uint256) public shares;
    uint256 public totalShares;
    uint256 public totalPooledRnbw;
    uint256 public cashbackReserve;
    uint256 public totalCashbackAllocated;
    uint256 public stakingReserve;

    // --- Fee Drip ---
    uint256 public dripDuration;
    uint256 public undistributedFees;
    uint256 public rewardRate;
    uint256 public lastSyncTime;
    uint256 public dripEndTime;

    // --- Users ---
    mapping(address => UserMeta) public userMeta;
    mapping(address => mapping(uint256 => bool)) public usedNonces;

    // --- Signers ---
    mapping(address => bool) internal _trustedSigners;
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

        exitFeeBps = 1000;
        minStakeAmount = 1e18;
        allowPartialUnstake = false;
        dripDuration = 7 days;

        lastSyncTime = block.timestamp;

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
        _syncPool();
        _stake(msg.sender, msg.sender, amount);
    }

    /// @inheritdoc IRNBWStaking
    function stakeFor(address recipient, uint256 amount) external nonReentrant whenNotPaused {
        if (recipient == address(0)) revert ZeroAddress();
        if (recipient == address(this) || recipient == DEAD_ADDRESS) revert InvalidRecipient();
        _syncPool();
        _stake(msg.sender, recipient, amount);
    }

    /// @inheritdoc IRNBWStaking
    function stakeForWithSignature(
        address recipient,
        uint256 amount,
        uint256 nonce,
        uint256 expiry,
        bytes calldata signature
    ) external nonReentrant whenNotPaused {
        if (recipient == address(0)) revert ZeroAddress();
        if (recipient == address(this) || recipient == DEAD_ADDRESS) revert InvalidRecipient();
        _syncPool();
        _validateSignature(
            recipient,
            nonce,
            expiry,
            keccak256(abi.encode(STAKE_FOR_TYPEHASH, recipient, amount, nonce, expiry)),
            signature
        );
        _stakeFromReserve(recipient, amount);
    }

    /// @inheritdoc IRNBWStaking
    function unstake(uint256 sharesToBurn) external nonReentrant whenNotPaused returns (uint256 netAmount) {
        _syncPool();
        netAmount = _unstake(msg.sender, sharesToBurn);
    }

    /// @inheritdoc IRNBWStaking
    function unstakeAll() external nonReentrant whenNotPaused returns (uint256 netAmount) {
        _syncPool();
        netAmount = _unstake(msg.sender, shares[msg.sender]);
    }

    /// @inheritdoc IRNBWStaking
    /// @dev Contract must be pre-funded with RNBW via fundCashbackReserve().
    ///      Cashback is converted to shares immediately in a single step.
    function allocateCashbackWithSignature(
        address user,
        uint256 rnbwCashback,
        uint256 nonce,
        uint256 expiry,
        bytes calldata signature
    ) external nonReentrant whenNotPaused {
        _syncPool();
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
        if (len == 0) revert EmptyBatch();
        if (len > MAX_BATCH_SIZE) revert BatchTooLarge();
        if (len != rnbwCashbacks.length || len != nonces.length || len != expiries.length || len != signatures.length) {
            revert ArrayLengthMismatch();
        }

        uint256 totalCashback;
        for (uint256 i; i < len; ++i) {
            totalCashback += rnbwCashbacks[i];
        }
        if (totalCashback > cashbackReserve) revert InsufficientCashbackBalance();

        _syncPool();
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
        returns (
            uint256 stakedAmount,
            uint256 userShares,
            uint256 lastUpdateTime,
            uint256 stakingStartTime,
            uint256 totalCashbackReceived,
            uint256 totalRnbwStaked,
            uint256 totalRnbwUnstaked,
            uint256 totalExitFeePaid
        )
    {
        UserMeta memory meta = userMeta[user];
        return (
            getRnbwForShares(shares[user]),
            shares[user],
            meta.lastUpdateTime,
            meta.stakingStartTime,
            meta.totalCashbackReceived,
            meta.totalRnbwStaked,
            meta.totalRnbwUnstaked,
            meta.totalExitFeePaid
        );
    }

    /// @inheritdoc IRNBWStaking
    function getRnbwForShares(uint256 sharesAmount) public view returns (uint256) {
        if (totalShares == 0) return 0;
        return (sharesAmount * _effectivePooledRnbw()) / totalShares;
    }

    /// @inheritdoc IRNBWStaking
    function getSharesForRnbw(uint256 rnbwAmount) public view returns (uint256) {
        if (totalShares == 0) {
            return rnbwAmount <= MINIMUM_SHARES ? 0 : rnbwAmount - MINIMUM_SHARES;
        }
        return (rnbwAmount * totalShares) / _effectivePooledRnbw();
    }

    /// @inheritdoc IRNBWStaking
    function getExchangeRate() external view returns (uint256) {
        if (totalShares == 0) return 1e18;
        return (_effectivePooledRnbw() * 1e18) / totalShares;
    }

    /// @inheritdoc IRNBWStaking
    function previewUnstake(uint256 sharesToBurn)
        external
        view
        returns (uint256 rnbwValue, uint256 exitFee, uint256 netReceived)
    {
        rnbwValue = getRnbwForShares(sharesToBurn);
        exitFee = Math.mulDiv(rnbwValue, exitFeeBps, BASIS_POINTS, Math.Rounding.Ceil);
        netReceived = exitFee >= rnbwValue ? 0 : rnbwValue - exitFee;
    }

    /// @inheritdoc IRNBWStaking
    function previewStake(address user, uint256 amount) external view returns (uint256 sharesToMint) {
        if (shares[user] == 0 && amount < minStakeAmount) return 0;
        return getSharesForRnbw(amount);
    }

    /// @inheritdoc IRNBWStaking
    function isNonceUsed(address user, uint256 nonce) public view returns (bool) {
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
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (token == address(RNBW_TOKEN)) {
            uint256 balance = RNBW_TOKEN.balanceOf(address(this));
            uint256 reserved = totalPooledRnbw + cashbackReserve + stakingReserve + undistributedFees;
            uint256 excess = balance > reserved ? balance - reserved : 0;
            if (excess == 0) revert InsufficientExcess();
            amount = amount > excess ? excess : amount;
        }
        IERC20(token).safeTransfer(safe, amount);
        emit EmergencyWithdrawn(token, amount);
    }

    /// @inheritdoc IRNBWStaking
    function proposeSafe(address newSafe) external onlySafe {
        if (newSafe == address(0)) revert ZeroAddress();
        if (newSafe == safe) revert NoChange();
        if (pendingSafe != address(0)) {
            emit SafeProposalCancelled(safe, pendingSafe);
        }
        pendingSafe = newSafe;
        emit SafeProposed(safe, newSafe);
    }

    /// @inheritdoc IRNBWStaking
    function cancelProposedSafe() external onlySafe {
        if (pendingSafe == address(0)) revert NoPendingSafe();
        address cancelled = pendingSafe;
        pendingSafe = address(0);
        emit SafeProposalCancelled(safe, cancelled);
    }

    /// @inheritdoc IRNBWStaking
    function acceptSafe() external {
        if (pendingSafe == address(0)) revert NoPendingSafe();
        if (msg.sender != pendingSafe) revert NotPendingSafe();
        emit SafeUpdated(safe, msg.sender);
        safe = msg.sender;
        pendingSafe = address(0);
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
    function fundCashbackReserve(uint256 amount) external onlySafe {
        if (amount == 0) revert ZeroAmount();
        RNBW_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        cashbackReserve += amount;
        emit CashbackReserveFunded(msg.sender, amount, cashbackReserve);
    }

    /// @inheritdoc IRNBWStaking
    function fundStakingReserve(uint256 amount) external onlySafe {
        if (amount == 0) revert ZeroAmount();
        RNBW_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        stakingReserve += amount;
        emit StakingReserveFunded(msg.sender, amount, stakingReserve);
    }

    /// @inheritdoc IRNBWStaking
    function defundStakingReserve(uint256 amount) external onlySafe {
        if (amount == 0) revert ZeroAmount();
        if (amount > stakingReserve) revert InsufficientStakingBalance();
        stakingReserve -= amount;
        RNBW_TOKEN.safeTransfer(safe, amount);
        emit StakingReserveDefunded(safe, amount, stakingReserve);
    }

    /// @inheritdoc IRNBWStaking
    function defundCashbackReserve(uint256 amount) external onlySafe {
        if (amount == 0) revert ZeroAmount();
        if (amount > cashbackReserve) revert InsufficientCashbackBalance();
        cashbackReserve -= amount;
        RNBW_TOKEN.safeTransfer(safe, amount);
        emit CashbackReserveDefunded(safe, amount, cashbackReserve);
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

    /// @inheritdoc IRNBWStaking
    function setAllowPartialUnstake(bool allowed) external onlySafe {
        if (allowed == allowPartialUnstake) revert NoChange();
        allowPartialUnstake = allowed;
        emit PartialUnstakeToggled(allowed);
    }

    /// @inheritdoc IRNBWStaking
    function setDripDuration(uint256 newDripDuration) external onlySafe {
        if (newDripDuration < MIN_DRIP_DURATION) revert DripDurationTooLow();
        if (newDripDuration > MAX_DRIP_DURATION) revert DripDurationTooHigh();
        if (newDripDuration == dripDuration) revert NoChange();
        _syncPool();
        uint256 oldDripDuration = dripDuration;
        dripDuration = newDripDuration;
        if (undistributedFees > 0) {
            rewardRate = undistributedFees / newDripDuration;
            dripEndTime = block.timestamp + newDripDuration;
        }
        emit DripDurationUpdated(oldDripDuration, newDripDuration);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Settles any pending fee drip into totalPooledRnbw.
    ///      Called before every state-changing operation to ensure pool totals are current.
    function _syncPool() internal {
        // 1. No stakers — nothing to distribute to, just advance the clock
        if (totalShares == 0) {
            lastSyncTime = block.timestamp;
            return;
        }

        // 2. No pending fees — nothing to drip, just advance the clock
        if (undistributedFees == 0) {
            lastSyncTime = block.timestamp;
            return;
        }

        // 3. Drip window has fully elapsed — flush all remaining fees into the pool
        //    (avoids dust from integer division in rewardRate)
        if (block.timestamp >= dripEndTime) {
            totalPooledRnbw += undistributedFees;
            undistributedFees = 0;
            rewardRate = 0;
            dripEndTime = 0;
            emit ExchangeRateUpdated(totalPooledRnbw, totalShares);

            // 4. Mid-drip — distribute proportional amount based on elapsed time
            //    earned = elapsed * rewardRate (linear: constant RNBW per second)
        } else if (block.timestamp > lastSyncTime) {
            uint256 earned = (block.timestamp - lastSyncTime) * rewardRate;
            if (earned > undistributedFees) earned = undistributedFees;
            if (earned > 0) {
                totalPooledRnbw += earned;
                undistributedFees -= earned;
                emit ExchangeRateUpdated(totalPooledRnbw, totalShares);
            }
        }

        // 5. Advance the sync checkpoint so the next call only processes new elapsed time
        lastSyncTime = block.timestamp;
    }

    /// @dev Routes exit fees into the drip pipeline.
    ///      Must be called after _syncPool() so undistributedFees reflects settled state.
    ///      rewardRate can only stay flat or increase — never decrease (prevents dust
    ///      unstake griefing). When undistributedFees < dripDuration, rewardRate rounds
    ///      to 0 and fees flush as a cliff at dripEndTime.
    function _addFees(uint256 amount) internal {
        if (amount == 0) return;
        undistributedFees += amount;

        // Case 1: No drip is active — start a fresh drip cycle.
        //         e.g., first unstake after pool was idle, or previous drip fully elapsed.
        if (block.timestamp >= dripEndTime) {
            rewardRate = undistributedFees / dripDuration;
            dripEndTime = block.timestamp + dripDuration;
            return;
        }

        // Case 2: A drip is already active — only reset the window if the new rate
        //         is higher (APY goes up). Otherwise keep the current rate and extend
        //         time slightly. Prevents dust unstakes from resetting the full window.
        uint256 proposedRate = undistributedFees / dripDuration;

        if (proposedRate >= rewardRate) {
            // Large fee added — rate goes up, reset the full drip window.
            rewardRate = proposedRate;
            dripEndTime = block.timestamp + dripDuration;
        } else {
            // Small fee added — keep current rate, extend window by just enough
            // time to distribute the remaining fees at the current speed.
            // Note: integer division may slightly undershoot; _syncPool flushes
            // all remaining undistributedFees once block.timestamp >= dripEndTime.
            dripEndTime = block.timestamp + (undistributedFees / rewardRate);
        }
    }

    /// @dev Returns totalPooledRnbw including any pending drip that hasn't been settled yet.
    ///      Used by view functions to show the effective exchange rate without mutating state.
    function _effectivePooledRnbw() internal view returns (uint256) {
        // 1. No stakers or no pending fees — raw total is already accurate
        if (totalShares == 0 || undistributedFees == 0) return totalPooledRnbw;

        // 2. Drip window has fully elapsed — include all remaining fees
        //    (avoids dust from integer division in rewardRate)
        if (block.timestamp >= dripEndTime) {
            return totalPooledRnbw + undistributedFees;
        }

        // 3. No time has passed since last sync — nothing new to simulate
        if (block.timestamp <= lastSyncTime) return totalPooledRnbw;

        // 4. Mid-drip — simulate proportional amount based on elapsed time
        //    earned = elapsed * rewardRate (linear: constant RNBW per second)
        uint256 earned = (block.timestamp - lastSyncTime) * rewardRate;
        if (earned > undistributedFees) earned = undistributedFees;

        return totalPooledRnbw + earned;
    }

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
        if (isNonceUsed(user, nonce)) revert NonceAlreadyUsed();

        // 3. Recover signer from EIP-712 typed data hash
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = digest.recover(signature);

        // 4. Verify signer is trusted
        if (!_trustedSigners[signer]) revert InvalidSignature();

        // 5. Mark nonce as used
        usedNonces[user][nonce] = true;
    }

    /// @dev Core staking logic
    /// Flow: validate → transfer tokens → mint shares → update metadata
    /// @param from The address tokens are pulled from (via safeTransferFrom)
    /// @param user The address that receives shares and owns the position
    function _stake(address from, address user, uint256 amount) internal {
        // 1. Validate amount
        if (amount == 0) revert ZeroAmount();
        if (shares[user] == 0 && amount < minStakeAmount) {
            revert BelowMinimumStake(user, amount, minStakeAmount);
        }

        // 2. Transfer RNBW tokens from sender to contract
        RNBW_TOKEN.safeTransferFrom(from, address(this), amount);

        // 3. Calculate shares, update pool totals, set metadata, emit events
        _mintShares(user, amount);
    }

    /// @dev Core unstaking logic
    /// Flow: validate → calculate value & fee → burn shares → route fee to drip → transfer net amount
    /// Exit fees are buffered in undistributedFees and dripped linearly over dripDuration
    function _unstake(address user, uint256 sharesToBurn) internal returns (uint256 netAmount) {
        // 1. Validate request
        if (sharesToBurn == 0) revert ZeroAmount();
        if (shares[user] == 0) revert NoStakePosition(user);
        if (shares[user] < sharesToBurn) revert InsufficientShares(user, sharesToBurn, shares[user]);
        if (!allowPartialUnstake && sharesToBurn != shares[user]) {
            revert PartialUnstakeDisabled(user, sharesToBurn, shares[user]);
        }
        uint256 remainingShares = shares[user] - sharesToBurn;
        if (remainingShares > 0 && remainingShares < MIN_SHARES_THRESHOLD) {
            revert DustSharesRemaining(user, remainingShares);
        }

        // 2. Calculate RNBW value of shares at current exchange rate
        //    Formula: rnbwValue = (sharesToBurn * totalPooledRnbw) / totalShares
        uint256 rnbwValue = (sharesToBurn * totalPooledRnbw) / totalShares;

        // 3. Calculate exit fee (e.g., 10% of value)
        //    Rounds up to ensure fractional wei always favors the protocol
        //    (user pays at most 1 wei more, protocol is never short-changed).
        uint256 exitFee = Math.mulDiv(rnbwValue, exitFeeBps, BASIS_POINTS, Math.Rounding.Ceil);

        //    If ceil-rounded fee consumes everything (dust), netAmount = 0 — shares
        //    are burned but no tokens transfer, letting users clear dust positions.
        netAmount = exitFee >= rnbwValue ? 0 : rnbwValue - exitFee;

        // 4. Invariant check: the pool must always have enough RNBW to cover the
        //    full operation. This should never fire because rnbwValue is derived
        //    from totalPooledRnbw via integer division (sharesToBurn ≤ totalShares),
        //    but we guard against any future rounding or logic change.
        if (totalPooledRnbw < rnbwValue) revert AccountingError();

        // 5. Burn user's shares and update global totals
        //    Full rnbwValue is removed from pool; exit fee is routed to the drip pipeline
        //    so it distributes gradually over dripDuration instead of instantly
        shares[user] -= sharesToBurn;
        totalShares -= sharesToBurn;
        totalPooledRnbw -= rnbwValue;
        _addFees(exitFee);

        // 6. Reset pool when all user shares are burned (only dead shares remain).
        //    Sweep both totalPooledRnbw and undistributedFees to safe so the invariant
        //    `totalShares == 0 ⟹ totalPooledRnbw == 0 ∧ undistributedFees == 0` holds.
        uint256 residual;
        if (totalShares <= MINIMUM_SHARES) {
            residual = totalPooledRnbw + undistributedFees;
            totalPooledRnbw = 0;
            undistributedFees = 0;
            rewardRate = 0;
            dripEndTime = 0;
            shares[DEAD_ADDRESS] = 0;
            totalShares = 0;
        }

        // 7. Update user metadata
        UserMeta storage meta = userMeta[user];
        meta.lastUpdateTime = block.timestamp;
        meta.totalRnbwUnstaked += netAmount;
        meta.totalExitFeePaid += exitFee;
        if (shares[user] == 0) {
            meta.stakingStartTime = 0;
        }

        // 8. Transfer net RNBW to user (skipped for dust burns where netAmount == 0)
        if (netAmount > 0) {
            RNBW_TOKEN.safeTransfer(user, netAmount);
        }

        // 9. Sweep residual dust to safe (done after user transfer to keep
        //    reentrancy surface minimal and state fully settled first)
        if (residual > 0) {
            RNBW_TOKEN.safeTransfer(safe, residual);
            emit ResidualSwept(residual);
        }

        // 10. Emit events
        emit Unstaked(user, sharesToBurn, rnbwValue, exitFee, netAmount);
        emit PoolTotalsUpdated(totalPooledRnbw, totalShares);
    }

    /// @dev Stakes from the pre-funded staking reserve — no token transfer,
    ///      RNBW is already in the contract from fundStakingReserve().
    function _stakeFromReserve(address user, uint256 amount) internal {
        // 1. Validate amount
        if (amount == 0) revert ZeroAmount();
        if (shares[user] == 0 && amount < minStakeAmount) {
            revert BelowMinimumStake(user, amount, minStakeAmount);
        }

        // 2. Deduct from pre-funded staking reserve (no token transfer needed)
        if (amount > stakingReserve) revert InsufficientStakingBalance();
        stakingReserve -= amount;

        // 3. Calculate shares, update pool totals, set metadata, emit events
        _mintShares(user, amount);
    }

    /// @dev Shared share-minting logic used by _stake and _stakeFromReserve.
    ///      Calculates shares, updates pool totals, sets metadata, emits events.
    function _mintShares(address user, uint256 amount) internal {
        // 1. Calculate shares to mint based on current exchange rate
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

        // 2. Prevent share inflation attack: if exchange rate is so high that
        //    the deposit rounds to 0 shares, revert to protect the depositor.
        if (sharesToMint == 0) revert ZeroSharesMinted(user, amount);

        // 3. Update user's share balance and global totals
        shares[user] += sharesToMint;
        totalShares += sharesToMint;
        totalPooledRnbw += amount;

        // 4. Update user metadata
        UserMeta storage meta = userMeta[user];
        if (meta.stakingStartTime == 0) {
            meta.stakingStartTime = block.timestamp;
        }
        meta.lastUpdateTime = block.timestamp;
        meta.totalRnbwStaked += amount;

        // 5. Emit events
        emit Staked(user, amount, sharesToMint, shares[user]);
        emit PoolTotalsUpdated(totalPooledRnbw, totalShares);
    }

    /// @dev Allocates cashback by minting shares directly in one step.
    ///      Contract must be pre-funded with RNBW via fundCashbackReserve().
    ///      Reverts if cashback is too small to mint at least 1 share (backend should batch).
    function _allocateCashback(address user, uint256 rnbwCashback) internal {
        // 1. Validate
        if (rnbwCashback == 0) revert ZeroAmount();
        if (shares[user] == 0) revert NoStakePosition(user);

        // 2. Verify cashback reserve has enough RNBW to cover this allocation
        if (rnbwCashback > cashbackReserve) {
            revert InsufficientCashbackBalance();
        }

        // 3. Calculate shares to mint at the current exchange rate
        //    totalShares > 0 guaranteed by shares[user] > 0 check above.
        uint256 sharesToMint = (rnbwCashback * totalShares) / totalPooledRnbw;

        // 4. Revert if cashback is too small to mint shares — backend should
        //    batch small amounts or retry when the exchange rate is more favorable
        if (sharesToMint == 0) revert ZeroSharesMinted(user, rnbwCashback);

        // 5. Mint shares and move cashback RNBW from reserve into the pool
        shares[user] += sharesToMint;
        totalShares += sharesToMint;
        totalPooledRnbw += rnbwCashback;
        cashbackReserve -= rnbwCashback;

        // 6. Update metadata
        UserMeta storage meta = userMeta[user];
        meta.lastUpdateTime = block.timestamp;
        meta.totalCashbackReceived += rnbwCashback;
        totalCashbackAllocated += rnbwCashback;

        // 7. Emit events
        emit CashbackAllocated(user, rnbwCashback, sharesToMint);
        emit PoolTotalsUpdated(totalPooledRnbw, totalShares);
    }
}
