#!/usr/bin/env bash
# Deploys Recurve to Robinhood Chain mainnet in one run (script/DeployMainnet.s.sol):
# $RECURVE, the watcher registry, the vault, the governor and the NVDA strategy.
#
#   ./deploy-mainnet.sh              simulate against mainnet; sends nothing
#   ./deploy-mainnet.sh --broadcast  deploy for real, then write the addresses
#
# Settings: mainnet.env (or ENV_FILE). Keys: $KEYS (default ~/.config/recurve):
# deployer.key pays and becomes the vault's deployer and the registry's owner;
# agent.address is registered as the agent.
set -euo pipefail
cd "$(dirname "$0")"
set -a; source "${ENV_FILE:-./mainnet.env}"; set +a
KEYS="${KEYS:-$HOME/.config/recurve}"
BROADCAST=""; [[ "${1:-}" == "--broadcast" ]] && BROADCAST="--broadcast"

chain=$(cast chain-id --rpc-url "$RPC_URL")
[[ "$chain" == "4663" ]] || { echo "RPC_URL answers chain $chain, not 4663 (Robinhood Chain mainnet)."; exit 1; }
[[ -n "${TREASURY:-}" ]] || { echo "Set TREASURY in mainnet.env: the Safe that receives the fees."; exit 1; }

PRIVATE_KEY="$(cat "$KEYS/deployer.key")"; export PRIVATE_KEY
AGENT="$(cat "$KEYS/agent.address")"; export AGENT
DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY")
BAL=$(cast balance "$DEPLOYER" --rpc-url "$RPC_URL")
echo "deployer  $DEPLOYER  ($(cast from-wei "$BAL") ETH)"
echo "agent     $AGENT"
echo "treasury  $TREASURY"
echo "fund      $(cast call "$VAULT_ASSET" 'symbol()(string)' --rpc-url "$RPC_URL"), deposit cap $DEPOSIT_CAP"
echo "\$RECURVE  ${REVE_TOKEN:-new token, 1B minted to the deployer}"
echo

if [[ -n "$BROADCAST" ]]; then
  # The whole deploy burns ~7.2M gas, ~0.00015 ETH at 0.02 gwei (2026-10-31),
  # but each transaction must be covered at forge's gas limit and doubled fee
  # cap when it is sent, so start from 0.0004.
  python3 -c "import sys; sys.exit(0 if int('$BAL') >= 4 * 10**14 else 1)" \
    || { echo "Fund the deployer with at least 0.0004 ETH on Robinhood Chain first."; exit 1; }
fi

forge script script/DeployMainnet.s.sol --rpc-url "$RPC_URL" $BROADCAST

if [[ -z "$BROADCAST" ]]; then
  echo
  echo "Simulation only: nothing was sent. ./deploy-mainnet.sh --broadcast deploys."
  exit 0
fi
python3 write-addresses.py
