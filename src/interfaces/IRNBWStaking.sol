// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IRNBWStaking
/// @notice Interface for the RNBWStaking contract
/// @custom:security-contact security@rainbow.me
interface IRNBWStaking {
    struct UserMeta {
        uint256 lastUpdateTime;
        uint256 stakingStartTime;
    }

    event Staked(address indexed user, uint256 rnbwAmount, uint256 sharesMinted, uint256 newShareBalance);
    event Unstaked(address indexed user, uint256 sharesBurned, uint256 rnbwValue, uint256 exitFee, uint256 netReceived);
    event CashbackAllocated(address indexed user, uint256 rnbwAmount, uint256 sharesMinted);
    event SignerAdded(address indexed signer);
    event SignerRemoved(address indexed signer);
    event ExchangeRateUpdated(uint256 totalPooledRnbw, uint256 totalShares);
    event ExitFeeBpsUpdated(uint256 indexed oldExitFeeBps, uint256 indexed newExitFeeBps);
    event MinStakeAmountUpdated(uint256 indexed oldMinStakeAmount, uint256 indexed newMinStakeAmount);
    event CashbackRewardsDeposited(address indexed from, uint256 amount);
    event SafeUpdated(address indexed oldSafe, address indexed newSafe);

    error ZeroAddress();
    error Unauthorized();
    error ZeroAmount();
    error InsufficientShares();
    error BelowMinimumStake();
    error NoStakePosition();
    error InvalidSignature();
    error SignatureExpired();
    error NonceAlreadyUsed();
    error CannotWithdrawStakedToken();
    error NoChange();
    error ExitFeeTooLow();
    error ExitFeeTooHigh();
    error MinStakeTooHigh();
    error SignerAlreadyAdded();
    error SignerNotFound();
    error CannotRemoveLastSigner();
    error MaxSignersReached();
    error InsufficientCashbackBalance();
    error InsufficientExcess();
    error ZeroSharesMinted();

    function stake(uint256 amount) external;

    function unstake(uint256 sharesToBurn) external;

    function allocateCashbackWithSignature(
        address user,
        uint256 rnbwCashback,
        uint256 nonce,
        uint256 expiry,
        bytes calldata signature
    ) external;

    function getPosition(address user)
        external
        view
        returns (uint256 stakedAmount, uint256 userShares, uint256 lastUpdateTime, uint256 stakingStartTime);

    function getRnbwForShares(uint256 sharesAmount) external view returns (uint256);

    function getSharesForRnbw(uint256 rnbwAmount) external view returns (uint256);

    function getExchangeRate() external view returns (uint256);

    function isNonceUsed(address user, uint256 nonce) external view returns (bool);

    function domainSeparator() external view returns (bytes32);

    function addTrustedSigner(address signer) external;

    function removeTrustedSigner(address signer) external;

    function isTrustedSigner(address signer) external view returns (bool);

    function pause() external;

    function unpause() external;

    function emergencyWithdraw(address token, uint256 amount) external;

    function setExitFeeBps(uint256 newExitFeeBps) external;

    function setMinStakeAmount(uint256 newMinStakeAmount) external;

    function depositCashbackRewards(uint256 amount) external;

    function setSafe(address newSafe) external;
}
