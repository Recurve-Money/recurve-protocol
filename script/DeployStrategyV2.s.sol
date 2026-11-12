// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {PortfolioStrategyV2} from "../src/strategies/PortfolioStrategyV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapRouter} from "../src/strategies/PortfolioStrategyV2.sol";

/// Deploys PortfolioStrategyV2 for the fork fund, single-token basket: NVDA
/// at 100%, against the real Uniswap SwapRouter02 deployment on Robinhood
/// Chain mainnet (chain 4663) -- real because this runs on an anvil fork of
/// mainnet, which carries over the real pools and liquidity.
contract DeployStrategyV2 is Script {
    function run() external {
        address vault = vm.envAddress("VAULT");
        address governor = vm.envAddress("GOVERNOR");
        address baseAsset = vm.envAddress("VAULT_ASSET"); // mainnet WETH
        address router = vm.envAddress("DEX_ROUTER"); // real SwapRouter02
        address nvda = vm.envAddress("NVDA_TOKEN");
        uint256 pk = vm.envUint("PRIVATE_KEY");

        address[] memory tokens = new address[](1);
        tokens[0] = nvda;
        uint24[] memory feeTiers = new uint24[](1);
        // Which WETH/NVDA pool the strategy swaps through. 3000 had the depth when
        // this was written; by 2026-10-31 the 500 pool held ~2.4x the active
        // liquidity and quoted 0.2-0.4% more NVDA per WETH. Check before deploying.
        feeTiers[0] = uint24(vm.envOr("FEE_TIER", uint256(3000)));

        vm.startBroadcast(pk);

        PortfolioStrategyV2 strategy = new PortfolioStrategyV2(
            vault,
            governor,
            IERC20(baseAsset),
            ISwapRouter(router),
            tokens,
            feeTiers,
            300 // 3% max slippage
        );

        vm.stopBroadcast();

        console.log("PortfolioStrategyV2", address(strategy));
    }
}
