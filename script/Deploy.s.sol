// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RecurveVault} from "../src/RecurveVault.sol";
import {RecurveGovernor} from "../src/RecurveGovernor.sol";
import {WatcherRegistry} from "../src/WatcherRegistry.sol";

/// @notice Deploys a registry plus one vault/governor pair.
/// @dev The vault and governor reference each other, so the governor address is
///      precomputed and the pair deployed in a fixed order. Getting this wrong
///      bricks the vault, which is why the script asserts the prediction held.
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

        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        RecurveVault vault = new RecurveVault(asset, "Recurve Fund", "rvFUND", predicted);
        RecurveGovernor governor = new RecurveGovernor(
            vault,
            registry,
            agent,
            24 hours, // veto window — matches Sherwood's "Voting window"
            2000, // 20% of supply vetoes — matches Sherwood's "Guardian veto"
            2, // watcher blocks needed to stop execution
            500, // 5% performance fee on profit — matches Sherwood's "Agent fee"
            treasury
        );
        require(address(governor) == predicted, "governor address mismatch");

        registry.setGovernor(address(governor));

        vm.stopBroadcast();

        console.log("WatcherRegistry", address(registry));
        console.log("RecurveVault    ", address(vault));
        console.log("RecurveGovernor ", address(governor));
    }
}
