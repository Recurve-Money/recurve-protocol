echo "=== fee 500 liquidity ==="
cast call 0x62AB521f71431f78ac374CdbadC6cda3c8916b6C "liquidity()(uint128)" --rpc-url http://127.0.0.1:8545
echo "=== fee 3000 liquidity ==="
cast call 0xC0Be1cb0f674D9737C72B2A63fC542361185b807 "liquidity()(uint128)" --rpc-url http://127.0.0.1:8545
echo "=== fee 10000 liquidity ==="
cast call 0x8b6a6416A5d1040EfCfa6234dA6AA1265DfE123e "liquidity()(uint128)" --rpc-url http://127.0.0.1:8545
