// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RecurveVault} from "../src/RecurveVault.sol";
import {RecurveGovernor} from "../src/RecurveGovernor.sol";
import {WatcherRegistry} from "../src/WatcherRegistry.sol";

/// @notice Deploys a registry plus one vault/governor pair.
/// @dev Straight-line order, no address prediction: the vault's governor is set
///      after both exist, via RecurveVault.setGovernor (see that function for
///      why). Kept this way even for the scripted path so the same sequence
///      works whether it's run by forge or reproduced by hand in a UI that has
///      no way to predict a not-yet-deployed address.
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        IERC20 asset = IERC20(vm.envAddress("VAULT_ASSET"));
        IERC20 reve = IERC20(vm.envAddress("REVE_TOKEN"));
        address agent = vm.envAddress("AGENT");
        address treasury = vm.envAddress("TREASURY");

        vm.startBroadcast(pk);

        WatcherRegistry registry = new WatcherRegistry(reve, 1_000e18, 7 days, deployer);
        RecurveVault vault = new RecurveVault(asset, "Recurve Fund", "rvFUND");
        RecurveGovernor governor = new RecurveGovernor(
            vault,
            registry,
            agent,
            24 hours, // veto window — matches Sherwood's "Voting window"
            2000, // 20% of supply vetoes — matches Sherwood's "Guardian veto"
            2, // watcher blocks needed to stop execution
            400, // 4% performance fee on profit
            treasury
        );

        vault.setGovernor(address(governor));
        registry.setGovernor(address(governor));

        vm.stopBroadcast();

        console.log("WatcherRegistry", address(registry));
        console.log("RecurveVault    ", address(vault));
        console.log("RecurveGovernor ", address(governor));
    }
}
