// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RNBWStaking} from "../src/RNBWStaking.sol";
import {IRNBWStaking} from "../src/interfaces/IRNBWStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract RNBWStakingHarness is RNBWStaking {
    constructor(address _rnbwToken, address _safe, address _initialSigner)
        RNBWStaking(_rnbwToken, _safe, _initialSigner)
    {}

    function exposedSyncPool() external {
        _syncPool();
    }
}

contract RNBWStakingTest is Test {
    RNBWStakingHarness public staking;
    MockERC20 public rnbwToken;

    address public admin = makeAddr("admin");
    uint256 public signerPrivateKey = 0xA11CE;
    address public signer;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 public constant INITIAL_BALANCE = 1000 ether;

    function setUp() public {
        signer = vm.addr(signerPrivateKey);
        rnbwToken = new MockERC20("Rainbow Token", "RNBW", 18);

        vm.prank(admin);
        staking = new RNBWStakingHarness(address(rnbwToken), admin, signer);

        rnbwToken.mint(alice, INITIAL_BALANCE);
        rnbwToken.mint(bob, INITIAL_BALANCE);

        vm.prank(admin);
        staking.setAllowPartialUnstake(true);
    }

    function _signAllocateCashback(address user, uint256 rnbwCashback, uint256 nonce, uint256 expiry)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash =
            keccak256(abi.encode(staking.ALLOCATE_CASHBACK_TYPEHASH(), user, rnbwCashback, nonce, expiry));
        bytes32 digest = MessageHashUtils.toTypedDataHash(staking.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signStakeFor(address recipient, uint256 amount, uint256 nonce, uint256 expiry)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(staking.STAKE_FOR_TYPEHASH(), recipient, amount, nonce, expiry));
        bytes32 digest = MessageHashUtils.toTypedDataHash(staking.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _depositStakingReserve(uint256 amount) internal {
        rnbwToken.mint(admin, amount);
        vm.startPrank(admin);
        rnbwToken.approve(address(staking), amount);
        staking.fundStakingReserve(amount);
        vm.stopPrank();
    }

    function _depositCashback(uint256 amount) internal {
        rnbwToken.mint(admin, amount);
        vm.startPrank(admin);
        rnbwToken.approve(address(staking), amount);
        staking.fundCashbackReserve(amount);
        vm.stopPrank();
    }

    function test_Deployment() public view {
        assertEq(address(staking.RNBW_TOKEN()), address(rnbwToken));
        assertEq(staking.safe(), admin);
        assertTrue(staking.isTrustedSigner(signer));
    }

    function test_Stake() public {
        uint256 amount = 100 ether;

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();

        uint256 deadShares = staking.MINIMUM_SHARES();
        assertEq(staking.shares(alice), amount - deadShares);
        assertEq(staking.totalShares(), amount);
        assertEq(staking.totalPooledRnbw(), amount);
        assertEq(rnbwToken.balanceOf(alice), INITIAL_BALANCE - amount);
    }

    function test_StakeRevertZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(IRNBWStaking.ZeroAmount.selector);
        staking.stake(0);
    }

    function test_StakeRevertBelowMinimum() public {
        uint256 amount = 0.5 ether;

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), amount);
        vm.expectRevert(
            abi.encodeWithSelector(IRNBWStaking.BelowMinimumStake.selector, alice, amount, staking.minStakeAmount())
        );
        staking.stake(amount);
        vm.stopPrank();
    }

    function test_Unstake() public {
        uint256 stakeAmount = 100 ether;

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);

        uint256 sharesToBurn = staking.shares(alice);
        staking.unstake(sharesToBurn);
        vm.stopPrank();

        assertEq(staking.shares(alice), 0);
        assertEq(staking.totalShares(), 0);
        assertGt(rnbwToken.balanceOf(alice), INITIAL_BALANCE - stakeAmount);
    }

    function test_UnstakePartial() public {
        uint256 stakeAmount = 100 ether;

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);

        uint256 aliceShares = staking.shares(alice);
        uint256 sharesToBurn = aliceShares / 2;
        staking.unstake(sharesToBurn);
        vm.stopPrank();

        assertEq(staking.shares(alice), aliceShares - sharesToBurn);
    }

    function test_UnstakeRevertZeroAmount() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.expectRevert(IRNBWStaking.ZeroAmount.selector);
        staking.unstake(0);
        vm.stopPrank();
    }

    function test_UnstakeRevertInsufficientShares() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IRNBWStaking.InsufficientShares.selector, alice, 200 ether, staking.shares(alice))
        );
        staking.unstake(200 ether);
        vm.stopPrank();
    }

    function test_UnstakeRevertNoPosition() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IRNBWStaking.NoStakePosition.selector, alice));
        staking.unstake(100 ether);
    }

    function test_PartialUnstakeDisabled() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.prank(admin);
        staking.setAllowPartialUnstake(false);
        assertEq(staking.allowPartialUnstake(), false);

        uint256 aliceShares = staking.shares(alice);
        uint256 halfShares = aliceShares / 2;

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IRNBWStaking.PartialUnstakeDisabled.selector, alice, halfShares, aliceShares)
        );
        staking.unstake(halfShares);

        vm.prank(alice);
        staking.unstake(aliceShares);
        assertEq(staking.shares(alice), 0);
    }

    function test_PartialUnstakeReEnabled() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.prank(admin);
        staking.setAllowPartialUnstake(false);

        vm.prank(admin);
        staking.setAllowPartialUnstake(true);

        uint256 halfShares = staking.shares(alice) / 2;
        vm.prank(alice);
        staking.unstake(halfShares);
        assertGt(staking.shares(alice), 0);
    }

    function test_SetAllowPartialUnstakeRevertNoChange() public {
        vm.prank(admin);
        vm.expectRevert(IRNBWStaking.NoChange.selector);
        staking.setAllowPartialUnstake(true);
    }

    function test_SetAllowPartialUnstakeRevertNoChangeWhenDisabled() public {
        vm.prank(admin);
        staking.setAllowPartialUnstake(false);

        vm.prank(admin);
        vm.expectRevert(IRNBWStaking.NoChange.selector);
        staking.setAllowPartialUnstake(false);
    }

    function test_SetAllowPartialUnstakeRevertUnauthorized() public {
        vm.prank(alice);
        vm.expectRevert(IRNBWStaking.Unauthorized.selector);
        staking.setAllowPartialUnstake(false);
    }

    function test_UnstakeExitFee() public {
        uint256 stakeAmount = 100 ether;

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);

        uint256 aliceShares = staking.shares(alice);
        uint256 balanceBefore = rnbwToken.balanceOf(alice);
        staking.unstake(aliceShares);
        uint256 balanceAfter = rnbwToken.balanceOf(alice);
        vm.stopPrank();

        uint256 received = balanceAfter - balanceBefore;
        uint256 expectedNet = (stakeAmount * 9000) / 10_000;
        assertApproxEqAbs(received, expectedNet, staking.MINIMUM_SHARES());
    }

    function test_GetPosition() public {
        uint256 amount = 100 ether;

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();

        uint256 deadShares = staking.MINIMUM_SHARES();
        (uint256 stakedAmount, uint256 userShares,,,,,,) = staking.getPosition(alice);

        assertEq(userShares, amount - deadShares);
        assertApproxEqAbs(stakedAmount, amount, deadShares);
    }

    function test_ExchangeRateInitial() public view {
        assertEq(staking.getExchangeRate(), 1e18);
    }

    function test_SharesCalculation() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        assertEq(staking.getRnbwForShares(100 ether), 100 ether);
        assertEq(staking.getSharesForRnbw(100 ether), 100 ether);
    }

    function test_AllocateCashbackWithSignature() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        _depositCashback(10 ether);

        uint256 nonce = 1;
        uint256 expiry = block.timestamp + 60;
        bytes memory sig = _signAllocateCashback(alice, 10 ether, nonce, expiry);

        staking.allocateCashbackWithSignature(alice, 10 ether, nonce, expiry, sig);

        uint256 deadShares = staking.MINIMUM_SHARES();
        (uint256 stakedAmount, uint256 userShares,,,,,,) = staking.getPosition(alice);
        assertApproxEqAbs(stakedAmount, 110 ether, deadShares);
        assertEq(userShares, 100 ether + 10 ether - deadShares);
        assertEq(staking.totalPooledRnbw(), 110 ether);
    }

    function test_AllocateCashbackRevertNoPosition() public {
        _depositCashback(10 ether);

        uint256 nonce = 1;
        uint256 expiry = block.timestamp + 60;
        bytes memory sig = _signAllocateCashback(alice, 10 ether, nonce, expiry);

        vm.expectRevert(abi.encodeWithSelector(IRNBWStaking.NoStakePosition.selector, alice));
        staking.allocateCashbackWithSignature(alice, 10 ether, nonce, expiry, sig);
    }

    function test_AllocateCashbackRevertInsufficientBalance() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        uint256 nonce = 1;
        uint256 expiry = block.timestamp + 60;
        bytes memory sig = _signAllocateCashback(alice, 10 ether, nonce, expiry);

        vm.expectRevert(IRNBWStaking.InsufficientCashbackBalance.selector);
        staking.allocateCashbackWithSignature(alice, 10 ether, nonce, expiry, sig);
    }

    function test_AllocateCashbackRevertZeroAmount() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        uint256 nonce = 1;
        uint256 expiry = block.timestamp + 60;
        bytes memory sig = _signAllocateCashback(alice, 0, nonce, expiry);

        vm.expectRevert(IRNBWStaking.ZeroAmount.selector);
        staking.allocateCashbackWithSignature(alice, 0, nonce, expiry, sig);
    }

    function test_DepositCashbackRewards() public {
        rnbwToken.mint(admin, 1000 ether);

        vm.startPrank(admin);
        rnbwToken.approve(address(staking), 1000 ether);
        staking.fundCashbackReserve(1000 ether);
        vm.stopPrank();

        assertEq(rnbwToken.balanceOf(address(staking)), 1000 ether);
    }

    function test_DepositCashbackRewardsRevertUnauthorized() public {
        rnbwToken.mint(alice, 1000 ether);

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 1000 ether);
        vm.expectRevert(IRNBWStaking.Unauthorized.selector);
        staking.fundCashbackReserve(1000 ether);
        vm.stopPrank();
    }

    function test_DepositCashbackRewardsRevertZeroAmount() public {
        vm.prank(admin);
        vm.expectRevert(IRNBWStaking.ZeroAmount.selector);
        staking.fundCashbackReserve(0);
    }

    function test_DefundCashbackReserve() public {
        _depositCashback(1000 ether);
        uint256 safeBefore = rnbwToken.balanceOf(admin);

        vm.prank(admin);
        staking.defundCashbackReserve(400 ether);

        assertEq(staking.cashbackReserve(), 600 ether);
        assertEq(rnbwToken.balanceOf(admin), safeBefore + 400 ether);
    }

    function test_DefundCashbackReserveFull() public {
        _depositCashback(500 ether);

        vm.prank(admin);
        staking.defundCashbackReserve(500 ether);

        assertEq(staking.cashbackReserve(), 0);
    }

    function test_DefundCashbackReserveRevertZeroAmount() public {
        _depositCashback(100 ether);
        vm.prank(admin);
        vm.expectRevert(IRNBWStaking.ZeroAmount.selector);
        staking.defundCashbackReserve(0);
    }

    function test_DefundCashbackReserveRevertInsufficientBalance() public {
        _depositCashback(100 ether);
        vm.prank(admin);
        vm.expectRevert(IRNBWStaking.InsufficientCashbackBalance.selector);
        staking.defundCashbackReserve(101 ether);
    }

    function test_DefundCashbackReserveRevertUnauthorized() public {
        _depositCashback(100 ether);
        vm.prank(alice);
        vm.expectRevert(IRNBWStaking.Unauthorized.selector);
        staking.defundCashbackReserve(50 ether);
    }

    function test_Pause() public {
        vm.prank(admin);
        staking.pause();

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        vm.expectRevert();
        staking.stake(100 ether);
        vm.stopPrank();
    }

    function test_Unpause() public {
        vm.startPrank(admin);
        staking.pause();
        staking.unpause();
        vm.stopPrank();

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        assertEq(staking.shares(alice), 100 ether - staking.MINIMUM_SHARES());
    }

    function test_AddTrustedSigner() public {
        address newSigner = makeAddr("newSigner");

        vm.prank(admin);
        staking.addTrustedSigner(newSigner);

        assertTrue(staking.isTrustedSigner(newSigner));
        assertEq(staking.trustedSignerCount(), 2);
    }

    function test_AddTrustedSignerRevertAlreadyAdded() public {
        vm.prank(admin);
        vm.expectRevert(IRNBWStaking.SignerAlreadyAdded.selector);
        staking.addTrustedSigner(signer);
    }

    function test_AddTrustedSignerRevertMaxSigners() public {
        address signer2 = makeAddr("signer2");
        address signer3 = makeAddr("signer3");
        address signer4 = makeAddr("signer4");

        vm.startPrank(admin);
        staking.addTrustedSigner(signer2);
        staking.addTrustedSigner(signer3);
        vm.expectRevert(IRNBWStaking.MaxSignersReached.selector);
        staking.addTrustedSigner(signer4);
        vm.stopPrank();
    }

    function test_RemoveTrustedSigner() public {
        address newSigner = makeAddr("newSigner");

        vm.startPrank(admin);
        staking.addTrustedSigner(newSigner);
        staking.removeTrustedSigner(newSigner);
        vm.stopPrank();

        assertFalse(staking.isTrustedSigner(newSigner));
        assertEq(staking.trustedSignerCount(), 1);
    }

    function test_RemoveTrustedSignerRevertNotFound() public {
        address notSigner = makeAddr("notSigner");

        vm.prank(admin);
        vm.expectRevert(IRNBWStaking.SignerNotFound.selector);
        staking.removeTrustedSigner(notSigner);
    }

    function test_RemoveTrustedSignerRevertLastSigner() public {
        vm.prank(admin);
        vm.expectRevert(IRNBWStaking.CannotRemoveLastSigner.selector);
        staking.removeTrustedSigner(signer);
    }

    function test_EmergencyWithdraw() public {
        MockERC20 randomToken = new MockERC20("Random", "RND", 18);
        randomToken.mint(address(staking), 100 ether);

        vm.prank(admin);
        staking.emergencyWithdraw(address(randomToken), 100 ether);

        assertEq(randomToken.balanceOf(admin), 100 ether);
    }

    function test_EmergencyWithdrawExcessRnbw() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        rnbwToken.mint(address(staking), 50 ether);

        vm.prank(admin);
        staking.emergencyWithdraw(address(rnbwToken), 50 ether);

        assertEq(rnbwToken.balanceOf(admin), 50 ether);
    }

    function test_EmergencyWithdrawRevertInsufficientExcess() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.prank(admin);
        vm.expectRevert(IRNBWStaking.InsufficientExcess.selector);
        staking.emergencyWithdraw(address(rnbwToken), 1 ether);
    }

    function test_EmergencyWithdrawCannotDrainCashbackReserve() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        _depositCashback(50 ether);

        vm.prank(admin);
        vm.expectRevert(IRNBWStaking.InsufficientExcess.selector);
        staking.emergencyWithdraw(address(rnbwToken), 1 ether);

        rnbwToken.mint(address(staking), 10 ether);

        vm.prank(admin);
        staking.emergencyWithdraw(address(rnbwToken), 10 ether);
        assertEq(staking.cashbackReserve(), 50 ether);
    }

    function test_ProposeSafeAndAccept() public {
        address newSafe = makeAddr("newSafe");

        vm.prank(admin);
        staking.proposeSafe(newSafe);
        assertEq(staking.pendingSafe(), newSafe);
        assertEq(staking.safe(), admin);

        vm.prank(newSafe);
        staking.acceptSafe();
        assertEq(staking.safe(), newSafe);
        assertEq(staking.pendingSafe(), address(0));
    }

    function test_ProposeSafeRevertZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(IRNBWStaking.ZeroAddress.selector);
        staking.proposeSafe(address(0));
    }

    function test_ProposeSafeRevertUnauthorized() public {
        vm.prank(alice);
        vm.expectRevert(IRNBWStaking.Unauthorized.selector);
        staking.proposeSafe(makeAddr("newSafe"));
    }

    function test_ProposeSafeRevertSameAsCurrent() public {
        vm.prank(admin);
        vm.expectRevert(IRNBWStaking.NoChange.selector);
        staking.proposeSafe(admin);
    }

    function test_AcceptSafeRevertNoPending() public {
        vm.prank(alice);
        vm.expectRevert(IRNBWStaking.NoPendingSafe.selector);
        staking.acceptSafe();
    }

    function test_AcceptSafeRevertWrongCaller() public {
        address newSafe = makeAddr("newSafe");
        vm.prank(admin);
        staking.proposeSafe(newSafe);

        vm.prank(alice);
        vm.expectRevert(IRNBWStaking.NotPendingSafe.selector);
        staking.acceptSafe();
    }

    function test_DomainSeparator() public view {
        bytes32 separator = staking.domainSeparator();
        assertTrue(separator != bytes32(0));
    }

    function testFuzz_Stake(uint256 amount) public {
        amount = bound(amount, 1 ether, INITIAL_BALANCE);

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();

        assertEq(staking.shares(alice), amount - staking.MINIMUM_SHARES());
    }

    function testFuzz_MultipleStakers(uint256 aliceAmount, uint256 bobAmount) public {
        aliceAmount = bound(aliceAmount, 1 ether, INITIAL_BALANCE);
        bobAmount = bound(bobAmount, 1 ether, INITIAL_BALANCE);

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), aliceAmount);
        staking.stake(aliceAmount);
        vm.stopPrank();

        vm.startPrank(bob);
        rnbwToken.approve(address(staking), bobAmount);
        staking.stake(bobAmount);
        vm.stopPrank();

        assertEq(staking.totalPooledRnbw(), aliceAmount + bobAmount);
    }

    function test_SetExitFeeBps() public {
        vm.prank(admin);
        staking.setExitFeeBps(2000);
        assertEq(staking.exitFeeBps(), 2000);
    }

    function test_SetExitFeeBpsRevertTooHigh() public {
        vm.prank(admin);
        vm.expectRevert(IRNBWStaking.ExitFeeTooHigh.selector);
        staking.setExitFeeBps(7501);
    }

    function test_SetExitFeeBpsRevertTooLow() public {
        vm.prank(admin);
        vm.expectRevert(IRNBWStaking.ExitFeeTooLow.selector);
        staking.setExitFeeBps(99);
    }

    function test_SetExitFeeBpsRevertNoChange() public {
        vm.prank(admin);
        vm.expectRevert(IRNBWStaking.NoChange.selector);
        staking.setExitFeeBps(1000);
    }

    function test_SetMinStakeAmount() public {
        vm.prank(admin);
        staking.setMinStakeAmount(10 ether);
        assertEq(staking.minStakeAmount(), 10 ether);
    }

    function test_SetMinStakeAmountRevertNoChange() public {
        vm.prank(admin);
        vm.expectRevert(IRNBWStaking.NoChange.selector);
        staking.setMinStakeAmount(1 ether);
    }

    function test_SetMinStakeAmountRevertTooLow() public {
        vm.prank(admin);
        vm.expectRevert(IRNBWStaking.MinStakeTooLow.selector);
        staking.setMinStakeAmount(0.5 ether);
    }

    function test_SetMinStakeAmountRevertTooHigh() public {
        vm.prank(admin);
        vm.expectRevert(IRNBWStaking.MinStakeTooHigh.selector);
        staking.setMinStakeAmount(1_000_001e18);
    }

    function test_ExitFeeUsesNewRate() public {
        uint256 stakeAmount = 100 ether;

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();

        uint256 aliceShares = staking.shares(alice);

        vm.prank(admin);
        staking.setExitFeeBps(2000);

        uint256 balBefore = rnbwToken.balanceOf(alice);
        vm.prank(alice);
        staking.unstake(aliceShares);
        uint256 received = rnbwToken.balanceOf(alice) - balBefore;

        assertApproxEqAbs(received, 80 ether, staking.MINIMUM_SHARES());
    }

    function test_ShareInflationAttackMitigatedByDustGuard() public {
        rnbwToken.mint(alice, 100_000 ether);

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), type(uint256).max);
        staking.stake(7 ether);

        uint256 aliceShares = staking.shares(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IRNBWStaking.DustSharesRemaining.selector, alice, 1)
        );
        staking.unstake(aliceShares - 1);
        vm.stopPrank();
    }

    function test_BatchAllocateCashback() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        _depositCashback(30 ether);

        uint256 expiry = block.timestamp + 60;

        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 10 ether;
        amounts[1] = 20 ether;

        uint256[] memory nonces = new uint256[](2);
        nonces[0] = 1;
        nonces[1] = 2;

        uint256[] memory expiries = new uint256[](2);
        expiries[0] = expiry;
        expiries[1] = expiry;

        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signAllocateCashback(alice, 10 ether, 1, expiry);
        sigs[1] = _signAllocateCashback(bob, 20 ether, 2, expiry);

        staking.batchAllocateCashbackWithSignature(users, amounts, nonces, expiries, sigs);

        assertEq(staking.totalPooledRnbw(), 230 ether);
        assertEq(staking.cashbackReserve(), 0);
    }

    function test_BatchAllocateCashbackRevertBatchTooLarge() public {
        address[] memory users = new address[](51);
        uint256[] memory amounts = new uint256[](51);
        uint256[] memory nonces = new uint256[](51);
        uint256[] memory expiries = new uint256[](51);
        bytes[] memory sigs = new bytes[](51);

        vm.expectRevert(IRNBWStaking.BatchTooLarge.selector);
        staking.batchAllocateCashbackWithSignature(users, amounts, nonces, expiries, sigs);
    }

    function test_BatchAllocateCashbackRevertArrayLengthMismatch() public {
        address[] memory users = new address[](2);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory nonces = new uint256[](2);
        uint256[] memory expiries = new uint256[](2);
        bytes[] memory sigs = new bytes[](2);

        vm.expectRevert(IRNBWStaking.ArrayLengthMismatch.selector);
        staking.batchAllocateCashbackWithSignature(users, amounts, nonces, expiries, sigs);
    }

    function test_LifetimeFieldsStake() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 200 ether);
        staking.stake(100 ether);
        staking.stake(50 ether);
        vm.stopPrank();

        (,,,,, uint256 totalStaked,,) = staking.getPosition(alice);
        assertEq(totalStaked, 150 ether);
    }

    function test_LifetimeFieldsUnstake() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        uint256 aliceShares = staking.shares(alice);
        staking.unstake(aliceShares);
        vm.stopPrank();

        (,,,,, uint256 totalStaked, uint256 totalUnstaked, uint256 totalFees) = staking.getPosition(alice);
        assertEq(totalStaked, 100 ether);
        assertGt(totalUnstaked, 0);
        assertGt(totalFees, 0);
        assertApproxEqAbs(totalUnstaked + totalFees, 100 ether, staking.MINIMUM_SHARES());
    }

    function test_LifetimeFieldsCashback() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        _depositCashback(20 ether);

        uint256 nonce = 1;
        uint256 expiry = block.timestamp + 60;
        bytes memory sig = _signAllocateCashback(alice, 10 ether, nonce, expiry);
        staking.allocateCashbackWithSignature(alice, 10 ether, nonce, expiry, sig);

        nonce = 2;
        sig = _signAllocateCashback(alice, 5 ether, nonce, expiry);
        staking.allocateCashbackWithSignature(alice, 5 ether, nonce, expiry, sig);

        (,,,, uint256 cashbackReceived,,,) = staking.getPosition(alice);
        assertEq(cashbackReceived, 15 ether);
        assertEq(staking.totalCashbackAllocated(), 15 ether);
    }

    function test_LifetimeFieldsPersistAfterFullUnstake() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 200 ether);
        staking.stake(100 ether);
        uint256 aliceShares = staking.shares(alice);
        staking.unstake(aliceShares);
        vm.stopPrank();

        (,,,, uint256 cashback, uint256 totalStaked, uint256 totalUnstaked, uint256 totalFees) =
            staking.getPosition(alice);

        assertEq(totalStaked, 100 ether);
        assertGt(totalUnstaked, 0);
        assertGt(totalFees, 0);

        vm.startPrank(alice);
        staking.stake(50 ether);
        vm.stopPrank();

        (,,,, uint256 cashback2, uint256 totalStaked2, uint256 totalUnstaked2, uint256 totalFees2) =
            staking.getPosition(alice);

        assertEq(cashback2, cashback);
        assertEq(totalStaked2, 150 ether);
        assertEq(totalUnstaked2, totalUnstaked);
        assertEq(totalFees2, totalFees);
    }

    function test_TotalCashbackAllocatedGlobal() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        _depositCashback(20 ether);

        uint256 expiry = block.timestamp + 60;

        bytes memory sig1 = _signAllocateCashback(alice, 5 ether, 1, expiry);
        staking.allocateCashbackWithSignature(alice, 5 ether, 1, expiry, sig1);

        bytes memory sig2 = _signAllocateCashback(bob, 3 ether, 1, expiry);
        staking.allocateCashbackWithSignature(bob, 3 ether, 1, expiry, sig2);

        assertEq(staking.totalCashbackAllocated(), 8 ether);

        (,,,, uint256 aliceCashback,,,) = staking.getPosition(alice);
        (,,,, uint256 bobCashback,,,) = staking.getPosition(bob);
        assertEq(aliceCashback, 5 ether);
        assertEq(bobCashback, 3 ether);
    }

    function test_UnstakeAll() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        uint256 aliceShares = staking.shares(alice);
        assertGt(aliceShares, 0);

        staking.unstakeAll();
        vm.stopPrank();

        assertEq(staking.shares(alice), 0);
    }

    function test_UnstakeAllRevertNoPosition() public {
        vm.prank(alice);
        vm.expectRevert(IRNBWStaking.ZeroAmount.selector);
        staking.unstakeAll();
    }

    function test_PreviewUnstake() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        uint256 aliceShares = staking.shares(alice);
        (uint256 rnbwValue, uint256 exitFee, uint256 netReceived) = staking.previewUnstake(aliceShares);

        assertGt(rnbwValue, 0);
        assertGt(exitFee, 0);
        assertEq(netReceived, rnbwValue - exitFee);

        uint256 balBefore = rnbwToken.balanceOf(alice);
        vm.prank(alice);
        staking.unstakeAll();
        uint256 balAfter = rnbwToken.balanceOf(alice);

        assertEq(balAfter - balBefore, netReceived);
    }

    function test_PreviewStake() public {
        uint256 preview = staking.previewStake(100 ether);

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        assertEq(staking.shares(alice), preview);
    }

    function test_PreviewStakeAfterExitFee() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        staking.unstakeAll();
        vm.stopPrank();

        uint256 preview = staking.previewStake(50 ether);

        vm.startPrank(bob);
        rnbwToken.approve(address(staking), 50 ether);
        staking.stake(50 ether);
        vm.stopPrank();

        assertEq(staking.shares(bob), preview);
    }

    function test_ConstructorRevertZeroToken() public {
        vm.expectRevert(IRNBWStaking.ZeroAddress.selector);
        new RNBWStaking(address(0), admin, signer);
    }

    function test_ConstructorRevertZeroSafe() public {
        vm.expectRevert(IRNBWStaking.ZeroAddress.selector);
        new RNBWStaking(address(rnbwToken), address(0), signer);
    }

    function test_ConstructorRevertZeroSigner() public {
        vm.expectRevert(IRNBWStaking.ZeroAddress.selector);
        new RNBWStaking(address(rnbwToken), admin, address(0));
    }

    function test_PreviewStakeDustOnEmptyPool() public view {
        uint256 preview = staking.previewStake(500);
        assertEq(preview, 0);
    }

    function test_PreviewStakeSecondStaker() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        uint256 preview = staking.previewStake(50 ether);

        vm.startPrank(bob);
        rnbwToken.approve(address(staking), 50 ether);
        staking.stake(50 ether);
        vm.stopPrank();

        assertEq(staking.shares(bob), preview);
    }

    function test_GetSharesForRnbwEmptyPool() public view {
        uint256 shares_ = staking.getSharesForRnbw(100 ether);
        assertEq(shares_, 100 ether - staking.MINIMUM_SHARES());
    }

    function test_GetSharesForRnbwEmptyPoolDust() public view {
        uint256 shares_ = staking.getSharesForRnbw(500);
        assertEq(shares_, 0);
    }

    function test_AddTrustedSignerRevertZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(IRNBWStaking.ZeroAddress.selector);
        staking.addTrustedSigner(address(0));
    }

    function test_InvalidSignerReverts() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        _depositCashback(50 ether);

        uint256 fakePk = 0xDEAD;
        bytes32 structHash = keccak256(
            abi.encode(staking.ALLOCATE_CASHBACK_TYPEHASH(), alice, 10 ether, uint256(0), block.timestamp + 1 hours)
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(staking.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(fakePk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.expectRevert(IRNBWStaking.InvalidSignature.selector);
        staking.allocateCashbackWithSignature(alice, 10 ether, 0, block.timestamp + 1 hours, sig);
    }

    function test_BatchCashbackRevertInsufficientReserve() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        _depositCashback(5 ether);

        address[] memory users = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        uint256[] memory nonces = new uint256[](2);
        uint256[] memory expiries = new uint256[](2);
        bytes[] memory sigs = new bytes[](2);

        users[0] = alice;
        users[1] = alice;
        amounts[0] = 3 ether;
        amounts[1] = 3 ether;
        nonces[0] = 100;
        nonces[1] = 101;
        expiries[0] = block.timestamp + 1 hours;
        expiries[1] = block.timestamp + 1 hours;
        sigs[0] = _signAllocateCashback(alice, 3 ether, 100, expiries[0]);
        sigs[1] = _signAllocateCashback(alice, 3 ether, 101, expiries[1]);

        vm.expectRevert(IRNBWStaking.InsufficientCashbackBalance.selector);
        staking.batchAllocateCashbackWithSignature(users, amounts, nonces, expiries, sigs);
    }

    function test_PreviewUnstakeDustShares() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        _depositCashback(1000 ether);

        for (uint256 i = 0; i < 10; ++i) {
            bytes memory sig = _signAllocateCashback(alice, 100 ether, i, block.timestamp + 1 hours);
            staking.allocateCashbackWithSignature(alice, 100 ether, i, block.timestamp + 1 hours, sig);
        }

        (uint256 rnbwValue, uint256 exitFee, uint256 netReceived) = staking.previewUnstake(1);
        assertGt(rnbwValue, 0);
        assertGt(exitFee, 0);
        if (rnbwValue <= exitFee) {
            assertEq(netReceived, 0);
        }
    }

    function test_UnstakeAllResidualSweep() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.prank(bob);
        staking.unstakeAll();

        uint256 safeBefore = rnbwToken.balanceOf(admin);
        vm.prank(alice);
        staking.unstakeAll();
        uint256 safeAfter = rnbwToken.balanceOf(admin);
        assertGt(safeAfter - safeBefore, 0);

        assertEq(staking.totalShares(), 0);
        assertEq(staking.totalPooledRnbw(), 0);
    }

    function test_RestakeAfterFullUnstake() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 200 ether);
        staking.stake(100 ether);
        staking.unstakeAll();

        (,,, uint256 stakingStart,,,,) = staking.getPosition(alice);
        assertEq(stakingStart, 0);

        vm.warp(block.timestamp + 1 days);
        staking.stake(50 ether);
        vm.stopPrank();

        (uint256 stakedAmount,, uint256 lastUpdate, uint256 newStart, uint256 cashback, uint256 totalStaked,,) =
            staking.getPosition(alice);
        assertGt(stakedAmount, 0);
        assertGt(newStart, 0);
        assertGt(lastUpdate, 0);
        assertEq(totalStaked, 150 ether);
        assertEq(cashback, 0);
    }

    function test_BatchCashbackPartialInvalidSignature() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        _depositCashback(50 ether);

        address[] memory users = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        uint256[] memory nonces = new uint256[](2);
        uint256[] memory expiries = new uint256[](2);
        bytes[] memory sigs = new bytes[](2);

        users[0] = alice;
        users[1] = alice;
        amounts[0] = 5 ether;
        amounts[1] = 5 ether;
        nonces[0] = 200;
        nonces[1] = 201;
        expiries[0] = block.timestamp + 1 hours;
        expiries[1] = block.timestamp + 1 hours;
        sigs[0] = _signAllocateCashback(alice, 5 ether, 200, expiries[0]);

        uint256 fakePk = 0xDEAD;
        bytes32 structHash =
            keccak256(abi.encode(staking.ALLOCATE_CASHBACK_TYPEHASH(), alice, 5 ether, uint256(201), expiries[1]));
        bytes32 digest = MessageHashUtils.toTypedDataHash(staking.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(fakePk, digest);
        sigs[1] = abi.encodePacked(r, s, v);

        vm.expectRevert(IRNBWStaking.InvalidSignature.selector);
        staking.batchAllocateCashbackWithSignature(users, amounts, nonces, expiries, sigs);
    }

    function test_EmergencyWithdrawNonRnbwToken() public {
        MockERC20 otherToken = new MockERC20("Other", "OTH", 18);
        otherToken.mint(address(staking), 500 ether);

        uint256 safeBefore = otherToken.balanceOf(admin);
        vm.prank(admin);
        staking.emergencyWithdraw(address(otherToken), 500 ether);
        uint256 safeAfter = otherToken.balanceOf(admin);

        assertEq(safeAfter - safeBefore, 500 ether);
    }

    function test_ExistingStakerCanAddBelowMinimum() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);

        rnbwToken.approve(address(staking), 0.5 ether);
        staking.stake(0.5 ether);
        vm.stopPrank();

        (uint256 stakedAmount,,,,,,,) = staking.getPosition(alice);
        assertGt(stakedAmount, 100 ether);
    }

    function test_PauseRevertUnauthorized() public {
        vm.prank(alice);
        vm.expectRevert(IRNBWStaking.Unauthorized.selector);
        staking.pause();
    }

    function test_UnpauseRevertUnauthorized() public {
        vm.prank(admin);
        staking.pause();

        vm.prank(alice);
        vm.expectRevert(IRNBWStaking.Unauthorized.selector);
        staking.unpause();
    }

    function test_AddTrustedSignerRevertUnauthorized() public {
        vm.prank(alice);
        vm.expectRevert(IRNBWStaking.Unauthorized.selector);
        staking.addTrustedSigner(makeAddr("newSignerUnauthorized"));
    }

    function test_RemoveTrustedSignerRevertUnauthorized() public {
        address newSigner = makeAddr("newSignerUnauthorizedRemove");

        vm.prank(admin);
        staking.addTrustedSigner(newSigner);

        vm.prank(alice);
        vm.expectRevert(IRNBWStaking.Unauthorized.selector);
        staking.removeTrustedSigner(newSigner);
    }

    function test_SetExitFeeBpsRevertUnauthorized() public {
        vm.prank(alice);
        vm.expectRevert(IRNBWStaking.Unauthorized.selector);
        staking.setExitFeeBps(1200);
    }

    function test_SetMinStakeAmountRevertUnauthorized() public {
        vm.prank(alice);
        vm.expectRevert(IRNBWStaking.Unauthorized.selector);
        staking.setMinStakeAmount(2 ether);
    }

    function test_EmergencyWithdrawRevertUnauthorized() public {
        MockERC20 otherToken = new MockERC20("Other Unauthorized", "OTHU", 18);
        otherToken.mint(address(staking), 100 ether);

        vm.prank(alice);
        vm.expectRevert(IRNBWStaking.Unauthorized.selector);
        staking.emergencyWithdraw(address(otherToken), 1 ether);
    }

    function test_EmergencyWithdrawRevertZeroAmount() public {
        vm.prank(admin);
        vm.expectRevert(IRNBWStaking.ZeroAmount.selector);
        staking.emergencyWithdraw(address(rnbwToken), 0);
    }

    function test_EmergencyWithdrawRevertZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(IRNBWStaking.ZeroAddress.selector);
        staking.emergencyWithdraw(address(0), 1 ether);
    }

    function test_BatchAllocateCashbackEmptyArraysReverts() public {
        address[] memory users = new address[](0);
        uint256[] memory amounts = new uint256[](0);
        uint256[] memory nonces = new uint256[](0);
        uint256[] memory expiries = new uint256[](0);
        bytes[] memory sigs = new bytes[](0);

        vm.expectRevert(IRNBWStaking.EmptyBatch.selector);
        staking.batchAllocateCashbackWithSignature(users, amounts, nonces, expiries, sigs);
    }

    function test_AllocateCashbackExpiryAtCurrentTimestampAllowed() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        _depositCashback(10 ether);

        uint256 nonce = 777;
        uint256 expiry = block.timestamp;
        bytes memory sig = _signAllocateCashback(alice, 10 ether, nonce, expiry);

        staking.allocateCashbackWithSignature(alice, 10 ether, nonce, expiry, sig);

        assertTrue(staking.isNonceUsed(alice, nonce));
    }

    function test_AllocateCashbackRevertExpiredOneSecondLater() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        _depositCashback(10 ether);

        uint256 nonce = 778;
        uint256 expiry = block.timestamp;
        bytes memory sig = _signAllocateCashback(alice, 10 ether, nonce, expiry);

        vm.warp(block.timestamp + 1);
        vm.expectRevert(IRNBWStaking.SignatureExpired.selector);
        staking.allocateCashbackWithSignature(alice, 10 ether, nonce, expiry, sig);
    }

    function test_ProposeSafeOverwritePendingSafe() public {
        address safeA = makeAddr("safeA");
        address safeB = makeAddr("safeB");

        vm.prank(admin);
        staking.proposeSafe(safeA);
        assertEq(staking.pendingSafe(), safeA);

        vm.prank(admin);
        staking.proposeSafe(safeB);
        assertEq(staking.pendingSafe(), safeB);

        vm.prank(safeA);
        vm.expectRevert(IRNBWStaking.NotPendingSafe.selector);
        staking.acceptSafe();

        vm.prank(safeB);
        staking.acceptSafe();

        assertEq(staking.safe(), safeB);
        assertEq(staking.pendingSafe(), address(0));
    }

    function test_CancelProposedSafe() public {
        address newSafe = makeAddr("newSafe");
        vm.prank(admin);
        staking.proposeSafe(newSafe);
        assertEq(staking.pendingSafe(), newSafe);

        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit IRNBWStaking.SafeProposalCancelled(admin, newSafe);
        staking.cancelProposedSafe();
        assertEq(staking.pendingSafe(), address(0));
    }

    function test_CancelProposedSafeRevertNoPending() public {
        vm.prank(admin);
        vm.expectRevert(IRNBWStaking.NoPendingSafe.selector);
        staking.cancelProposedSafe();
    }

    function test_CancelProposedSafeRevertUnauthorized() public {
        address newSafe = makeAddr("newSafe");
        vm.prank(admin);
        staking.proposeSafe(newSafe);

        vm.prank(alice);
        vm.expectRevert(IRNBWStaking.Unauthorized.selector);
        staking.cancelProposedSafe();
    }

    function test_StakeFor() public {
        uint256 amount = 100 ether;

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), amount);
        staking.stakeFor(bob, amount);
        vm.stopPrank();

        uint256 deadShares = staking.MINIMUM_SHARES();
        assertEq(staking.shares(bob), amount - deadShares);
        assertEq(staking.shares(alice), 0);
        assertEq(rnbwToken.balanceOf(alice), INITIAL_BALANCE - amount);
        assertEq(staking.totalPooledRnbw(), amount);
    }

    function test_StakeForMetadata() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stakeFor(bob, 100 ether);
        vm.stopPrank();

        (uint256 stakedAmount, uint256 userShares,, uint256 stakingStartTime,, uint256 totalStaked,,) =
            staking.getPosition(bob);
        assertGt(stakedAmount, 0);
        assertGt(userShares, 0);
        assertEq(stakingStartTime, block.timestamp);
        assertEq(totalStaked, 100 ether);

        (,,, uint256 aliceStart,, uint256 aliceStaked,,) = staking.getPosition(alice);
        assertEq(aliceStart, 0);
        assertEq(aliceStaked, 0);
    }

    function test_StakeForRecipientCanUnstake() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stakeFor(bob, 100 ether);
        vm.stopPrank();

        uint256 bobShares = staking.shares(bob);
        uint256 bobBalBefore = rnbwToken.balanceOf(bob);

        vm.prank(bob);
        staking.unstake(bobShares);

        assertEq(staking.shares(bob), 0);
        assertGt(rnbwToken.balanceOf(bob), bobBalBefore);
    }

    function test_StakeForRevertZeroRecipient() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        vm.expectRevert(IRNBWStaking.ZeroAddress.selector);
        staking.stakeFor(address(0), 100 ether);
        vm.stopPrank();
    }

    function test_StakeForRevertZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(IRNBWStaking.ZeroAmount.selector);
        staking.stakeFor(bob, 0);
    }

    function test_StakeForRevertBelowMinimum() public {
        uint256 amount = 0.5 ether;

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), amount);
        vm.expectRevert(
            abi.encodeWithSelector(IRNBWStaking.BelowMinimumStake.selector, bob, amount, staking.minStakeAmount())
        );
        staking.stakeFor(bob, amount);
        vm.stopPrank();
    }

    function test_StakeForExistingPosition() public {
        vm.startPrank(bob);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        uint256 bobSharesBefore = staking.shares(bob);

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 50 ether);
        staking.stakeFor(bob, 50 ether);
        vm.stopPrank();

        assertGt(staking.shares(bob), bobSharesBefore);
        assertEq(staking.totalPooledRnbw(), 150 ether);
    }

    function test_StakeForRevertContractRecipient() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        vm.expectRevert(IRNBWStaking.InvalidRecipient.selector);
        staking.stakeFor(address(staking), 100 ether);
        vm.stopPrank();
    }

    function test_StakeForRevertDeadAddressRecipient() public {
        address dead = staking.DEAD_ADDRESS();
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        vm.expectRevert(IRNBWStaking.InvalidRecipient.selector);
        staking.stakeFor(dead, 100 ether);
        vm.stopPrank();
    }

    function test_DustUnstakeRevertsBelowMinimumShares() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        _depositCashback(1000 ether);
        for (uint256 i = 0; i < 10; ++i) {
            bytes memory sig = _signAllocateCashback(alice, 100 ether, i, block.timestamp + 1 hours);
            staking.allocateCashbackWithSignature(alice, 100 ether, i, block.timestamp + 1 hours, sig);
        }

        uint256 aliceShares = staking.shares(alice);
        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IRNBWStaking.DustSharesRemaining.selector, alice, 1)
        );
        staking.unstake(aliceShares - 1);
        vm.stopPrank();

        vm.prank(alice);
        staking.unstakeAll();
        assertEq(staking.shares(alice), 0);
    }

    // ───────────────────────────────────────────────────────────
    // stakeForWithSignature
    // ───────────────────────────────────────────────────────────

    function test_StakeForWithSignature() public {
        uint256 amount = 100 ether;
        uint256 nonce = 42;
        uint256 expiry = block.timestamp + 1 hours;

        _depositStakingReserve(amount);
        bytes memory sig = _signStakeFor(bob, amount, nonce, expiry);

        staking.stakeForWithSignature(bob, amount, nonce, expiry, sig);

        uint256 deadShares = staking.MINIMUM_SHARES();
        assertEq(staking.shares(bob), amount - deadShares);
        assertEq(staking.totalPooledRnbw(), amount);
        assertEq(staking.stakingReserve(), 0);
    }

    function test_StakeForWithSignatureRelayerSubmits() public {
        address relayer = makeAddr("relayer");
        uint256 amount = 100 ether;
        uint256 expiry = block.timestamp + 1 hours;

        _depositStakingReserve(amount);
        bytes memory sig = _signStakeFor(bob, amount, 0, expiry);

        vm.prank(relayer);
        staking.stakeForWithSignature(bob, amount, 0, expiry, sig);

        uint256 deadShares = staking.MINIMUM_SHARES();
        assertEq(staking.shares(bob), amount - deadShares);
        assertEq(rnbwToken.balanceOf(relayer), 0);
    }

    function test_StakeForWithSignatureMetadata() public {
        uint256 amount = 100 ether;
        _depositStakingReserve(amount);
        bytes memory sig = _signStakeFor(bob, amount, 0, block.timestamp + 1 hours);

        staking.stakeForWithSignature(bob, amount, 0, block.timestamp + 1 hours, sig);

        (,,, uint256 stakingStartTime,, uint256 totalStaked,,) = staking.getPosition(bob);
        assertEq(stakingStartTime, block.timestamp);
        assertEq(totalStaked, amount);
    }

    function test_StakeForWithSignatureRevertExpired() public {
        uint256 amount = 100 ether;
        uint256 expiry = block.timestamp + 1 hours;
        _depositStakingReserve(amount);
        bytes memory sig = _signStakeFor(bob, amount, 0, expiry);

        vm.warp(expiry + 1);

        vm.expectRevert(IRNBWStaking.SignatureExpired.selector);
        staking.stakeForWithSignature(bob, amount, 0, expiry, sig);
    }

    function test_StakeForWithSignatureRevertReplayNonce() public {
        uint256 amount = 100 ether;
        uint256 expiry = block.timestamp + 1 hours;
        _depositStakingReserve(amount * 2);
        bytes memory sig = _signStakeFor(bob, amount, 0, expiry);

        staking.stakeForWithSignature(bob, amount, 0, expiry, sig);

        vm.expectRevert(IRNBWStaking.NonceAlreadyUsed.selector);
        staking.stakeForWithSignature(bob, amount, 0, expiry, sig);
    }

    function test_StakeForWithSignatureRevertInvalidSigner() public {
        uint256 amount = 100 ether;
        uint256 expiry = block.timestamp + 1 hours;
        _depositStakingReserve(amount);

        uint256 fakePk = 0xBAD;
        bytes32 structHash = keccak256(abi.encode(staking.STAKE_FOR_TYPEHASH(), bob, amount, uint256(0), expiry));
        bytes32 digest = MessageHashUtils.toTypedDataHash(staking.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(fakePk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.expectRevert(IRNBWStaking.InvalidSignature.selector);
        staking.stakeForWithSignature(bob, amount, 0, expiry, sig);
    }

    function test_StakeForWithSignatureRevertZeroRecipient() public {
        uint256 amount = 100 ether;
        _depositStakingReserve(amount);
        bytes memory sig = _signStakeFor(address(0), amount, 0, block.timestamp + 1 hours);

        vm.expectRevert(IRNBWStaking.ZeroAddress.selector);
        staking.stakeForWithSignature(address(0), amount, 0, block.timestamp + 1 hours, sig);
    }

    function test_StakeForWithSignatureRevertDeadAddress() public {
        address dead = staking.DEAD_ADDRESS();
        uint256 amount = 100 ether;
        _depositStakingReserve(amount);
        bytes memory sig = _signStakeFor(dead, amount, 0, block.timestamp + 1 hours);

        vm.expectRevert(IRNBWStaking.InvalidRecipient.selector);
        staking.stakeForWithSignature(dead, amount, 0, block.timestamp + 1 hours, sig);
    }

    function test_StakeForWithSignatureRevertContractRecipient() public {
        uint256 amount = 100 ether;
        _depositStakingReserve(amount);
        bytes memory sig = _signStakeFor(address(staking), amount, 0, block.timestamp + 1 hours);

        vm.expectRevert(IRNBWStaking.InvalidRecipient.selector);
        staking.stakeForWithSignature(address(staking), amount, 0, block.timestamp + 1 hours, sig);
    }

    function test_StakeForWithSignatureRevertInsufficientReserve() public {
        uint256 amount = 100 ether;
        _depositStakingReserve(50 ether);
        bytes memory sig = _signStakeFor(bob, amount, 0, block.timestamp + 1 hours);

        vm.expectRevert(IRNBWStaking.InsufficientStakingBalance.selector);
        staking.stakeForWithSignature(bob, amount, 0, block.timestamp + 1 hours, sig);
    }

    function test_StakeForWithSignatureSharedNonceDifferentUsers() public {
        uint256 amount = 100 ether;
        uint256 nonce = 99;
        uint256 expiry = block.timestamp + 1 hours;

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();

        _depositCashback(50 ether);
        bytes memory cashbackSig = _signAllocateCashback(alice, 10 ether, nonce, expiry);
        staking.allocateCashbackWithSignature(alice, 10 ether, nonce, expiry, cashbackSig);

        _depositStakingReserve(10 ether);
        bytes memory stakeForSig = _signStakeFor(bob, 10 ether, nonce, expiry);
        staking.stakeForWithSignature(bob, 10 ether, nonce, expiry, stakeForSig);

        assertGt(staking.shares(bob), 0);
    }

    function test_StakeForWithSignatureSharedNonceSameUserCollides() public {
        uint256 amount = 100 ether;
        uint256 nonce = 5;
        uint256 expiry = block.timestamp + 1 hours;

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();

        _depositCashback(50 ether);
        bytes memory cashbackSig = _signAllocateCashback(alice, 10 ether, nonce, expiry);
        staking.allocateCashbackWithSignature(alice, 10 ether, nonce, expiry, cashbackSig);

        _depositStakingReserve(10 ether);
        bytes memory stakeForSig = _signStakeFor(alice, 10 ether, nonce, expiry);

        vm.expectRevert(IRNBWStaking.NonceAlreadyUsed.selector);
        staking.stakeForWithSignature(alice, 10 ether, nonce, expiry, stakeForSig);
    }

    function test_FundStakingReserve() public {
        uint256 amount = 500 ether;
        rnbwToken.mint(admin, amount);
        vm.startPrank(admin);
        rnbwToken.approve(address(staking), amount);
        staking.fundStakingReserve(amount);
        vm.stopPrank();

        assertEq(staking.stakingReserve(), amount);
    }

    function test_FundStakingReserveRevertZeroAmount() public {
        vm.prank(admin);
        vm.expectRevert(IRNBWStaking.ZeroAmount.selector);
        staking.fundStakingReserve(0);
    }

    function test_FundStakingReserveRevertUnauthorized() public {
        vm.prank(alice);
        vm.expectRevert(IRNBWStaking.Unauthorized.selector);
        staking.fundStakingReserve(100 ether);
    }

    function test_DefundStakingReserve() public {
        _depositStakingReserve(500 ether);

        vm.prank(admin);
        staking.defundStakingReserve(200 ether);

        assertEq(staking.stakingReserve(), 300 ether);
        assertEq(rnbwToken.balanceOf(admin), 200 ether);
    }

    function test_DefundStakingReserveRevertInsufficientBalance() public {
        _depositStakingReserve(100 ether);

        vm.prank(admin);
        vm.expectRevert(IRNBWStaking.InsufficientStakingBalance.selector);
        staking.defundStakingReserve(200 ether);
    }

    function test_DefundStakingReserveRevertZeroAmount() public {
        vm.prank(admin);
        vm.expectRevert(IRNBWStaking.ZeroAmount.selector);
        staking.defundStakingReserve(0);
    }

    function test_DefundStakingReserveRevertUnauthorized() public {
        _depositStakingReserve(100 ether);
        vm.prank(alice);
        vm.expectRevert(IRNBWStaking.Unauthorized.selector);
        staking.defundStakingReserve(50 ether);
    }

    function test_EmergencyWithdrawProtectsStakingReserve() public {
        _depositStakingReserve(100 ether);
        _depositCashback(50 ether);

        rnbwToken.mint(address(staking), 25 ether);

        vm.prank(admin);
        staking.emergencyWithdraw(address(rnbwToken), 25 ether);

        vm.prank(admin);
        vm.expectRevert(IRNBWStaking.InsufficientExcess.selector);
        staking.emergencyWithdraw(address(rnbwToken), 1);
    }

    /*//////////////////////////////////////////////////////////////
                          DRIP SYSTEM TESTS
    //////////////////////////////////////////////////////////////*/

    function test_DripExitFeesNotInstant() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        uint256 rateBefore = staking.getExchangeRate();

        vm.prank(bob);
        staking.unstakeAll();

        assertEq(staking.getExchangeRate(), rateBefore);
        assertGt(staking.undistributedFees(), 0);
    }

    function test_DripLinearDistribution() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.prank(bob);
        staking.unstakeAll();

        uint256 totalFees = staking.undistributedFees();
        assertGt(totalFees, 0);

        vm.warp(block.timestamp + 3.5 days);
        staking.exposedSyncPool();

        uint256 halfDripped = totalFees - staking.undistributedFees();
        assertApproxEqRel(halfDripped, totalFees / 2, 0.01e18);

        vm.warp(block.timestamp + 3.5 days);
        staking.exposedSyncPool();

        assertEq(staking.undistributedFees(), 0);
    }

    function test_DripFullDistributionAfter7Days() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.prank(bob);
        staking.unstakeAll();

        vm.warp(block.timestamp + 7 days);
        staking.exposedSyncPool();

        assertEq(staking.undistributedFees(), 0);
    }

    function test_DripOverlappingFees() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        rnbwToken.mint(alice, 100 ether);
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        vm.stopPrank();

        uint256 bobHalf = staking.shares(bob) / 2;
        vm.prank(bob);
        staking.unstake(bobHalf);
        vm.warp(block.timestamp + 3 days);

        vm.prank(bob);
        staking.unstakeAll();

        assertGt(staking.undistributedFees(), 0);

        vm.warp(block.timestamp + 7 days);
        staking.exposedSyncPool();

        assertEq(staking.undistributedFees(), 0);
    }

    function test_DripViewFunctionsIncludePending() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        uint256 rateBefore = staking.getExchangeRate();

        vm.prank(bob);
        staking.unstakeAll();

        assertEq(staking.getExchangeRate(), rateBefore);

        vm.warp(block.timestamp + 3.5 days);

        uint256 rateMid = staking.getExchangeRate();
        assertGt(rateMid, rateBefore);

        vm.warp(block.timestamp + 3.5 days);

        uint256 rateFull = staking.getExchangeRate();
        assertGt(rateFull, rateMid);
    }

    function test_DripSyncPoolIdempotent() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.prank(bob);
        staking.unstakeAll();

        vm.warp(block.timestamp + 7 days);
        staking.exposedSyncPool();

        uint256 poolAfterFirst = staking.totalPooledRnbw();
        uint256 feesAfterFirst = staking.undistributedFees();

        staking.exposedSyncPool();
        staking.exposedSyncPool();

        assertEq(staking.totalPooledRnbw(), poolAfterFirst);
        assertEq(staking.undistributedFees(), feesAfterFirst);
    }

    function test_DripResidualSweepIncludesUndistributed() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        uint256 safeBefore = rnbwToken.balanceOf(admin);

        vm.prank(alice);
        staking.unstakeAll();

        assertEq(staking.totalShares(), 0);
        assertEq(staking.totalPooledRnbw(), 0);
        assertEq(staking.undistributedFees(), 0);
        assertEq(staking.rewardRate(), 0);
        assertEq(staking.dripEndTime(), 0);
        assertGt(rnbwToken.balanceOf(admin), safeBefore);
    }

    function test_DripEmergencyWithdrawProtectsUndistributed() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.prank(bob);
        staking.unstakeAll();

        assertGt(staking.undistributedFees(), 0);

        rnbwToken.mint(address(staking), 10 ether);

        vm.prank(admin);
        staking.emergencyWithdraw(address(rnbwToken), 10 ether);

        vm.prank(admin);
        vm.expectRevert(IRNBWStaking.InsufficientExcess.selector);
        staking.emergencyWithdraw(address(rnbwToken), 1);
    }

    function test_DripExchangeRateUpdatedEvent() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.prank(bob);
        staking.unstakeAll();

        vm.warp(block.timestamp + 7 days);

        vm.expectEmit(false, false, false, false);
        emit IRNBWStaking.ExchangeRateUpdated(0, 0);
        staking.exposedSyncPool();
    }

    function test_DripNoFeesNoEffect() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        uint256 rateBefore = staking.getExchangeRate();

        vm.warp(block.timestamp + 30 days);
        staking.exposedSyncPool();

        assertEq(staking.getExchangeRate(), rateBefore);
        assertEq(staking.undistributedFees(), 0);
    }

    function test_DripPreventsSelfAbsorption() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        rnbwToken.approve(address(staking), 10 ether);
        staking.stake(10 ether);
        vm.stopPrank();

        vm.prank(alice);
        staking.unstakeAll();

        (uint256 bobAfterInstant,,,,,,,) = staking.getPosition(bob);

        vm.warp(block.timestamp + 7 days);
        staking.exposedSyncPool();

        (uint256 bobAfterDrip,,,,,,,) = staking.getPosition(bob);

        assertGt(bobAfterDrip, bobAfterInstant);
    }

    /*//////////////////////////////////////////////////////////////
                      SET DRIP DURATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetDripDuration() public {
        vm.prank(admin);
        staking.setDripDuration(14 days);
        assertEq(staking.dripDuration(), 14 days);
    }

    function test_SetDripDurationEmitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit IRNBWStaking.DripDurationUpdated(7 days, 14 days);
        staking.setDripDuration(14 days);
    }

    function test_SetDripDurationRevertUnauthorized() public {
        vm.prank(alice);
        vm.expectRevert(IRNBWStaking.Unauthorized.selector);
        staking.setDripDuration(14 days);
    }

    function test_SetDripDurationRevertTooLow() public {
        vm.prank(admin);
        vm.expectRevert(IRNBWStaking.DripDurationTooLow.selector);
        staking.setDripDuration(6 days);
    }

    function test_SetDripDurationRevertTooHigh() public {
        vm.prank(admin);
        vm.expectRevert(IRNBWStaking.DripDurationTooHigh.selector);
        staking.setDripDuration(61 days);
    }

    function test_SetDripDurationRevertNoChange() public {
        vm.prank(admin);
        vm.expectRevert(IRNBWStaking.NoChange.selector);
        staking.setDripDuration(7 days);
    }

    function test_SetDripDurationMidDrip() public {
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        rnbwToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.prank(bob);
        staking.unstakeAll();

        uint256 totalFees = staking.undistributedFees();
        uint256 poolAtUnstake = staking.totalPooledRnbw();
        assertGt(totalFees, 0);

        vm.warp(block.timestamp + 3 days);
        uint256 poolBefore = staking.totalPooledRnbw();

        vm.prank(admin);
        staking.setDripDuration(14 days);

        uint256 poolAfterSync = staking.totalPooledRnbw();
        uint256 remainingFees = staking.undistributedFees();

        assertEq(poolAfterSync + remainingFees, poolAtUnstake + totalFees);
        assertGt(poolAfterSync, poolBefore);
        assertGt(remainingFees, 0);
        assertEq(staking.rewardRate(), remainingFees / 14 days);
        assertEq(staking.dripEndTime(), block.timestamp + 14 days);

        uint256 totalAccounted = poolAfterSync + remainingFees;
        vm.warp(block.timestamp + 14 days);
        staking.exposedSyncPool();

        assertEq(staking.undistributedFees(), 0);
        assertEq(staking.totalPooledRnbw(), totalAccounted);
        assertEq(staking.rewardRate(), 0);
        assertEq(staking.dripEndTime(), 0);
    }

    function test_SetDripDurationBoundaries() public {
        vm.startPrank(admin);
        staking.setDripDuration(staking.MAX_DRIP_DURATION());
        assertEq(staking.dripDuration(), 60 days);

        staking.setDripDuration(staking.MIN_DRIP_DURATION());
        assertEq(staking.dripDuration(), 7 days);
        vm.stopPrank();
    }
}
