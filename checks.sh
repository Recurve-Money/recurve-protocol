# Sourced by deploy-mainnet.sh and handover.sh. What both must be sure of before
# anything irreversible is signed: that TREASURY is the Safe and nothing else.

# same_address <a> <b>: addresses compare whatever their case. (No ${x,,}: macOS ships bash 3.)
same_address() { [[ "$(printf '%s' "$1" | tr 'A-F' 'a-f')" == "$(printf '%s' "$2" | tr 'A-F' 'a-f')" ]]; }

# check_treasury <deployer address> <agent address>
# Stops unless TREASURY is a well-formed address with a Safe behind it that is
# neither of the two keys. The governor's fee recipient is fixed at deploy and
# ownership handed to a wrong address cannot be taken back.
check_treasury() {
  local deployer="$1" agent="$2" sum
  sum=$(cast to-check-sum-address "${TREASURY:-}" 2>/dev/null) \
    || { echo "TREASURY in mainnet.env is not an address: ${TREASURY:-<empty>}"; exit 1; }
  TREASURY="$sum"
  [[ "$TREASURY" != "0x0000000000000000000000000000000000000000" ]] \
    || { echo "TREASURY is the zero address."; exit 1; }
  if same_address "$TREASURY" "$deployer" || same_address "$TREASURY" "$agent"; then
    echo "TREASURY is the deployer or the agent. It has to be the Safe."; exit 1
  fi
  # A read that fails must stop this, not pass it: an empty answer is not "has code".
  local code threshold
  code=$(cast code "$TREASURY" --rpc-url "$RPC_URL") \
    || { echo "Could not read the code at TREASURY $TREASURY from $RPC_URL."; exit 1; }
  [[ -n "$code" && "$code" != "0x" ]] \
    || { echo "TREASURY $TREASURY has no contract behind it on this chain. A Safe is a contract: check the address and the network."; exit 1; }
  threshold=$(cast call "$TREASURY" 'getThreshold()(uint256)' --rpc-url "$RPC_URL" 2>/dev/null) || threshold=""
  [[ "$threshold" =~ ^[1-9][0-9]* ]] \
    || { echo "TREASURY $TREASURY is a contract, but it does not answer as a Safe does (getThreshold). Check the address."; exit 1; }
}

# is_address <value>
is_address() { [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]; }
