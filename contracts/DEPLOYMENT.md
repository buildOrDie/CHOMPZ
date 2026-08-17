# Contract deployment order

Robinhood Chain mainnet:

- Chain ID: `4663`
- WETH: `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`
- V2 router recovered from adapter bytecode: `0x89e5dB8B5aa49AA85AC63f691524311AEB649eBa`
- V3 router recovered from adapter bytecode: `0xcaF681a66D020601342297493863e78C959e5cB2`
- Permit2: `0x000000000022D473030F116dDEE9F6B43aC78BA3`
- V4 Universal Router recovered from adapter bytecode: `0x8876789976DEcbfcBBbe364623c63652db8c0904`

## Deploy adapters

```bash
forge create contracts/adapters/UniV2Adapter.sol:UniV2Adapter \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" \
  --constructor-args 0x89e5dB8B5aa49AA85AC63f691524311AEB649eBa

forge create contracts/adapters/UniV3Adapter.sol:UniV3Adapter \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" \
  --constructor-args 0xcaF681a66D020601342297493863e78C959e5cB2

forge create contracts/adapters/UniV4Adapter.sol:UniV4Adapter \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" \
  --constructor-args \
    0x000000000022D473030F116dDEE9F6B43aC78BA3 \
    0x8876789976DEcbfcBBbe364623c63652db8c0904 \
    0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73
```

## Deploy core

```bash
forge create contracts/CHOMPZRouterV2.sol:CHOMPZRouterV2 \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" \
  --constructor-args \
    0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73 \
    "$FEE_VAULT" \
    10
```

## Register adapters

```bash
cast send "$CHOMPZ_ROUTER" "setVenueAdapter(uint8,address)" 2 "$V2_ADAPTER" --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY"
cast send "$CHOMPZ_ROUTER" "setVenueAdapter(uint8,address)" 3 "$V3_ADAPTER" --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY"
cast send "$CHOMPZ_ROUTER" "setVenueAdapter(uint8,address)" 4 "$V4_ADAPTER" --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY"
```

The legacy `swap`, `swapMultiHop`, and `swapSplit` paths additionally require `approveRouter(address)` for each downstream router. Do not approve arbitrary-command routers through that legacy allowlist.


## Fee-free launch

Deploy the core router with constructor `_feeBps = 0`, or call `setFeeBps(0)` from the owner on an existing deployment. Execution tooling should read and verify the live `feeBps` value before relying on a fee assumption.
