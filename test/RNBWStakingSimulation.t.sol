// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {RNBWStaking} from "../src/RNBWStaking.sol";
import {IRNBWStaking} from "../src/interfaces/IRNBWStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title RNBWStakingSimulation
 * @notice End-to-end simulation tests with logging for TDD flows
 * @dev Run with: forge test --match-contract RNBWStakingSimulation -vvv
 */
contract RNBWStakingSimulation is Test {
    RNBWStaking public staking;
    MockERC20 public rnbwToken;

    address public admin;
    uint256 public signerPrivateKey = 0xA11CE;
    address public signer;
    address public alice;
    address public bob;
    address public charlie;

    function setUp() public {
        admin = makeAddr("admin");
        signer = vm.addr(signerPrivateKey);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        rnbwToken = new MockERC20("Rainbow Token", "RNBW", 18);

        vm.prank(admin);
        staking = new RNBWStaking(address(rnbwToken), admin, signer);

        rnbwToken.mint(alice, 100_000 ether);
        rnbwToken.mint(bob, 100_000 ether);
        rnbwToken.mint(charlie, 100_000 ether);

        console.log("=== SIMULATION SETUP COMPLETE ===");
    }

    function test_Simulation_StakingFlow() public {
        console.log("");
        console.log("=== FLOW 3.4.1: STAKING (FRONTEND DIRECT) ===");

        console.log("STEP 1: Alice initiates stake of 25,000 RNBW");

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 25_000 ether);
        staking.stake(25_000 ether);
        vm.stopPrank();

        console.log("STEP 2: On-chain execution complete");

        (uint256 staked, uint256 shares,,,) = staking.getPosition(alice);
        console.log("Alice staked amount:", staked / 1e18);
        console.log("Alice shares:", shares / 1e18);
        console.log("Total pooled:", staking.totalPooledRnbw() / 1e18);
        console.log("=== STAKING COMPLETE ===");

        assertEq(staked, 25_000 ether);
    }

    function test_Simulation_UnstakingViaRelayer() public {
        console.log("");
        console.log("=== FLOW 3.4.2: UNSTAKING (BACKEND RELAYER) ===");

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 10_000 ether);
        staking.stake(10_000 ether);
        vm.stopPrank();
        console.log("SETUP: Alice staked 10,000 RNBW");

        console.log("STEP 1: Backend generates EIP-712 signature");
        uint256 nonce = 12_345;
        uint256 expiry = block.timestamp + 60;

        bytes32 structHash = keccak256(abi.encode(staking.UNSTAKE_TYPEHASH(), alice, 10_000 ether, nonce, expiry));
        bytes32 digest = MessageHashUtils.toTypedDataHash(staking.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        console.log("STEP 2: Relayer submits unstakeWithSignature");
        uint256 balBefore = rnbwToken.balanceOf(alice);

        staking.unstakeWithSignature(alice, 10_000 ether, nonce, expiry, sig);

        uint256 received = rnbwToken.balanceOf(alice) - balBefore;
        console.log("STEP 3: Exit fee calculation");
        console.log("Gross: 10,000 RNBW");
        console.log("Exit fee (15%): 1,500 RNBW");
        console.log("Net received:", received / 1e18);
        console.log("Nonce used:", staking.isNonceUsed(alice, nonce));
        console.log("=== UNSTAKING COMPLETE ===");

        assertEq(received, 8500 ether);
    }

    function test_Simulation_CashbackFlow() public {
        console.log("");
        console.log("=== FLOW 3.4.3: CASHBACK FLOW ===");
        console.log("");

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 50_000 ether);
        staking.stake(50_000 ether);
        vm.stopPrank();

        _logPosition("SETUP: Initial Stake", alice);

        console.log("--- STEP 1: Allocate Cashback (Swap #1) ---");
        console.log("RNBW cashback: 500");
        _allocateCashback(alice, 500 ether);
        _logPosition("After Swap #1", alice);

        console.log("--- STEP 2: Allocate More Cashback (Swap #2) ---");
        vm.warp(block.timestamp + 1 hours);
        console.log("RNBW cashback: 1250");
        _allocateCashback(alice, 1250 ether);

        _logPosition("After Swap #2", alice);

        console.log("--- STEP 3: Auto-Compound on Next Stake ---");
        console.log("Additional stake: 1000 RNBW");
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);
        vm.stopPrank();

        _logPosition("After Compound", alice);
        console.log("=== CASHBACK FLOW COMPLETE ===");

        (uint256 stakedFinal,, uint256 cashbackFinal,,) = staking.getPosition(alice);
        assertEq(cashbackFinal, 0);
        assertEq(stakedFinal, 50_000 ether + 500 ether + 1250 ether + 1000 ether);
    }

    uint256 internal allocateNonce = 1;

    function _allocateCashback(address user, uint256 amount) internal {
        uint256 expiry = block.timestamp + 60;
        bytes32 structHash =
            keccak256(abi.encode(staking.ALLOCATE_CASHBACK_TYPEHASH(), user, amount, allocateNonce, expiry));
        bytes32 digest = MessageHashUtils.toTypedDataHash(staking.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        rnbwToken.mint(address(staking), amount);
        staking.allocateCashbackWithSignature(user, amount, allocateNonce, expiry, sig);
        allocateNonce++;
    }

    function _signStake(address user, uint256 amount, uint256 nonce, uint256 expiry)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(staking.STAKE_TYPEHASH(), user, amount, nonce, expiry));
        bytes32 digest = MessageHashUtils.toTypedDataHash(staking.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signCompound(address user, uint256 nonce, uint256 expiry) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(staking.COMPOUND_TYPEHASH(), user, nonce, expiry));
        bytes32 digest = MessageHashUtils.toTypedDataHash(staking.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _logPosition(string memory label, address user) internal view {
        (uint256 staked, uint256 userShares, uint256 cashback, uint256 lastUpdate, uint256 stakingStart) =
            staking.getPosition(user);
        console.log("---", label, "---");
        console.log("Staked RNBW:", staked / 1e18);
        console.log("Shares:", userShares / 1e18);
        console.log("Cashback pending:", cashback / 1e18);
        console.log("Exchange rate:", staking.getExchangeRate());
        console.log("Total pooled:", staking.totalPooledRnbw() / 1e18);
        console.log("Total shares:", staking.totalShares() / 1e18);
        console.log("Staking start:", stakingStart);
        console.log("Last update:", lastUpdate);
        console.log("");
    }

    function test_Simulation_ExitFeeDistribution() public {
        console.log("");
        console.log("=== EXIT FEE DISTRIBUTION ===");

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 50_000 ether);
        staking.stake(50_000 ether);
        vm.stopPrank();
        console.log("Alice staked: 50,000 RNBW");

        vm.startPrank(bob);
        rnbwToken.approve(address(staking), 50_000 ether);
        staking.stake(50_000 ether);
        vm.stopPrank();
        console.log("Bob staked: 50,000 RNBW");
        console.log("Total pooled:", staking.totalPooledRnbw() / 1e18);

        (uint256 aliceBefore,,,,) = staking.getPosition(alice);
        console.log("Alice value before Bob unstakes:", aliceBefore / 1e18);

        console.log("Bob unstakes all 50,000 shares...");
        vm.prank(bob);
        staking.unstake(50_000 ether);

        (uint256 aliceAfter,,,,) = staking.getPosition(alice);
        console.log("Alice value after Bob unstakes:", aliceAfter / 1e18);
        console.log("Alice gained:", (aliceAfter - aliceBefore) / 1e18);
        console.log("Exchange rate:", staking.getExchangeRate());
        console.log("=== EXIT FEE DISTRIBUTED ===");

        assertGt(aliceAfter, aliceBefore);
    }

    function test_Simulation_FullLifecycle() public {
        console.log("");
        console.log("=== FULL LIFECYCLE SIMULATION ===");

        console.log("PHASE 1: Initial stakes");
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 50_000 ether);
        staking.stake(50_000 ether);
        vm.stopPrank();
        console.log("Alice staked 50,000 RNBW");

        vm.startPrank(bob);
        rnbwToken.approve(address(staking), 30_000 ether);
        staking.stake(30_000 ether);
        vm.stopPrank();
        console.log("Bob staked 30,000 RNBW");

        console.log("PHASE 2: Cashback allocation");
        _allocateCashback(alice, 1000 ether);
        _allocateCashback(bob, 500 ether);
        console.log("Cashback allocated: Alice=1000, Bob=500");

        console.log("PHASE 3: Alice compounds by staking more");
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 5000 ether);
        staking.stake(5000 ether);
        vm.stopPrank();

        console.log("PHASE 4: Bob unstakes half");
        vm.prank(bob);
        staking.unstake(15_000 ether);

        console.log("PHASE 5: Final state");
        (uint256 aliceFinal,,,,) = staking.getPosition(alice);
        (uint256 bobFinal,,,,) = staking.getPosition(bob);
        console.log("Alice final:", aliceFinal / 1e18);
        console.log("Bob final:", bobFinal / 1e18);
        console.log("Total pooled:", staking.totalPooledRnbw() / 1e18);
        console.log("Exchange rate:", staking.getExchangeRate());
        console.log("=== LIFECYCLE COMPLETE ===");
    }

    function test_Simulation_DirectUnstake() public {
        console.log("");
        console.log("=== DIRECT UNSTAKE (CLIENT) ===");

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 10_000 ether);
        staking.stake(10_000 ether);
        console.log("Alice staked 10,000 RNBW");

        uint256 balBefore = rnbwToken.balanceOf(alice);
        staking.unstake(10_000 ether);
        uint256 received = rnbwToken.balanceOf(alice) - balBefore;
        vm.stopPrank();

        console.log("Alice unstaked directly (no relayer)");
        console.log("Received:", received / 1e18);
        console.log("Exit fee paid: 1,500 RNBW");
        console.log("=== DIRECT UNSTAKE COMPLETE ===");

        assertEq(received, 8500 ether);
    }

    function test_Simulation_ResidualDustSweep() public {
        console.log("");
        console.log("=== RESIDUAL DUST SWEEP (ISSUE #1 FIX) ===");

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 10_000 ether);
        staking.stake(10_000 ether);
        vm.stopPrank();
        console.log("Alice staked 10,000 RNBW");

        uint256 safeBefore = rnbwToken.balanceOf(admin);
        uint256 aliceShares = staking.shares(alice);

        vm.prank(alice);
        staking.unstake(aliceShares);

        console.log("Alice unstaked all shares");
        console.log("totalShares:", staking.totalShares());
        console.log("totalPooledRnbw:", staking.totalPooledRnbw());
        console.log("Dust swept to safe:", (rnbwToken.balanceOf(admin) - safeBefore) / 1e18);

        assertEq(staking.totalShares(), 0);
        assertEq(staking.totalPooledRnbw(), 0);
        assertGt(rnbwToken.balanceOf(admin), safeBefore);
        console.log("=== INVARIANT HOLDS: totalShares==0 => totalPooledRnbw==0 ===");
    }

    function test_Simulation_StakeViaRelayer() public {
        console.log("");
        console.log("=== STAKE VIA RELAYER (stakeWithSignature) ===");

        uint256 amount = 10_000 ether;
        uint256 nonce = 100;
        uint256 expiry = block.timestamp + 60;
        bytes memory sig = _signStake(alice, amount, nonce, expiry);

        vm.prank(alice);
        rnbwToken.approve(address(staking), amount);

        address relayer = makeAddr("relayer");
        vm.prank(relayer);
        staking.stakeWithSignature(alice, amount, nonce, expiry, sig);

        (uint256 staked,,,,) = staking.getPosition(alice);
        console.log("Relayer submitted stakeWithSignature for Alice");
        console.log("Alice staked:", staked / 1e18);
        console.log("Relayer address:", relayer);
        console.log("=== RELAYER STAKE COMPLETE ===");

        assertEq(staked, amount);
        assertEq(staking.shares(alice), amount);
    }

    function test_Simulation_CompoundWithSignature() public {
        console.log("");
        console.log("=== COMPOUND VIA SIGNATURE ===");

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 50_000 ether);
        staking.stake(50_000 ether);
        vm.stopPrank();

        _allocateCashback(alice, 2000 ether);

        (,, uint256 cashbackBefore,,) = staking.getPosition(alice);
        console.log("Cashback before compound:", cashbackBefore / 1e18);

        uint256 nonce = 200;
        uint256 expiry = block.timestamp + 60;
        bytes memory sig = _signCompound(alice, nonce, expiry);
        staking.compoundWithSignature(alice, nonce, expiry, sig);

        (uint256 stakedAfter,, uint256 cashbackAfter,,) = staking.getPosition(alice);
        console.log("Cashback after compound:", cashbackAfter);
        console.log("Staked after compound:", stakedAfter / 1e18);
        console.log("=== COMPOUND COMPLETE ===");

        assertEq(cashbackAfter, 0);
        assertEq(stakedAfter, 52_000 ether);
    }

    function test_Simulation_DustCashbackPreserved() public {
        console.log("");
        console.log("=== DUST CASHBACK PRESERVED (ISSUE #9 FIX) ===");

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 50_000 ether);
        staking.stake(50_000 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        rnbwToken.approve(address(staking), 50_000 ether);
        staking.stake(50_000 ether);
        vm.stopPrank();

        uint256 bobShares = staking.shares(bob);
        vm.prank(bob);
        staking.unstake(bobShares);

        _allocateCashback(alice, 1);
        console.log("Allocated 1 wei cashback to Alice");

        (,, uint256 cashbackBefore,,) = staking.getPosition(alice);

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);
        vm.stopPrank();

        (,, uint256 cashbackAfter,,) = staking.getPosition(alice);
        console.log("Cashback before stake:", cashbackBefore);
        console.log("Cashback after stake:", cashbackAfter);
        console.log("Dust preserved (not lost):", cashbackAfter > 0);
        console.log("=== DUST CASHBACK NOT LOST ===");

        assertEq(cashbackAfter, 1);
    }

    function test_Simulation_NonceReplayPrevention() public {
        console.log("");
        console.log("=== NONCE REPLAY PREVENTION ===");

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 20_000 ether);
        staking.stake(10_000 ether);
        vm.stopPrank();

        uint256 nonce = 999;
        uint256 expiry = block.timestamp + 60;

        bytes32 structHash = keccak256(abi.encode(staking.UNSTAKE_TYPEHASH(), alice, 5000 ether, nonce, expiry));
        bytes32 digest = MessageHashUtils.toTypedDataHash(staking.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        staking.unstakeWithSignature(alice, 5000 ether, nonce, expiry, sig);
        console.log("First unstake succeeded with nonce:", nonce);
        assertTrue(staking.isNonceUsed(alice, nonce));

        vm.expectRevert(IRNBWStaking.NonceAlreadyUsed.selector);
        staking.unstakeWithSignature(alice, 5000 ether, nonce, expiry, sig);
        console.log("Replay reverted as expected");
        console.log("=== REPLAY PREVENTION VERIFIED ===");
    }

    function test_Simulation_ExpiredSignatureReverts() public {
        console.log("");
        console.log("=== EXPIRED SIGNATURE ===");

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 10_000 ether);
        staking.stake(10_000 ether);
        vm.stopPrank();

        uint256 nonce = 500;
        uint256 expiry = block.timestamp + 60;

        bytes32 structHash = keccak256(abi.encode(staking.UNSTAKE_TYPEHASH(), alice, 5000 ether, nonce, expiry));
        bytes32 digest = MessageHashUtils.toTypedDataHash(staking.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.warp(expiry + 1);

        vm.expectRevert(IRNBWStaking.SignatureExpired.selector);
        staking.unstakeWithSignature(alice, 5000 ether, nonce, expiry, sig);
        console.log("Expired signature correctly reverted");
        console.log("=== EXPIRY CHECK VERIFIED ===");
    }

    function test_Simulation_PausedContractBlocks() public {
        console.log("");
        console.log("=== PAUSED CONTRACT ===");

        vm.prank(admin);
        staking.pause();

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 10_000 ether);
        vm.expectRevert();
        staking.stake(10_000 ether);
        vm.stopPrank();
        console.log("Stake blocked while paused");

        vm.prank(admin);
        staking.unpause();

        vm.startPrank(alice);
        staking.stake(10_000 ether);
        vm.stopPrank();
        console.log("Stake succeeded after unpause");

        assertEq(staking.shares(alice), 10_000 ether);
        console.log("=== PAUSE/UNPAUSE VERIFIED ===");
    }

    function test_Simulation_MultiStakerExitFeeAccrual() public {
        console.log("");
        console.log("=== THREE-STAKER EXIT FEE ACCRUAL ===");

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 40_000 ether);
        staking.stake(40_000 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        rnbwToken.approve(address(staking), 30_000 ether);
        staking.stake(30_000 ether);
        vm.stopPrank();

        vm.startPrank(charlie);
        rnbwToken.approve(address(staking), 30_000 ether);
        staking.stake(30_000 ether);
        vm.stopPrank();

        console.log("Alice: 40k, Bob: 30k, Charlie: 30k");
        uint256 rateBefore = staking.getExchangeRate();

        uint256 charlieShares = staking.shares(charlie);
        vm.prank(charlie);
        staking.unstake(charlieShares);
        console.log("Charlie unstaked all (15% fee stays in pool)");

        uint256 rateAfter = staking.getExchangeRate();
        console.log("Exchange rate before:", rateBefore);
        console.log("Exchange rate after:", rateAfter);

        (uint256 aliceVal,,,,) = staking.getPosition(alice);
        (uint256 bobVal,,,,) = staking.getPosition(bob);
        console.log("Alice value:", aliceVal / 1e18);
        console.log("Bob value:", bobVal / 1e18);
        console.log("=== FEE DISTRIBUTED PROPORTIONALLY ===");

        assertGt(rateAfter, rateBefore);
        assertGt(aliceVal, 40_000 ether);
        assertGt(bobVal, 30_000 ether);
    }

    function test_Simulation_SharedNonceNamespace() public {
        console.log("");
        console.log("=== SHARED NONCE NAMESPACE ===");

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 20_000 ether);
        staking.stake(10_000 ether);
        vm.stopPrank();

        uint256 nonce = 42;
        uint256 expiry = block.timestamp + 60;
        bytes memory stakeSig = _signStake(alice, 5000 ether, nonce, expiry);

        vm.prank(alice);
        rnbwToken.approve(address(staking), 5000 ether);
        staking.stakeWithSignature(alice, 5000 ether, nonce, expiry, stakeSig);
        console.log("stakeWithSignature used nonce 42");

        bytes32 structHash = keccak256(abi.encode(staking.UNSTAKE_TYPEHASH(), alice, 1000 ether, nonce, expiry));
        bytes32 digest = MessageHashUtils.toTypedDataHash(staking.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        bytes memory unstakeSig = abi.encodePacked(r, s, v);

        vm.expectRevert(IRNBWStaking.NonceAlreadyUsed.selector);
        staking.unstakeWithSignature(alice, 1000 ether, nonce, expiry, unstakeSig);
        console.log("unstakeWithSignature with same nonce 42 reverted");
        console.log("=== SHARED NAMESPACE CONFIRMED ===");
    }
}
