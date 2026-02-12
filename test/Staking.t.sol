// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {Staking} from "../src/Staking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract StakingTest is Test {
    Staking public staking;
    MockERC20 public stakingToken;
    MockERC20 public rewardToken;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 public constant INITIAL_BALANCE = 1000 ether;
    uint256 public constant REWARD_RATE = 1 ether;

    function setUp() public {
        stakingToken = new MockERC20("Staking Token", "STK", 18);
        rewardToken = new MockERC20("Reward Token", "RWD", 18);

        vm.prank(owner);
        staking = new Staking(address(stakingToken), address(rewardToken), owner);

        stakingToken.mint(alice, INITIAL_BALANCE);
        stakingToken.mint(bob, INITIAL_BALANCE);
        rewardToken.mint(address(staking), INITIAL_BALANCE * 100);

        vm.prank(owner);
        staking.setRewardRate(REWARD_RATE);
    }

    function test_Deployment() public view {
        assertEq(address(staking.stakingToken()), address(stakingToken));
        assertEq(address(staking.rewardToken()), address(rewardToken));
        assertEq(staking.owner(), owner);
    }

    function test_Stake() public {
        uint256 amount = 100 ether;

        vm.startPrank(alice);
        stakingToken.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();

        assertEq(staking.balances(alice), amount);
        assertEq(staking.totalStaked(), amount);
        assertEq(stakingToken.balanceOf(alice), INITIAL_BALANCE - amount);
    }

    function test_StakeRevertZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(Staking.ZeroAmount.selector);
        staking.stake(0);
    }

    function test_Withdraw() public {
        uint256 stakeAmount = 100 ether;
        uint256 withdrawAmount = 50 ether;

        vm.startPrank(alice);
        stakingToken.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        staking.withdraw(withdrawAmount);
        vm.stopPrank();

        assertEq(staking.balances(alice), stakeAmount - withdrawAmount);
        assertEq(staking.totalStaked(), stakeAmount - withdrawAmount);
    }

    function test_WithdrawRevertInsufficientBalance() public {
        uint256 amount = 100 ether;

        vm.startPrank(alice);
        stakingToken.approve(address(staking), amount);
        staking.stake(amount);
        vm.expectRevert(Staking.InsufficientBalance.selector);
        staking.withdraw(amount + 1);
        vm.stopPrank();
    }

    function test_EarnRewards() public {
        uint256 amount = 100 ether;

        vm.startPrank(alice);
        stakingToken.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();

        vm.warp(block.timestamp + 100);

        uint256 earned = staking.earned(alice);
        assertGt(earned, 0);
    }

    function test_ClaimReward() public {
        uint256 amount = 100 ether;

        vm.startPrank(alice);
        stakingToken.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();

        vm.warp(block.timestamp + 100);

        uint256 earnedBefore = staking.earned(alice);
        uint256 balanceBefore = rewardToken.balanceOf(alice);

        vm.prank(alice);
        staking.claimReward();

        assertEq(rewardToken.balanceOf(alice), balanceBefore + earnedBefore);
        assertEq(staking.earned(alice), 0);
    }

    function test_Exit() public {
        uint256 amount = 100 ether;

        vm.startPrank(alice);
        stakingToken.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();

        vm.warp(block.timestamp + 100);

        vm.prank(alice);
        staking.exit();

        assertEq(staking.balances(alice), 0);
        assertEq(stakingToken.balanceOf(alice), INITIAL_BALANCE);
    }

    function test_Pause() public {
        vm.prank(owner);
        staking.pause();

        vm.startPrank(alice);
        stakingToken.approve(address(staking), 100 ether);
        vm.expectRevert();
        staking.stake(100 ether);
        vm.stopPrank();
    }

    function test_Unpause() public {
        vm.startPrank(owner);
        staking.pause();
        staking.unpause();
        vm.stopPrank();

        vm.startPrank(alice);
        stakingToken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        assertEq(staking.balances(alice), 100 ether);
    }

    function test_OnlyOwnerCanSetRewardRate() public {
        vm.prank(alice);
        vm.expectRevert();
        staking.setRewardRate(2 ether);
    }

    function test_RecoverERC20() public {
        MockERC20 randomToken = new MockERC20("Random", "RND", 18);
        randomToken.mint(address(staking), 100 ether);

        vm.prank(owner);
        staking.recoverERC20(address(randomToken), 100 ether);

        assertEq(randomToken.balanceOf(owner), 100 ether);
    }

    function test_CannotRecoverStakingToken() public {
        vm.prank(owner);
        vm.expectRevert();
        staking.recoverERC20(address(stakingToken), 100 ether);
    }

    function testFuzz_Stake(uint256 amount) public {
        amount = bound(amount, 1, INITIAL_BALANCE);

        vm.startPrank(alice);
        stakingToken.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();

        assertEq(staking.balances(alice), amount);
    }

    function testFuzz_StakeAndWithdraw(uint256 stakeAmount, uint256 withdrawAmount) public {
        stakeAmount = bound(stakeAmount, 1, INITIAL_BALANCE);
        withdrawAmount = bound(withdrawAmount, 1, stakeAmount);

        vm.startPrank(alice);
        stakingToken.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        staking.withdraw(withdrawAmount);
        vm.stopPrank();

        assertEq(staking.balances(alice), stakeAmount - withdrawAmount);
    }
}
