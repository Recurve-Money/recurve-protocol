#!/usr/bin/env python3
"""Writes the mainnet addresses from the last DeployMainnet broadcast.

Into addresses/4663.json here, and the same file into the website's
app/src/lib/addresses/4663.json (the app and the docs read it; that copy is
what switches them to mainnet). Paths can be overridden with ADDRESSES_OUT and
APP_ADDRESSES_OUT, e.g. for a rehearsal on a fork.
"""
import datetime, json, os, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
run = json.load(open(os.path.join(HERE, "broadcast/DeployMainnet.s.sol/4663/run-latest.json")))
created = {}
block = {}
for tx, receipt in zip(run["transactions"], run["receipts"]):
    if tx["transactionType"] == "CREATE":
        created[tx["contractName"]] = tx["contractAddress"]
        block[tx["contractName"]] = int(receipt["blockNumber"], 16)
    assert int(receipt["status"], 16) == 1, f"failed transaction {receipt['transactionHash']}"

def checksum(addr):
    return subprocess.run(["cast", "to-check-sum-address", addr], capture_output=True, text=True, check=True).stdout.strip()


created = {name: checksum(addr) for name, addr in created.items()}
token = created.get("RecurveToken") or checksum(os.environ["REVE_TOKEN"])
out = {
    "chainId": 4663,
    "name": "Robinhood Chain",
    "deployedAt": datetime.date.today().isoformat(),
    "deployer": checksum(run["transactions"][0]["transaction"]["from"]),
    "RecurveToken": token,
    "vaults": [
        {
            "slug": "main",
            "name": "Recurve Fund",
            "symbol": "rvFUND",
            "WatcherRegistry": created["WatcherRegistry"],
            "RecurveVault": created["RecurveVault"],
            "RecurveGovernor": created["RecurveGovernor"],
            "deployBlock": block["RecurveVault"],
            "PortfolioStrategy": created["PortfolioStrategyV2"],
        }
    ],
}
targets = [
    os.environ.get("ADDRESSES_OUT", os.path.join(HERE, "addresses/4663.json")),
    os.environ.get("APP_ADDRESSES_OUT", os.path.join(HERE, "../app/src/lib/addresses/4663.json")),
]
for path in targets:
    with open(path, "w") as f:
        json.dump(out, f, indent=2)
        f.write("\n")
    print("wrote", os.path.normpath(path))
print(json.dumps(out, indent=2))
