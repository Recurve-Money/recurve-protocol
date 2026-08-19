// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {RecurveToken} from "../src/RecurveToken.sol";

/// @notice Deploys $RECURVE. Run this first — the printed address is what goes
///         into REVE_TOKEN before running Deploy.s.sol, since WatcherRegistry
///         takes that address as an immutable constructor argument.
contract DeployToken is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        // Override with TOTAL_SUPPLY=<amount in whole tokens> if 1B isn't right.
        uint256 supply = vm.envOr("TOTAL_SUPPLY", uint256(1_000_000_000)) * 1e18;

        vm.startBroadcast(pk);
        RecurveToken token = new RecurveToken(supply, deployer);
        vm.stopBroadcast();

        console.log("RecurveToken ($RECURVE)", address(token));
        console.log("Minted to", deployer);
        console.log("Supply", supply / 1e18);
    }
}
