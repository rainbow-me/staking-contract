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

        (uint256 staked, uint256 shares,,) = staking.getPosition(alice);
        console.log("Alice staked amount:", staked / 1e18);
        console.log("Alice shares:", shares / 1e18);
        console.log("Total pooled:", staking.totalPooledRnbw() / 1e18);
        console.log("=== STAKING COMPLETE ===");

        assertApproxEqAbs(staked, 25_000 ether, staking.MINIMUM_SHARES());
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
        console.log("RNBW cashback: 500 (mints shares immediately)");
        _allocateCashback(alice, 500 ether);
        _logPosition("After Swap #1", alice);

        console.log("--- STEP 2: Allocate More Cashback (Swap #2) ---");
        vm.warp(block.timestamp + 1 hours);
        console.log("RNBW cashback: 1250 (mints shares immediately)");
        _allocateCashback(alice, 1250 ether);
        _logPosition("After Swap #2", alice);

        console.log("--- STEP 3: Additional Stake ---");
        console.log("Additional stake: 1000 RNBW");
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);
        vm.stopPrank();

        _logPosition("After Additional Stake", alice);
        console.log("=== CASHBACK FLOW COMPLETE ===");

        (uint256 stakedFinal,,,) = staking.getPosition(alice);
        assertApproxEqAbs(stakedFinal, 50_000 ether + 500 ether + 1250 ether + 1000 ether, staking.MINIMUM_SHARES());
    }

    uint256 internal allocateNonce = 1;

    function _allocateCashback(address user, uint256 amount) internal {
        uint256 expiry = block.timestamp + 60;
        bytes32 structHash =
            keccak256(abi.encode(staking.ALLOCATE_CASHBACK_TYPEHASH(), user, amount, allocateNonce, expiry));
        bytes32 digest = MessageHashUtils.toTypedDataHash(staking.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        rnbwToken.mint(admin, amount);
        vm.startPrank(admin);
        rnbwToken.approve(address(staking), amount);
        staking.depositCashbackRewards(amount);
        vm.stopPrank();
        staking.allocateCashbackWithSignature(user, amount, allocateNonce, expiry, sig);
        allocateNonce++;
    }

    function _logPosition(string memory label, address user) internal view {
        (uint256 staked, uint256 userShares, uint256 lastUpdate, uint256 stakingStart) = staking.getPosition(user);
        console.log("---", label, "---");
        console.log("Staked RNBW:", staked / 1e18);
        console.log("Shares:", userShares / 1e18);
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

        (uint256 aliceBefore,,,) = staking.getPosition(alice);
        console.log("Alice value before Bob unstakes:", aliceBefore / 1e18);

        console.log("Bob unstakes all 50,000 shares...");
        vm.prank(bob);
        staking.unstake(50_000 ether);

        (uint256 aliceAfter,,,) = staking.getPosition(alice);
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

        console.log("PHASE 2: Cashback allocation (shares minted immediately)");
        _allocateCashback(alice, 1000 ether);
        _allocateCashback(bob, 500 ether);
        console.log("Cashback allocated: Alice=1000, Bob=500");

        console.log("PHASE 3: Alice stakes more");
        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 5000 ether);
        staking.stake(5000 ether);
        vm.stopPrank();

        console.log("PHASE 4: Bob unstakes half");
        vm.prank(bob);
        staking.unstake(15_000 ether);

        console.log("PHASE 5: Final state");
        (uint256 aliceFinal,,,) = staking.getPosition(alice);
        (uint256 bobFinal,,,) = staking.getPosition(bob);
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

        uint256 aliceShares = staking.shares(alice);
        uint256 balBefore = rnbwToken.balanceOf(alice);
        staking.unstake(aliceShares);
        uint256 received = rnbwToken.balanceOf(alice) - balBefore;
        vm.stopPrank();

        console.log("Alice unstaked directly (no relayer)");
        console.log("Received:", received / 1e18);
        console.log("Exit fee paid: 1,500 RNBW");
        console.log("=== DIRECT UNSTAKE COMPLETE ===");

        assertApproxEqAbs(received, 8500 ether, staking.MINIMUM_SHARES());
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

    function test_Simulation_CashbackMintsSharesDirectly() public {
        console.log("");
        console.log("=== CASHBACK MINTS SHARES DIRECTLY ===");

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 50_000 ether);
        staking.stake(50_000 ether);
        vm.stopPrank();

        uint256 sharesBefore = staking.shares(alice);
        _allocateCashback(alice, 2000 ether);
        uint256 sharesAfter = staking.shares(alice);

        (uint256 stakedAfter,,,) = staking.getPosition(alice);
        console.log("Shares before cashback:", sharesBefore / 1e18);
        console.log("Shares after cashback:", sharesAfter / 1e18);
        console.log("Staked after cashback:", stakedAfter / 1e18);
        console.log("=== CASHBACK COMPLETE ===");

        assertEq(sharesAfter, sharesBefore + 2000 ether);
        assertApproxEqAbs(stakedAfter, 52_000 ether, staking.MINIMUM_SHARES());
    }

    function test_Simulation_DustCashbackReverts() public {
        console.log("");
        console.log("=== DUST CASHBACK REVERTS ===");

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

        uint256 expiry = block.timestamp + 60;
        bytes32 structHash =
            keccak256(abi.encode(staking.ALLOCATE_CASHBACK_TYPEHASH(), alice, uint256(1), allocateNonce, expiry));
        bytes32 digest = MessageHashUtils.toTypedDataHash(staking.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        rnbwToken.mint(admin, 1);
        vm.startPrank(admin);
        rnbwToken.approve(address(staking), 1);
        staking.depositCashbackRewards(1);
        vm.stopPrank();

        vm.expectRevert(IRNBWStaking.ZeroSharesMinted.selector);
        staking.allocateCashbackWithSignature(alice, 1, allocateNonce, expiry, sig);

        console.log("Dust cashback (1 wei) correctly reverted with ZeroSharesMinted");
        console.log("=== DUST PROTECTION VERIFIED ===");
    }

    function test_Simulation_NonceReplayPrevention() public {
        console.log("");
        console.log("=== NONCE REPLAY PREVENTION ===");

        vm.startPrank(alice);
        rnbwToken.approve(address(staking), 10_000 ether);
        staking.stake(10_000 ether);
        vm.stopPrank();

        uint256 nonce = 999;
        uint256 expiry = block.timestamp + 60;

        rnbwToken.mint(admin, 1000 ether);
        vm.startPrank(admin);
        rnbwToken.approve(address(staking), 1000 ether);
        staking.depositCashbackRewards(1000 ether);
        vm.stopPrank();

        bytes32 structHash =
            keccak256(abi.encode(staking.ALLOCATE_CASHBACK_TYPEHASH(), alice, 500 ether, nonce, expiry));
        bytes32 digest = MessageHashUtils.toTypedDataHash(staking.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        staking.allocateCashbackWithSignature(alice, 500 ether, nonce, expiry, sig);
        console.log("First cashback succeeded with nonce:", nonce);
        assertTrue(staking.isNonceUsed(alice, nonce));

        vm.expectRevert(IRNBWStaking.NonceAlreadyUsed.selector);
        staking.allocateCashbackWithSignature(alice, 500 ether, nonce, expiry, sig);
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

        rnbwToken.mint(admin, 500 ether);
        vm.startPrank(admin);
        rnbwToken.approve(address(staking), 500 ether);
        staking.depositCashbackRewards(500 ether);
        vm.stopPrank();

        uint256 nonce = 500;
        uint256 expiry = block.timestamp + 60;

        bytes32 structHash =
            keccak256(abi.encode(staking.ALLOCATE_CASHBACK_TYPEHASH(), alice, 500 ether, nonce, expiry));
        bytes32 digest = MessageHashUtils.toTypedDataHash(staking.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.warp(expiry + 1);

        vm.expectRevert(IRNBWStaking.SignatureExpired.selector);
        staking.allocateCashbackWithSignature(alice, 500 ether, nonce, expiry, sig);
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

        assertEq(staking.shares(alice), 10_000 ether - staking.MINIMUM_SHARES());
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

        (uint256 aliceVal,,,) = staking.getPosition(alice);
        (uint256 bobVal,,,) = staking.getPosition(bob);
        console.log("Alice value:", aliceVal / 1e18);
        console.log("Bob value:", bobVal / 1e18);
        console.log("=== FEE DISTRIBUTED PROPORTIONALLY ===");

        assertGt(rateAfter, rateBefore);
        assertGt(aliceVal, 40_000 ether);
        assertGt(bobVal, 30_000 ether);
    }
}
