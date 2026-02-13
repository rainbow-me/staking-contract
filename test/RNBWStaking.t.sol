// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RNBWStaking} from "../src/RNBWStaking.sol";
import {IRNBWStaking} from "../src/interfaces/IRNBWStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract RNBWStakingTest is Test {
    RNBWStaking public staking;
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
        staking = new RNBWStaking(address(rnbwToken), admin, signer);

        rnbwToken.mint(alice, INITIAL_BALANCE);
        rnbwToken.mint(bob, INITIAL_BALANCE);
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

        assertEq(staking.shares(alice), amount);
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
        vm.expectRevert(IRNBWStaking.BelowMinimumStake.selector);
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

        uint256 sharesToBurn = 50 ether;
        staking.unstake(sharesToBurn);
        vm.stopPrank();

        assertEq(staking.shares(alice), 50 ether);
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
        vm.expectRevert(IRNBWStaking.InsufficientShares.selector);
        staking.unstake(200 ether);
        vm.stopPrank();
    }

    function test_UnstakeRevertNoPosition() public {
        vm.prank(alice);
        vm.expectRevert(IRNBWStaking.NoStakePosition.selector);
        staking.unstake(100 ether);
    }

    function test_UnstakeExitFee() public {
        uint256 stakeAmount = 100 ether;

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);

        uint256 balanceBefore = rnbwToken.balanceOf(alice);
        staking.unstake(stakeAmount);
        uint256 balanceAfter = rnbwToken.balanceOf(alice);
        vm.stopPrank();

        uint256 received = balanceAfter - balanceBefore;
        uint256 expectedNet = (stakeAmount * 8500) / 10_000;
        assertEq(received, expectedNet);
    }

    function test_GetPosition() public {
        uint256 amount = 100 ether;

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();

        (uint256 stakedAmount, uint256 userShares, uint256 cashback,,) = staking.getPosition(alice);

        assertEq(stakedAmount, amount);
        assertEq(userShares, amount);
        assertEq(cashback, 0);
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

        rnbwToken.mint(address(staking), 10 ether);

        uint256 nonce = 1;
        uint256 expiry = block.timestamp + 60;
        bytes memory sig = _signAllocateCashback(alice, 10 ether, nonce, expiry);

        staking.allocateCashbackWithSignature(alice, 10 ether, nonce, expiry, sig);

        (,, uint256 cashback,,) = staking.getPosition(alice);
        assertEq(cashback, 10 ether);
        assertEq(staking.totalAllocatedCashback(), 10 ether);
    }

    function test_AllocateCashbackRevertNoPosition() public {
        rnbwToken.mint(address(staking), 10 ether);

        uint256 nonce = 1;
        uint256 expiry = block.timestamp + 60;
        bytes memory sig = _signAllocateCashback(alice, 10 ether, nonce, expiry);

        vm.expectRevert(IRNBWStaking.NoStakePosition.selector);
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

    function test_DepositCashbackRewards() public {
        rnbwToken.mint(admin, 1000 ether);

        vm.startPrank(admin);
        rnbwToken.approve(address(staking), 1000 ether);
        staking.depositCashbackRewards(1000 ether);
        vm.stopPrank();

        assertEq(rnbwToken.balanceOf(address(staking)), 1000 ether);
    }

    function test_DepositCashbackRewardsRevertUnauthorized() public {
        rnbwToken.mint(alice, 1000 ether);

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 1000 ether);
        vm.expectRevert(IRNBWStaking.Unauthorized.selector);
        staking.depositCashbackRewards(1000 ether);
        vm.stopPrank();
    }

    function test_DepositCashbackRewardsRevertZeroAmount() public {
        vm.prank(admin);
        vm.expectRevert(IRNBWStaking.ZeroAmount.selector);
        staking.depositCashbackRewards(0);
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

        assertEq(staking.shares(alice), 100 ether);
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

    function test_SetSafe() public {
        address newSafe = makeAddr("newSafe");

        vm.prank(admin);
        staking.setSafe(newSafe);

        assertEq(staking.safe(), newSafe);
    }

    function test_SetSafeRevertZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(IRNBWStaking.ZeroAddress.selector);
        staking.setSafe(address(0));
    }

    function test_SetSafeRevertUnauthorized() public {
        vm.prank(alice);
        vm.expectRevert(IRNBWStaking.Unauthorized.selector);
        staking.setSafe(makeAddr("newSafe"));
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

        assertEq(staking.shares(alice), amount);
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
        staking.setExitFeeBps(1000);
        assertEq(staking.exitFeeBps(), 1000);
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
        staking.setExitFeeBps(1500);
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
        staking.setExitFeeBps(1000);

        uint256 balBefore = rnbwToken.balanceOf(alice);
        vm.prank(alice);
        staking.unstake(aliceShares);
        uint256 received = rnbwToken.balanceOf(alice) - balBefore;

        assertEq(received, 90 ether);
    }
}
