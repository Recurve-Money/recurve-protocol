// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {PortfolioStrategy, ISwapRouter} from "../src/strategies/PortfolioStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Deploys PortfolioStrategy for the fund already live at VAULT/GOVERNOR,
/// pointed at our own testnet Uniswap V3 deployment (recurve-dex) since no
/// official one exists on chain 46630. Single-token basket: $RECURVE at
/// 100% -- the only token we have a seeded pool for.
contract DeployStrategy is Script {
    function run() external {
        address vault = vm.envAddress("VAULT");
        address governor = vm.envAddress("GOVERNOR");
        address baseAsset = vm.envAddress("VAULT_ASSET"); // WETH
        address router = vm.envAddress("DEX_ROUTER");
        address recurve = vm.envAddress("REVE_TOKEN");
        uint256 pk = vm.envUint("PRIVATE_KEY");

        address[] memory tokens = new address[](1);
        tokens[0] = recurve;
        uint24[] memory feeTiers = new uint24[](1);
        feeTiers[0] = 3000; // the fee tier the seeded pool actually uses

        vm.startBroadcast(pk);

        PortfolioStrategy strategy = new PortfolioStrategy(
            vault,
            governor,
            IERC20(baseAsset),
            ISwapRouter(router),
            tokens,
            feeTiers,
            300 // 3% max slippage
        );

        vm.stopBroadcast();

        console.log("PortfolioStrategy", address(strategy));
    }
}
