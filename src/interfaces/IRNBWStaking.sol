// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IRNBWStaking
/// @notice Interface for the RNBWStaking contract — shares-based staking for $RNBW with exit fees
/// @custom:security-contact security@rainbow.me
interface IRNBWStaking {
    /// @notice Metadata tracked per staking position
    /// @param lastUpdateTime Timestamp of the last stake, unstake, or cashback action
    /// @param stakingStartTime Timestamp of the user's first stake (reset to 0 on full unstake)
    /// @param totalCashbackReceived Lifetime cumulative cashback RNBW allocated to this user (never resets)
    /// @param totalRnbwStaked Lifetime cumulative RNBW deposited via stake() (never resets)
    /// @param totalRnbwUnstaked Lifetime cumulative net RNBW received from unstake(), after exit fee (never resets)
    /// @param totalExitFeePaid Lifetime cumulative exit fees paid by this user (never resets)
    struct UserMeta {
        uint256 lastUpdateTime;
        uint256 stakingStartTime;
        uint256 totalCashbackReceived;
        uint256 totalRnbwStaked;
        uint256 totalRnbwUnstaked;
        uint256 totalExitFeePaid;
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a user stakes RNBW
    /// @param user The staker's address
    /// @param rnbwAmount The amount of RNBW staked
    /// @param sharesMinted The number of shares minted to the user
    /// @param newShareBalance The user's total share balance after staking
    event Staked(address indexed user, uint256 rnbwAmount, uint256 sharesMinted, uint256 newShareBalance);

    /// @notice Emitted when a user unstakes (burns shares for RNBW minus exit fee)
    /// @param user The unstaker's address
    /// @param sharesBurned The number of shares burned
    /// @param rnbwValue The gross RNBW value of the burned shares
    /// @param exitFee The exit fee deducted (stays in pool)
    /// @param netReceived The net RNBW transferred to the user
    event Unstaked(address indexed user, uint256 sharesBurned, uint256 rnbwValue, uint256 exitFee, uint256 netReceived);

    /// @notice Emitted when cashback is allocated (shares minted from pre-funded reserve)
    /// @param user The recipient's address
    /// @param rnbwAmount The RNBW amount of cashback allocated
    /// @param sharesMinted The number of shares minted
    event CashbackAllocated(address indexed user, uint256 rnbwAmount, uint256 sharesMinted);

    /// @notice Emitted when a trusted EIP-712 signer is added
    /// @param signer The signer's address
    event SignerAdded(address indexed signer);

    /// @notice Emitted when a trusted EIP-712 signer is removed
    /// @param signer The signer's address
    event SignerRemoved(address indexed signer);

    /// @notice Emitted after any action that changes the exchange rate
    /// @param totalPooledRnbw The total RNBW in the staking pool
    /// @param totalShares The total shares outstanding
    event ExchangeRateUpdated(uint256 totalPooledRnbw, uint256 totalShares);

    /// @notice Emitted when the exit fee is updated
    /// @param oldExitFeeBps The previous exit fee in basis points
    /// @param newExitFeeBps The new exit fee in basis points
    event ExitFeeBpsUpdated(uint256 indexed oldExitFeeBps, uint256 indexed newExitFeeBps);

    /// @notice Emitted when the minimum stake amount is updated
    /// @param oldMinStakeAmount The previous minimum stake amount
    /// @param newMinStakeAmount The new minimum stake amount
    event MinStakeAmountUpdated(uint256 indexed oldMinStakeAmount, uint256 indexed newMinStakeAmount);

    /// @notice Emitted when partial unstake permission is toggled
    /// @param allowed Whether partial unstake is now allowed
    event PartialUnstakeToggled(bool allowed);

    /// @notice Emitted when the admin deposits RNBW to fund cashback rewards
    /// @param from The depositor's address (must be safe)
    /// @param amount The amount of RNBW deposited
    event CashbackReserveFunded(address indexed from, uint256 amount);

    /// @notice Emitted when a new safe address is proposed (step 1 of 2-step transfer)
    /// @param currentSafe The current safe address that proposed the change
    /// @param proposedSafe The proposed new safe address
    event SafeProposed(address indexed currentSafe, address indexed proposedSafe);

    /// @notice Emitted when the safe (admin) address is updated (step 2 of 2-step transfer)
    /// @param oldSafe The previous safe address
    /// @param newSafe The new safe address
    event SafeUpdated(address indexed oldSafe, address indexed newSafe);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a zero address is provided where a valid address is required
    error ZeroAddress();

