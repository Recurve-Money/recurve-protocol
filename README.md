# Recurve Protocol

Solidity contracts for agent-run funds. Depositors pool capital into an ERC-4626 vault;
a registered agent posts strategies; shareholders veto under optimistic governance;
staked $RECURVE watchers replay the calldata before it executes. The contracts hold the
line — agents operate, depositors keep the exit.

Built with Foundry and OpenZeppelin v5, Solidity `0.8.28`, `via_ir` compilation.
Protocol docs: **https://www.recurvemoney.xyz/docs**

## Contracts

| Contract | Description |
|----------|-------------|
| `src/RecurveVault.sol` | ERC-4626 vault plus `ERC20Votes`, so shares carry voting weight and the governor can snapshot it. Holds every position. Redemptions clear instantly against the idle float; when the float is short the request queues and settles at the price realized when the agent unwinds. Capital leaves only through `fundStrategy`, and only the governor can call it. It comes back through `returnFromStrategy`, which takes the assets in and the deployment off the books in one call, so the returned capital is never counted twice. |
| `src/RecurveGovernor.sol` | Proposal lifecycle: propose → veto window → watcher review → execute → settle. One governor per vault. Charges the performance fee on profit at settlement. |
| `src/WatcherRegistry.sol` | Stake, verdicts, and slashing. Watchers stake $RECURVE to become eligible, cast one final verdict per proposal, and forfeit the entire stake if a proposal they approved is later convicted. The stake token is named in the constructor or once afterwards (`setStakeToken`), so a fund can open before its token exists; until it is named nobody can stake, so nobody can rule. |
| `src/strategies/PortfolioStrategyV2.sol` | What the fund's capital may do: a basket fixed at construction, bought and sold through one Uniswap V3 pool per token under a slippage cap, with the vault as the only way out. |
| `src/RecurveToken.sol` | A fixed-supply ERC-20 with no owner, for a deployment that has no token of its own yet. The testnet fund uses it. |

## Why optimistic governance

An agent that has to wait for a quorum to say yes cannot trade. Approval-gated
governance turns every position into a committee decision, and by the time the
committee answers the edge is gone.

So proposals pass by default. The protection is not an approval gate, it's two things
that cost nothing when the agent behaves:

- **Depositors can veto.** Weight is snapshotted one block before the proposal lands, so
  nobody buys votes after reading the calldata. Cross the threshold and the proposal dies.
- **Watchers can block.** Enough blocks on a proposal and execution reverts.

## Why slashed stake is burned

`convict()` sends slashed stake to a burn address rather than distributing it to the
watchers who blocked correctly.

Paying out slashed stake sounds fairer and is much worse. If convictions paid, a
coordinated majority could approve-then-convict a minority and farm them, and every
watcher would be weighing the reward from a conviction against the honesty of their
own verdict. Burning removes the payoff. Nobody gains from a slash, so nobody has a
reason to engineer one.

## The queue exists because the price is unknown

A vault holding a live position cannot honestly price an exit. Marking it to an oracle
lets an informed depositor redeem at a stale number and leaves the loss with everyone
who stayed.

Instead: if the float covers you, you leave immediately. If it doesn't, you join a
queue that settles at whatever the position actually returned. A queued exit shares in
the gain and eats its part of the loss — the same as staying, which is the point.

## Layout

```
src/                           core contracts and strategies
test/                          Foundry tests, unit + fuzz
script/Deploy.s.sol            registry + vault/governor pair
script/DeployStrategyV2.s.sol  the strategy
script/DeployMainnet.s.sol     all of it in one run, for Robinhood Chain mainnet
deploy-mainnet.sh, handover.sh the mainnet deploy from a terminal (DEPLOY-MAINNET.md)
checks.sh                      what both refuse to go on without
mainnet.env                    its settings, public values only
addresses/                     one file per chain, written by the deploy
chains/                        the external contracts each chain's deploy relies on
```

## Build

```bash
forge install
forge build
forge test
```

Fuzz runs default to 512; `FOUNDRY_PROFILE=ci` runs 5000.

## Deploy

```bash
export PRIVATE_KEY=0x...
export VAULT_ASSET=0x...   # the ERC-20 the fund denominates in
export REVE_TOKEN=0x...     # $RECURVE, the token watchers stake
export AGENT=0x...
export TREASURY=0x...

forge script script/Deploy.s.sol --rpc-url robinhood --broadcast --verify
```

The vault and governor reference each other, so the script precomputes the governor
address and asserts the prediction held before wiring the registry. If that assert ever
trips, stop — a vault pointing at the wrong governor can never move capital again.

### Robinhood Chain mainnet

[DEPLOY-MAINNET.md](DEPLOY-MAINNET.md) is the runbook: what it costs, the addresses it
relies on, and the two scripts, each of which simulates unless given `--broadcast`. It was
rehearsed end to end on a fork of mainnet.

The website's `/admin` page deploys the same contracts from a browser wallet, from the
bytecode this repository builds. It deploys the registry with no stake token and names
$RECURVE later, once, with `setStakeToken`.

## Deployment addresses

`addresses/46630.json` is the testnet fund. `addresses/4663.json` is written when the
mainnet fund is deployed.

## Security

The contracts have not been independently audited; treat anything you deploy from this
repository as unaudited. What they do not do is listed plainly under
[Known limitations](https://www.recurvemoney.xyz/docs/contracts#limitations).

Report anything you find to **security@recurvemoney.xyz** rather than opening an issue.

## License

BUSL-1.1. See [LICENSE](LICENSE).
