# CHOMPZ Contract

CHOMPZ is an on-chain swap execution contract repository for Robinhood Chain mainnet.

This repository is focused on the Solidity contract, deployed contract configuration, adapter wiring, and direct on-chain execution. There is no web application layer.

## Core Contract

The CHOMPZ router executes modular fungible-token swap routes through registered venue adapters.

Primary execution entry point:

```solidity
swapModular(...)
```

Each route is composed of one or more execution legs. A leg defines the venue, token path, adapter, pool parameters, and execution constraints required by the router.

Route construction happens externally; validation and settlement are performed against the deployed contracts.

## Contract Architecture

```text
contracts/
├── core router
├── adapters
├── interfaces
└── libraries
```

The router delegates venue-specific execution to registered adapters.

Supported adapter parameter formats in the included execution tooling:

- **V2** — empty `poolParams`
- **V3** — `abi.encode(uint24 fee)`
- **V4** — `abi.encode(uint24 fee, int24 tickSpacing, address hooks)`

Additional venues must use the exact encoding expected by their registered adapter.

## Deployed Contracts

Public network and deployed contract addresses are maintained in:

```text
config/contracts.json
```

Always verify these addresses against the intended deployment before executing a mainnet transaction.

The deployed router keeps its original Solidity contract identifier where required for source and deployment compatibility. **CHOMPZ** is the repository and execution-layer name.

## Verify Contract State

Install dependencies and inspect the deployed contracts:

```bash
npm ci
npm run status
```

The status command verifies:

- chain ID
- router bytecode
- router pause state
- router fee configuration
- WETH configuration
- registered V2, V3, and V4 adapters
- configured CHOMPZ NFT collection contract

Validate Solidity source with Foundry:

```bash
forge build
forge test
```

## Execute the Contract

### 1. Approve ERC-20 input

ERC-20 input tokens must have sufficient allowance for the router.

Set local execution values:

```bash
PRIVATE_KEY=0x...
TOKEN=0x...
AMOUNT=...
```

Then run:

```bash
npm run approve
```

The command resolves token decimals, simulates the approval, and broadcasts only after successful simulation.

Native ETH input does not require ERC-20 approval.

### 2. Build a `swapModular` route

Create a local route file from the supplied execution schema:

```bash
cp examples/route.example.json route.json
```

`amountInRaw` and `amountOutMinRaw` must be integer base-unit values.

For every route leg, verify the venue, adapter, token path, pool parameters, and recipient before signing.

### 3. Simulate and execute

Set:

```bash
ROUTE_FILE=./route.json
PRIVATE_KEY=0x...
```

Execute:

```bash
npm run execute
```

Before broadcasting, the execution layer:

1. validates contract addresses and raw token amounts;
2. reads the registered adapter for each venue directly from the live router;
3. rejects an adapter address that does not match the router's current configuration;
4. encodes venue-specific pool parameters;
5. validates route continuity;
6. checks ERC-20 allowance when required;
7. simulates the complete `swapModular` call against current chain state;
8. broadcasts only after simulation succeeds.

## NFT Contract

The CHOMPZ ERC-721 collection is maintained as a separate deployed contract target in:

```text
config/contracts.json
```

Inspect the collection contract:

```bash
npm run nft
```

Inspect a specific token:

```bash
TOKEN_ID=123 npm run nft
```

The current `swapModular` router is designed for fungible-token execution. The ERC-721 collection is intentionally not represented as a fungible swap leg.

NFT exchange or settlement should be implemented through a dedicated audited contract with explicit ERC-721 authorization, transfer, settlement, and reentrancy protections.

## Contract Configuration

Create local execution configuration with:

```bash
cp .env.example .env
```

Configuration is separated into:

```text
config/contracts.json   Public chain and deployed contract addresses
.env                    Local RPC and execution credentials
```

Never commit `.env`.

## Contract Repository

```text
contracts/              Solidity contract source
config/contracts.json   Deployed addresses and chain configuration
lib/                    Contract ABIs and shared chain configuration
scripts/status.mjs      Read and verify deployed contract state
scripts/approve.mjs     Execute ERC-20 approval
scripts/execute.mjs     Simulate and execute swapModular
scripts/nft.mjs         Read the configured ERC-721 contract
examples/               Contract execution route schema
foundry.toml            Foundry configuration
SECURITY.md             Contract execution security policy
```

## Security

Mainnet contract execution is irreversible.

Before signing, independently verify the chain ID, router, adapters, token addresses, amounts, minimum output, recipient, allowance, route ordering, and pool parameters.

Simulation reduces execution mistakes but does not replace source review, route verification, testing, or an independent security audit.

Never commit private keys, seed phrases, `.env` files, authenticated RPC credentials, or funded production secrets.

See `SECURITY.md` for the repository security policy.