    /// @notice Thrown when a non-safe address calls an admin-only function
    error Unauthorized();

    /// @notice Thrown when a zero amount is provided
    error ZeroAmount();

    /// @notice Thrown when a user tries to burn more shares than they hold
    error InsufficientShares(address user, uint256 requested, uint256 available);

    /// @notice Thrown when a first-time staker's amount is below minStakeAmount
    error BelowMinimumStake(address user, uint256 amount, uint256 minRequired);

    /// @notice Thrown when an action requires an active stake but the user has none
    error NoStakePosition(address user);

    /// @notice Thrown when an EIP-712 signature is invalid or from an untrusted signer
    error InvalidSignature();

    /// @notice Thrown when an EIP-712 signature has expired
    error SignatureExpired();

    /// @notice Thrown when a nonce has already been used (replay protection)
    error NonceAlreadyUsed();

    /// @notice Thrown when a setter is called with the current value (no-op prevention)
    error NoChange();

    /// @notice Thrown when the exit fee is set below MIN_EXIT_FEE_BPS
    error ExitFeeTooLow();

    /// @notice Thrown when the exit fee is set above MAX_EXIT_FEE_BPS
    error ExitFeeTooHigh();

    /// @notice Thrown when minStakeAmount is set below MIN_STAKE_FLOOR
    error MinStakeTooLow();

    /// @notice Thrown when minStakeAmount is set above MAX_MIN_STAKE_AMOUNT
    error MinStakeTooHigh();

    /// @notice Thrown when attempting to add a signer that is already trusted
    error SignerAlreadyAdded();

    /// @notice Thrown when attempting to remove a signer that is not trusted
    error SignerNotFound();

    /// @notice Thrown when attempting to remove the last remaining trusted signer
    error CannotRemoveLastSigner();

    /// @notice Thrown when attempting to add a signer beyond MAX_SIGNERS
    error MaxSignersReached();

    /// @notice Thrown when cashback allocation exceeds the pre-funded cashbackReserve
    error InsufficientCashbackBalance();

    /// @notice Thrown when emergencyWithdraw tries to withdraw more RNBW than excess
    error InsufficientExcess();

    /// @notice Thrown when acceptSafe is called but no safe transfer has been proposed
    error NoPendingSafe();

    /// @notice Thrown when a stake or cashback amount is too small to mint at least 1 share
    error ZeroSharesMinted(address user, uint256 amount);

    /// @notice Thrown when ceil-rounded exit fee consumes entire unstake amount (dust protection)
    error ZeroUnstakeAmount(address user, uint256 rnbwValue);

    /// @notice Thrown when partial unstake is attempted but not allowed
    error PartialUnstakeDisabled(address user, uint256 sharesToBurn, uint256 totalUserShares);

    /// @notice Thrown when batch array lengths do not match
    error ArrayLengthMismatch();

    /// @notice Thrown when batch size exceeds MAX_BATCH_SIZE
    error BatchTooLarge();

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Stake RNBW tokens to receive shares. First-time stakers must meet minStakeAmount.
    /// @param amount The amount of RNBW to stake
    function stake(uint256 amount) external;

    /// @notice Burn shares to unstake RNBW. An exit fee is deducted and stays in the pool.
    /// @param sharesToBurn The number of shares to burn
    function unstake(uint256 sharesToBurn) external;

    /// @notice Burn all of the caller's shares to unstake RNBW. Convenience wrapper around unstake().
    function unstakeAll() external;

    /// @notice Allocate cashback to a staker by minting shares (backend-only, signature-gated)
    /// @param user The recipient staker's address
    /// @param rnbwCashback The amount of RNBW cashback to allocate
    /// @param nonce A unique nonce for replay protection
    /// @param expiry The timestamp after which the signature is invalid
    /// @param signature The EIP-712 signature from a trusted signer
    function allocateCashbackWithSignature(
        address user,
        uint256 rnbwCashback,
        uint256 nonce,
        uint256 expiry,
        bytes calldata signature
    ) external;

