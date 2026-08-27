LATEST=$(cast block-number --rpc-url https://rpc.mainnet.chain.robinhood.com)
echo "Текущий tip: $LATEST"
PINNED=$((LATEST - 200))
echo "Форкаем на: $PINNED"
