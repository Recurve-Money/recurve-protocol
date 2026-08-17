# Recurve Protocol

Solidity contracts for agent-run funds. Depositors pool capital into an ERC-4626 vault;
a registered agent posts strategies; shareholders veto under optimistic governance;
staked $REVE guardians replay the calldata before it executes. The contracts hold the
line — agents operate, depositors keep the exit.

Built with Foundry and OpenZeppelin v5, Solidity `0.8.28`, `via_ir` compilation.
Protocol docs: **https://docs.recurvemoney.xyz/**

## Contracts

| Contract | Description |
|----------|-------------|
| `src/RecurveVault.sol` | ERC-4626 vault plus `ERC20Votes`, so shares carry voting weight and the governor can snapshot it. Holds every position. Redemptions clear instantly against the idle float; when the float is short the request queues and settles at the price realized when the agent unwinds. Capital leaves only through `fundStrategy`, and only the governor can call it. |
| `src/RecurveGovernor.sol` | Proposal lifecycle: propose → veto window → guardian review → execute → settle. One governor per vault. Charges the performance fee on profit at settlement. |
| `src/GuardianRegistry.sol` | Stake, verdicts, and slashing. Guardians stake $REVE to become eligible, cast one final verdict per proposal, and forfeit the entire stake if a proposal they approved is later convicted. |

## Why optimistic governance

An agent that has to wait for a quorum to say yes cannot trade. Approval-gated
governance turns every position into a committee decision, and by the time the
committee answers the edge is gone.

So proposals pass by default. The protection is not an approval gate, it's two things
that cost nothing when the agent behaves:

- **Depositors can veto.** Weight is snapshotted one block before the proposal lands, so
  nobody buys votes after reading the calldata. Cross the threshold and the proposal dies.
- **Guardians can block.** Enough blocks on a proposal and execution reverts.

## Why slashed stake is burned

`convict()` sends slashed stake to a burn address rather than distributing it to the
guardians who blocked correctly.

Paying out slashed stake sounds fairer and is much worse. If convictions paid, a
coordinated majority could approve-then-convict a minority and farm them, and every
guardian would be weighing the reward from a conviction against the honesty of their
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
src/                 core contracts
test/                Foundry tests, unit + fuzz
script/Deploy.s.sol  registry + vault/governor pair
.github/workflows/   fmt, build --sizes, test, coverage
```

## Build

```bash
forge install
forge build
forge test
```

Fuzz runs default to 512 locally and 5000 in CI (`FOUNDRY_PROFILE=ci`).

## Deploy

```bash
export PRIVATE_KEY=0x...
export VAULT_ASSET=0x...   # the ERC-20 the fund denominates in
export REVE_TOKEN=0x...     # the token guardians stake
export AGENT=0x...
export TREASURY=0x...

forge script script/Deploy.s.sol --rpc-url robinhood --broadcast --verify
```

The vault and governor reference each other, so the script precomputes the governor
address and asserts the prediction held before wiring the registry. If that assert ever
trips, stop — a vault pointing at the wrong governor can never move capital again.

## Deployment addresses

Mainnet addresses land in `addresses/` once the audit closes. Nothing here is audited
yet; treat anything you deploy from this repo as unaudited.

## Security

Third-party audit pending. Contracts are source-verified onchain at deploy time.

Report anything you find to **security@recurvemoney.xyz** rather than opening an issue.

## License

BUSL-1.1. See [LICENSE](LICENSE).
