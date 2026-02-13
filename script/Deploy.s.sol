// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {RNBWStaking} from "../src/RNBWStaking.sol";

contract DeployScript is Script {
    function run() external returns (RNBWStaking) {
        address rnbwToken = vm.envAddress("RNBW_TOKEN");
        address admin = vm.envAddress("ADMIN");
        address initialSigner = vm.envAddress("INITIAL_SIGNER");

        vm.startBroadcast();
        RNBWStaking staking = new RNBWStaking(rnbwToken, admin, initialSigner);
        vm.stopBroadcast();

        console.log("RNBWStaking deployed at:", address(staking));
        return staking;
    }
}
