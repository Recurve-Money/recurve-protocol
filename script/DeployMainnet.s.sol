// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {RecurveToken} from "../src/RecurveToken.sol";
import {RecurveVault} from "../src/RecurveVault.sol";
import {RecurveGovernor} from "../src/RecurveGovernor.sol";
import {WatcherRegistry} from "../src/WatcherRegistry.sol";
import {PortfolioStrategyV2, ISwapRouter} from "../src/strategies/PortfolioStrategyV2.sol";

/// @notice The whole mainnet deploy in one broadcast: $RECURVE (unless
///         REVE_TOKEN names an existing one), the registry, one vault/governor
///         pair and its PortfolioStrategyV2 basket. Same contracts and the same
///         arguments as DeployToken, Deploy and DeployStrategyV2; one run, so a
///         simulation against mainnet exercises every step against real state.
/// @dev DEPOSIT_CAP has no default here on purpose: Deploy.s.sol's default of
///      10 whole units is ten dollars for a USDG fund.
contract DeployMainnet is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        IERC20 asset = IERC20(vm.envAddress("VAULT_ASSET"));
        address agent = vm.envAddress("AGENT");
        address treasury = vm.envAddress("TREASURY");
        address router = vm.envAddress("DEX_ROUTER");
        address leg = vm.envAddress("NVDA_TOKEN");
        uint24 feeTier = uint24(vm.envOr("FEE_TIER", uint256(500)));
        uint256 cap = vm.envUint("DEPOSIT_CAP") * (10 ** IERC20Metadata(address(asset)).decimals());
        address reve = vm.envOr("REVE_TOKEN", address(0));

        require(agent != deployer, "AGENT must not be the deployer");
        require(treasury != agent && treasury != deployer, "TREASURY must be its own account (the Safe)");

        vm.startBroadcast(pk);

        if (reve == address(0)) {
            reve = address(new RecurveToken(vm.envOr("TOTAL_SUPPLY", uint256(1_000_000_000)) * 1e18, deployer));
        }
        WatcherRegistry registry = new WatcherRegistry(IERC20(reve), 1_000e18, 7 days, deployer);
        RecurveVault vault = new RecurveVault(asset, "Recurve Fund", "rvFUND", cap);
        RecurveGovernor governor = new RecurveGovernor(
            vault,
            registry,
            agent,
            24 hours, // veto window
            2000, // 20% of supply vetoes
            2, // watcher blocks needed to stop execution
            500, // 5% performance fee on profit
            treasury
        );
        vault.setGovernor(address(governor));
        registry.setGovernor(address(governor));

        address[] memory tokens = new address[](1);
        tokens[0] = leg;
        uint24[] memory feeTiers = new uint24[](1);
        feeTiers[0] = feeTier;
        PortfolioStrategyV2 strategy = new PortfolioStrategyV2(
            address(vault), address(governor), asset, ISwapRouter(router), tokens, feeTiers, 300 // 3% max slippage
        );

        vm.stopBroadcast();

        // Wiring checks: a vault pointing at the wrong governor can never move capital again.
        require(vault.governor() == address(governor), "vault governor");
        require(registry.governor() == address(governor), "registry governor");
        require(governor.isAgent(agent), "agent not registered");
        require(strategy.feeTier(leg) == feeTier, "strategy fee tier");

        console.log("RecurveToken    ", reve);
        console.log("WatcherRegistry ", address(registry));
        console.log("RecurveVault    ", address(vault));
        console.log("RecurveGovernor ", address(governor));
        console.log("PortfolioStrategy", address(strategy));
        console.log("Deposit cap (base units)", cap);
    }
}