    /// @notice Batch allocate cashback to multiple stakers in a single transaction
    /// @param users Array of recipient staker addresses
    /// @param rnbwCashbacks Array of RNBW cashback amounts
    /// @param nonces Array of unique nonces for replay protection
    /// @param expiries Array of signature expiry timestamps
    /// @param signatures Array of EIP-712 signatures from trusted signers
    function batchAllocateCashbackWithSignature(
        address[] calldata users,
        uint256[] calldata rnbwCashbacks,
        uint256[] calldata nonces,
        uint256[] calldata expiries,
        bytes[] calldata signatures
    ) external;

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns a user's staking position
    /// @param user The user's address
    /// @return stakedAmount The RNBW value of the user's shares at the current exchange rate
    /// @return userShares The user's raw share balance
    /// @return lastUpdateTime Timestamp of the last action on this position
    /// @return stakingStartTime Timestamp of the user's first stake
    /// @return totalCashbackReceived Lifetime cumulative cashback RNBW allocated
    /// @return totalRnbwStaked Lifetime cumulative RNBW deposited via stake()
    /// @return totalRnbwUnstaked Lifetime cumulative net RNBW received from unstake()
    /// @return totalExitFeePaid Lifetime cumulative exit fees paid
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
        );

    /// @notice Converts a share amount to its RNBW value at the current exchange rate
    /// @param sharesAmount The number of shares to convert
    /// @return The equivalent RNBW amount
    function getRnbwForShares(uint256 sharesAmount) external view returns (uint256);

    /// @notice Converts an RNBW amount to shares at the current exchange rate
    /// @param rnbwAmount The RNBW amount to convert
    /// @return The equivalent number of shares
    function getSharesForRnbw(uint256 rnbwAmount) external view returns (uint256);

    /// @notice Returns the current exchange rate (RNBW per share), scaled by 1e18
    /// @return The exchange rate (1e18 = 1:1)
    function getExchangeRate() external view returns (uint256);

    /// @notice Preview the outcome of unstaking a given number of shares
    /// @param sharesToBurn The number of shares to burn
    /// @return rnbwValue The gross RNBW value before exit fee
    /// @return exitFee The exit fee amount
    /// @return netReceived The net RNBW the user would receive
    function previewUnstake(uint256 sharesToBurn)
        external
        view
        returns (uint256 rnbwValue, uint256 exitFee, uint256 netReceived);

    /// @notice Preview the number of shares that would be minted for a given stake amount
    /// @param amount The RNBW amount to stake
    /// @return sharesToMint The number of shares that would be minted
    function previewStake(uint256 amount) external view returns (uint256 sharesToMint);

    /// @notice Checks if a nonce has been used for a given user
    /// @param user The user's address
    /// @param nonce The nonce to check
    /// @return True if the nonce has been used
    function isNonceUsed(address user, uint256 nonce) external view returns (bool);

    /// @notice Returns the EIP-712 domain separator
    /// @return The domain separator hash
    function domainSeparator() external view returns (bytes32);

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Add a trusted EIP-712 signer for cashback operations
    /// @param signer The signer's address to add
    function addTrustedSigner(address signer) external;

    /// @notice Remove a trusted EIP-712 signer
    /// @param signer The signer's address to remove
    function removeTrustedSigner(address signer) external;

    /// @notice Check if an address is a trusted signer
    /// @param signer The address to check
    /// @return True if the address is a trusted signer
    function isTrustedSigner(address signer) external view returns (bool);

    /// @notice Pause the contract (blocks stake, unstake, and cashback)
    function pause() external;

    /// @notice Unpause the contract
    function unpause() external;

    /// @notice Withdraw tokens from the contract. For RNBW, only excess above
    ///         totalPooledRnbw + cashbackReserve can be withdrawn.
    /// @param token The token address to withdraw
    /// @param amount The amount to withdraw
    function emergencyWithdraw(address token, uint256 amount) external;

    /// @notice Update the exit fee in basis points
    /// @param newExitFeeBps The new exit fee (must be between MIN_EXIT_FEE_BPS and MAX_EXIT_FEE_BPS)
    function setExitFeeBps(uint256 newExitFeeBps) external;

    /// @notice Update the minimum stake amount for first-time stakers
    /// @param newMinStakeAmount The new minimum (must be between MIN_STAKE_FLOOR and MAX_MIN_STAKE_AMOUNT)
    function setMinStakeAmount(uint256 newMinStakeAmount) external;

    /// @notice Deposit RNBW to fund the cashback reserve
    /// @param amount The amount of RNBW to deposit
    function fundCashbackReserve(uint256 amount) external;

    /// @notice Propose a new safe address (step 1 of 2-step transfer, callable by current safe only)
    /// @param newSafe The proposed new safe address
    function proposeSafe(address newSafe) external;

    /// @notice Accept the proposed safe address (step 2 of 2-step transfer, callable by pending safe only)
    function acceptSafe() external;

    /// @notice Toggle whether partial unstake is allowed (default: true)
    /// @param allowed Whether to allow partial unstake
    function setAllowPartialUnstake(bool allowed) external;
}
