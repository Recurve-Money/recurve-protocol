for FEE in 100 500 3000 10000; do
  echo "=== fee $FEE ==="
  cast call 0x1f7d7550b1b028f7571e69a784071f0205fd2efa \
    "getPool(address,address,uint24)(address)" \
    0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73 \
    0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC \
    $FEE \
    --rpc-url http://127.0.0.1:8545
done
