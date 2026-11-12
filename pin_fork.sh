LATEST=$(cast block-number --rpc-url https://rpc.mainnet.chain.robinhood.com)
echo "Current tip: $LATEST"
PINNED=$((LATEST - 200))
echo "Forking at: $PINNED"
