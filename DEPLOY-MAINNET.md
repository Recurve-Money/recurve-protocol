# Deploying Recurve to Robinhood Chain mainnet (4663)

Rehearsed on 2026-10-31 against a local fork of mainnet (anvil, block
102,669,957, chain id 4663) with exactly the scripts in this folder:

- the whole deploy (token, registry, vault, governor, NVDA strategy);
- a WETH fund: 1 WETH deposited, two full runner cycles (buy NVDA → hold →
  sell → return → settle) through the real Uniswap V3 pools;
- a USDG fund: 2,000 USDG deposited, one full cycle;
- the app in mainnet mode against the fork (fund, proposals, explorer links).

Nothing was sent to mainnet itself: only read calls and `eth_estimateGas`.

"The website repo" below is [Recurve-Money/recurve](https://github.com/Recurve-Money/recurve):
the site, the app, the docs and the indexer. This repository is checked out
inside it as `protocol/`, and the runner as `runner/`.

## What it costs

| Transaction | Gas (mainnet estimate) |
|---|---|
| RecurveToken | 510,263 |
| WatcherRegistry | 962,162 |
| RecurveVault | 2,906,624 |
| RecurveGovernor | 1,544,223 |
| `vault.setGovernor`, `registry.setGovernor` | ~92,000 |
| PortfolioStrategyV2 | 1,156,395 |
| **Total** | **≈ 7.2M** |

At the 2026-10-31 gas price (0.02 gwei, no priority fee on this chain) that
is **≈ 0.00015 ETH**; with `REVE_TOKEN` set (the Pons launch) the RecurveToken
row drops out (≈ 6.7M). Measured on a fork with mainnet's fee settings:

| Wallet | Send | Why |
|---|---|---|
| Deployer | **0.0004 ETH** | Forge only sends each transaction if the balance covers its gas limit at a doubled fee cap (it asks for 0.00037 up front); the deploy then burns 0.000125, the handover 0.0000011 |
| Agent | **0.0001 ETH** to start | `setAgentAdmin` costs 0.0000003; one full trading cycle (propose and execute buy, sell, return, then settle — 7 transactions, ~1.4M gas) ≈ 0.00003. A cycle takes at least three days (three 24 h veto windows), so this lasts weeks; the runner warns below 0.00005 |

The agent also needs a little of the fund asset (e.g. 20 USDG) by the first
profitable settle: the performance fee is paid from its wallet.

## Mainnet addresses the scripts use (checked on chain 2026-10-31)

| | Address | Checked |
|---|---|---|
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` | symbol, 18 decimals; SwapRouter02's `WETH9` |
| USDG | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` | symbol, 6 decimals |
| NVDA (Robinhood token) | `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` | "NVIDIA • Robinhood Token", 18 decimals |
| Uniswap V3 Factory | `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` | `factory()` of every pool below, of the router and the quoter |
| SwapRouter02 | `0xcaf681a66d020601342297493863e78c959e5cb2` | |
| QuoterV2 | `0x33e885ed0ec9bf04ecfb19341582aadcb4c8a9e7` | quotes below |

Pools (fee tier: depth on 2026-10-31):

- WETH/NVDA — 500: `0x62AB521f71431f78ac374CdbadC6cda3c8916b6C` (deepest; 1 WETH → 11.03 NVDA), 3000: `0xC0Be1cb0f674D9737C72B2A63fC542361185b807`, 10000: thin.
- USDG/NVDA — 500: `0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3` (50,000 USDG moves the price ~0.4%), 3000: thin above 10k.

The strategy swaps through ONE pool per token, fixed at deploy (`FEE_TIER`,
added to `DeployStrategyV2.s.sol` for this; the old hardcoded 3000 is now the
shallower WETH pool). Use **500** for either asset. The runner reads the tier
from the strategy, so nothing else needs it.

## Decisions before running anything

1. **Fund asset** (`VAULT_ASSET`): WETH or USDG. Both rehearsed. USDG is a
   dollar fund (shares priced in dollars); WETH a fund in ether.
2. **Agent** (`AGENT`): the runner's hot key. It needs ETH for gas and some of
   the fund asset, because `settle` pulls the performance fee from the agent's
   wallet.
3. **Treasury** (`TREASURY`): receives the performance fee. A multisig.
4. **Deposit cap** (`DEPOSIT_CAP`, whole units of the asset): the script's
   default is 10 — 10 WETH, or **10 USDG** (ten dollars) for a USDG fund. Set it.
5. **$RECURVE** (`REVE_TOKEN`): this script needs the token to exist first. The
   launch at `/admin` on the website does not: it deploys the registry with no
   stake token and names it later with `setStakeToken`, once, so the fund can
   open before the token. The owner launches it on **Pons v2** (Robinhood Chain launchpad: 1B fixed
   supply, 18 decimals, no mint, no owner; the creator picks the fee wallet —
   use the Safe). Launch it there first, then put its address in
   `REVE_TOKEN`: the deploy creates no token and `handover.sh` skips it. Tested
   on a fork with a live Pons v2 token (TRIPS,
   `0x64ca7c5f5a58ca8aeab7c15d9e44674b0d85400c`): stake 1,000 → the registry
   received exactly 1,000, unstake after 7 days returned exactly 1,000.
   (Leaving `REVE_TOKEN` empty mints a separate RecurveToken, 1B to the
   deployer, instead.)

Fixed by the scripts (change them first if these are wrong): veto window 24 h,
20% of supply vetoes, 2 watcher blocks stop a proposal, 5% performance fee,
watcher minimum stake 1,000 $RECURVE with a 7-day unstake delay, strategy max
slippage 3%.

The registry's owner (the deployer; the Safe after `handover.sh`) can change
the minimum stake and the delay later with `setParameters`. `/admin` does it
for you when it attaches the token: about $20 of $RECURVE at the market price
(`minStakeUsd` in `scripts/export-contracts.mjs`), set before the token is
named, so staking never opens at 1,000. From the terminal the 1,000 stays
until the owner calls `setParameters`. Size the minimum
to the token's market price: two watchers at the minimum stop any proposal,
and a block is never slashed (`convict` burns approvers only), so a cheap
minimum makes stalling the fund cheap. `convict` is callable only by the
registry's `governor`, and `RecurveGovernor` never calls it: as deployed,
nobody can slash. The owner can point `registry.setGovernor` at an account
that will (the Safe); `RecurveGovernor` only reads `blockCount`, so that
changes nothing else.

## The deploy

Two scripts, both simulate unless given `--broadcast`, both rehearsed on a fork
(`deploy-mainnet.sh` also simulated against live mainnet with the real keys):

- `mainnet.env` — the decisions above, public values only. Fill `TREASURY`.
- Keys in `~/.config/recurve/` (mode 600, never in git):
  `deployer.key` / `deployer.address` and `agent.key` / `agent.address`.
  Back both up (a password manager). The deployer key is the only one that can
  ever raise the vault's deposit cap; nothing can replace it.

```bash
./deploy-mainnet.sh               # simulation: prints every address, sends nothing
./deploy-mainnet.sh --broadcast   # the deploy (script/DeployMainnet.s.sol, one run)
./handover.sh                     # shows what moves to the Safe
./handover.sh --broadcast         # registry owner, agentAdmin (and a minted $RECURVE supply) -> Safe
```

Both scripts stop unless `TREASURY` is a contract on this chain that is neither
of the two keys: a Safe is a contract, and the fee recipient and the ownership
they hand out cannot be changed afterwards. `handover.sh` also stops if
`TREASURY` is no longer the address the governor pays its fees to, and moves a
$RECURVE balance only when the deploy minted the token. `cast` takes a key as
a command-line argument, visible to other processes while it runs, so do this
on a machine only you use.

`deploy-mainnet.sh --broadcast` refuses to start below 0.0004 ETH on the
deployer, checks the chain id, and after the deploy writes
`addresses/4663.json` and the website's `app/src/lib/addresses/4663.json`
(checksummed, `deployBlock` from the receipt). `handover.sh` needs a little
ETH on the agent too (it signs `setAgentAdmin`). Add `--keep-token` to leave
the $RECURVE supply with the deployer.

The predicted addresses in a simulation hold only while the deployer sends
nothing else first: they follow from its nonce.

### By hand, step by step (equivalent)

Run from this folder, in your own terminal; the key never leaves it.

```bash
export ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com
export PRIVATE_KEY=0x...                       # deployer, 0.0004 ETH on Robinhood mainnet

# 1. $RECURVE (decision 5): the token launched on Pons v2
export REVE_TOKEN=0x...
#    (without Pons: forge script script/DeployToken.s.sol --rpc-url robinhood --broadcast,
#    then REVE_TOKEN = the "RecurveToken ($RECURVE)" it prints)

# 2. registry, vault, governor
export VAULT_ASSET=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168   # USDG (or WETH 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73)
export AGENT=0x...  TREASURY=0x...  DEPOSIT_CAP=10000
forge script script/Deploy.s.sol --rpc-url robinhood --broadcast
export VAULT=0x...  GOVERNOR=0x...             # printed above; note the registry too

# 3. the NVDA strategy, through the 0.05% pool
export DEX_ROUTER=0xcaf681a66d020601342297493863e78c959e5cb2
export NVDA_TOKEN=0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC FEE_TIER=500
forge script script/DeployStrategyV2.s.sol --rpc-url robinhood --broadcast
```

Each step prints the addresses; `broadcast/*/4663/run-latest.json` keeps the
receipts (block numbers included). Without `--broadcast` each command is a
simulation against mainnet: run it that way first.

Source verification on Blockscout was not rehearsed. After the deploy:
`forge verify-contract <address> <Contract> --chain 4663 --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/`.

## After the deploy

1. **Addresses**: `deploy-mainnet.sh --broadcast` has already written
   `app/src/lib/addresses/4663.json` in the website repo. After a by-hand deploy
   write it yourself, in the shape of `46630.json`: `chainId`, `name`,
   `RecurveToken`, and one entry in `vaults` with `slug`, `name`, `symbol`
   (`rvFUND`), `WatcherRegistry`, `RecurveVault`, `RecurveGovernor`,
   `PortfolioStrategy`, `deployBlock` (the vault's block). The app and the docs
   switch to mainnet from that file alone.
2. **Website**: `VITE_WALLETCONNECT_ID` in `app/.env.production` (and
   `www.recurvemoney.xyz` on the project's allowlist at dashboard.reown.com;
   optionally `VITE_API_URL`), then `npm run deploy` at the website repo's root.
   That ships the site, the app and the docs together.
3. **Indexer**: the same deploy gives it its settings from that file
   (`deploy/write-env.mjs`, with `LOG_CHUNK=100000`: both Robinhood RPCs refuse
   wider log ranges).
4. **Runner**: `bash deploy/agent-key.sh` from the website repo, run by hand, then
   `npm run deploy` again. It starts with the fund's addresses, NVDA as
   `RECURVE_TOKEN` (the strategy's basket leg, despite the name) and
   **`DRY_RUN=true`**. Read the log, then turn it off (`deploy/README.md`).

Found during the rehearsal and fixed in `runner/`: with `FORCE_UNWIND=true` the
runner sold, returned and settled, then immediately opened a new position. It
now stays idle after the forced unwind, as its README always said.
