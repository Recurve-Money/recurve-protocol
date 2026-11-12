#!/usr/bin/env bash
# After the deploy, move every admin right that can move to the treasury Safe:
#   - the $RECURVE supply, if this deploy minted it (skip with --keep-token)
#   - ownership of the WatcherRegistry (deployer key)
#   - the governor's agentAdmin, which the deploy gives the agent's hot key
#     (agent key; it needs a little ETH for gas)
# The vault's deployer right (raiseDepositCap) cannot move: keep deployer.key.
#
#   ./handover.sh                show what would be sent
#   ./handover.sh --broadcast    send it
set -euo pipefail
cd "$(dirname "$0")"
set -a; source "${ENV_FILE:-./mainnet.env}"; set +a
source ./checks.sh
KEYS="${KEYS:-$HOME/.config/recurve}"
SEND=false; KEEP_TOKEN=false
for a in "$@"; do
  case "$a" in --broadcast) SEND=true ;; --keep-token) KEEP_TOKEN=true ;; *) echo "unknown option $a"; exit 1 ;; esac
done

chain=$(cast chain-id --rpc-url "$RPC_URL")
[[ "$chain" == "4663" ]] || { echo "RPC_URL answers chain $chain, not 4663."; exit 1; }
[[ -n "${TREASURY:-}" ]] || { echo "Set TREASURY in mainnet.env."; exit 1; }
FILE="${ADDRESSES_OUT:-addresses/4663.json}"
read -r TOKEN REGISTRY GOVERNOR < <(python3 -c '
import json, sys
d = json.load(open(sys.argv[1])); v = d["vaults"][0]
print(d["RecurveToken"], v["WatcherRegistry"], v["RecurveGovernor"])' "$FILE")
for a in "$TOKEN" "$REGISTRY" "$GOVERNOR"; do
  is_address "$a" || { echo "$FILE does not hold three addresses."; exit 1; }
done
# cast takes a key as an argument, which other processes on this machine can
# see while it runs: do this from a machine only you use.
DEPLOYER_KEY="$(cat "$KEYS/deployer.key")"
AGENT_KEY="$(cat "$KEYS/agent.key")"
DEPLOYER=$(cast wallet address --private-key "$DEPLOYER_KEY")
AGENT=$(cast wallet address --private-key "$AGENT_KEY")
check_treasury "$DEPLOYER" "$AGENT"

# The Safe the deploy was given is in the governor for good, as the address its
# fees go to. If mainnet.env names another one now, something has changed since
# the deploy, and ownership handed to a wrong address cannot be taken back.
FEES_TO=$(cast call "$GOVERNOR" 'feeRecipient()(address)' --rpc-url "$RPC_URL")
same_address "$FEES_TO" "$TREASURY" \
  || { echo "TREASURY is $TREASURY but the governor pays its fees to $FEES_TO. Stopping."; exit 1; }

step() { # description, key, address, signature, args...
  local what="$1" key="$2"; shift 2
  if $SEND; then
    echo "-> $what"
    cast send --rpc-url "$RPC_URL" --private-key "$key" "$@" | grep -E "^(status|transactionHash)"
  else
    echo "would: $what"
  fi
}

# Only a supply this deploy minted. With REVE_TOKEN set the token came from
# elsewhere, and whatever the deployer holds of it is the deployer's own.
SUPPLY_HELD=$(cast call "$TOKEN" 'balanceOf(address)(uint256)' "$DEPLOYER" --rpc-url "$RPC_URL" | awk '{print $1}')
if ! $KEEP_TOKEN && [[ -z "${REVE_TOKEN:-}" && "$SUPPLY_HELD" != "0" ]]; then
  step "send the deployer's $(cast from-wei "$SUPPLY_HELD") \$RECURVE to the treasury" "$DEPLOYER_KEY" "$TOKEN" 'transfer(address,uint256)' "$TREASURY" "$SUPPLY_HELD"
fi
if [[ "$(cast call "$REGISTRY" 'owner()(address)' --rpc-url "$RPC_URL")" == "$DEPLOYER" ]]; then
  step "hand WatcherRegistry ownership to the treasury" "$DEPLOYER_KEY" "$REGISTRY" 'transferOwnership(address)' "$TREASURY"
fi
if [[ "$(cast call "$GOVERNOR" 'agentAdmin()(address)' --rpc-url "$RPC_URL")" != "$TREASURY" ]]; then
  step "make the treasury the governor's agentAdmin (signed by the agent)" "$AGENT_KEY" "$GOVERNOR" 'setAgentAdmin(address)' "$TREASURY"
fi

echo
echo "registry owner:  $(cast call "$REGISTRY" 'owner()(address)' --rpc-url "$RPC_URL")"
echo "agentAdmin:      $(cast call "$GOVERNOR" 'agentAdmin()(address)' --rpc-url "$RPC_URL")"
echo "treasury token:  $(cast call "$TOKEN" 'balanceOf(address)(uint256)' "$TREASURY" --rpc-url "$RPC_URL")"
$SEND || echo "Nothing sent. ./handover.sh --broadcast sends it."
