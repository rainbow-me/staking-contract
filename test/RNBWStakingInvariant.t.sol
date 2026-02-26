// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {RNBWStaking} from "../src/RNBWStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract RNBWStakingHandler is Test {
    RNBWStaking public staking;
    MockERC20 public token;

    address public admin;
    uint256 public signerPrivateKey;
    address public signer;

    address[] public actors;
    uint256 public nextNonce;

    constructor(
        RNBWStaking _staking,
        MockERC20 _token,
        address _admin,
        uint256 _signerPrivateKey,
        address[] memory _actors
    ) {
        staking = _staking;
        token = _token;
        admin = _admin;
        signerPrivateKey = _signerPrivateKey;
        signer = vm.addr(_signerPrivateKey);
        for (uint256 i; i < _actors.length; ++i) {
            actors.push(_actors[i]);
        }
    }

    function stake(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        uint256 stakeAmount = bound(amount, 1, 1000 ether);

        vm.startPrank(actor);
        token.approve(address(staking), type(uint256).max);
        staking.stake(stakeAmount);
        vm.stopPrank();
    }

    function unstake(uint256 actorSeed, uint256 sharesToBurnSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 userShares = staking.shares(actor);
        if (userShares == 0) return;

        uint256 sharesToBurn = bound(sharesToBurnSeed, 1, userShares);
        vm.prank(actor);
        staking.unstake(sharesToBurn);
    }

    function unstakeAll(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        if (staking.shares(actor) == 0) return;

        vm.prank(actor);
        staking.unstakeAll();
    }

    function fundCashbackReserve(uint256 amount) external {
        uint256 reserveAmount = bound(amount, 1, 1000 ether);
        address safeAddr = staking.safe();
        token.mint(safeAddr, reserveAmount);

        vm.startPrank(safeAddr);
        token.approve(address(staking), type(uint256).max);
        staking.fundCashbackReserve(reserveAmount);
        vm.stopPrank();
    }

    function allocateCashback(uint256 actorSeed, uint256 amount, uint256 expiryDelta) external {
        address user = actors[actorSeed % actors.length];
        if (staking.shares(user) == 0) return;

        uint256 cashbackAmount = bound(amount, 1, 1000 ether);
        address safeAddr = staking.safe();
        token.mint(safeAddr, cashbackAmount);

        vm.startPrank(safeAddr);
        token.approve(address(staking), type(uint256).max);
        staking.fundCashbackReserve(cashbackAmount);
        vm.stopPrank();

        uint256 expiry = block.timestamp + bound(expiryDelta, 1, 7 days);
        uint256 nonce = ++nextNonce;

        bytes32 structHash =
            keccak256(abi.encode(staking.ALLOCATE_CASHBACK_TYPEHASH(), user, cashbackAmount, nonce, expiry));
        bytes32 digest = MessageHashUtils.toTypedDataHash(staking.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        staking.allocateCashbackWithSignature(user, cashbackAmount, nonce, expiry, sig);
    }

    function togglePause() external {
        address safeAddr = staking.safe();
        vm.prank(safeAddr);
        if (staking.paused()) {
            staking.unpause();
        } else {
            staking.pause();
        }
    }

    function togglePartialUnstake() external {
        address safeAddr = staking.safe();
        vm.prank(safeAddr);
        staking.setAllowPartialUnstake(!staking.allowPartialUnstake());
    }

    function rotateSafe(uint256 actorSeed) external {
        address currentSafe = staking.safe();
        address newSafe = actors[actorSeed % actors.length];
        if (newSafe == currentSafe) return;

        vm.prank(currentSafe);
        staking.proposeSafe(newSafe);

        vm.prank(newSafe);
        staking.acceptSafe();
    }
}

contract RNBWStakingInvariant is StdInvariant, Test {
    RNBWStaking public staking;
    MockERC20 public token;
    RNBWStakingHandler public handler;

    address public admin;
    uint256 public signerPrivateKey;
    address public signer;
    address[] public actors;

    function setUp() public {
        admin = makeAddr("admin");
        signerPrivateKey = 0xA11CE;
        signer = vm.addr(signerPrivateKey);

        token = new MockERC20("Rainbow Token", "RNBW", 18);

        vm.prank(admin);
        staking = new RNBWStaking(address(token), admin, signer);

        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("charlie"));

        for (uint256 i; i < actors.length; ++i) {
            token.mint(actors[i], 1_000_000 ether);
        }

        vm.prank(admin);
        staking.setAllowPartialUnstake(true);

        handler = new RNBWStakingHandler(staking, token, admin, signerPrivateKey, actors);

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](20);
        selectors[0] = handler.stake.selector;
        selectors[1] = handler.stake.selector;
        selectors[2] = handler.stake.selector;
        selectors[3] = handler.stake.selector;
        selectors[4] = handler.unstake.selector;
        selectors[5] = handler.unstake.selector;
        selectors[6] = handler.unstake.selector;
        selectors[7] = handler.unstakeAll.selector;
        selectors[8] = handler.unstakeAll.selector;
        selectors[9] = handler.fundCashbackReserve.selector;
        selectors[10] = handler.fundCashbackReserve.selector;
        selectors[11] = handler.fundCashbackReserve.selector;
        selectors[12] = handler.allocateCashback.selector;
        selectors[13] = handler.allocateCashback.selector;
        selectors[14] = handler.allocateCashback.selector;
        selectors[15] = handler.rotateSafe.selector;
        selectors[16] = handler.rotateSafe.selector;
        selectors[17] = handler.togglePause.selector;
        selectors[18] = handler.togglePartialUnstake.selector;
        selectors[19] = handler.togglePartialUnstake.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_BalanceCoversAccounting() public view {
        uint256 tracked = staking.totalPooledRnbw() + staking.cashbackReserve();
        uint256 balance = token.balanceOf(address(staking));
        assertGe(balance, tracked);
    }

    function invariant_ZeroSharesImpliesZeroPooled() public view {
        if (staking.totalShares() == 0) {
            assertEq(staking.totalPooledRnbw(), 0);
            assertEq(staking.shares(staking.DEAD_ADDRESS()), 0);
        }
    }

    function invariant_DeadShareConsistency() public view {
        uint256 totalShares = staking.totalShares();
        uint256 deadShares = staking.shares(staking.DEAD_ADDRESS());

        if (totalShares == 0) {
            assertEq(deadShares, 0);
        } else {
            assertEq(deadShares, staking.MINIMUM_SHARES());
            assertGe(totalShares, deadShares);
        }
    }

    function invariant_TrustedSignerBounds() public view {
        uint256 count = staking.trustedSignerCount();
        assertGe(count, 1);
        assertLe(count, staking.MAX_SIGNERS());
    }

    function invariant_SafeNeverZeroAddress() public view {
        assertTrue(staking.safe() != address(0));
    }
}
