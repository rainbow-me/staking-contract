// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Staking} from "../src/Staking.sol";

contract DeployScript is Script {
    function run() external returns (Staking) {
        address stakingToken = vm.envAddress("STAKING_TOKEN");
        address rewardToken = vm.envAddress("REWARD_TOKEN");
        address owner = vm.envAddress("OWNER");

        vm.startBroadcast();
        Staking staking = new Staking(stakingToken, rewardToken, owner);
        vm.stopBroadcast();

        console.log("Staking deployed at:", address(staking));
        return staking;
    }
}
